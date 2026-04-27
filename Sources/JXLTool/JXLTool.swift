// jxl-tool: command-line front-end for JXLSwift.

import ArgumentParser

@main
struct JXLTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jxl-tool",
        abstract: "JPEG XL encode/decode/inspect via libjxl-backed JXLSwift.",
        subcommands: [Encode.self, Decode.self, Info.self]
    )
}

enum JXLExitCode: Int32, Error {
    case generalError = 1
    case invalidArguments = 2
}
