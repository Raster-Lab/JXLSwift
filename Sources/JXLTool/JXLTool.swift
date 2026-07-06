// jxl — front-end CLI for the pure-Swift JXLSwift implementation.
//
// The canonical name is `jxl` (matches J2KSwift's `j2k`). The
// `jxl-tool` binary is also produced (legacy alias) by the second
// `.executable` product entry in Package.swift.
//
// STATUS: mature lossless codec. `info`, `encode` (lossless Modular +
// preview lossy VarDCT), `decode`, `transcode` (JPEG ⇄ JXL), `convert`,
// and `batch` all work; output is `djxl`-validated. See ROADMAP.md.

import ArgumentParser

@main
struct JXLTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jxl",
        abstract: "JPEG XL inspect/encode/decode/convert (pure Swift, ISO/IEC 18181).",
        version: "jxl \(JXLToolVersion) (pure-Swift JPEG XL, ISO/IEC 18181)",
        subcommands: [
            // Core codec subcommands.
            Info.self, Encode.self, Decode.self, Convert.self,
            // Project-internal placeholder (M0 lossless vertical slice).
            EncodeM0.self, DecodeM0.self,
            // Performance.
            Benchmark.self,
            // Family-parity surface (mirror J2KSwift's `j2k`).
            Version.self, Compare.self, Completions.self, Validate.self,
            Batch.self, Transcode.self,
        ]
    )
}

let JXLToolVersion = "1.4.0"

enum JXLExitCode: Int32, Error {
    case generalError = 1
    case invalidArguments = 2
    case notImplemented = 64
}
