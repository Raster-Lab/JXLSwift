/// Decode subcommand — decode a JPEG XL file back to pixel data
///
/// Decodes a JPEG XL codestream or container file and writes information
/// about the decoded image. Currently supports lossless (Modular) mode.

import ArgumentParser
import Foundation
import JXLSwift

struct Decode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Decode a JPEG XL file"
    )

    @Argument(help: "Input JPEG XL file path")
    var input: String

    @Option(name: .shortAndLong, help: "Output file path (raw pixel data)")
    var output: String?

    @Flag(name: .long, help: "Print decoded image header information")
    var info: Bool = false

    @Flag(name: .long, help: "Print header only, do not decode pixel data")
    var headerOnly: Bool = false

    @Flag(name: .long, help: "Extract and display metadata (EXIF, XMP, ICC)")
    var metadata: Bool = false

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ExitCode(2)
        }

        let data = try Data(contentsOf: inputURL)
        let decoder = JXLDecoder()

        // Extract codestream (handles both bare and container formats)
        let codestream = try decoder.extractCodestream(data)

        // Parse and display header
        let header = try decoder.parseImageHeader(codestream)

        if info || headerOnly {
            print("JPEG XL Image Header:")
            print("  Dimensions: \(header.width)×\(header.height)")
            print("  Channels:   \(header.channels)")
            print("  Bit depth:  \(header.bitsPerSample)")
            print("  Has alpha:  \(header.hasAlpha)")
            print("  Color space: \(header.colorSpaceIndicator)")
            print("  Header size: \(header.headerSize) bytes")
            print("  Total size:  \(codestream.count) bytes")
        }

        // Display metadata if requested
        if metadata {
            let (exif, xmp, iccProfile) = try decoder.extractMetadata(data)
            print("Metadata:")
            if let exif = exif {
                let orientation = EXIFOrientation.extractOrientation(from: exif.data)
                print("  EXIF: \(exif.data.count) bytes (orientation: \(orientation))")
            } else {
                print("  EXIF: not present")
            }
            if let xmp = xmp {
                let xmlString = String(data: xmp.data, encoding: .utf8) ?? "(binary)"
                let preview = xmlString.prefix(100)
                print("  XMP:  \(xmp.data.count) bytes")
                print("        \(preview)\(xmlString.count > 100 ? "…" : "")")
            } else {
                print("  XMP:  not present")
            }
            if let icc = iccProfile {
                print("  ICC:  \(icc.data.count) bytes")
            } else {
                print("  ICC:  not present")
            }
        }

        if headerOnly {
            return
        }

        // Decode the image
        let frame = try decoder.decode(codestream)

        let pixelCount = frame.width * frame.height * frame.channels
        print("Decoded \(frame.width)×\(frame.height) image (\(frame.channels) channels, \(pixelCount) pixels)")

        // Write output if requested
        if let outputPath = output {
            let outputURL = URL(fileURLWithPath: outputPath)
            try Data(frame.data).write(to: outputURL)
            print("Wrote raw pixel data to \(outputPath) (\(frame.data.count) bytes)")
        }
    }
}
