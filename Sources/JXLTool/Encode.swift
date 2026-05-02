// `jxl-tool encode` — pure-Swift JPEG XL encoder front-end.
//
// Routes through `JXLEncoder`, which dispatches into
// `SpecModularEncoder` for the lossless Modular path. Today's
// supported inputs: 8-bit grayscale (PGM), 8-bit RGB (PPM), 8-bit
// RGBA (PAM), and 16-bit grayscale (PGM with maxval > 255). Output
// is a real `.jxl` codestream that round-trips through `djxl`.
//
// `--lossless` is currently the only mode (matches what the
// encoder produces). Lossy / VarDCT is still pending — the flag is
// kept for forward-compat so scripts don't break when it lands.

import ArgumentParser
import Foundation
import JXLSwift

struct Encode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Encode an image to JPEG XL (lossless Modular)."
    )

    @Option(name: .shortAndLong, help: "Input image path (PGM/PPM/PAM)")
    var input: String

    @Option(name: .shortAndLong, help: "Output .jxl path")
    var output: String

    @Flag(name: .shortAndLong, help: "Lossless compression (currently the only mode)")
    var lossless: Bool = false

    @Option(name: .shortAndLong, help: "Quality 0–100 (ignored — lossy path not implemented)")
    var quality: Float = 90

    @Option(name: .shortAndLong, help: "Effort 1–9 (currently ignored)")
    var effort: Int = 7

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)

        let pnmData: Data
        do { pnmData = try Data(contentsOf: inputURL) }
        catch {
            print("error reading \(input): \(error)", to: &standardError)
            throw JXLExitCode.generalError
        }

        let frame: ImageFrame
        do { frame = try PNM.read(pnmData) }
        catch let e as PNMError {
            print("PNM parse error: \(e)", to: &standardError)
            throw JXLExitCode.invalidArguments
        }

        let encoder = JXLEncoder()
        let encoded: EncodedImage
        do { encoded = try encoder.encode(frame) }
        catch let e as EncoderError {
            print("encode error: \(e.localizedDescription)", to: &standardError)
            throw JXLExitCode.generalError
        }

        do { try encoded.data.write(to: outputURL) }
        catch {
            print("error writing \(output): \(error)", to: &standardError)
            throw JXLExitCode.generalError
        }

        let rawSize = pnmData.count
        let encSize = encoded.data.count
        let pct = Double(encSize) * 100 / Double(rawSize)
        print(
            "encoded \(frame.width)×\(frame.height) "
            + "\(channelDescription(frame.channels))"
            + " \(frame.pixelType.bitsPerSample)-bit: "
            + "\(formatBytes(rawSize)) → \(formatBytes(encSize)) "
            + "(\(String(format: "%.1f", pct))% of source) "
            + "in \(String(format: "%.3f", encoded.stats.encodingTime))s"
        )
    }
}
