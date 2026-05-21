// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "file_picker_writable",
    platforms: [
        .macOS("10.11")
    ],
    products: [
        .library(name: "file-picker-writable", targets: ["file_picker_writable"])
    ],
    dependencies: [
        .package(name: "FlutterMacOS", path: "../FlutterMacOS")
    ],
    targets: [
        .target(
            name: "file_picker_writable",
            dependencies: [
                .product(name: "FlutterMacOS", package: "FlutterMacOS")
            ]
        )
    ]
)
