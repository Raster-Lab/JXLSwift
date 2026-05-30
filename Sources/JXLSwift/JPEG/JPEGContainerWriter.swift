// `JPEG/JPEGContainerWriter.swift` — assemble a complete JPEG file
// from its constituent parts (quant tables, Huffman tables, frame
// dimensions, scan, entropy-coded data).
//
// Phase J step 5i support. v0.12.0g4.
//
// This writer produces a **minimal valid baseline-JPEG file** — SOI,
// then DQT + DHT + SOFn + SOS + entropy + EOI. It does NOT yet
// reproduce a source JPEG byte-for-byte; that requires a `jbrd`-
// driven assembler (which knows the original marker order, app/com
// data, intermarker bytes, tail data, and padding bits) and is the
// follow-on bite.
//
// For a JXL → JPEG transcode that produces decodable JPEG output
// matching the source pixels (but with our own marker layout), this
// is enough.

import Foundation

/// Errors raised by the container writer.
package enum JPEGContainerWriteError: Error, Sendable, Equatable {
    /// Component count outside 1..3.
    case invalidComponentCount(Int)
    /// Frame dimension exceeds the 16-bit field limit (65535).
    case dimensionTooLarge(Int)
    /// Quant precision must be 0 (8-bit) or 1 (16-bit) — for 8-bit
    /// JPEGs we accept only precision=0.
    case invalidQuantPrecision(UInt32)
}

package enum JPEGContainerWriter {

    /// Build a complete minimal baseline-JPEG byte stream.
    ///
    /// - Parameters:
    ///   - image: per-component coefficient blocks + frame metadata.
    ///   - dcHuffmanTables: list of DC Huffman tables to emit (each
    ///     with a slot id 0..3).
    ///   - acHuffmanTables: list of AC Huffman tables to emit (each
    ///     with a slot id 0..3).
    ///   - scanComponents: per-scan binding info (component id →
    ///     DC/AC table id pair).
    /// - Returns: complete JPEG bytes (SOI..EOI).
    package static func write(
        image: JPEGCoefficientImage,
        dcHuffmanTables: [JPEGHuffmanTable],
        acHuffmanTables: [JPEGHuffmanTable],
        scanComponents: [JPEGScanComponentEncode]
    ) throws -> Data {
        guard image.frameComponents.count >= 1
            && image.frameComponents.count <= 3 else {
            throw JPEGContainerWriteError.invalidComponentCount(
                image.frameComponents.count)
        }
        guard image.width <= 0xFFFF && image.height <= 0xFFFF else {
            throw JPEGContainerWriteError.dimensionTooLarge(
                max(image.width, image.height))
        }
        var out = Data()

        // SOI.
        out.append(contentsOf: [0xFF, 0xD8])

        // DQT — one segment per quant table.
        for q in image.quantTables {
            try writeDQT(q, to: &out)
        }

        // SOFn — baseline-DCT for now (other frame kinds need
        // distinct SOF markers — SOF0 = 0xC0, SOF2 = 0xC2 for
        // progressive, etc.). Defaults to SOF0.
        try writeSOF0(image, to: &out)

        // DHT — emit all DC then AC tables. Each table has its
        // own DHT marker (technically can be combined but per-marker
        // emission is simpler and accepted by all decoders).
        for t in dcHuffmanTables {
            writeDHT(t, to: &out)
        }
        for t in acHuffmanTables {
            writeDHT(t, to: &out)
        }

        // SOS + entropy-coded data.
        writeSOS(scanComponents: scanComponents,
                 components: image.frameComponents,
                 to: &out)
        // Entropy data — caller-supplied via `JPEGScanEncoder`.
        let dcEnc: [[JPEGHuffmanEncodeEntry]?] =
            buildEncodeTables(dcHuffmanTables)
        let acEnc: [[JPEGHuffmanEncodeEntry]?] =
            buildEncodeTables(acHuffmanTables)
        let scan = try JPEGScanEncoder.encodeBaselineSequential(
            components: image.quantisedComponents,
            frameComponents: image.frameComponents,
            scanComponents: scanComponents,
            dcTables: dcEnc, acTables: acEnc,
            restartInterval: 0,
            imageWidth: image.width,
            imageHeight: image.height)
        out.append(scan)

        // EOI.
        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    // MARK: - Segment writers

    /// DQT marker payload:
    ///   marker:       0xFF 0xDB
    ///   length:       2 bytes (covers length field + payload)
    ///   PqTq:         1 byte (high nibble = precision, low = slot id)
    ///   Qk:           64 bytes (precision=0) or 128 (precision=1)
    private static func writeDQT(
        _ q: JPEGQuantTable, to out: inout Data
    ) throws {
        // Total length = 2 (length field) + 1 (PqTq) + (64 or 128).
        let qBytes = q.precision == .bits8 ? 64 : 128
        let len = 2 + 1 + qBytes
        out.append(0xFF); out.append(0xDB)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        let pqtq = (UInt8(q.precision.rawValue) << 4)
            | UInt8(q.tableId)
        out.append(pqtq)
        for v in q.zigZagValues {
            if q.precision == .bits8 {
                out.append(UInt8(v & 0xFF))
            } else {
                out.append(UInt8((v >> 8) & 0xFF))
                out.append(UInt8(v & 0xFF))
            }
        }
    }

    /// SOF0 (baseline DCT) marker:
    ///   marker:       0xFF 0xC0
    ///   length:       2 bytes
    ///   P:            1 byte (precision, typically 8)
    ///   Y:            2 bytes (height)
    ///   X:            2 bytes (width)
    ///   Nf:           1 byte (component count)
    ///   per component: id (1B), HiVi (1B), Tq (1B)
    private static func writeSOF0(
        _ image: JPEGCoefficientImage, to out: inout Data
    ) throws {
        let nf = image.frameComponents.count
        let len = 2 + 1 + 2 + 2 + 1 + nf * 3
        out.append(0xFF); out.append(0xC0)
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

    /// DHT marker:
    ///   marker:       0xFF 0xC4
    ///   length:       2 bytes
    ///   TcTh:         1 byte (high nibble = class 0/1 = DC/AC,
    ///                          low = slot id)
    ///   Li (16):      16 bytes of code-length counts
    ///   Vi:           sum(Li) bytes of symbol values
    private static func writeDHT(
        _ t: JPEGHuffmanTable, to out: inout Data
    ) {
        let nVals = t.huffvals.count
        let len = 2 + 1 + 16 + nVals
        out.append(0xFF); out.append(0xC4)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        let tcth = (UInt8(t.class.rawValue) << 4)
            | UInt8(t.tableId)
        out.append(tcth)
        for b in t.bits {
            out.append(b)
        }
        for v in t.huffvals {
            out.append(v)
        }
    }

    /// SOS marker:
    ///   marker:       0xFF 0xDA
    ///   length:       2 bytes
    ///   Ns:           1 byte (component count in scan)
    ///   per component: Cs (1B id), TdTa (1B = DC table | AC table)
    ///   Ss:           1 byte (start of spectral selection, 0 for
    ///                          baseline)
    ///   Se:           1 byte (end, 63 for baseline)
    ///   AhAl:         1 byte (0 for baseline)
    private static func writeSOS(
        scanComponents: [JPEGScanComponentEncode],
        components: [JPEGFrameComponent],
        to out: inout Data
    ) {
        let ns = scanComponents.count
        let len = 2 + 1 + ns * 2 + 3
        out.append(0xFF); out.append(0xDA)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(UInt8(ns))
        for sc in scanComponents {
            let id = components[sc.componentIndex].componentId
            out.append(UInt8(id))
            let tdta = (UInt8(sc.dcTableId) << 4)
                | UInt8(sc.acTableId)
            out.append(tdta)
        }
        out.append(0x00)   // Ss
        out.append(0x3F)   // Se = 63
        out.append(0x00)   // AhAl = 0
    }

    /// Convert a list of `JPEGHuffmanTable`s into the 4-slot
    /// encode-side table indexed by slot id (0..3). Each present
    /// table populates the corresponding slot; unused slots stay nil.
    private static func buildEncodeTables(
        _ tables: [JPEGHuffmanTable]
    ) -> [[JPEGHuffmanEncodeEntry]?] {
        var out: [[JPEGHuffmanEncodeEntry]?] = [nil, nil, nil, nil]
        for t in tables {
            var counts = [UInt32](repeating: 0, count: 17)
            for i in 0..<16 {
                counts[i + 1] = UInt32(t.bits[i])
            }
            let values = t.huffvals.map { UInt32($0) }
            out[t.tableId] = JPEGHuffmanEncodeTable.build(
                counts: counts, values: values)
        }
        return out
    }
}
