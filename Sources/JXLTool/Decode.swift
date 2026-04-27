// `jxl-tool decode` — decode a JPEG XL file to PNG via JXLSwift.

import ArgumentParser
import Foundation
import JXLSwift

struct Decode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Decode a JPEG XL file to PNG"
    )

    @Option(name: .shortAndLong, help: "Input .jxl path")
    var input: String

    @Option(name: .shortAndLong, help: "Output .png path")
    var output: String

    @Flag(name: .long, help: "Show verbose output")
    var verbose: Bool = false

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            print("Error: input file not found: \(input)", to: &standardError)
            throw JXLExitCode.invalidArguments
        }

        let bytes = try Data(contentsOf: inputURL)
        let decoder = JXLDecoder()
        let frame = try decoder.decode(bytes)

        guard writePNG(frame, to: outputURL) else {
            print("Error: failed to write PNG to \(output)", to: &standardError)
            throw JXLExitCode.generalError
        }
        print("Decoded \(frame.width)×\(frame.height) (\(frame.channels)ch) → \(output)")
        if verbose {
            print("  Pixel type:   \(frame.pixelType)")
            print("  Colour space: \(frame.colorSpace)")
            print("  Has alpha:    \(frame.hasAlpha)")
        }
    }
}
