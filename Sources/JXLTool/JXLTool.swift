// jxl-tool — front-end CLI for the pure-Swift JXLSwift implementation.
//
// STATUS: foundation only. `info` works (parses container + SizeHeader).
// `encode`/`decode` throw "not yet implemented" — see ROADMAP.md.

import ArgumentParser

@main
struct JXLTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jxl-tool",
        abstract: "JPEG XL inspect/encode/decode (pure Swift, ISO/IEC 18181).",
        version: "jxl \(JXLToolVersion) (pure-Swift, foundation only — see ROADMAP.md)",
        subcommands: [
            // Core codec subcommands.
            Info.self, Encode.self, Decode.self,
            // Project-internal placeholder (M0 lossless vertical slice).
            EncodeM0.self, DecodeM0.self,
            // Performance.
            Benchmark.self,
            // Family-parity stubs (mirror J2KSwift's `j2k`).
            Version.self, Compare.self, Completions.self, Validate.self,
        ]
    )
}

let JXLToolVersion = "0.5.0-pure-swift"

enum JXLExitCode: Int32, Error {
    case generalError = 1
    case invalidArguments = 2
    case notImplemented = 64
}
