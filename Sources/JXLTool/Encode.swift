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
            parsing: .upToNextOption,
            help: "Input image path(s) (PGM/PPM/PAM). Accepts one or many: `-i frame.ppm`, `-i f0.ppm -i f1.ppm`, or `-i frame_*.ppm` (shell glob). Multi-value invocations are encoded as a multi-frame animation.")
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
            help: "Per-frame duration in tps units (multi-frame only; default 10 = 100 ms at the libjxl-default 100 tps). Accepts either a single value applied to every frame, or a comma-separated list `--frame-duration 10,30,10` matching the number of input frames.")
    var frameDuration: String = "10"

    func run() throws {
        guard !input.isEmpty else {
            print("error: at least one -i / --input is required",
                  to: &standardError)
            throw JXLExitCode.invalidArguments
        }
        let outputURL = URL(fileURLWithPath: output)

        // Read every input into an ImageFrame. JPEG inputs are
        // auto-detected via SOI magic and routed through
        // JPEGDecoder; everything else is parsed as PNM. Mixing
        // PNM + JPEG inputs in the same multi-frame invocation
        // works too — the encoder downstream just sees frames.
        var frames: [ImageFrame] = []
        var rawTotal = 0
        for path in input {
            let inputURL = URL(fileURLWithPath: path)
            let bytes: Data
            do { bytes = try Data(contentsOf: inputURL) }
            catch {
                print("error reading \(path): \(error)",
                      to: &standardError)
                throw JXLExitCode.generalError
            }
            rawTotal += bytes.count
            if JPEGSegmentReader.looksLikeJPEG(bytes) {
                do { frames.append(try JPEGDecoder.decode(bytes)) }
                catch let e as JPEGDecoderError {
                    print("JPEG decode error in \(path): "
                        + (e.errorDescription ?? "\(e)"),
                          to: &standardError)
                    throw JXLExitCode.invalidArguments
                }
            } else {
                do { frames.append(try PNM.read(bytes)) }
                catch let e as PNMError {
                    print("PNM parse error in \(path): \(e)",
                          to: &standardError)
                    throw JXLExitCode.invalidArguments
                }
            }
        }

        let mode: CompressionMode = lossless
            ? .lossless
            : .lossy(quality: max(0, min(quality, 100)))
        let effortLevel = EncodingEffort(
            rawValue: max(1, min(effort, 9))) ?? .squirrel
        // Parse `--frame-duration`. Accepts a single integer
        // ("10") or a comma-separated list ("10,30,10"). For the
        // list form, the count must match the number of frames.
        let rawDurations = frameDuration
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var parsedDurations: [UInt32] = []
        for s in rawDurations {
            guard let v = UInt32(s) else {
                print("error: invalid --frame-duration '\(s)' "
                    + "(expected integer)", to: &standardError)
                throw JXLExitCode.invalidArguments
            }
            parsedDurations.append(v)
        }
        let defaultDur: UInt32 = parsedDurations.first ?? 10
        let perFrameDurs: [UInt32]?
        if parsedDurations.count <= 1 {
            perFrameDurs = nil // single value handled by default
        } else {
            guard parsedDurations.count == frames.count else {
                print("error: --frame-duration list has "
                    + "\(parsedDurations.count) values but "
                    + "\(frames.count) input frame(s)",
                    to: &standardError)
                throw JXLExitCode.invalidArguments
            }
            perFrameDurs = parsedDurations
        }
        let encoder = JXLEncoder(options: EncodingOptions(
            mode: mode, effort: effortLevel,
            gaborish: gaborish, adaptiveQF: adaptiveQF,
            defaultFrameDuration: defaultDur,
            frameDurations: perFrameDurs))
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
        // Report the mode that *actually* ran, not just what was asked.
        // The encoder falls back to lossless Modular for inputs the lossy
        // VarDCT codec can't take (e.g. 16-bit) — important for medical
        // users not to see a lossless result mislabelled "lossy".
        let modeLabel: String
        if encoded.stats.wasLossless {
            modeLabel = lossless
                ? "lossless"
                : "lossless — lossy VarDCT unavailable for this input"
        } else {
            modeLabel = "lossy q\(String(format: "%g", quality))"
        }
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
