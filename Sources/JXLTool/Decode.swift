// `jxl-tool decode` — pure-Swift JPEG XL decoder front-end.
// STATUS: not yet implemented (see ROADMAP.md).

import ArgumentParser
import Foundation
import JXLSwift

struct Decode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Decode a JPEG XL file (NOT YET IMPLEMENTED in pure Swift)."
    )

    @Option(name: .shortAndLong, help: "Input .jxl path")
    var input: String

    @Option(name: .shortAndLong, help: "Output .png path")
    var output: String

    func run() throws {
        print("""
            jxl-tool decode is not yet implemented in the pure-Swift
            JXLSwift. The codec layer is in active development — see
            ROADMAP.md.

            Switch to the libjxl-backend branch for a working decoder:
                git checkout libjxl-backend
                swift build -c release

            Foundation-only `info` works now and may help diagnose
            container/header issues:
                jxl-tool info \(input)
            """, to: &standardError)
        throw JXLExitCode.notImplemented
    }
}
