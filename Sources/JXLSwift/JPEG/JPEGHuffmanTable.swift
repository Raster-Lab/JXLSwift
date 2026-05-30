// Parse JPEG DHT (Define Huffman Table) payloads — third step on
// the Phase J road. Turns the raw segment bytes into typed
// `JPEGHuffmanTable` records carrying the bit-length-counts +
// symbol values the eventual entropy decoder needs.
//
// DHT payload layout (ITU-T T.81 §B.2.4.2):
//   for each table within the segment:
//     u(4) Tc  — table class (0 = DC, 1 = AC)
//     u(4) Th  — destination identifier (0..3)
//     16  ×  u(8) Li — number of codes of length i (i = 1..16)
//     sum(Li) × u(8) Vi — the symbols, longest-code-first in input
//                         order; the canonical Huffman code is
//                         derivable from `(Li, Vi)` alone (§C.2).
//
// We don't construct the actual code table here — that's a job for
// the Huffman *decoder* layer above this one. This file just
// peels the segment payload into the structural record so the
// boundary between bitstream-layout parsing and entropy-coding
// runtime stays clean.

import Foundation

/// Which entropy-coding role this Huffman table fills. A baseline
/// JPEG carries one DC and one AC table per component; progressive
/// scans may pull in different tables per scan.
package enum JPEGHuffmanClass: Int, Sendable, Equatable {
    case dc = 0
    case ac = 1
}

/// One JPEG Huffman table — bit-length counts + flattened symbol
/// list, exactly as they appear in the DHT payload. Length-counts
/// + symbol order are enough to reconstruct the canonical Huffman
/// code via the ITU-T T.81 §C.2 algorithm.
package struct JPEGHuffmanTable: Sendable, Equatable {
    /// DC or AC class.
    package let `class`: JPEGHuffmanClass
    /// Destination identifier 0..3 (referenced by the SOS scan
    /// header to bind a component to a particular DC + AC pair).
    package let tableId: Int
    /// `bits[i]` is the number of Huffman codes with length `i + 1`
    /// bits (so `bits.count` is always 16). Sums to the total
    /// symbol count `huffvals.count`.
    package let bits: [UInt8]
    /// The symbol values, in canonical Huffman code order. Each
    /// `Vi` is one byte; for a DC table the value is the magnitude
    /// category (0..11), for an AC table it packs `run << 4 | size`.
    package let huffvals: [UInt8]
}

extension JPEGHuffmanTable {
    /// Parse every table out of one DHT segment payload. Returns
    /// the tables in the order they appeared. Throws
    /// `JPEGParseError.invalidSegmentLength` if the byte budget
    /// doesn't line up cleanly (typical malformed inputs:
    /// truncated symbol list, `sum(Li) > 256`).
    package static func parse(
        dhtPayload p: Data
    ) throws -> [JPEGHuffmanTable] {
        var out: [JPEGHuffmanTable] = []
        var i = 0
        while i < p.count {
            guard i + 17 <= p.count else {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xC4, length: p.count + 2)
            }
            let header = p[p.startIndex + i]
            let tc = Int(header >> 4)
            let th = Int(header & 0x0F)
            guard let cls = JPEGHuffmanClass(rawValue: tc) else {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xC4, length: p.count + 2)
            }
            guard (0...3).contains(th) else {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xC4, length: p.count + 2)
            }
            i += 1
            var bits: [UInt8] = []
            bits.reserveCapacity(16)
            for k in 0..<16 {
                bits.append(p[p.startIndex + i + k])
            }
            i += 16
            let totalSymbols = bits.reduce(0) { $0 + Int($1) }
            // Per §B.2.4.2, sum(Li) must be ≤ 256 (Tc=0 / DC) or
            // ≤ 256 (Tc=1 / AC). Anything more is a malformed file.
            guard totalSymbols <= 256 else {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xC4, length: p.count + 2)
            }
            guard i + totalSymbols <= p.count else {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xC4, length: p.count + 2)
            }
            var huffvals: [UInt8] = []
            huffvals.reserveCapacity(totalSymbols)
            for k in 0..<totalSymbols {
                huffvals.append(p[p.startIndex + i + k])
            }
            i += totalSymbols
            out.append(JPEGHuffmanTable(
                class: cls, tableId: th,
                bits: bits, huffvals: huffvals))
        }
        return out
    }
}

extension JPEGStructure {
    /// Walk every DHT segment in `data` and return the
    /// concatenated list of `JPEGHuffmanTable`s. Same input the
    /// segment walker expects (full JPEG file starting with SOI).
    package static func huffmanTables(
        in data: Data
    ) throws -> [JPEGHuffmanTable] {
        var reader = JPEGSegmentReader(data)
        var out: [JPEGHuffmanTable] = []
        while let seg = try reader.next() {
            if seg.kind == .defineHuffmanTable {
                out.append(contentsOf:
                    try JPEGHuffmanTable.parse(
                        dhtPayload: seg.payload))
            }
            if seg.kind == .endOfImage { break }
        }
        return out
    }
}
