// JXLDecoder+LosslessJPEG.swift
//
// Public reverse JPEG-recompression entry point — the symmetric mirror
// of `JXLEncoder.encodeLosslessJPEG(_:)`. Reconstructs the byte-identical
// original JPEG from a JPEG-XL file produced by lossless JPEG
// recompression (Phase J capstone, ISO/IEC 18181-1 Annex J / the `jbrd`
// JPEG-bitstream-reconstruction box of ISO/IEC 18181-2).
//
// The reverse pipeline itself lives in `package`-scoped types
// (`JXLToJPEGAdapter`, `JXLJPEGBridgeData`, the container/jbrd/Brotli
// helpers); this file is the single thin `public` wrapper that chains
// them so an external `import JXLSwift` consumer can reverse-transcode
// without reaching into package internals. The same sequence was
// previously assembled only inside `JXLTool/Transcode.swift`.

import Foundation

extension JXLDecoder {

    /// Reverse JPEG recompression: reconstruct the **byte-identical**
    /// original JPEG from a JPEG-XL file that was produced by lossless
    /// JPEG recompression.
    ///
    /// This is the public mirror of ``JXLEncoder/encodeLosslessJPEG(_:)``
    /// — the round trip `encodeLosslessJPEG` → `decodeLosslessJPEG`
    /// returns the source JPEG bit-for-bit (no generational loss). It
    /// also reverses files produced by `cjxl --lossless_jpeg=1`.
    ///
    /// The reconstruction is **autonomous**: every input is recovered
    /// from the JXL itself — the DCT coefficient planes, the RAW slot-0
    /// quant table, the chroma subsampling, the colour transform and the
    /// codestream ICC profile (all via the VarDCT bridge decode) — plus
    /// the container's `jbrd` box (marker order, Huffman tables, scan
    /// structure, APP/COM metadata). No reference to the original JPEG
    /// is required.
    ///
    /// Supported today: baseline and the common progressive JPEGs, with
    /// 4:4:4 / 4:2:2 / 4:2:0 / 4:4:0 chroma, restart intervals, grayscale,
    /// non-MCU-aligned dimensions, and small / uncompressed APP metadata
    /// (incl. an APP2 `ICC_PROFILE` recovered from the codestream).
    ///
    /// - Parameter jxlBytes: an ISOBMFF-wrapped JPEG-XL file carrying a
    ///   `jbrd` box. The box is present only when the file was produced
    ///   by a JPEG-bridge encoder; a naked codestream or an ordinary
    ///   (non-recompressed) JXL has none.
    /// - Returns: the reconstructed JPEG bytes — byte-identical to the
    ///   source for the supported feature set.
    /// - Throws:
    ///   - ``DecoderError/container(_:)`` if the JXL container is
    ///     malformed.
    ///   - ``DecoderError/notImplemented(_:)`` if the input is a naked
    ///     codestream, carries no `jbrd` box (i.e. is not a recompressed
    ///     JPEG and so cannot be turned back into one), uses a
    ///     Brotli-*compressed* metadata payload (large EXIF/XMP/ICC —
    ///     not yet supported), or contains a frame the autonomous
    ///     coefficient decoder can't handle. The decoder fails safe: it
    ///     throws rather than emitting wrong bytes.
    public func decodeLosslessJPEG(_ jxlBytes: Data) throws -> Data {
        // 1. Parse the container — the `jbrd` box only exists in ISOBMFF.
        let form: JXLContainerForm
        do { form = try parseJXLContainer(jxlBytes) }
        catch let e as ContainerError { throw DecoderError.container(e) }
        guard case .iso(let boxes) = form else {
            throw DecoderError.notImplemented(
                "decodeLosslessJPEG: input is a naked codestream — reverse "
                + "JPEG recompression needs the `jbrd` box from an ISOBMFF "
                + "container.")
        }

        // 2. Locate + read the jbrd box, then Brotli-decode its trailing
        //    payload (APP/COM/inter-marker/tail data).
        let jbrdPayload: Data
        do {
            guard let p = try extractJBRDBox(from: boxes, in: jxlBytes) else {
                throw DecoderError.notImplemented(
                    "decodeLosslessJPEG: JXL container has no `jbrd` box — "
                    + "this file was not produced by JPEG recompression and "
                    + "cannot be reconstructed to a JPEG.")
            }
            jbrdPayload = p
        } catch let e as ContainerError {
            throw DecoderError.container(e)
        }

        var r = BitReader(jbrdPayload)
        var box: JBRDBox
        do { box = try JBRDBoxReader.read(from: &r) }
        catch let e as JBRDError {
            throw DecoderError.notImplemented(
                "decodeLosslessJPEG: jbrd Bundle parse failed: \(e)")
        }
        let brotliStart = (r.position + 7) / 8
        let brotliBytes = jbrdPayload.suffix(from: brotliStart)
        let decoded: Data
        do { decoded = try BrotliDecoder.decode(Data(brotliBytes)) }
        catch let e as BrotliError {
            throw DecoderError.notImplemented(
                "decodeLosslessJPEG: jbrd Brotli payload — \(e). Compressed "
                + "payloads (large EXIF/XMP/ICC metadata) are not supported "
                + "yet; common-case JPEGs (small APP0) decode today.")
        }

        // 3. Extract optional metadata boxes (Exif / xml — direct or
        //    `brob`-wrapped) so kExif / kXMP markers reconstruct exactly.
        let exifBox: Data?
        let xmpBox: Data?
        do {
            exifBox = try extractMetadataBox(
                type: "Exif", from: boxes, in: jxlBytes)
            xmpBox = try extractMetadataBox(
                type: "xml ", from: boxes, in: jxlBytes)
        } catch let e as BrotliError {
            throw DecoderError.notImplemented(
                "decodeLosslessJPEG: metadata box (Exif/xml) uses unsupported "
                + "Brotli-compressed encoding — \(e).")
        }

        // 4. Autonomous bridge decode: coefficient planes + RAW quant
        //    table + chroma subsampling + colour transform + codestream
        //    ICC. Done BEFORE distributing the payload so the recovered
        //    ICC can be spliced into the APP2 `ICC_PROFILE` marker.
        let bridge = try decodeJPEGBridgeData(jxlBytes)

        // 5. Distribute the Brotli payload across the jbrd's app/com/
        //    inter-marker/tail slots, splicing the external metadata.
        let external = JBRDBox.ExternalMetadata(
            exif: exifBox, xmp: xmpBox, icc: bridge.icc)
        do { try box.distributeBrotliPayload(decoded, external: external) }
        catch let e as JBRDError {
            throw DecoderError.notImplemented(
                "decodeLosslessJPEG: jbrd payload distribution failed: \(e)")
        }

        // 6. Reconstruct the byte-identical JPEG.
        do {
            return try JXLToJPEGAdapter.reconstruct(bridgeData: bridge, jbrd: box)
        } catch let e as JXLToJPEGAdapterError {
            throw DecoderError.notImplemented(
                "decodeLosslessJPEG: JPEG reconstruction failed: \(e)")
        }
    }
}
