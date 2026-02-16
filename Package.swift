// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// MARK: - Feature Flags

/// Enable the LibJXL reference backend (requires libjxl C library).
/// Pass `-Xswiftc -DJXL_ENABLE_LIBJXL` to enable.
let enableLibJXL = false

let package = Package(
    name: "JXLSwift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1)
    ],
    products: [
        // Main compression library (backend-agnostic public API)
        .library(
            name: "JXLSwift",
            targets: ["JXLSwift"]),
        // Command line tool
        .executable(
            name: "jxl-tool",
            targets: ["JXLTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Core compression codec (Native backend, always built)
        .target(
            name: "JXLSwift",
            dependencies: []
        ),
        
        // Command line tool
        .executableTarget(
            name: "JXLTool",
            dependencies: [
                "JXLSwift",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        
        // Tests
        .testTarget(
            name: "JXLSwiftTests",
            dependencies: ["JXLSwift"]
        ),
    ]
)
