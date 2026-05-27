// `JPEG/JPEGBlockEncoder.swift` — encode one 8×8 quantised DCT
// block to a JPEG entropy stream. Inverse of `JPEGBlockDecoder`.
//
// Reference: ITU-T T.81 §F.1.4 (encoder) + §F.2.2 (decoder, mirror).
//
// Phase J step 5i support — needed by the reverse bridge to write
// the SOS payload from JXL-decoded coefficients + jbrd Huffman
// tables.
//
// DC path mirrors §F.1.4.1:
//   1. Compute `delta = block[0] - dcPredictor.value`.
//   2. Update predictor: `dcPredictor.value = block[0]`.
//   3. Find size category `S` such that `|delta|` fits in `S` bits
//      (S=0 for delta=0).
//   4. Emit the DC Huffman code for `S` MSB-first.
//   5. Emit the magnitude bits via `EXTEND_INV`:
//        delta ≥ 0: raw = UInt(delta), emit S low bits
//        delta < 0: raw = UInt(delta + (1 << S) - 1), emit S low bits
//
// AC path mirrors §F.1.4.2 with EOB compression:
//   - Walk zig-zag positions 1..63 of the natural-order block.
//   - Track zero-run length `zerosRun`.
//   - For each nonzero coefficient `value` at zig-zag pos `k`:
//       while zerosRun >= 16:
//         emit ZRL (Huffman code for 0xF0)
//         zerosRun -= 16
//       size = bitsNeeded(|value|)
//       sym = (zerosRun << 4) | size
//       emit AC Huffman code for sym
//       emit value magnitude bits via EXTEND_INV
//       zerosRun = 0
//   - At end, if any nonzero coefficient was emitted but trailing
//     zeros remain, emit EOB (Huffman code for 0x00). If the block
//     is entirely zero (after DC), emit EOB immediately.

import Foundation

/// Errors raised by the block encoder when its inputs don't fit
/// JPEG's coefficient format.
public enum JPEGBlockEncodeError: Error, Sendable, Equatable,
                                  LocalizedError {
    /// DC delta magnitude exceeded the spec's 11-bit limit (8-bit
    /// JPEG; the upper bound is 15 bits for 12-bit JPEG but we
    /// don't support that here).
    case dcDeltaOutOfRange(Int32)
    /// AC coefficient magnitude exceeded the spec's 10-bit limit
    /// (or 14 bits for extended-precision JPEG).
    case acCoefficientOutOfRange(Int32)
    /// Huffman codebook didn't contain a code for a required
    /// symbol (e.g. EOB 0x00, ZRL 0xF0, or a specific (run, size)
    /// combination). Indicates the source jbrd Huffman tables are
    /// incompatible with the input coefficients.
    case missingHuffmanSymbol(UInt8)

    public var errorDescription: String? {
        switch self {
        case .dcDeltaOutOfRange(let d):
            return "JPEG block encode: DC delta \(d) out of range"
        case .acCoefficientOutOfRange(let v):
            return "JPEG block encode: AC coefficient \(v) out of range"
        case .missingHuffmanSymbol(let s):
            let hex = String(s, radix: 16, uppercase: true)
            return "JPEG block encode: Huffman table missing 0x\(hex)"
        }
    }
}

/// Encode one 8×8 quantised DCT block to JPEG entropy bits.
public enum JPEGBlockEncoder {

    /// Encode a single block. The DC predictor is updated in place
    /// (current value becomes `block.coefficients[0]`).
    ///
    /// - Parameters:
    ///   - block: natural-order coefficient block.
    ///   - dcCodeTable: per-symbol (code, length) pairs for the DC
    ///     Huffman table. `dcCodeTable[s]` = (code, length) for
    ///     magnitude size `s` ∈ 0..15.
    ///   - acCodeTable: per-symbol (code, length) pairs for the AC
    ///     Huffman table. Indexed by `(run << 4) | size` ∈ 0..255.
    ///   - dcPredictor: in-out per-component DC predictor.
    ///   - writer: bit writer accumulating output.
    public static func encode(
        _ block: JPEGCoefficientBlock,
        dcCodeTable: [JPEGHuffmanEncodeEntry],
        acCodeTable: [JPEGHuffmanEncodeEntry],
        dcPredictor: inout JPEGDCPredictor,
        to writer: inout JPEGBitWriter
    ) throws {
        let natural = block.coefficients
        // --- DC ---
        let dcDelta = natural[0] &- dcPredictor.value
        dcPredictor.value = natural[0]
        let dcSize = bitsNeeded(dcDelta)
        guard dcSize <= 15 else {
            throw JPEGBlockEncodeError.dcDeltaOutOfRange(dcDelta)
        }
        let dcEntry = dcCodeTable[dcSize]
        guard dcEntry.length > 0 else {
            throw JPEGBlockEncodeError.missingHuffmanSymbol(
                UInt8(dcSize))
        }
        writer.writeBits(dcEntry.code, count: dcEntry.length)
        if dcSize > 0 {
            let magBits = magnitudeBits(dcDelta, size: dcSize)
            writer.writeBits(magBits, count: dcSize)
        }
        // --- AC ---
        var zerosRun = 0
        // Find the position of the last non-zero AC coefficient so
        // we can emit EOB at the right place.
        var lastNonZeroPos = 0
        for k in 1..<64 {
            if natural[JPEGZigZag.order[k]] != 0 {
                lastNonZeroPos = k
            }
        }
        if lastNonZeroPos == 0 {
            // Pure DC block — emit EOB and done.
            let eob = acCodeTable[0x00]
            guard eob.length > 0 else {
                throw JPEGBlockEncodeError.missingHuffmanSymbol(0x00)
            }
            writer.writeBits(eob.code, count: eob.length)
            return
        }
        // Walk positions 1..lastNonZeroPos.
        for k in 1...lastNonZeroPos {
            let value = natural[JPEGZigZag.order[k]]
            if value == 0 {
                zerosRun += 1
                continue
            }
            while zerosRun >= 16 {
                let zrl = acCodeTable[0xF0]
                guard zrl.length > 0 else {
                    throw JPEGBlockEncodeError.missingHuffmanSymbol(
                        0xF0)
                }
                writer.writeBits(zrl.code, count: zrl.length)
                zerosRun -= 16
            }
            let size = bitsNeeded(value)
            guard size <= 15 else {
                throw JPEGBlockEncodeError.acCoefficientOutOfRange(
                    value)
            }
            let sym = UInt8((zerosRun << 4) | size)
            let entry = acCodeTable[Int(sym)]
            guard entry.length > 0 else {
                throw JPEGBlockEncodeError.missingHuffmanSymbol(sym)
            }
            writer.writeBits(entry.code, count: entry.length)
            let magBits = magnitudeBits(value, size: size)
            writer.writeBits(magBits, count: size)
            zerosRun = 0
        }
        // If trailing zeros exist (lastNonZeroPos < 63), emit EOB.
        if lastNonZeroPos < 63 {
            let eob = acCodeTable[0x00]
            guard eob.length > 0 else {
                throw JPEGBlockEncodeError.missingHuffmanSymbol(0x00)
            }
            writer.writeBits(eob.code, count: eob.length)
        }
    }

    /// Number of bits needed to represent `|value|` per JPEG's
    /// EXTEND categorisation. value=0 → 0; ±1 → 1; ±2..±3 → 2; etc.
    @inline(__always)
    static func bitsNeeded(_ value: Int32) -> Int {
        if value == 0 { return 0 }
        // Magnitude is up to 2^15-1 for 8-bit JPEG; 32-bit is safe.
        let mag = UInt32(value.magnitude)
        return 32 - mag.leadingZeroBitCount
    }

    /// Convert a signed value + size to the raw bit pattern JPEG
    /// stores (inverse of EXTEND, Figure F.12):
    ///   value ≥ 0: raw = UInt(value)
    ///   value < 0: raw = UInt(value + (1 << size) - 1)
    @inline(__always)
    static func magnitudeBits(_ value: Int32, size: Int) -> UInt32 {
        if value >= 0 {
            return UInt32(value)
        }
        let bias = (Int32(1) << Int32(size)) - 1
        return UInt32(value &+ bias)
    }
}

/// One (Huffman code, bit length) pair, indexed by Huffman symbol.
/// Length 0 marks an unused symbol — `JPEGBlockEncoder.encode`
/// throws `missingHuffmanSymbol` if a required symbol is unused.
public struct JPEGHuffmanEncodeEntry: Sendable, Equatable {
    public var code: UInt32
    public var length: Int
    public init(code: UInt32 = 0, length: Int = 0) {
        self.code = code
        self.length = length
    }
}

/// Build per-symbol (code, length) tables from a JPEG DHT
/// `counts[]` + `values[]` pair. Mirrors the canonical-Huffman
/// algorithm `JPEGHuffmanCodebook.init` runs for decoding, but
/// emits the (code, length) form an encoder needs.
public enum JPEGHuffmanEncodeTable {

    /// - Parameters:
    ///   - counts: `counts[L]` = number of symbols with code length
    ///     L (1..16). `counts[0]` is ignored.
    ///   - values: symbol values in ascending bit-length order.
    /// - Returns: 256-entry table where `table[sym]` is the
    ///   (code, length) for that symbol. Unused symbols have
    ///   length 0.
    public static func build(
        counts: [UInt32], values: [UInt32]
    ) -> [JPEGHuffmanEncodeEntry] {
        precondition(counts.count == 17,
            "JPEGHuffmanEncodeTable.build: counts must have 17 entries")
        var table = Array(
            repeating: JPEGHuffmanEncodeEntry(),
            count: 256)
        var code: UInt32 = 0
        var idx = 0
        for L in 1...16 {
            let n = Int(counts[L])
            for _ in 0..<n {
                if idx < values.count {
                    let sym = Int(values[idx])
                    if sym < 256 {
                        table[sym] = JPEGHuffmanEncodeEntry(
                            code: code, length: L)
                    }
                    idx += 1
                }
                code += 1
            }
            code <<= 1
        }
        return table
    }
}
