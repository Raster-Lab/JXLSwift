// `JPEG/JBRDExtractor.swift` — build a `JBRDBox` (+ Brotli payload)
// from a source JPEG. The forward direction of the jbrd reader: it
// captures everything `JXLToJPEGAdapter.reconstruct` needs to rebuild
// the JPEG byte-for-byte — marker order, Huffman tables, scan
// structure, quant-table metadata, component bindings — plus the raw
// app-marker / COM / tail byte content (carried in the Brotli
// payload).
//
// Pairs with `JBRDBoxWriter` (Bundle serialiser) + `BrotliEncoder`
// (uncompressed payload) to let the forward coefficient-bridge emit a
// true lossless-JPEG JXL whose reverse transcode is byte-identical.
//
// Scope: baseline + progressive JPEGs (SOF0/SOF2), with or without
// DRI, treating all app markers as kUnknown (their bytes go in the
// payload — correct for any marker; libjxl's ICC/Exif/XMP templates
// are a file-size optimisation we don't need). Inter-marker data and
// non-canonical padding are not yet captured (cjpeg / our scan encoder
// both use all-ones padding, so `has_zero_padding_bit = false`).

import Foundation

extension JBRDBox {

    /// Errors specific to the forward jbrd extraction.
    package enum ExtractError: Error, Sendable, Equatable {
        case unsupportedMarker(UInt8)
        case malformedSegment(String)
    }

    /// Extract jbrd reconstruction data from a source JPEG. Returns
    /// the populated Bundle plus the (uncompressed) Brotli payload
    /// bytes carrying the kUnknown app / COM / tail content, in the
    /// order `distributeBrotliPayload` reads them.
    package static func extract(
        fromJPEG data: Data
    ) throws -> (box: JBRDBox, brotliPayload: Data) {
        var box = JBRDBox()
        var reader = JPEGSegmentReader(data)
        var appPayload = Data()
        var comPayload = Data()
        var eoiEnd: Int? = nil

        while let seg = try reader.next() {
            let m = seg.markerByte
            if m == 0xD8 { continue }   // SOI excluded from marker_order
            box.markerOrder.append(m)
            switch m {
            case 0xE0...0xEF:           // APPn — all kUnknown
                let content = markerContent(m, seg.payload)
                box.appMarkerType.append(.unknown)
                box.appData.append(content)
                appPayload.append(content)
            case 0xFE:                  // COM
                let content = markerContent(m, seg.payload)
                box.comData.append(content)
                comPayload.append(content)
            case 0xDB:                  // DQT
                try appendQuantTables(seg.payload, to: &box)
            case 0xC0, 0xC1, 0xC2, 0xC3:   // SOFn
                try setFrame(seg.payload, to: &box)
            case 0xC4:                  // DHT
                try appendHuffmanTables(seg.payload, to: &box)
            case 0xDD:                  // DRI
                guard seg.payload.count == 2 else {
                    throw ExtractError.malformedSegment(
                        "DRI payload length \(seg.payload.count) != 2")
                }
                let p = seg.payload
                box.restartInterval =
                    (UInt32(p[p.startIndex]) << 8)
                    | UInt32(p[p.startIndex + 1])
            case 0xDA:                  // SOS
                try appendScanInfo(seg.payload, to: &box)
            case 0xD9:                  // EOI
                eoiEnd = seg.byteOffset + 2
            default:
                throw ExtractError.unsupportedMarker(m)
            }
        }
        // Tail data: anything after the EOI marker.
        if let end = eoiEnd, end < data.count {
            box.tailData = data.subdata(in: end..<data.count)
        }
        box.hasZeroPaddingBit = false   // canonical all-ones padding

        // Brotli payload = app(kUnknown) + com + inter + tail, in the
        // order `distributeBrotliPayload` consumes them.
        var payload = appPayload
        payload.append(comPayload)
        payload.append(box.tailData)
        return (box, BrotliEncoder.encodeUncompressed(payload))
    }

    // MARK: - helpers

    /// Full marker segment content *minus the leading 0xFF*:
    /// `[markerByte, lenHi, lenLo, payload…]` — exactly what
    /// `reconstruct` emits after the `0xFF` prefix and what
    /// `distributeBrotliPayload` reads back.
    private static func markerContent(
        _ m: UInt8, _ payload: Data
    ) -> Data {
        let len = 2 + payload.count
        var d = Data([m,
            UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
        d.append(payload)
        return d
    }

    private static func appendQuantTables(
        _ payload: Data, to box: inout JBRDBox
    ) throws {
        let tables = try JPEGQuantTable.parse(dqtPayload: payload)
        for (i, t) in tables.enumerated() {
            box.quant.append(JBRDQuantTable(
                precision: t.precision == .bits16 ? 1 : 0,
                index: UInt32(t.tableId),
                isLast: i == tables.count - 1))   // last in this marker
        }
    }

    private static func setFrame(
        _ payload: Data, to box: inout JBRDBox
    ) throws {
        guard payload.count >= 6 else {
            throw ExtractError.malformedSegment("SOFn payload < 6")
        }
        let s = payload.startIndex
        box.height = (Int(payload[s + 1]) << 8) | Int(payload[s + 2])
        box.width = (Int(payload[s + 3]) << 8) | Int(payload[s + 4])
        let comps = try JPEGFrameComponent.parseSOFComponents(
            sofPayload: payload)
        box.components = comps.map { c in
            JBRDComponent(
                id: UInt32(c.componentId),
                hSampFactor: c.hSamplingFactor,
                vSampFactor: c.vSamplingFactor,
                quantIdx: UInt32(c.quantTableId))
        }
    }

    private static func appendHuffmanTables(
        _ payload: Data, to box: inout JBRDBox
    ) throws {
        let tables = try JPEGHuffmanTable.parse(dhtPayload: payload)
        for (i, t) in tables.enumerated() {
            // jbrd `counts` is 17-wide (index 0 unused); the EOI
            // sentinel (256) is an extra symbol at the highest used
            // code length. `values` carries the JPEG symbols plus the
            // 256 sentinel.
            var counts = [UInt32](repeating: 0, count: 17)
            for k in 0..<16 { counts[k + 1] = UInt32(t.bits[k]) }
            for k in stride(from: 16, through: 1, by: -1)
            where counts[k] > 0 {
                counts[k] += 1
                break
            }
            var values = t.huffvals.map { UInt32($0) }
            values.append(256)
            let slotId = (t.class == .ac ? 0x10 : 0) | t.tableId
            box.huffmanCode.append(JBRDHuffmanCode(
                counts: counts, values: values,
                slotId: slotId,
                isLast: i == tables.count - 1))   // last in this marker
        }
    }

    private static func appendScanInfo(
        _ payload: Data, to box: inout JBRDBox
    ) throws {
        let sh = try JPEGScanHeader.parse(sosPayload: payload)
        let comps: [JBRDScanComponent] = sh.components.map { sc in
            // jbrd `compIdx` is the component's *index* in the frame
            // (its position in `components`), not its 1-byte id.
            let idx = box.components.firstIndex {
                $0.id == UInt32(sc.componentId)
            } ?? 0
            return JBRDScanComponent(
                compIdx: UInt32(idx),
                dcTblIdx: UInt32(sc.dcTableId),
                acTblIdx: UInt32(sc.acTableId))
        }
        box.scanInfo.append(JBRDScanInfo(
            ss: UInt32(sh.spectralSelectionStart),
            se: UInt32(sh.spectralSelectionEnd),
            ah: UInt32(sh.successiveApproximationHigh),
            al: UInt32(sh.successiveApproximationLow),
            numComponents: UInt32(comps.count),
            components: comps))
    }
}
