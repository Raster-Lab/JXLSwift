// `JPEG/JXLToJPEGAdapter.swift` — reverse direction of the JPEG
// coefficient bridge. Inverse of `JPEGToJXLAdapter`. Takes a JXL
// frame produced by the forward bridge plus its accompanying `jbrd`
// box and produces JPEG bytes that match the source JPEG byte-for-
// byte (when the source went through the forward bridge).
//
// Conceptual data flow:
//
// ```
// JXL bytes ──┬─► JXLDecoder.decode → coefficient planes (Y/Cb/Cr)
//             │
// jbrd box ───┼─► JBRDBox: marker order, quant tables, Huffman tables,
//             │              scan info, padding bits
//             │
//             ▼
//   JXLToJPEGAdapter.reconstruct → JPEG bytes (SOI..EOI)
// ```
//
// Phase J step 5i. v0.12.0g0 scaffold.
//
// Implementation order (planned bites, each becomes its own commit):
//
//  1. **Reverse adapter (coefficient planes → JPEGCoefficientImage)**
//     — invert `toJXLCoefficientPlanes()`. Includes:
//       - undo the JPEG-component-to-JXL-channel remap
//         (`remappedForJXLBridge` inverse)
//       - undo the 8×8 transpose (`block[y*8+x] = jpeg[x*8+y]` reverse)
//       - undo the DC offset added by `applyJPEGBridgeDC` for non-
//         DCzero (kNone) color transforms
//  2. **JPEG bitstream writer** — given a `JPEGCoefficientImage`
//     plus Huffman tables from `jbrd`, emit the JPEG SOS payload
//     (Huffman-coded DC + AC coefficients with byte-stuffing).
//  3. **JPEG container assembly** — walk `jbrd.markerOrder` and emit
//     SOI, COM, APP, DQT, SOF, DHT, DRI, SOS, EOI markers in the
//     recorded order, splicing in the marker payloads from `jbrd`
//     and the scan data from step 2.
//  4. **Padding-bit restoration** — re-apply `jbrd.paddingBits` at
//     the end of each scan so the encoded bits match byte-for-byte.

import Foundation

/// Errors raised by the reverse bridge.
public enum JXLToJPEGAdapterError: Error, Sendable {
    /// The JXL frame's coefficient planes don't match the shape
    /// the jbrd box says they should have.
    case shapeMismatch(String)
    /// A jbrd field has an invalid value or references something
    /// missing from the JXL frame.
    case malformedJBRD(String)
    /// A feature in the reverse bridge we haven't implemented yet.
    case notImplemented(String)
}

/// Reverse-bridge entry point. Given a JXL frame (produced by the
/// forward bridge) and its accompanying `jbrd` box, return the
/// byte-identical JPEG bytes.
public enum JXLToJPEGAdapter {

    /// **Autonomous reverse transcode.** Reconstruct the source JPEG
    /// from a cjxl `--lossless_jpeg=1` file with **no reference to
    /// the original** — every input comes from the JXL itself:
    /// `bridgeData` (coefficients + RAW quant table + chroma info,
    /// from `JXLDecoder.decodeJPEGBridgeData`) plus the container's
    /// jbrd box (marker order / Huffman / scan structure).
    ///
    /// Fills the two slots the jbrd Bundle leaves empty — the quant
    /// table **values** (recovered from the codestream RAW slot) and
    /// the per-component **sampling factors** (recovered from the
    /// frame's chroma subsampling) — then delegates to
    /// `reconstruct(coefficients:jbrd:colorTransform:)`.
    public static func reconstruct(
        bridgeData: JXLJPEGBridgeData,
        jbrd: JBRDBox
    ) throws -> Data {
        var box = jbrd
        let ct = bridgeData.colorTransform
        let isGray = box.components.count == 1
        let order = JPEGToJXLAdapter.jpegOrder(
            colorTransform: ct, isGray: isGray)
        let mapping = [order.0, order.1, order.2]   // jxlChannel → jpegComp

        // 1. Recover JPEG quant-table values from the RAW slot.
        //    `rawQuantTable[jxlC*64 + 8*x + y] = naturalQuant[8*y + x]`
        //    (inverse of `buildJXLBridgeRAWQuantPayload`); then pack
        //    natural → zig-zag and store into the quant table each
        //    component points at.
        if let raw = bridgeData.rawQuantTable, raw.count == 3 * 64 {
            for jxlC in 0..<3 {
                let jpegC = mapping[jxlC]
                guard jpegC < box.components.count else { continue }
                let qIdx = Int(box.components[jpegC].quantIdx)
                guard qIdx < box.quant.count else { continue }
                var natural = [Int32](repeating: 1, count: 64)
                for y in 0..<8 {
                    for x in 0..<8 {
                        natural[8 * y + x] = raw[jxlC * 64 + 8 * x + y]
                    }
                }
                var zigzag = [Int32](repeating: 0, count: 64)
                for k in 0..<64 {
                    zigzag[k] = natural[JPEGZigZag.order[k]]
                }
                box.quant[qIdx].values = zigzag
            }
        }

        // 2. Recover per-component JPEG sampling factors from the
        //    frame's chroma subsampling. libjxl `Set` stores
        //    `hsample[jpeg] == 1 << RawHShift(color)`; with
        //    `RawHShift(c) = maxHShift - HShift(c)` and the color
        //    channel for JPEG component `jpegC` being the `jxlC`
        //    that maps to it.
        let cs = bridgeData.chromaSubsampling
        for jxlC in 0..<3 {
            let jpegC = mapping[jxlC]
            guard jpegC < box.components.count else { continue }
            box.components[jpegC].hSampFactor =
                1 << (cs.maxHShift - cs.hShift(jxlC))
            box.components[jpegC].vSampFactor =
                1 << (cs.maxVShift - cs.vShift(jxlC))
        }

        return try reconstruct(
            coefficients: bridgeData.planes,
            jbrd: box,
            colorTransform: ct,
            imageWidth: bridgeData.width,
            imageHeight: bridgeData.height)
    }

    /// Reconstruct the source JPEG bytes from a JXL frame + jbrd
    /// metadata. Output matches the source JPEG **byte-for-byte**
    /// when the jbrd's `app_data` / `com_data` / `inter_marker_data` /
    /// `tail_data` slots have been filled (via
    /// `JBRDBox.distributeBrotliPayload(...)` after running the
    /// Brotli decoder on the trailing payload of the jbrd box).
    ///
    /// Walks `jbrd.markerOrder` and emits markers in source order:
    /// - SOI (0xD8) — always emitted first (it's NOT in markerOrder
    ///   per libjxl convention).
    /// - APPn (0xE0..0xEF) — splice in `jbrd.appData[appIdx++]`.
    /// - COM (0xFE) — splice in `jbrd.comData[comIdx++]`.
    /// - DQT (0xDB) — emit from `coefficients` via `quantTables`.
    /// - DRI (0xDD) — emit `jbrd.restartInterval`.
    /// - SOFn (0xC0/0xC2/...) — emit from coefficients dimensions +
    ///   frame components.
    /// - DHT (0xC4) — emit from `jbrd.huffmanCode`, walking up to
    ///   `is_last`.
    /// - SOS (0xDA) — emit scan header from `jbrd.scanInfo[scanIdx]`
    ///   then the entropy-coded data via `JPEGScanEncoder` using
    ///   the jbrd's Huffman tables; restore `jbrd.paddingBits` at
    ///   end of scan.
    /// - 0xFF (intermarker sentinel) — splice in
    ///   `jbrd.interMarkerData[imIdx++]`.
    /// - EOI (0xD9) — terminate output.
    /// - Otherwise — surface as malformed for the moment.
    ///
    /// `jbrd.tailData` (if any) is appended after EOI.
    ///
    /// **Status (v0.12.0ge — initial integration).** Implements the
    /// common-case marker set (SOI / APPn / DQT / SOFn / DHT / SOS /
    /// EOI). DRI, COM, intermarker, padding-bit-restoration are
    /// straightforward extensions; multi-scan SOS (progressive)
    /// would need a scan-encoder rewrite to handle Ss/Se/Ah/Al.
    public static func reconstruct(
        coefficients: JXLCoefficientPlanes,
        jbrd: JBRDBox,
        colorTransform: JXLBridgeColorTransform,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil
    ) throws -> Data {
        guard !jbrd.markerOrder.isEmpty else {
            throw JXLToJPEGAdapterError.malformedJBRD(
                "markerOrder is empty")
        }
        // Step 1: Undo the JXL bridge channel remap so planes are
        // in JPEG component order (Y, Cb, Cr).
        let unremapped = coefficients.inverseJXLBridgeRemap(
            colorTransform: colorTransform)
        // Build frameComponents and quantTables from `jbrd`.
        let frameComponents = try buildFrameComponents(jbrd: jbrd)
        let quantTables = try buildQuantTables(jbrd: jbrd)
        // Step 2: Build the per-component coefficient image
        // (inverts the 8×8 transpose). The SOFn dimensions are the
        // *true* pixel size (from the JXL SizeHeader) when supplied —
        // not the block-rounded grid — so odd-sized JPEGs (e.g.
        // 17×23) reconstruct byte-identically. The block-rounded
        // fallback preserves callers that don't thread the true size.
        let image = try unremapped.toJPEGCoefficientImage(
            width: imageWidth ?? coefficients.blocksX * 8,
            height: imageHeight ?? coefficients.blocksY * 8,
            precision: 8, frameKind: .baselineDCT,
            frameComponents: frameComponents,
            quantTables: quantTables)
        // Step 3: Marker-order walk.
        var out = Data()
        out.reserveCapacity(1024 + image.totalCoefficientCount)
        // SOI first — libjxl excludes it from markerOrder.
        out.append(contentsOf: [0xFF, 0xD8])
        var appIdx = 0
        var comIdx = 0
        var imIdx = 0
        var scanIdx = 0
        var huffCursor = 0
        var quantCursor = 0
        var isProgressive = false
        for marker in jbrd.markerOrder {
            switch marker {
            case 0xD8:
                // SOI inside markerOrder — already emitted above.
                // libjxl convention is to omit but we tolerate.
                break
            case 0xD9:
                // EOI — terminator.
                out.append(contentsOf: [0xFF, 0xD9])
            case 0xE0...0xEF:
                // APPn — splice from jbrd.appData[appIdx].
                guard appIdx < jbrd.appData.count else {
                    throw JXLToJPEGAdapterError.malformedJBRD(
                        "APP marker but appData[\(appIdx)] OOB")
                }
                // libjxl convention: `appData[i][0]` IS the marker
                // byte itself; `[1..2]` is the length field; rest
                // is payload. We only emit the marker prefix
                // (`0xFF`) and the full `appData[i]` — NOT the
                // marker byte again.
                out.append(0xFF)
                out.append(jbrd.appData[appIdx])
                appIdx += 1
            case 0xFE:
                // COM marker — same convention as APP markers:
                // comData[i][0] is the marker byte (0xFE).
                guard comIdx < jbrd.comData.count else {
                    throw JXLToJPEGAdapterError.malformedJBRD(
                        "COM marker but comData[\(comIdx)] OOB")
                }
                out.append(0xFF)
                out.append(jbrd.comData[comIdx])
                comIdx += 1
            case 0xDB:
                // DQT segment — emit consecutive quant tables from
                // `jbrd.quant` until one has `isLast == true`. This
                // mirrors how the source JPEG packed multiple tables
                // into a single DQT marker.
                emitDQT(jbrd: jbrd, cursor: &quantCursor, to: &out)
            case 0xDD:
                // DRI marker (define-restart-interval).
                out.append(contentsOf: [0xFF, 0xDD])
                // Segment length = 4 (2 length + 2 interval).
                out.append(contentsOf: [0x00, 0x04])
                out.append(UInt8((jbrd.restartInterval >> 8) & 0xFF))
                out.append(UInt8(jbrd.restartInterval & 0xFF))
            case 0xC0, 0xC1, 0xC2, 0xC3:
                // SOFn. 0xC2 = progressive DCT (SOF2).
                if marker == 0xC2 { isProgressive = true }
                try emitSOF(marker: marker, image: image, to: &out)
            case 0xC4:
                // DHT — consume Huffman codes up to is_last.
                try emitDHT(jbrd: jbrd, cursor: &huffCursor,
                            to: &out)
            case 0xDA:
                // SOS — scan header + entropy-coded data.
                guard scanIdx < jbrd.scanInfo.count else {
                    throw JXLToJPEGAdapterError.malformedJBRD(
                        "SOS but scanInfo[\(scanIdx)] OOB")
                }
                try emitSOSPlusScan(
                    jbrd: jbrd, scanIdx: scanIdx,
                    image: image, progressive: isProgressive,
                    huffDefinedUpTo: huffCursor, to: &out)
                scanIdx += 1
            case 0xFF:
                // Intermarker data sentinel.
                guard imIdx < jbrd.interMarkerData.count else {
                    throw JXLToJPEGAdapterError.malformedJBRD(
                        "intermarker but interMarkerData["
                        + "\(imIdx)] OOB")
                }
                out.append(jbrd.interMarkerData[imIdx])
                imIdx += 1
            default:
                throw JXLToJPEGAdapterError.notImplemented(
                    "marker 0x" + String(marker, radix: 16,
                        uppercase: true)
                    + " not yet supported in reconstruct()")
            }
        }
        // Tail data after EOI (uncommon — some scanners append
        // trailing bytes that some decoders ignore).
        if !jbrd.tailData.isEmpty {
            out.append(jbrd.tailData)
        }
        return out
    }

    /// Build `frameComponents` from `jbrd.components` for the
    /// reconstruction pipeline.
    private static func buildFrameComponents(
        jbrd: JBRDBox
    ) throws -> [JPEGFrameComponent] {
        return jbrd.components.map { c in
            JPEGFrameComponent(
                componentId: Int(c.id),
                hSamplingFactor: c.hSampFactor,
                vSamplingFactor: c.vSampFactor,
                quantTableId: Int(c.quantIdx))
        }
    }

    /// Build `quantTables` placeholder — the actual values come from
    /// the JXL frame's HfGlobal quant matrices and need to be
    /// passed in separately. For now, returns empty tables sized
    /// to `jbrd.quant.count`. The reconstruct() entry expects the
    /// caller to have set `coefficients.dcPerChannel` etc. with
    /// already-decoded coefficients; the quant table values are
    /// emitted into DQT segments from `jbrd.quant.values`.
    ///
    /// **Status (v0.12.0ge)**. JBRDQuantTable.values is currently
    /// always empty after Bundle parse (quant values come from the
    /// JXL frame, not the Bundle). For real round-trip use, the
    /// caller fills these in from the JXL frame's quant matrices.
    private static func buildQuantTables(
        jbrd: JBRDBox
    ) throws -> [JPEGQuantTable] {
        return jbrd.quant.map { q in
            let zigzag: [UInt16] = q.values.isEmpty
                ? Array(repeating: 0, count: 64)
                : q.values.map { UInt16($0) }
            return JPEGQuantTable(
                tableId: Int(q.index),
                precision: q.precision == 0 ? .bits8 : .bits16,
                zigZagValues: zigzag)
        }
    }

    private static func emitDQT(
        jbrd: JBRDBox, cursor: inout Int, to out: inout Data
    ) {
        // Group consecutive quant tables from `cursor` until one
        // has `isLast == true` — that group goes into a single DQT
        // marker segment.
        var group: [JBRDQuantTable] = []
        while cursor < jbrd.quant.count {
            let q = jbrd.quant[cursor]
            group.append(q)
            cursor += 1
            if q.isLast { break }
        }
        // Compute total segment length.
        var payloadLen = 0
        for q in group {
            let bytes = q.precision == 0 ? 64 : 128
            payloadLen += 1 + bytes
        }
        let totalLen = 2 + payloadLen
        out.append(0xFF); out.append(0xDB)
        out.append(UInt8((totalLen >> 8) & 0xFF))
        out.append(UInt8(totalLen & 0xFF))
        for q in group {
            let pqtq = (UInt8(q.precision) << 4)
                | UInt8(q.index)
            out.append(pqtq)
            for v in q.values {
                if q.precision == 0 {
                    out.append(UInt8(v & 0xFF))
                } else {
                    out.append(UInt8((v >> 8) & 0xFF))
                    out.append(UInt8(v & 0xFF))
                }
            }
        }
    }

    private static func emitSOF(
        marker: UInt8, image: JPEGCoefficientImage,
        to out: inout Data
    ) throws {
        let nf = image.frameComponents.count
        let len = 2 + 1 + 2 + 2 + 1 + nf * 3
        out.append(0xFF); out.append(marker)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(UInt8(image.precision))
        out.append(UInt8((image.height >> 8) & 0xFF))
        out.append(UInt8(image.height & 0xFF))
        out.append(UInt8((image.width >> 8) & 0xFF))
        out.append(UInt8(image.width & 0xFF))
        out.append(UInt8(nf))
        for fc in image.frameComponents {
            out.append(UInt8(fc.componentId))
            let hv = (UInt8(fc.hSamplingFactor) << 4)
                | UInt8(fc.vSamplingFactor)
            out.append(hv)
            out.append(UInt8(fc.quantTableId))
        }
    }

    private static func emitDHT(
        jbrd: JBRDBox, cursor: inout Int, to out: inout Data
    ) throws {
        // Consume Huffman entries up to is_last.
        guard cursor < jbrd.huffmanCode.count else {
            throw JXLToJPEGAdapterError.malformedJBRD(
                "DHT but huffmanCode[\(cursor)] OOB")
        }
        // Group entries up to and including `is_last`.
        var group: [JBRDHuffmanCode] = []
        while cursor < jbrd.huffmanCode.count {
            let hc = jbrd.huffmanCode[cursor]
            group.append(hc)
            cursor += 1
            if hc.isLast { break }
        }
        // Compute segment length.
        var payloadLen = 0
        for hc in group {
            let n = hc.values.count - 1   // exclude EOI sentinel
            payloadLen += 1 + 16 + n
        }
        let totalLen = 2 + payloadLen
        out.append(0xFF); out.append(0xC4)
        out.append(UInt8((totalLen >> 8) & 0xFF))
        out.append(UInt8(totalLen & 0xFF))
        for hc in group {
            // Class nibble + slot id nibble.
            let isAC = (hc.slotId & 0x10) != 0
            let id = hc.slotId & 0x0F
            out.append(UInt8((isAC ? 1 : 0) << 4) | UInt8(id))
            // Emit `bits[16]` (counts[1..16]). libjxl's jbrd Bundle
            // stores `counts` such that sum equals the symbol count
            // *including* the EOI sentinel (256). When emitting JPEG
            // DHT bytes we must subtract the sentinel's contribution:
            // decrement the count at the highest non-zero bit length
            // by 1 (per libjxl encoder convention, the EOI sentinel
            // is placed at the maximum bit length).
            var emitCounts = Array(hc.counts[1...16])
            for k in stride(from: 15, through: 0, by: -1) {
                if emitCounts[k] > 0 {
                    emitCounts[k] -= 1
                    break
                }
            }
            for c in emitCounts {
                out.append(UInt8(c & 0xFF))
            }
            // Values excluding EOI sentinel = 256.
            for v in hc.values where v < 256 {
                out.append(UInt8(v & 0xFF))
            }
        }
    }

    private static func emitSOSPlusScan(
        jbrd: JBRDBox, scanIdx: Int,
        image: JPEGCoefficientImage,
        progressive: Bool,
        huffDefinedUpTo: Int,
        to out: inout Data
    ) throws {
        let scan = jbrd.scanInfo[scanIdx]
        // SOS segment.
        let ns = Int(scan.numComponents)
        let len = 2 + 1 + ns * 2 + 3
        out.append(0xFF); out.append(0xDA)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(UInt8(ns))
        for k in 0..<ns {
            let sc = scan.components[k]
            let comp = image.frameComponents[Int(sc.compIdx)]
            out.append(UInt8(comp.componentId))
            let tdta = (UInt8(sc.dcTblIdx) << 4)
                | UInt8(sc.acTblIdx)
            out.append(tdta)
        }
        out.append(UInt8(scan.ss & 0xFF))
        out.append(UInt8(scan.se & 0xFF))
        out.append(UInt8(((scan.ah & 0xF) << 4) | (scan.al & 0xF)))
        // Entropy-coded data via JPEGScanEncoder.
        var dcTables: [[JPEGHuffmanEncodeEntry]?] = Array(
            repeating: nil, count: 4)
        var acTables: [[JPEGHuffmanEncodeEntry]?] = Array(
            repeating: nil, count: 4)
        // Use only the Huffman tables defined by DHT markers emitted
        // *before* this scan (`huffDefinedUpTo`). Progressive JPEGs
        // redefine the same slot IDs between scans, so the full list
        // would wrongly apply a later scan's table. Later definitions
        // within the active prefix override earlier ones.
        for hc in jbrd.huffmanCode.prefix(huffDefinedUpTo) {
            let isAC = (hc.slotId & 0x10) != 0
            let id = hc.slotId & 0x0F
            var counts17 = [UInt32](repeating: 0, count: 17)
            for k in 0..<16 { counts17[k + 1] = hc.counts[k + 1] }
            // exclude EOI sentinel (256) from encoder values
            let vals = hc.values.filter { $0 < 256 }
            let table = JPEGHuffmanEncodeTable.build(
                counts: counts17, values: vals)
            if isAC {
                acTables[id] = table
            } else {
                dcTables[id] = table
            }
        }
        let scanCompsEnc: [JPEGScanComponentEncode] =
            scan.components.prefix(ns).map { sc in
            JPEGScanComponentEncode(
                componentIndex: Int(sc.compIdx),
                dcTableId: Int(sc.dcTblIdx),
                acTableId: Int(sc.acTblIdx))
        }
        let scanBytes: Data
        if progressive {
            scanBytes = try JPEGScanEncoder.encodeProgressive(
                ss: Int(scan.ss), se: Int(scan.se),
                ah: Int(scan.ah), al: Int(scan.al),
                components: image.quantisedComponents,
                frameComponents: image.frameComponents,
                scanComponents: scanCompsEnc,
                dcTables: dcTables, acTables: acTables,
                restartInterval: Int(jbrd.restartInterval),
                imageWidth: image.width,
                imageHeight: image.height)
        } else {
            scanBytes = try JPEGScanEncoder.encodeBaselineSequential(
                components: image.quantisedComponents,
                frameComponents: image.frameComponents,
                scanComponents: scanCompsEnc,
                dcTables: dcTables, acTables: acTables,
                restartInterval: Int(jbrd.restartInterval),
                imageWidth: image.width,
                imageHeight: image.height)
        }
        out.append(scanBytes)
    }

    /// **Minimal-JPEG reconstruction.** Produces a structurally valid
    /// JPEG file (SOI..EOI) from JXL coefficient planes plus
    /// supplied Huffman + quant tables. Doesn't require Brotli or
    /// jbrd. The output won't match the source byte-for-byte but
    /// will:
    ///   - Decode to the same coefficient values via any JPEG decoder.
    ///   - Decode to the same pixels (modulo decoder rounding).
    ///
    /// Caller-supplied parameters:
    ///   - `coefficients`: JXL planes in JXL channel order (X=Cb,
    ///     Y, B=Cr for `.ycbcr`). This function applies the inverse
    ///     remap + (if needed) the inverse DC offset internally.
    ///   - `width` / `height`: pixel dimensions (typically from the
    ///     SOFn that produced the JXL frame).
    ///   - `frameComponents`: SOFn component definitions in JPEG
    ///     order (Y first, then Cb, then Cr for 3-component YCbCr;
    ///     or just Y for grayscale).
    ///   - `quantTables`: per-table quant matrices in zig-zag order.
    ///   - `dcHuffmanTables` / `acHuffmanTables`: Huffman tables to
    ///     emit. Typically the ITU-T Annex K standard luma + chroma
    ///     tables when we don't have a `jbrd` to draw on.
    ///   - `scanComponents`: per-scan binding info (component index,
    ///     DC/AC table ids).
    ///   - `colorTransform`: the JXL color transform that was used
    ///     by the forward bridge (controls whether DC inversion is
    ///     applied).
    ///   - `quantDCPerChannel`: DC quant factors per component in
    ///     JXL channel order; used only when `colorTransform == .none`
    ///     to invert the `1024/qt[DC]` offset.
    public static func reconstructMinimal(
        coefficients: JXLCoefficientPlanes,
        width: Int, height: Int,
        frameComponents: [JPEGFrameComponent],
        quantTables: [JPEGQuantTable],
        dcHuffmanTables: [JPEGHuffmanTable],
        acHuffmanTables: [JPEGHuffmanTable],
        scanComponents: [JPEGScanComponentEncode],
        colorTransform: JXLBridgeColorTransform,
        quantDCPerChannel: [UInt16] = []
    ) throws -> Data {
        // 1. Undo the JXL bridge's channel remap so planes are in
        //    JPEG component order (Y, Cb, Cr).
        let unremapped = coefficients.inverseJXLBridgeRemap(
            colorTransform: colorTransform)
        // 2. Undo the DC offset if needed.
        let unoffset: JXLCoefficientPlanes
        if colorTransform == .none && !quantDCPerChannel.isEmpty {
            unoffset = unremapped.inverseJPEGBridgeDC(
                colorTransform: colorTransform,
                quantDCPerChannel: quantDCPerChannel)
        } else {
            unoffset = unremapped
        }
        // 3. Transpose AC back and build a JPEGCoefficientImage.
        let image = try unoffset.toJPEGCoefficientImage(
            width: width, height: height,
            precision: 8, frameKind: .baselineDCT,
            frameComponents: frameComponents,
            quantTables: quantTables)
        // 4. Assemble the JPEG container.
        return try JPEGContainerWriter.write(
            image: image,
            dcHuffmanTables: dcHuffmanTables,
            acHuffmanTables: acHuffmanTables,
            scanComponents: scanComponents)
    }
}

extension JXLCoefficientPlanes {

    /// Invert `remappedForJXLBridge` — given planes in JXL channel
    /// order (X=Cb, Y, B=Cr), return planes in JPEG component order
    /// (Y, Cb, Cr) for grayscale or 3-component frames.
    public func inverseJXLBridgeRemap(
        colorTransform: JXLBridgeColorTransform
    ) -> JXLCoefficientPlanes {
        if channelCount == 1 { return self }
        precondition(channelCount == 3,
            "inverseJXLBridgeRemap requires 1 or 3 channels")
        let forward = JPEGToJXLAdapter.jpegOrder(
            colorTransform: colorTransform, isGray: false)
        let forwardMap = [forward.0, forward.1, forward.2]
        // Inverse: for each JPEG component `j`, find the JXL slot
        // it ended up in. `inverseMap[j] = i` iff `forwardMap[i] = j`.
        var inverseMap = [Int](repeating: 0, count: 3)
        for i in 0..<3 {
            inverseMap[forwardMap[i]] = i
        }
        let newDC = inverseMap.map { dcPerChannel[$0] }
        let newAC = inverseMap.map { acPerChannel[$0] }
        let newBpc = inverseMap.map { blocksPerChannel[$0] }
        return JXLCoefficientPlanes(
            blocksX: blocksX, blocksY: blocksY,
            channelCount: channelCount,
            dcPerChannel: newDC,
            acPerChannel: newAC,
            blocksPerChannel: newBpc)
    }

    /// Invert `applyJPEGBridgeDC` — for `colorTransform == .none`,
    /// subtract the `1024 / qt[DC]` offset that the forward bridge
    /// added. For `.ycbcr` (DCzero=true) the forward pass didn't
    /// modify DC, so this is a no-op.
    public func inverseJPEGBridgeDC(
        colorTransform: JXLBridgeColorTransform,
        quantDCPerChannel: [UInt16]
    ) -> JXLCoefficientPlanes {
        precondition(quantDCPerChannel.count == channelCount,
            "inverseJPEGBridgeDC: quantDCPerChannel.count must "
            + "equal channelCount")
        switch colorTransform {
        case .ycbcr:
            return self
        case .none:
            var newDC = dcPerChannel
            for c in 0..<channelCount {
                let qDC = Int32(quantDCPerChannel[c])
                guard qDC != 0 else { continue }
                let offset = Int32(1024) / qDC
                for i in 0..<newDC[c].count {
                    newDC[c][i] &-= offset
                }
            }
            return JXLCoefficientPlanes(
                blocksX: blocksX, blocksY: blocksY,
                channelCount: channelCount,
                dcPerChannel: newDC,
                acPerChannel: acPerChannel,
                blocksPerChannel: blocksPerChannel)
        }
    }

    /// Build a `JPEGCoefficientImage` from JXL coefficient planes by
    /// inverting both the channel remap and the 8×8 transpose the
    /// forward adapter applied (`ac[k=y*8+x] = jpeg[x*8+y]`).
    ///
    /// **Caller contract.** `self` must be in **JPEG component order**
    /// (i.e. caller has already applied `inverseJXLBridgeRemap` if the
    /// frame was kYCbCr-remapped) and DC values must be in JPEG raw
    /// form (caller has applied `inverseJPEGBridgeDC` if the forward
    /// pass added the `1024/qt[DC]` offset for `.none`).
    ///
    /// Inputs needed beyond `self`:
    ///   - `width`, `height` — SOFn dimensions (from jbrd / source).
    ///   - `frameComponents` — per-component sampling factors + quant
    ///     bindings (mirrors what `JPEGScanHeader.parse` produced for
    ///     the original JPEG; passed in because we don't reconstruct
    ///     SOFn from JXL alone).
    ///   - `quantTables` — per-table zig-zag matrices (from `jbrd`).
    ///   - `precision`, `frameKind` — typically 8 + `.baselineDCT`.
    ///
    /// **v0.12.0g1.** Forward path was:
    ///   `ac[bi][k = y*8+x] = jpeg.coefficients[x*8+y]` (transpose)
    /// Reverse path is the inverse:
    ///   `jpeg.coefficients[x*8+y] = ac[bi][y*8+x]`
    /// DC is just copied straight from `dcPerChannel[c][bi]`.
    public func toJPEGCoefficientImage(
        width: Int, height: Int,
        precision: Int = 8,
        frameKind: JPEGStructure.FrameKind = .baselineDCT,
        frameComponents: [JPEGFrameComponent],
        quantTables: [JPEGQuantTable]
    ) throws -> JPEGCoefficientImage {
        guard frameComponents.count == channelCount else {
            throw JXLToJPEGAdapterError.shapeMismatch(
                "frameComponents.count \(frameComponents.count) ≠ "
                + "channelCount \(channelCount)")
        }
        var components: [JPEGComponentBlocks] = []
        components.reserveCapacity(channelCount)
        for c in 0..<channelCount {
            let bX = blocksPerChannel[c].blocksX
            let bY = blocksPerChannel[c].blocksY
            let total = bX * bY
            guard dcPerChannel[c].count == total else {
                throw JXLToJPEGAdapterError.shapeMismatch(
                    "channel \(c): dcPerChannel.count "
                    + "\(dcPerChannel[c].count) ≠ "
                    + "blocksWide × blocksHigh \(total)")
            }
            guard acPerChannel[c].count == total else {
                throw JXLToJPEGAdapterError.shapeMismatch(
                    "channel \(c): acPerChannel.count "
                    + "\(acPerChannel[c].count) ≠ "
                    + "blocksWide × blocksHigh \(total)")
            }
            var blocks: [JPEGCoefficientBlock] = []
            blocks.reserveCapacity(total)
            for bi in 0..<total {
                var coeffs = [Int32](repeating: 0, count: 64)
                // DC at position 0.
                coeffs[0] = dcPerChannel[c][bi]
                // AC transpose-back: jpeg[x*8 + y] = ac[y*8 + x].
                let acBlock = acPerChannel[c][bi]
                for y in 0..<8 {
                    for x in 0..<8 {
                        let jxlIdx = y * 8 + x
                        if jxlIdx == 0 { continue }
                        coeffs[x * 8 + y] = acBlock[jxlIdx]
                    }
                }
                blocks.append(JPEGCoefficientBlock(coeffs))
            }
            components.append(JPEGComponentBlocks(
                componentId: frameComponents[c].componentId,
                blocksWide: bX, blocksHigh: bY,
                blocks: blocks))
        }
        return JPEGCoefficientImage(
            width: width, height: height,
            precision: precision,
            frameKind: frameKind,
            frameComponents: frameComponents,
            quantisedComponents: components,
            quantTables: quantTables)
    }
}
