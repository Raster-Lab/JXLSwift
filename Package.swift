// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

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
        // Main compression library
        .library(
            name: "JXLSwift",
            targets: ["JXLSwift"]),
    ],
    dependencies: [],
    targets: [
        // Core compression codec
        .target(
            name: "JXLSwift",
            dependencies: [],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        
        // Tests
        .testTarget(
            name: "JXLSwiftTests",
            dependencies: ["JXLSwift"]
        ),
    ]
)
