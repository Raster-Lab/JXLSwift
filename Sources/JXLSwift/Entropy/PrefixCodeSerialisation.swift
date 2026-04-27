// PrefixCodeSerialisation — bitstream format for prefix-code tables.
//
// ISO/IEC 18181-1 §C.6.2.1. A prefix-code table is encoded in one of
// two ways: "simple" (1–4 explicit symbols with predefined lengths) or
// "complex" (a per-symbol lengths array, itself entropy-coded by a
// small meta-Huffman over the code-length values 0–18).
//
// This file currently implements only the SIMPLE format, which covers
// the cases JXL uses for short-alphabet distributions. The complex
// format is documented and tracked in ROADMAP.md.
//
// Simple format layout:
//
//     hskip            u(2)            // 1 = simple format
//     nsym             u(2)            // 0..3 → 1..4 symbols
//     symbols[0..nsym] u(log_alphabet) // symbol indices
//     if nsym == 3:                    // 4 symbols total
//         use_long_codewords  u(1)     // 0 → all length 2
//                                       // 1 → lengths {1,2,3,3}
//
// The lengths each simple-code shape implies are:
//
//     1 symbol  → that symbol has length 0 (always emitted)
//     2 symbols → both length 1
//     3 symbols → {1, 2, 2}
//     4 symbols → either {2,2,2,2} or {1,2,3,3} depending on the bit

import Foundation

public enum SimplePrefixCodeError: Error, Sendable, Equatable {
    case wrongHeader(expectedHskip: Int, gotHskip: Int)
    case unsupportedNumSymbols(Int)
    case alphabetTooLarge(Int)
    case bitstream(BitstreamError)
}

public struct SimplePrefixCodeFormat {

    /// Build a complete `[UInt8]` lengths array of size `alphabetSize`
    /// from a list of explicit (symbol, length) pairs. Symbols not
    /// listed get length 0.
    public static func makeLengths(alphabetSize: Int,
                                    pairs: [(symbol: Int, length: UInt8)]) -> [UInt8] {
        var lengths = [UInt8](repeating: 0, count: alphabetSize)
        for (s, l) in pairs { lengths[s] = l }
        return lengths
    }

    /// Encode a simple prefix code from a list of 1–4 symbol indices.
    /// `pairs.count` determines the shape:
    ///
    ///   - 1  → single-symbol code (length 0)
    ///   - 2  → two-symbol code (both length 1)
    ///   - 3  → three-symbol code (lengths 1, 2, 2)
    ///   - 4  → four-symbol code; pass `useLongCodewords` to choose
    ///          between {2,2,2,2} (false) and {1,2,3,3} (true).
    ///
    /// `alphabetSize` controls how many bits are used per symbol index
    /// (`ceil(log2(alphabetSize))`). Must be ≥ 2.
    public static func encode(
        to w: inout BitWriter,
        symbols: [Int],
        alphabetSize: Int,
        useLongCodewords: Bool = false
    ) throws {
        guard alphabetSize >= 2 && alphabetSize <= (1 << 16) else {
            throw SimplePrefixCodeError.alphabetTooLarge(alphabetSize)
        }
        let count = symbols.count
        guard (1...4).contains(count) else {
            throw SimplePrefixCodeError.unsupportedNumSymbols(count)
        }
        let logAlpha = Int(ceilLog2(UInt32(alphabetSize)))

        // hskip = 1 → simple format
        w.write(bits: 2, value: 1)
        // nsym = count - 1
        w.write(bits: 2, value: UInt32(count - 1))
        for sym in symbols {
            guard sym >= 0 && sym < alphabetSize else {
                throw SimplePrefixCodeError.alphabetTooLarge(alphabetSize)
            }
            w.write(bits: logAlpha, value: UInt32(sym))
        }
        if count == 4 {
            w.writeBit(useLongCodewords)
        }
    }

    /// Decode a simple prefix code into a complete lengths array of
    /// size `alphabetSize`. Reader must be positioned at the `hskip`
    /// header bits when called.
    public static func decode(
        from r: inout BitReader,
        alphabetSize: Int
    ) throws -> [UInt8] {
        guard alphabetSize >= 2 && alphabetSize <= (1 << 16) else {
            throw SimplePrefixCodeError.alphabetTooLarge(alphabetSize)
        }
        let hskip = try r.read(bits: 2)
        guard hskip == 1 else {
            throw SimplePrefixCodeError.wrongHeader(expectedHskip: 1, gotHskip: Int(hskip))
        }
        let nsym = Int(try r.read(bits: 2))   // 0..3 → 1..4 symbols
        let count = nsym + 1
        let logAlpha = Int(ceilLog2(UInt32(alphabetSize)))

        var symbols: [Int] = []
        symbols.reserveCapacity(count)
        for _ in 0..<count {
            let s = Int(try r.read(bits: logAlpha))
            guard s < alphabetSize else {
                throw SimplePrefixCodeError.alphabetTooLarge(alphabetSize)
            }
            symbols.append(s)
        }

        var lengths = [UInt8](repeating: 0, count: alphabetSize)
        switch count {
        case 1:
            // Degenerate: lengths[symbols[0]] = 0 (caller's lengths
            // array already starts as all zeros). Effectively a
            // "single symbol always emitted" code.
            return lengths
        case 2:
            lengths[symbols[0]] = 1
            lengths[symbols[1]] = 1
        case 3:
            lengths[symbols[0]] = 1
            lengths[symbols[1]] = 2
            lengths[symbols[2]] = 2
        case 4:
            let long = try r.readBit()
            if long {
                lengths[symbols[0]] = 1
                lengths[symbols[1]] = 2
                lengths[symbols[2]] = 3
                lengths[symbols[3]] = 3
            } else {
                lengths[symbols[0]] = 2
                lengths[symbols[1]] = 2
                lengths[symbols[2]] = 2
                lengths[symbols[3]] = 2
            }
        default:
            throw SimplePrefixCodeError.unsupportedNumSymbols(count)
        }
        return lengths
    }
}

/// Ceiling of log2(value), with `ceilLog2(1) = 0`. Used for sizing the
/// per-symbol-index field in the simple prefix-code header.
@inline(__always)
func ceilLog2(_ value: UInt32) -> UInt32 {
    if value <= 1 { return 0 }
    return 32 - UInt32((value &- 1).leadingZeroBitCount)
}
