/// JXL Tool — Command line interface for JXLSwift
///
/// Provides encoding, info, hardware detection, and benchmarking
/// functionality via a command line tool.

import ArgumentParser
import Foundation
import JXLSwift

@main
struct JXLTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jxl-tool",
        abstract: "JPEG XL encoding tool powered by JXLSwift",
        version: JXLSwift.version,
        subcommands: [
            Encode.self,
            Info.self,
            Hardware.self,
            Benchmark.self,
        ],
        defaultSubcommand: Encode.self
    )
}
