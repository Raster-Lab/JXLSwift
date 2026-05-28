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
    /// `jbrd`-driven byte-identical JXL → JPEG reconstruction.
    /// Autonomous (v0.12.0hc): coefficients + quant table + chroma
    /// info come from the codestream; `--source` is an optional
    /// fallback for frames the autonomous decoder can't handle.
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
            help: "Transcode mode. Default `pixel-fallback`; `coefficient-bridge` is for forward bridge work (currently throws). `reverse` runs JXL → JPEG via the jbrd box, byte-identical and autonomous (no `--source` needed) for baseline cjxl --lossless_jpeg files.")
    var mode: TranscodeMode = .pixelFallback

    @Option(name: .long,
            help: "Optional source JPEG path — a fallback for `--mode reverse` when the autonomous codestream decode can't handle the frame (e.g. progressive). Not needed for baseline JPEGs.")
    var source: String? = nil

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
                mode: mode,
                sourceJPEGPath: source)
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
            // Wire to the v0.12.0g API stub — it throws today but
            // surfaces useful validation errors (bad precision /
            // frame kind / component count) before the bridge core
            // lands. This keeps the CLI surface aligned with the
            // library API as the implementation evolves.
            let coef: JPEGCoefficientImage
            do {
                coef = try JPEGDecoder.decodeToCoefficients(
                    jpegBytes)
            } catch let e as JPEGDecoderError {
                print("JPEG decode error: "
                    + (e.errorDescription ?? "\(e)"),
                    to: &standardError)
                throw JXLExitCode.generalError
            }
            do {
                _ = try JXLEncoder().encodeFromJPEGCoefficients(
                    coef)
            } catch EncoderError.notImplemented(_) {
                // Expected today — the bridge is stubbed.
                print("error: JPEG → JXL coefficient bridge "
                    + "(--mode coefficient-bridge) is not yet "
                    + "implemented. This is the in-progress "
                    + "Phase J capstone; see "
                    + "Documentation/PHASE-J-COEFFICIENT-BRIDGE.md "
                    + "for the plan. Use --mode pixel-fallback "
                    + "(the default) for today's behaviour.",
                    to: &standardError)
                throw JXLExitCode.notImplemented
            } catch let e as EncoderError {
                // Input-shape validation rejected (bad precision /
                // frame kind / component count). The eventual
                // bridge would reject these too — surface them
                // cleanly today.
                print("error: \(e.localizedDescription)",
                    to: &standardError)
                throw JXLExitCode.invalidArguments
            }
            // Unreachable today; safety net for when the bridge
            // lands and starts returning real EncodedImage.
            print("error: coefficient-bridge unexpectedly "
                + "succeeded without writing output — please file "
                + "a bug.", to: &standardError)
            throw JXLExitCode.generalError
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
        jxlBytes: Data, outputURL: URL, mode: TranscodeMode,
        sourceJPEGPath: String?
    ) throws {
        switch mode {
        case .pixelFallback, .coefficientBridge:
            print("error: JXL → JPEG requires `--mode reverse`. "
                + "The other modes are JPEG → JXL only.",
                to: &standardError)
            throw JXLExitCode.invalidArguments
        case .reverse:
            // Continue.
            break
        }
        // Parse the JXL container to find the jbrd box.
        let form: JXLContainerForm
        do { form = try parseJXLContainer(jxlBytes) }
        catch let e as ContainerError {
            print("error: failed to parse JXL container: \(e)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }
        guard case .iso(let boxes) = form else {
            print("error: JXL is a naked codestream "
                + "(no container box) — reverse transcode needs "
                + "the `jbrd` box from an ISOBMFF container.",
                to: &standardError)
            throw JXLExitCode.invalidArguments
        }
        let jbrdPayload: Data
        do {
            guard let p = try extractJBRDBox(
                from: boxes, in: jxlBytes)
            else {
                print("error: JXL container has no `jbrd` box. "
                    + "Reverse transcode requires the jbrd box "
                    + "(only present when the JXL was produced by "
                    + "a JPEG-bridge encoder).",
                    to: &standardError)
                throw JXLExitCode.invalidArguments
            }
            jbrdPayload = p
        } catch let e as ContainerError {
            print("error: \(e)", to: &standardError)
            throw JXLExitCode.generalError
        }
        // Parse jbrd Bundle + decode Brotli + distribute payload.
        var r = BitReader(jbrdPayload)
        var box: JBRDBox
        do { box = try JBRDBoxReader.read(from: &r) }
        catch let e as JBRDError {
            print("error: jbrd Bundle parse failed: \(e)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }
        let brotliStart = (r.position + 7) / 8
        let brotliBytes = jbrdPayload.suffix(from: brotliStart)
        let decoded: Data
        do {
            decoded = try BrotliDecoder.decode(Data(brotliBytes))
        } catch let e as BrotliError {
            if case .notImplemented(let msg) = e {
                print(
                    "error: jbrd Brotli payload uses compressed "
                    + "encoding which is not yet implemented: "
                    + "\(msg). This happens for JPEGs with large "
                    + "EXIF/XMP/ICC metadata. Common-case JPEGs "
                    + "(small APP0) use uncompressed Brotli and "
                    + "decode today.",
                    to: &standardError)
                throw JXLExitCode.notImplemented
            }
            print("error: Brotli decode failed: \(e)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }
        // Extract optional metadata boxes (Exif/xml/jumb — direct
        // or wrapped in `brob`). Splice into appData/comData when
        // distributing the Brotli payload so kICC/kExif/kXMP
        // markers reconstruct byte-identically.
        let exifBox: Data?
        let xmpBox: Data?
        do {
            exifBox = try extractMetadataBox(
                type: "Exif", from: boxes, in: jxlBytes)
            xmpBox = try extractMetadataBox(
                type: "xml ", from: boxes, in: jxlBytes)
        } catch let e as BrotliError {
            if case .notImplemented(let msg) = e {
                print(
                    "error: metadata box (Exif/xml) uses Brotli "
                    + "compressed encoding which is not supported "
                    + "yet for arbitrary streams: \(msg)",
                    to: &standardError)
                throw JXLExitCode.notImplemented
            }
            print("error: metadata box extract failed: \(e)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }
        let external = JBRDBox.ExternalMetadata(
            exif: exifBox, xmp: xmpBox, icc: nil)
        do {
            try box.distributeBrotliPayload(
                decoded, external: external)
        }
        catch let e as JBRDError {
            print("error: jbrd payload distribution failed: \(e)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }
        // Autonomous path (v0.12.0hc): decode the coefficients +
        // RAW quant table + chroma info from the JXL itself and
        // reconstruct with no `--source`. Falls back to the source
        // path only when the autonomous decode can't handle the
        // frame (non-VarDCT, progressive, etc.) AND `--source` was
        // supplied.
        var rebuilt: Data? = nil
        do {
            let bridge = try JXLDecoder().decodeJPEGBridgeData(jxlBytes)
            rebuilt = try JXLToJPEGAdapter.reconstruct(
                bridgeData: bridge, jbrd: box)
        } catch let e as DecoderError {
            if case .notImplemented(let msg) = e, sourceJPEGPath != nil {
                print("note: autonomous decode unavailable "
                    + "(\(msg)); falling back to --source.",
                    to: &standardError)
            } else if sourceJPEGPath == nil {
                print("error: autonomous JXL → JPEG reverse "
                    + "transcode failed: \(e). Supply `--source "
                    + "<orig.jpg>` to fall back to the "
                    + "source-driven path.", to: &standardError)
                throw JXLExitCode.notImplemented
            }
        } catch {
            if sourceJPEGPath == nil {
                print("error: autonomous reverse transcode "
                    + "failed: \(error)", to: &standardError)
                throw JXLExitCode.generalError
            }
        }

        // Source-driven fallback (only when autonomous didn't
        // produce output and `--source` is present).
        var sourceBytes: Data? = nil
        if rebuilt == nil {
            guard let sourcePath = sourceJPEGPath else {
                print("error: JXL → JPEG reverse transcode failed "
                    + "and no `--source` fallback was provided.",
                    to: &standardError)
                throw JXLExitCode.notImplemented
            }
            let sb: Data
            do {
                sb = try Data(
                    contentsOf: URL(fileURLWithPath: sourcePath))
            } catch {
                print("error reading source JPEG \(sourcePath): "
                    + "\(error)", to: &standardError)
                throw JXLExitCode.generalError
            }
            sourceBytes = sb
            let originalCoeffs: JPEGCoefficientImage
            do {
                originalCoeffs = try JPEGDecoder
                    .decodeToCoefficients(sb)
            } catch let e as JPEGDecoderError {
                print("error: source JPEG decode failed: "
                    + (e.errorDescription ?? "\(e)"),
                    to: &standardError)
                throw JXLExitCode.generalError
            }
            for i in 0..<box.quant.count
            where i < originalCoeffs.quantTables.count {
                box.quant[i].values =
                    originalCoeffs.quantTables[i]
                    .zigZagValues.map { Int32($0) }
            }
            for i in 0..<box.components.count
            where i < originalCoeffs.frameComponents.count {
                box.components[i].hSampFactor =
                    originalCoeffs.frameComponents[i].hSamplingFactor
                box.components[i].vSampFactor =
                    originalCoeffs.frameComponents[i].vSamplingFactor
            }
            let planes: JXLCoefficientPlanes
            do {
                planes = try originalCoeffs.toJXLCoefficientPlanes()
            } catch let e as JPEGToJXLAdapterError {
                print("error: source JPEG → JXL planes adapter "
                    + "failed: \(e)", to: &standardError)
                throw JXLExitCode.generalError
            }
            do {
                rebuilt = try JXLToJPEGAdapter.reconstruct(
                    coefficients: planes.remappedForJXLBridge(
                        colorTransform: .ycbcr),
                    jbrd: box, colorTransform: .ycbcr)
            } catch let e as JXLToJPEGAdapterError {
                print("error: reconstruct failed: \(e)",
                      to: &standardError)
                throw JXLExitCode.generalError
            }
        }

        guard let out = rebuilt else {
            print("error: reverse transcode produced no output.",
                  to: &standardError)
            throw JXLExitCode.generalError
        }
        // Write output.
        do {
            try out.write(to: outputURL)
        } catch {
            print("error writing \(outputURL.path): \(error)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }
        print("wrote \(out.count) bytes to \(outputURL.path)")
        // Optional verification against `--source` when supplied.
        if let sb = sourceBytes {
            if out == sb {
                print("byte-identical to source ✓")
            } else {
                let cmpLen = min(out.count, sb.count)
                var firstDiff = -1
                for i in 0..<cmpLen
                where out[out.startIndex + i]
                    != sb[sb.startIndex + i] {
                    firstDiff = i; break
                }
                print("warning: rebuilt JPEG differs from source"
                    + " at byte \(firstDiff) of \(cmpLen).")
            }
        }
    }
}
