// swift-tools-version: 6.2
import PackageDescription

// JXLSwift wraps libjxl (Homebrew jpeg-xl) via a C systemLibrary target.
// On macOS / Apple Silicon the headers and dylibs are at
//   /opt/homebrew/include/jxl/* and /opt/homebrew/lib/libjxl{,_threads}.dylib
// On Intel Macs, /usr/local/...
let homebrewIncludes = ["/opt/homebrew/include", "/usr/local/include"]
let homebrewLibs     = ["/opt/homebrew/lib",     "/usr/local/lib"]

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
        // C systemLibrary wrapping the Homebrew libjxl install. Uses
        // pkg-config to locate headers and libraries portably.
        .systemLibrary(
            name: "Cjxl",
            path: "Sources/Cjxl",
            pkgConfig: "libjxl"
        ),
        // Pure-Swift public API on top of Cjxl. The unsafeFlags here are
        // a fallback when pkg-config isn't installed — Homebrew's default
        // prefixes are passed explicitly so the headers and dylibs can
        // still be found.
        .target(
            name: "JXLSwift",
            dependencies: ["Cjxl"],
            swiftSettings: [
                .unsafeFlags(homebrewIncludes.flatMap { ["-I", $0] }),
            ],
            linkerSettings: [
                .unsafeFlags(homebrewLibs.flatMap { ["-L", $0] }),
                .linkedLibrary("jxl"),
                .linkedLibrary("jxl_threads"),
            ]
        ),
        // Command line tool.
        .executableTarget(
            name: "JXLTool",
            dependencies: [
                "JXLSwift",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Integration tests against LocalDatasets/medical-dicom-organized.
        .testTarget(
            name: "JXLSwiftTests",
            dependencies: ["JXLSwift"]
        ),
    ]
)
