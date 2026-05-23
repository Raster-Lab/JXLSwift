// `jxl-tool encode` — pure-Swift JPEG XL encoder front-end.
//
// Routes through `JXLEncoder`. The default mode is **lossy** VarDCT
// (`--quality`, default 90), which the encoder applies to 8-bit
// RGB/RGBA frames; for inputs VarDCT can't take (grayscale, 16-bit)
// `JXLEncoder` falls back to the lossless Modular path. `--lossless`
// forces the Modular path. Supported inputs: 8-bit grayscale (PGM),
// 8-bit RGB (PPM), 8-bit RGBA (PAM), 16-bit grayscale (PGM with
// maxval > 255). Output is a real `.jxl` codestream that
// round-trips through `djxl`.

import ArgumentParser
import Foundation
import JXLSwift

struct Encode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Encode an image to JPEG XL (lossy VarDCT or "
            + "lossless Modular)."
    )

    @Option(name: .shortAndLong, help: "Input image path (PGM/PPM/PAM)")
    var input: String

    @Option(name: .shortAndLong, help: "Output .jxl path")
    var output: String

    @Flag(name: .shortAndLong,
          help: "Lossless Modular compression (default is lossy VarDCT)")
    var lossless: Bool = false

    @Option(name: .shortAndLong, help: "Quality 0–100 (lossy mode)")
    var quality: Float = 90

    @Option(name: .shortAndLong, help: "Effort 1–9 (currently advisory)")
    var effort: Int = 7

    @Flag(name: .long,
          inversion: .prefixedNo,
          help: "Apply the inverse-Gaborish 5×5 sharpening pre-pass (lossy only). Default: on.")
    var gaborish: Bool = true

    @Flag(name: .customLong("adaptive-qf"),
          inversion: .prefixedNo,
          help: "Per-block variance-driven adaptive quantisation (lossy only). Default: on.")
    var adaptiveQF: Bool = true

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

        let mode: CompressionMode = lossless
            ? .lossless
            : .lossy(quality: max(0, min(quality, 100)))
        let effortLevel = EncodingEffort(
            rawValue: max(1, min(effort, 9))) ?? .squirrel
        let encoder = JXLEncoder(options: EncodingOptions(
            mode: mode, effort: effortLevel,
            gaborish: gaborish, adaptiveQF: adaptiveQF))
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
        let modeLabel = lossless
            ? "lossless"
            : "lossy q\(String(format: "%g", quality))"
        print(
            "encoded \(frame.width)×\(frame.height) "
            + "\(channelDescription(frame.channels))"
            + " \(frame.pixelType.bitsPerSample)-bit (\(modeLabel)): "
            + "\(formatBytes(rawSize)) → \(formatBytes(encSize)) "
            + "(\(String(format: "%.1f", pct))% of source) "
            + "in \(String(format: "%.3f", encoded.stats.encodingTime))s"
        )
    }
}
