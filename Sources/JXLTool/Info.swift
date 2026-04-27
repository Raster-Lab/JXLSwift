// `jxl-tool info` — print the basic info of a JPEG XL file.

import ArgumentParser
import Foundation
import JXLSwift

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print basic info from a JPEG XL file"
    )

    @Argument(help: "JPEG XL file path")
    var input: String

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            print("Error: file not found: \(input)", to: &standardError)
            throw JXLExitCode.invalidArguments
        }
        let bytes = try Data(contentsOf: inputURL)
        let frame = try JXLDecoder().decode(bytes)
        print("File:         \(input)")
        print("Bitstream:    \(formatBytes(bytes.count))")
        print("Dimensions:   \(frame.width)×\(frame.height)")
        print("Channels:     \(frame.channels) (\(frame.alphaChannels) alpha)")
        print("Pixel type:   \(frame.pixelType)  (\(frame.pixelType.bitsPerSample)-bit)")
        print("Colour space: \(frame.colorSpace)")
        print("ICC profile:  \(frame.iccProfile?.count ?? 0) bytes")
    }
}
