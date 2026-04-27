// swift-tools-version: 6.2
import PackageDescription

// JXLSwift — a pure-Swift implementation of JPEG XL (ISO/IEC 18181).
// No native code, no C dependency. The codec is implemented in Swift
// targeting the strict-concurrency model of Swift 6.2.
//
// Status: foundation only. See ROADMAP.md for what's done vs. WIP.

let package = Package(
    name: "JXLSwift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "JXLSwift", targets: ["JXLSwift"]),
        .executable(name: "jxl-tool", targets: ["JXLTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "JXLSwift",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "JXLTool",
            dependencies: [
                "JXLSwift",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "JXLSwiftTests",
            dependencies: ["JXLSwift"]
        ),
    ]
)
