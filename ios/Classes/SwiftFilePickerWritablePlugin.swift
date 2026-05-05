#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import Cocoa
import FlutterMacOS
#endif
import UniformTypeIdentifiers

enum FilePickerError: Error {
  case readError(message: String)
  case invalidArguments(message: String)
  case noViewController
}

public class SwiftFilePickerWritablePlugin: NSObject, FlutterPlugin {
  private var _viewController: UIViewController {
    get throws {
      guard let vc = UIApplication.shared.delegate?.window??.rootViewController else {
        throw FilePickerError.noViewController
      }
      return vc
    }
  }

  private let _channel: FlutterMethodChannel
  private var _filePickerResult: FlutterResult?
  private var _filePickerPath: String?
  private var isInitialized = false
  private var _initOpen: (url: URL, persistable: Bool)?
  private var _eventSink: FlutterEventSink?
  private var _eventQueue: [[String: String]] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    _ = SwiftFilePickerWritablePlugin(registrar: registrar)
  }

  public init(registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "design.codeux.file_picker_writable", binaryMessenger: registrar.messenger())
    _channel = channel

    super.init()

    registrar.addMethodCallDelegate(self, channel: channel)
    registrar.addApplicationDelegate(self)
    registrar.addSceneDelegate(self)

    let eventChannel = FlutterEventChannel(name: "design.codeux.file_picker_writable/events", binaryMessenger: registrar.messenger())
    eventChannel.setStreamHandler(self)

    #if os(macOS)
    NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleEvent(_:with:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    #endif
  }

  deinit {
    #if os(macOS)
    NSAppleEventManager.shared().removeEventHandler(forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    #endif
  }

  #if os(macOS)
  @objc
  private func handleEvent(_ event: NSAppleEventDescriptor, with replyEvent: NSAppleEventDescriptor) {
    print("Got event. \(event)")
    guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
    guard let url = URL(string: urlString) else { return }
    print(url)
    channel.invokeMethod("handleUri", arguments: url.absoluteString)
  }
  #endif


  private func logDebug(_ message: String) {
    print("DEBUG", "FilePickerWritablePlugin:", message)
    sendEvent(event: ["type": "log", "level": "DEBUG", "message": message])
  }

  private func logError(_ message: String) {
    print("ERROR", "FilePickerWritablePlugin:", message)
    sendEvent(event: ["type": "log", "level": "ERROR", "message": message])
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "init":
        isInitialized = true
        if let (openUrl, persistable) = _initOpen {
          _handleUrl(url: openUrl, persistable: persistable)
          _initOpen = nil
        }
        result(true)
      case "openFilePicker":
        try openFilePicker(result: result)
      case "openFilePickerForCreate":
        guard
          let args = call.arguments as? [String: Any],
          let path = args["path"] as? String
        else {
          throw FilePickerError.invalidArguments(message: "Expected 'args'")
        }
        try openFilePickerForCreate(path: path, result: result)
      case "isDirectoryAccessSupported":
        result(true)
      case "openDirectoryPicker":
        guard let args = call.arguments as? [String: Any] else {
          throw FilePickerError.invalidArguments(message: "Expected 'args'")
        }
        try openDirectoryPicker(result: result, initialDirUrl: args["initialDirUri"] as? String)
      case "readFileWithIdentifier":
        guard
          let args = call.arguments as? [String: Any],
          let identifier = args["identifier"] as? String
        else {
          throw FilePickerError.invalidArguments(message: "Expected 'identifier'")
        }
        try readFile(identifier: identifier, result: result)
      case "getDirectory":
        guard
          let args = call.arguments as? [String: Any],
          let rootIdentifier = args["rootIdentifier"] as? String,
          let fileIdentifier = args["fileIdentifier"] as? String
        else {
          throw FilePickerError.invalidArguments(message: "Expected 'rootIdentifier' and 'fileIdentifier'")
        }
        try getDirectory(rootIdentifier: rootIdentifier, fileIdentifier: fileIdentifier, result: result)
      case "resolveRelativePath":
        guard
          let args = call.arguments as? [String: Any],
          let directoryIdentifier = args["directoryIdentifier"] as? String,
          let relativePath = args["relativePath"] as? String
        else {
          throw FilePickerError.invalidArguments(message: "Expected 'directoryIdentifier' and 'relativePath'")
        }
        try resolveRelativePath(directoryIdentifier: directoryIdentifier, relativePath: relativePath, result: result)
      case "writeFileWithIdentifier":
        guard let args = call.arguments as? [String: Any],
              let identifier = args["identifier"] as? String,
              let path = args["path"] as? String
        else {
          throw FilePickerError.invalidArguments(message: "Expected 'identifier' and 'path' arguments.")
        }
        try writeFile(identifier: identifier, path: path, result: result)
      case "disposeIdentifier", "disposeAllIdentifiers":
        // iOS doesn't have a concept of disposing identifiers (bookmarks)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch let error as FilePickerError {
      result(FlutterError(code: "FilePickerError", message: "\(error)", details: nil))
    } catch {
      result(FlutterError(code: "UnknownError", message: "\(error)", details: nil))
    }
  }

  func readFile(identifier: String, result: @escaping FlutterResult) throws {
    guard let bookmark = Data(base64Encoded: identifier) else {
      result(FlutterError(code: "InvalidDataError", message: "Unable to decode bookmark.", details: nil))
      return
    }
    var isStale = false
    let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
    logDebug("url: \(url) / isStale: \(isStale)")
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let securityScope = url.startAccessingSecurityScopedResource()
      defer {
        if securityScope {
          url.stopAccessingSecurityScopedResource()
        }
      }
      if !securityScope {
        logDebug("Warning: startAccessingSecurityScopedResource is false for \(url).")
      }
      do {
        let copiedFile = try _copyToTempDirectory(url: url)
        DispatchQueue.main.async { [self] in
          result(_fileInfoResult(tempFile: copiedFile, originalURL: url, bookmark: bookmark))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "UnknownError", message: "\(error)", details: nil))
        }
      }
    }
  }

  func getDirectory(rootIdentifier: String, fileIdentifier: String, result: @escaping FlutterResult) throws {
    // In principle these URLs could be opaque like on Android, in which
    // case this analysis would not work. But it seems that URLs even for
    // cloud-based content providers are always file:// (tested with iCloud
    // Drive, Google Drive, Dropbox, FileBrowser)
    guard let rootUrl = restoreUrl(from: rootIdentifier) else {
      result(FlutterError(code: "InvalidDataError", message: "Unable to decode root bookmark.", details: nil))
      return
    }
    guard let fileUrl = restoreUrl(from: fileIdentifier) else {
      result(FlutterError(code: "InvalidDataError", message: "Unable to decode file bookmark.", details: nil))
      return
    }
    guard fileUrl.absoluteString.starts(with: rootUrl.absoluteString) else {
      result(FlutterError(code: "InvalidArguments", message: "The supplied file \(fileUrl) is not a child of \(rootUrl)", details: nil))
      return
    }
    let securityScope = rootUrl.startAccessingSecurityScopedResource()
    defer {
      if securityScope {
        rootUrl.stopAccessingSecurityScopedResource()
      }
    }
    let dirUrl = fileUrl.deletingLastPathComponent()
    result([
      "identifier": try dirUrl.bookmarkData().base64EncodedString(),
      "persistable": "true",
      "uri": dirUrl.absoluteString,
      "fileName": dirUrl.lastPathComponent,
    ])
  }

  func resolveRelativePath(directoryIdentifier: String, relativePath: String, result: @escaping FlutterResult) throws {
    guard let url = restoreUrl(from: directoryIdentifier) else {
      result(FlutterError(code: "InvalidDataError", message: "Unable to restore URL from identifier.", details: nil))
      return
    }
    let childUrl = url.appendingPathComponent(relativePath).standardized
    logDebug("Resolved to \(childUrl)")
    DispatchQueue.global(qos: .userInitiated).async {
      var coordError: NSError? = nil
      var bookmarkError: Error? = nil
      var identifier: String? = nil
      // Coordinate reading the item here because it might be a
      // not-yet-downloaded file, in which case we can't get a bookmark for
      // it--bookmarkData() fails with a "file doesn't exist" error
      NSFileCoordinator().coordinate(readingItemAt: childUrl, error: &coordError) { url in
        do {
          identifier = try childUrl.bookmarkData().base64EncodedString()
        } catch let error {
          bookmarkError = error
        }
      }
      DispatchQueue.main.async { [self] in
        if let error = coordError ?? bookmarkError {
          result(FlutterError(code: "UnknownError", message: "\(error)", details: nil))
        }
        result([
          "identifier": identifier,
          "persistable": "true",
          "uri": childUrl.absoluteString,
          "fileName": childUrl.lastPathComponent,
          "isDirectory": "\(isDirectory(childUrl))",
        ])
      }
    }
  }

  func writeFile(identifier: String, path: String, result: @escaping FlutterResult) throws {
    guard let bookmark = Data(base64Encoded: identifier) else {
      throw FilePickerError.invalidArguments(message: "Unable to decode bookmark/identifier.")
    }
    var isStale = false
    let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
    logDebug("url: \(url) / isStale: \(isStale)")
    try _writeFile(path: path, destination: url)
    let sourceFile = URL(fileURLWithPath: path)
    result(_fileInfoResult(tempFile: sourceFile, originalURL: url, bookmark: bookmark))
  }

  // TODO: skipDestinationStartAccess is not doing anything right now. maybe get rid of it.
  private func _writeFile(path: String, destination: URL, skipDestinationStartAccess: Bool = false) throws {
    let sourceFile = URL(fileURLWithPath: path)

    let destAccess = destination.startAccessingSecurityScopedResource()
    if !destAccess {
      logDebug("Warning: startAccessingSecurityScopedResource is false for \(destination) (destination); skipDestinationStartAccess=\(skipDestinationStartAccess)")
//            throw FilePickerError.invalidArguments(message: "Unable to access original url \(destination)")
    }
    let sourceAccess = sourceFile.startAccessingSecurityScopedResource()
    if !sourceAccess {
      logDebug("Warning: startAccessingSecurityScopedResource is false for \(sourceFile) (sourceFile)")
//            throw FilePickerError.readError(message: "Unable to access source file \(sourceFile)")
    }
    defer {
      if destAccess {
        destination.stopAccessingSecurityScopedResource()
      }
      if sourceAccess {
        sourceFile.stopAccessingSecurityScopedResource()
      }
    }
    let data = try Data(contentsOf: sourceFile)
    try data.write(to: destination, options: .atomicWrite)
  }

  func openFilePickerForCreate(path: String, result: @escaping FlutterResult) throws {
    if _filePickerResult != nil {
      result(FlutterError(code: "DuplicatedCall", message: "Only one file open call at a time.", details: nil))
      return
    }
    _filePickerResult = result
    _filePickerPath = path
    let ctrl = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
  //        let ctrl = UIDocumentPickerViewController(documentTypes: [kUTTypeFolder as String], in: UIDocumentPickerMode.open)
    ctrl.delegate = self
    ctrl.modalPresentationStyle = .currentContext
    try _viewController.present(ctrl, animated: true, completion: nil)
  }

  func openFilePicker(result: @escaping FlutterResult) throws {
    if _filePickerResult != nil {
      result(FlutterError(code: "DuplicatedCall", message: "Only one file open call at a time.", details: nil))
      return
    }
    _filePickerResult = result
    _filePickerPath = nil
    let ctrl = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
    //        let ctrl = UIDocumentPickerViewController(documentTypes: [kUTTypeItem as String], in: UIDocumentPickerMode.open)
    ctrl.delegate = self
    ctrl.modalPresentationStyle = .currentContext
    try _viewController.present(ctrl, animated: true, completion: nil)
  }

  func openDirectoryPicker(result: @escaping FlutterResult, initialDirUrl: String?) throws {
    if _filePickerResult != nil {
      result(FlutterError(code: "DuplicatedCall", message: "Only one file open call at a time.", details: nil))
      return
    }
    _filePickerResult = result
    _filePickerPath = nil
    let ctrl = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    //        let ctrl = UIDocumentPickerViewController(documentTypes: [kUTTypeFolder as String], in: .open)
    ctrl.delegate = self
    if #available(iOS 13.0, *) {
      if let initialDirUrl = initialDirUrl {
        ctrl.directoryURL = URL(string: initialDirUrl)
      }
    }
    ctrl.modalPresentationStyle = .currentContext
    try _viewController.present(ctrl, animated: true, completion: nil)
  }

  private func _copyToTempDirectory(url: URL) throws -> URL {
    let tempDir = NSURL.fileURL(withPath: NSTemporaryDirectory(), isDirectory: true)
    let tempFile = tempDir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
    // Copy the file with coordination to ensure e.g. cloud documents are
    // downloaded or updated with the latest content
    var coordError: NSError? = nil
    var copyError: Error? = nil
    NSFileCoordinator().coordinate(readingItemAt: url, error: &coordError) { url in
      do {
        // This is the best, safest place to do the copy
        try FileManager.default.copyItem(at: url, to: tempFile)
      } catch {
        copyError = error
      }
    }
    if let coordError = coordError {
      logDebug("Error coordinating access to \(url): \(coordError)")
      copyError = nil
      // Try again without coordination because e.g. if the device is
      // offline and the content provider is cloud-based then the
      // coordination will fail but we might still be able to access a
      // cached copy of the file
      do {
        try FileManager.default.copyItem(at: url, to: tempFile)
      } catch {
        copyError = error
      }
    }
    if let copyError = copyError {
      NSLog("Unable to copy file: \(copyError)")
      throw copyError
    }
    return tempFile
  }

  private func _prepareUrlForReading(url: URL, persistable: Bool) throws -> [String: String] {
    let securityScope = url.startAccessingSecurityScopedResource()
    defer {
      if securityScope {
        url.stopAccessingSecurityScopedResource()
      }
    }
    if !securityScope {
      logDebug("Warning: startAccessingSecurityScopedResource is false for \(url)")
    }
    let tempFile = try _copyToTempDirectory(url: url)
    // Get bookmark *after* ensuring file has been materialized to local device!
    let bookmark = try url.bookmarkData()
    return _fileInfoResult(tempFile: tempFile, originalURL: url, bookmark: bookmark, persistable: persistable)
  }

  private func _prepareDirUrlForReading(url: URL) throws -> [String: String] {
    let securityScope = url.startAccessingSecurityScopedResource()
    defer {
      if securityScope {
        url.stopAccessingSecurityScopedResource()
      }
    }
    if !securityScope {
      logDebug("Warning: startAccessingSecurityScopedResource is false for \(url)")
    }
    let bookmark = try url.bookmarkData()
    return [
      "identifier": bookmark.base64EncodedString(),
      "persistable": "true",
      "uri": url.absoluteString,
      "fileName": url.lastPathComponent,
    ]
  }

  private func _fileInfoResult(tempFile: URL, originalURL: URL, bookmark: Data, persistable: Bool = true) -> [String: String] {
    let identifier = bookmark.base64EncodedString()
    return [
      "path": tempFile.path,
      "identifier": identifier,
      "persistable": "\(persistable)",
      "uri": originalURL.absoluteString,
      "fileName": originalURL.lastPathComponent,
    ]
  }

  private func _sendFilePickerResult(_ result: Any?) {
    DispatchQueue.main.async { [self] in
      if let _result = _filePickerResult {
        _result(result)
      }
      _filePickerResult = nil
    }
  }
}

extension SwiftFilePickerWritablePlugin: UIDocumentPickerDelegate {

  public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      do {
        if let path = _filePickerPath {
          _filePickerPath = nil
          guard url.startAccessingSecurityScopedResource() else {
            throw FilePickerError.readError(message: "Unable to acquire acces to \(url)")
          }
          logDebug("Need to write \(path) to \(url)")
          let sourceFile = URL(fileURLWithPath: path)
          let targetFile = url.appendingPathComponent(sourceFile.lastPathComponent)
          //                  if !targetFile.startAccessingSecurityScopedResource() {
          //                      logDebug("Warning: Unnable to acquire acces to \(targetFile)")
          //                  }
          //                  defer {
          //                      targetFile.stopAccessingSecurityScopedResource()
          //                  }
          try _writeFile(path: path, destination: targetFile, skipDestinationStartAccess: true)

          let tempFile = try _copyToTempDirectory(url: targetFile)
          // Get bookmark *after* ensuring file has been created!
          let bookmark = try targetFile.bookmarkData()
          _sendFilePickerResult(_fileInfoResult(tempFile: tempFile, originalURL: targetFile, bookmark: bookmark))
          return
        }
        if isDirectory(url) {
          try _sendFilePickerResult(_prepareDirUrlForReading(url: url))
        } else {
          try _sendFilePickerResult(_prepareUrlForReading(url: url, persistable: true))
        }
      } catch {
        _sendFilePickerResult(FlutterError(code: "ErrorProcessingResult", message: "Error handling result url \(url): \(error)", details: nil))
        return
      }
    }
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    _sendFilePickerResult(nil)
  }

  private func isDirectory(_ url: URL) -> Bool {
    if #available(iOS 9.0, *) {
      return url.hasDirectoryPath
    } else if let resVals = try? url.resourceValues(forKeys: [.isDirectoryKey]),
      let isDir = resVals.isDirectory
    {
      return isDir
    } else {
      return false
    }
  }

  private func restoreUrl(from identifier: String) -> URL? {
    guard let bookmark = Data(base64Encoded: identifier) else {
      return nil
    }
    var isStale: Bool = false
    guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) else {
      return nil
    }
    logDebug("url: \(url) / isStale: \(isStale)")
    return url
  }
}

// application delegate methods..
extension SwiftFilePickerWritablePlugin: FlutterApplicationLifeCycleDelegate, FlutterSceneLifeCycleDelegate {
  public func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    logDebug("Opening URL \(url) - options: \(options)")
    let persistable: Bool
    if #available(iOS 9.0, *) {
      // Will be true for files received by "Open in", false for "Copy to"
      persistable = options[.openInPlace] as? Bool ?? false
    } else {
      // Prior to iOS 9.0 files must not be openable in-place?
      persistable = false
    }
    return _handle(url: url, persistable: persistable)
  }

  public func application(_ application: UIApplication, handleOpen url: URL) -> Bool {
    logDebug("handleOpen for \(url)")
    // This is an old API predating open-in-place support(?)
    return _handle(url: url, persistable: false)
  }

  // This plugin should NOT handle this kind of link
  // public func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([Any]) -> Void) -> Bool {
  //     // (handle universal links)
  //     // Get URL components from the incoming user activity
  //     guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
  //         let incomingURL = userActivity.webpageURL else {
  //             logDebug("Unsupported user activity. \(userActivity)")
  //             return false
  //     }
  //     logDebug("continue userActivity webpageURL: \(incomingURL)")
  //     // TODO: Confirm that persistable should be true here
  //     return _handle(url: incomingURL, persistable: true)
  // }

  public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions?) -> Bool {
    logDebug("scene will connect with \(connectionOptions?.urlContexts.count ?? 0) URLContexts")
    var handled = false
    if let urlContexts = connectionOptions?.urlContexts {
      for context in urlContexts {
        logDebug("attempting to handle \(context.url)")
        handled = _handle(url: context.url, persistable: context.options.openInPlace) || handled
      }
    }
    return handled
  }

  public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    var handled = false
    logDebug("openURLContexts for \(URLContexts.count) items")
    for context in URLContexts {
      logDebug("attempting to handle \(context.url)")
      handled = _handle(url: context.url, persistable: context.options.openInPlace) || handled
    }
    return handled
  }

  private func _handle(url: URL, persistable: Bool) -> Bool {
//        if (!url.isFileURL) {
//            logDebug("url \(url) is not a file url. ignoring it for now.")
//            return false
//        }
    if !isInitialized {
      _initOpen = (url, persistable)
      return true
    }
    _handleUrl(url: url, persistable: persistable)
    return true
  }

  private func _handleUrl(url: URL, persistable: Bool) {
    do {
      if url.isFileURL {
        try _channel.invokeMethod("openFile", arguments: _prepareUrlForReading(url: url, persistable: persistable)) { _ in
          guard !persistable else {
            // Persistable files don't need cleanup
            return
          }
          if self._isInboxFile(url) {
            do {
              try FileManager.default.removeItem(at: url)
            } catch {
              self.logError("Failed to delete inbox file \(url); error: \(error)")
            }
          } else {
            self.logError("Unexpected non-persistable file \(url)")
          }
        }
      } else {
        _channel.invokeMethod("handleUri", arguments: url.absoluteString)
      }
    } catch {
      logError("Error handling open url for \(url): \(error)")
      _channel.invokeMethod(
        "handleError",
        arguments: [
          "message": "Error while handling openUrl for isFileURL=\(url.isFileURL): \(error)",
        ])
    }
  }

  private func _isInboxFile(_ url: URL) -> Bool {
    let inboxes = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).map {
      $0.resolvingSymlinksInPath().appendingPathComponent("Inbox").absoluteString
    }
    let resolvedUrl = url.resolvingSymlinksInPath().absoluteString
    return inboxes.contains { resolvedUrl.starts(with: $0) }
  }
}

extension SwiftFilePickerWritablePlugin: FlutterStreamHandler {
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    _eventSink = events
    let queue = _eventQueue
    _eventQueue = []
    for item in queue {
      events(item)
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    _eventSink = nil
    return nil
  }

  private func sendEvent(event: [String: String]) {
    if let _eventSink = _eventSink {
      DispatchQueue.main.async {
        _eventSink(event)
      }
    } else {
      _eventQueue.append(event)
    }
  }
}
