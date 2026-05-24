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
        abstract: "Encode one or more images to JPEG XL (lossy "
            + "VarDCT or lossless Modular; multiple `-i` flags "
            + "produce a multi-frame animation)."
    )

    @Option(name: .shortAndLong,
            parsing: .singleValue,
            help: "Input image path (PGM/PPM/PAM). Repeat `-i` to encode multiple frames as an animation.")
    var input: [String]

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

    @Option(name: .customLong("frame-duration"),
            help: "Per-frame duration in tps units (multi-frame only; default 10 = 100 ms at the libjxl-default 100 tps).")
    var frameDuration: UInt32 = 10

    func run() throws {
        guard !input.isEmpty else {
            print("error: at least one -i / --input is required",
                  to: &standardError)
            throw JXLExitCode.invalidArguments
        }
        let outputURL = URL(fileURLWithPath: output)

        // Read every input PNM into an ImageFrame.
        var frames: [ImageFrame] = []
        var rawTotal = 0
        for path in input {
            let inputURL = URL(fileURLWithPath: path)
            let pnmData: Data
            do { pnmData = try Data(contentsOf: inputURL) }
            catch {
                print("error reading \(path): \(error)",
                      to: &standardError)
                throw JXLExitCode.generalError
            }
            rawTotal += pnmData.count
            do { frames.append(try PNM.read(pnmData)) }
            catch let e as PNMError {
                print("PNM parse error in \(path): \(e)",
                      to: &standardError)
                throw JXLExitCode.invalidArguments
            }
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
        do {
            if frames.count == 1 {
                encoded = try encoder.encode(frames[0])
            } else {
                // Multi-frame path. JXLEncoder.encode([ImageFrame])
                // dispatches to VarDCTBitstreamWriter.encodeAnimation
                // with libjxl-default 100 tps timestamps.
                encoded = try encoder.encode(frames)
            }
        } catch let e as EncoderError {
            print("encode error: \(e.localizedDescription)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }

        do { try encoded.data.write(to: outputURL) }
        catch {
            print("error writing \(output): \(error)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }

        let encSize = encoded.data.count
        let pct = Double(encSize) * 100 / Double(rawTotal)
        let modeLabel = lossless
            ? "lossless"
            : "lossy q\(String(format: "%g", quality))"
        let first = frames[0]
        let frameLabel = frames.count == 1
            ? ""
            : " (\(frames.count)-frame animation)"
        print(
            "encoded \(first.width)×\(first.height) "
            + "\(channelDescription(first.channels))"
            + " \(first.pixelType.bitsPerSample)-bit "
            + "(\(modeLabel))\(frameLabel): "
            + "\(formatBytes(rawTotal)) → \(formatBytes(encSize)) "
            + "(\(String(format: "%.1f", pct))% of source) "
            + "in \(String(format: "%.3f", encoded.stats.encodingTime))s"
        )
    }
}
