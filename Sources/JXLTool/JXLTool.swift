// jxl-tool: command-line front-end for JXLSwift.

import ArgumentParser
import Cjxl
import Foundation

@main
struct JXLTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jxl-tool",
        abstract: "JPEG XL encode/decode/inspect via libjxl-backed JXLSwift.",
        version: jxlToolVersionString(),
        subcommands: [Encode.self, Decode.self, Info.self, Batch.self]
    )
}

enum JXLExitCode: Int32, Error {
    case generalError = 1
    case invalidArguments = 2
}

/// Version string printed by `jxl-tool --version`.
/// Reports both the Swift package version and the libjxl version so users
/// can debug compatibility issues with the underlying C library.
func jxlToolVersionString() -> String {
    let libjxlVer = JxlEncoderVersion()
    let major = (libjxlVer / 1_000_000) % 1000
    let minor = (libjxlVer / 1_000) % 1000
    let patch = libjxlVer % 1000
    return "jxl-tool \(JXLToolVersion)  (libjxl \(major).\(minor).\(patch))"
}

/// Bumped per release. Track in sync with CHANGELOG.md / git tags.
let JXLToolVersion = "0.4.0"
