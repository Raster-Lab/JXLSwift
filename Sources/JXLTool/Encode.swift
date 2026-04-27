// `jxl-tool encode` — pure-Swift JPEG XL encoder front-end.
//
// STATUS: not yet implemented. The pure-Swift codec layer (Modular,
// VarDCT, rANS) is the multi-person-year project tracked in ROADMAP.md.
// This subcommand exists so the surface is in place; calling it
// produces a clear "not implemented" error rather than mystery output.

import ArgumentParser
import Foundation
import JXLSwift

struct Encode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Encode an image to JPEG XL (NOT YET IMPLEMENTED in pure Swift)."
    )

    @Option(name: .shortAndLong, help: "Input image path")
    var input: String

    @Option(name: .shortAndLong, help: "Output .jxl path")
    var output: String

    @Flag(name: .shortAndLong, help: "Lossless compression")
    var lossless: Bool = false

    @Option(name: .shortAndLong, help: "Quality (0–100, ignored if --lossless)")
    var quality: Float = 90

    @Option(name: .shortAndLong, help: "Effort 1–9 (1=fastest, 9=best)")
    var effort: Int = 7

    func run() throws {
        print("""
            jxl-tool encode is not yet implemented in the pure-Swift
            JXLSwift. The codec layer (Modular tree, VarDCT, rANS entropy
            coding, color transforms) is in active development — see
            ROADMAP.md for the current status.

            For a working encoder today, switch to the libjxl-backend
            branch:
                git checkout libjxl-backend
                swift build -c release

            Foundation-only operations available now:
                jxl-tool info <file.jxl>     — parse container + SizeHeader
            """, to: &standardError)
        throw JXLExitCode.notImplemented
    }
}
