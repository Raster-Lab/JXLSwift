// `jxl-tool encode-m0` — pure-Swift encoder front-end for the M0
// project-internal placeholder format.
//
// This wraps `MinimalLosslessCodec.encode(_:)`. It reads a binary
// PNM (PGM/PPM) file, encodes it, and writes a `.m0` buffer.
//
// **The output is NOT a JPEG XL file.** It uses the project-
// internal layout (signature + SizeHeader + ImageMetadata + 'M0'
// marker + entropy stream) and won't decode through `djxl` or any
// real JXL decoder. The `encode` / `decode` subcommands stay
// `notImplemented` until the real spec frame header lands; this
// `encode-m0` / `decode-m0` pair lets callers exercise the pixel
// pipeline today.

import ArgumentParser
import Foundation
import JXLSwift

struct EncodeM0: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encode-m0",
        abstract: "Encode a PNM image to the project-internal M0 placeholder format (NOT a real JXL file)."
    )

    @Option(name: .shortAndLong, help: "Input image path (PGM or PPM)")
    var input: String

    @Option(name: .shortAndLong, help: "Output .m0 path")
    var output: String

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)

        let pnmData: Data
        do { pnmData = try Data(contentsOf: inputURL) }
        catch { print("error reading \(input): \(error)", to: &standardError)
                throw JXLExitCode.generalError }

        let frame: ImageFrame
        do { frame = try PNM.read(pnmData) }
        catch let e as PNMError {
            print("PNM parse error: \(e)", to: &standardError)
            throw JXLExitCode.invalidArguments
        }

        let encoded: Data
        do { encoded = try MinimalLosslessCodec.encode(frame) }
        catch {
            print("M0 encode error: \(error)", to: &standardError)
            throw JXLExitCode.generalError
        }

        do { try encoded.write(to: outputURL) }
        catch { print("error writing \(output): \(error)", to: &standardError)
                throw JXLExitCode.generalError }

        let rawSize = pnmData.count
        let encSize = encoded.count
        let pct = Double(encSize) * 100 / Double(rawSize)
        print(
            "encoded \(frame.width)×\(frame.height) " +
            "\(channelDescription(frame.channels))" +
            " \(frame.pixelType.bitsPerSample)-bit: " +
            "\(formatBytes(rawSize)) → \(formatBytes(encSize)) " +
            "(\(String(format: "%.1f", pct))% of source)"
        )
        print(
            "NOTE: \(output) is the project-internal M0 placeholder format, " +
            "NOT a JPEG XL file. It will not decode through djxl.",
            to: &standardError
        )
    }
}
