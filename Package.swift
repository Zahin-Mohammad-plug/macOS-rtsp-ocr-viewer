// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SharpStream",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SharpStream",
            targets: ["SharpStream"]),
    ],
    dependencies: [
        // OpenCV via SPM (when available)
        // .package(url: "https://github.com/opencv/opencv-swift", from: "1.0.0"),
        
        // MPVKit via SPM (when available)
        // .package(url: "https://github.com/mpv-player/mpv", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SharpStream",
            dependencies: []),
    ]
)
