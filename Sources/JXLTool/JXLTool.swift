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
            Decode.self,
            Info.self,
            Hardware.self,
            Benchmark.self,
            Batch.self,
            Compare.self,
            Validate.self,
        ],
        defaultSubcommand: Encode.self
    )
}

/// Exit codes used across jxl-tool subcommands.
///
/// - `success` (0): Operation completed successfully.
/// - `generalError` (1): A runtime error occurred during execution.
/// - `invalidArguments` (2): One or more arguments were invalid.
enum JXLExitCode {
    static let success = ExitCode.success           // 0
    static let generalError = ExitCode.failure      // 1
    static let invalidArguments = ExitCode(2)       // 2
}
