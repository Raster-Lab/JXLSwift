// `jxl transcode` — convert between JPEG and JXL formats.
//
// **Scope today (v0.12.0e):**
//   - `jxl transcode foo.jpg foo.jxl` — invokes the JPEG-decode +
//     JXL-encode pixel-fallback path (same behaviour as
//     `jxl encode -i foo.jpg -o foo.jxl`). Lossy at the JPEG-decode
//     step (8-bit YCbCr → RGB via JFIF BT.601, then JXL VarDCT
//     re-encodes the pixels). This is **not** bit-perfect JPEG
//     transcoding — the source JPEG cannot be reconstructed from
//     the output.
//   - `jxl transcode foo.jxl foo.jpg` — throws a clear error.
//     Reverse direction is gated on a pure-Swift Brotli decompressor
//     (the JXL `jbrd` box payload is Brotli-compressed) which is
//     multi-session work. See Documentation/PHASE-J-COEFFICIENT-BRIDGE.md.
//
// **Future (planned v0.12.x):**
//   - `--mode coefficient-bridge` — true forward transcode: pack JPEG
//     quantised DCT coefficients into a JXL frame so decoding the
//     output produces pixels matching the source JPEG with no
//     additional quantisation loss. Still no bit-perfect reverse
//     without Brotli.
//   - `--mode reverse` — `jbrd`-driven byte-identical JXL → JPEG
//     reconstruction (gated on Brotli).
//
// The subcommand exists today so the CLI surface matches J2KSwift's
// `j2k transcode` (the family-parity audit had this as one of two
// remaining gaps; `convert` is the other and depends on broader
// image-format support).

import ArgumentParser
import Foundation
import JXLSwift

enum TranscodeMode: String, ExpressibleByArgument, CaseIterable {
    /// Decode the source, re-encode through the standard pipeline.
    /// JPEG → JXL: pixel-decode the JPEG then VarDCT-encode the
    /// pixels. JXL → JPEG: not supported (reverse needs Brotli).
    case pixelFallback = "pixel-fallback"
    /// **Not yet implemented.** Direct JPEG quantised coefficient
    /// → JXL frame packing. No IDCT/DCT round-trip in the middle.
    case coefficientBridge = "coefficient-bridge"
    /// **Not yet implemented.** `jbrd`-driven byte-identical
    /// JXL → JPEG reconstruction. Needs Brotli.
    case reverse = "reverse"
}

struct Transcode: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcode",
        abstract: "Convert between JPEG and JXL formats. Today: JPEG → JXL via the pixel-fallback pipeline. Bit-perfect coefficient-bridge transcoding and JXL → JPEG reverse are in-progress Phase J work; see CHANGELOG."
    )

    @Argument(help: "Input image path (JPEG or JXL).")
    var input: String

    @Argument(help: "Output image path. Format determined by extension (.jxl or .jpg/.jpeg).")
    var output: String

    @Option(name: .shortAndLong,
            help: "Quality 0–100 for JPEG → JXL (lossy VarDCT). Default 90.")
    var quality: Float = 90

    @Flag(name: .shortAndLong,
          help: "Lossless Modular for JPEG → JXL (forces the pixel-fallback path through the Modular encoder).")
    var lossless: Bool = false

    @Option(name: .long,
            help: "Transcode mode. Default `pixel-fallback`; `coefficient-bridge` and `reverse` are reserved for future Phase J work and currently throw.")
    var mode: TranscodeMode = .pixelFallback

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)

        let bytes: Data
        do { bytes = try Data(contentsOf: inputURL) }
        catch {
            print("error reading \(input): \(error)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }

        let isJPEG = JPEGSegmentReader.looksLikeJPEG(bytes)
        let isJXL = bytes.count >= 2
            && ((bytes[0] == 0xFF && bytes[1] == 0x0A)
                || (bytes.count >= 8 && bytes[0] == 0x00
                    && bytes[1] == 0x00 && bytes[2] == 0x00
                    && bytes[3] == 0x0C
                    && bytes[4] == 0x4A && bytes[5] == 0x58
                    && bytes[6] == 0x4C && bytes[7] == 0x20))

        switch (isJPEG, isJXL) {
        case (true, _):
            try transcodeJPEGtoJXL(
                jpegBytes: bytes,
                outputURL: outputURL,
                mode: mode,
                quality: quality,
                lossless: lossless)
        case (_, true):
            try transcodeJXLtoJPEG(
                jxlBytes: bytes,
                outputURL: outputURL,
                mode: mode)
        default:
            print("error: input is neither JPEG (SOI marker) "
                + "nor JXL (naked-codestream or ISOBMFF magic): "
                + "\(input)", to: &standardError)
            throw JXLExitCode.invalidArguments
        }
    }

    private func transcodeJPEGtoJXL(
        jpegBytes: Data, outputURL: URL,
        mode: TranscodeMode, quality: Float, lossless: Bool
    ) throws {
        switch mode {
        case .pixelFallback:
            break  // proceed with the pixel-fallback path below
        case .coefficientBridge:
            print("error: --mode coefficient-bridge is not yet "
                + "implemented; this is the in-progress Phase J "
                + "capstone (see Documentation/"
                + "PHASE-J-COEFFICIENT-BRIDGE.md). Re-run with "
                + "--mode pixel-fallback for today's behaviour.",
                to: &standardError)
            throw JXLExitCode.notImplemented
        case .reverse:
            print("error: --mode reverse runs JXL → JPEG, but "
                + "input \(input) is a JPEG. Did you mean to "
                + "swap the arguments?", to: &standardError)
            throw JXLExitCode.invalidArguments
        }
        let frame: ImageFrame
        do { frame = try JPEGDecoder.decode(jpegBytes) }
        catch let e as JPEGDecoderError {
            print("JPEG decode error: "
                + (e.errorDescription ?? "\(e)"),
                to: &standardError)
            throw JXLExitCode.generalError
        }
        let encodingMode: CompressionMode = lossless
            ? .lossless
            : .lossy(quality: max(0, min(quality, 100)))
        let encoder = JXLEncoder(options: EncodingOptions(
            mode: encodingMode))
        let encoded: EncodedImage
        do { encoded = try encoder.encode(frame) }
        catch let e as EncoderError {
            print("JXL encode error: "
                + e.localizedDescription,
                to: &standardError)
            throw JXLExitCode.generalError
        }
        do { try encoded.data.write(to: outputURL) }
        catch {
            print("error writing \(output): \(error)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }
        let pct = Double(encoded.data.count) * 100
            / Double(max(1, jpegBytes.count))
        let modeLabel = lossless
            ? "lossless"
            : "lossy q\(String(format: "%g", quality))"
        print(
            "transcoded JPEG → JXL "
            + "(\(modeLabel), pixel-fallback): "
            + "\(frame.width)×\(frame.height) "
            + "\(channelDescription(frame.channels)) "
            + "\(frame.pixelType.bitsPerSample)-bit, "
            + "\(formatBytes(jpegBytes.count)) → "
            + "\(formatBytes(encoded.data.count)) "
            + "(\(String(format: "%.1f", pct))% of source)"
        )
    }

    private func transcodeJXLtoJPEG(
        jxlBytes: Data, outputURL: URL, mode: TranscodeMode
    ) throws {
        // All three modes throw — reverse is the entire point of
        // this direction and it's gated on Brotli (jbrd box
        // decompression). Documented in CHANGELOG + ROADMAP.
        print(
            "error: JXL → JPEG transcoding is not yet "
            + "implemented. The reverse direction requires "
            + "`jbrd`-box decompression (Brotli) which is "
            + "in-progress; see Documentation/"
            + "PHASE-J-COEFFICIENT-BRIDGE.md for the plan.",
            to: &standardError)
        _ = jxlBytes; _ = outputURL; _ = mode
        throw JXLExitCode.notImplemented
    }
}
