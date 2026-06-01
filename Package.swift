// swift-tools-version: 6.2
import PackageDescription

// JXLSwift — a pure-Swift implementation of JPEG XL (ISO/IEC 18181).
// Swift-first (Swift 6.2, strict concurrency); the scalar Swift path is the
// always-correct source of truth. The `JXLPerfC` target is the optional C
// boundary for measured hot-path optimisations (CLAUDE.md constraint 1,
// amended 2026-05) — currently scaffolding only; functions added there must
// be byte-equivalent to a scalar Swift reference and gate-tested.
//
// Status: v1.0.1 production-ready lossless JPEG XL codec — medical-grade
// (DICOM + CID22 byte-exact via djxl), API frozen, Swift-first with the
// `JXLPerfC` boundary scaffolded for future C/C++ hot-path work.
// See CHANGELOG.md / ROADMAP.md.

// JXLSwift is fully self-contained: no shared-protocol package. The only
// dependency is swift-argument-parser, and that is CLI-only (the JXLSwift
// library target itself has zero external dependencies). This keeps
// JXLSwift trivially URL-consumable as a SwiftPM dependency — a consumer
// pulls one repo and nothing transitive. Type/method-name parity with
// J2KSwift is maintained by convention, not a shared protocol module.

let package = Package(
    name: "JXLSwift",
    // Apple platforms only — JXLSwift targets Apple silicon/Apple OSes
    // exclusively (no Linux/Windows deployment).
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
        // Family-parity alias: `jxl` (matches J2KSwift's `j2k`).
        // Same target as `jxl-tool`; SwiftPM produces two binaries
        // from the same source. See Documentation/FAMILY-API-PARITY.md.
        .executable(name: "jxl", targets: ["JXLTool"]),
    ],
    dependencies: [
        // CLI only — the JXLSwift library target has no dependencies.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Optional C boundary for measured hot-path primitives. The scalar
        // Swift implementation in `JXLSwift` remains the source of truth; the
        // C target is deletable without disturbing the core.
        .target(
            name: "JXLPerfC",
            path: "Sources/JXLPerfC",
            publicHeadersPath: "include"
        ),
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
            dependencies: [
                "JXLSwift",
                "JXLPerfC",
            ]
        ),
    ]
)
