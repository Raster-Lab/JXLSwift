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
            // True lossless-JPEG transcode: pack the quantised DCT
            // coefficients into a VarDCT JXL frame (no IDCT) and emit
            // a complete container with a `jbrd` reconstruction box, so
            // the reverse transcode (or `djxl --jpeg`) recovers the
            // source JPEG byte-for-byte.
            let bridged: EncodedImage
            do {
                bridged = try JXLEncoder().encodeLosslessJPEG(jpegBytes)
            } catch let e as EncoderError {
                // Out-of-scope input (precision / frame kind /
                // component count / progressive — `decodeToCoefficients`
                // is baseline-only). Surface cleanly.
                print("error: JPEG → JXL lossless bridge: "
                    + e.localizedDescription
                    + ". Use --mode pixel-fallback (the default) for "
                    + "the lossy pixel path.",
                    to: &standardError)
                throw JXLExitCode.notImplemented
            }
            do { try bridged.data.write(to: outputURL) }
            catch {
                print("error writing \(output): \(error)",
                      to: &standardError)
                throw JXLExitCode.generalError
            }
            let pct = Double(bridged.data.count) * 100
                / Double(max(1, jpegBytes.count))
            print(
                "transcoded JPEG → JXL (lossless coefficient-bridge): "
                + "\(formatBytes(jpegBytes.count)) → "
                + "\(formatBytes(bridged.data.count)) "
                + "(\(String(format: "%.1f", pct))% of source); "
                + "reverse with `--mode reverse`")
            return
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
        // Primary path: the public autonomous reverse-transcode API
        // (`JXLDecoder.decodeLosslessJPEG`). It re-parses the container
        // internally and recovers everything from the JXL itself
        // (coefficients, RAW quant, chroma, ICC) plus the jbrd box, then
        // reconstructs the byte-identical JPEG. The source-driven
        // fallback runs only when this can't handle the frame AND
        // `--source` was supplied.
        do {
            let out = try JXLDecoder().decodeLosslessJPEG(jxlBytes)
            try writeReverseOutput(out, to: outputURL, sourceBytes: nil)
            return
        } catch let e as DecoderError {
            guard sourceJPEGPath != nil else {
                print("error: autonomous JXL → JPEG reverse transcode "
                    + "failed: \(e.errorDescription ?? "\(e)"). Supply "
                    + "`--source <orig.jpg>` to fall back to the "
                    + "source-driven path.", to: &standardError)
                throw JXLExitCode.notImplemented
            }
            print("note: autonomous decode unavailable "
                + "(\(e.errorDescription ?? "\(e)")); falling back to "
                + "--source.", to: &standardError)
        }

        // Source-driven fallback (only reached when `--source` present).
        try transcodeJXLtoJPEGFromSource(
            jxlBytes: jxlBytes, outputURL: outputURL,
            sourcePath: sourceJPEGPath!)
    }

    /// Source-driven reverse transcode — used when the autonomous
    /// `JXLDecoder.decodeLosslessJPEG` can't handle the frame. Re-parses
    /// the jbrd box from the JXL, then fills the quant-table values and
    /// per-component sampling factors from the supplied original JPEG
    /// before reconstructing.
    private func transcodeJXLtoJPEGFromSource(
        jxlBytes: Data, outputURL: URL, sourcePath: String
    ) throws {
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
        // Opportunistically recover the codestream ICC for the APP2
        // marker (the autonomous bridge decode that failed upstream may
        // still surface the ICC).
        let bridge = try? JXLDecoder().decodeJPEGBridgeData(jxlBytes)
        let external = JBRDBox.ExternalMetadata(
            exif: exifBox, xmp: xmpBox, icc: bridge?.icc)
        do {
            try box.distributeBrotliPayload(
                decoded, external: external)
        }
        catch let e as JBRDError {
            print("error: jbrd payload distribution failed: \(e)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }
        // Read the source JPEG and patch quant values + sampling factors.
        let sourceBytes: Data
        do {
            sourceBytes = try Data(
                contentsOf: URL(fileURLWithPath: sourcePath))
        } catch {
            print("error reading source JPEG \(sourcePath): "
                + "\(error)", to: &standardError)
            throw JXLExitCode.generalError
        }
        let originalCoeffs: JPEGCoefficientImage
        do {
            originalCoeffs = try JPEGDecoder
                .decodeToCoefficients(sourceBytes)
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
        let rebuilt: Data
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
        try writeReverseOutput(
            rebuilt, to: outputURL, sourceBytes: sourceBytes)
    }

    /// Write reverse-transcode output, and — when a source JPEG is
    /// supplied — report whether the result is byte-identical to it.
    private func writeReverseOutput(
        _ out: Data, to outputURL: URL, sourceBytes: Data?
    ) throws {
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
