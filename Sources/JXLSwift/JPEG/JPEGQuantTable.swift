// Parse JPEG DQT (Define Quantization Table) payloads — second
// step on the Phase J road. Each DQT segment can carry one or more
// tables; this layer turns the raw segment bytes into typed
// `JPEGQuantTable` records so the eventual transcoder has the
// per-block quantisation factors ready to hand.
//
// DQT payload layout (ITU-T T.81 §B.2.4.1):
//   for each table within the segment:
//     u(4) Pq  — element precision (0 = 8-bit, 1 = 16-bit)
//     u(4) Tq  — table destination identifier (0..3)
//     64 ×  Pq==0 ? u(8) : u(16) values, in **zig-zag** order
//
// The first byte packs `Pq` (high nibble) + `Tq` (low nibble); the
// 64 values follow contiguously. Segments hold concatenated tables
// until the declared payload length runs out.

import Foundation

/// Element precision of a JPEG quantisation table — controls
/// whether each entry is stored as one byte (8-bit) or two bytes
/// (16-bit big-endian) in the DQT payload.
public enum JPEGQuantPrecision: Int, Sendable, Equatable {
    case bits8 = 0
    case bits16 = 1
}

/// One JPEG quantisation table — 64 values in **zig-zag** order
/// (the same order they appear in the DQT payload). The
/// transcoder will need to un-zig-zag them before applying.
public struct JPEGQuantTable: Sendable, Equatable {
    /// Destination identifier 0..3. The SOS scan header references
    /// these IDs to bind a component to a particular table.
    public let tableId: Int
    /// 8-bit or 16-bit storage in the source DQT payload.
    public let precision: JPEGQuantPrecision
    /// 64 quantisation factors, in zig-zag order. Stored as
    /// `UInt16` regardless of source precision so callers don't
    /// need to switch on the storage width.
    public let zigZagValues: [UInt16]
}

extension JPEGQuantTable {
    /// Parse every table out of one DQT segment payload. Throws
    /// `JPEGParseError.invalidSegmentLength` if the byte budget
    /// doesn't line up with a clean sequence of (header + 64×Pq
    /// bytes) tables.
    public static func parse(
        dqtPayload p: Data
    ) throws -> [JPEGQuantTable] {
        var out: [JPEGQuantTable] = []
        var i = 0
        while i < p.count {
            guard i + 1 <= p.count else {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xDB, length: p.count + 2)
            }
            let pq = Int(p[p.startIndex + i] >> 4)
            let tq = Int(p[p.startIndex + i] & 0x0F)
            guard let precision = JPEGQuantPrecision(rawValue: pq)
            else {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xDB, length: p.count + 2)
            }
            guard (0...3).contains(tq) else {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xDB, length: p.count + 2)
            }
            i += 1
            let bytesPerValue = (precision == .bits8) ? 1 : 2
            let bytesNeeded = 64 * bytesPerValue
            guard i + bytesNeeded <= p.count else {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xDB, length: p.count + 2)
            }
            var values: [UInt16] = []
            values.reserveCapacity(64)
            if precision == .bits8 {
                for k in 0..<64 {
                    values.append(
                        UInt16(p[p.startIndex + i + k]))
                }
            } else {
                for k in 0..<64 {
                    let hi = UInt16(p[p.startIndex + i + 2*k])
                    let lo = UInt16(p[p.startIndex + i + 2*k + 1])
                    values.append((hi << 8) | lo)
                }
            }
            i += bytesNeeded
            out.append(JPEGQuantTable(
                tableId: tq, precision: precision,
                zigZagValues: values))
        }
        return out
    }
}

extension JPEGStructure {
    /// Walk every DQT segment in `data` and return the
    /// concatenated list of `JPEGQuantTable`s. Same input the
    /// segment walker expects (full JPEG file starting with SOI).
    /// Throws `JPEGParseError` for malformed input.
    public static func quantTables(
        in data: Data
    ) throws -> [JPEGQuantTable] {
        var reader = JPEGSegmentReader(data)
        var out: [JPEGQuantTable] = []
        while let seg = try reader.next() {
            if seg.kind == .defineQuantizationTable {
                out.append(contentsOf:
                    try JPEGQuantTable.parse(
                        dqtPayload: seg.payload))
            }
            if seg.kind == .endOfImage { break }
        }
        return out
    }
}
