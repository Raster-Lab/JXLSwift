// Decode one 8×8 block of quantised DCT coefficients from a JPEG
// entropy-coded stream — seventh step on the Phase J road. This
// is the substance of JPEG decoding: the bit reader + Huffman
// codebooks become a sequence of (DC, 63 × AC) per-component
// coefficient blocks.
//
// Reference: ITU-T T.81 §F.1.2 + §F.2.2.
//
// DC path (§F.1.2.1.1, §F.2.2.1):
//   1. Decode 1 byte `S` from the DC Huffman codebook.
//   2. Read `S` magnitude bits MSB-first; reconstruct the signed
//      DC delta via `EXTEND(VALUE, S)` (Figure F.12).
//   3. Add delta to the per-component running DC predictor.
//
// AC path (§F.1.2.2.1, §F.2.2.2):
//   - Loop over the 63 AC positions (1..63 in zig-zag order):
//     1. Decode 1 byte from the AC Huffman codebook. Split into
//        `RRRR` (high nibble = zero-run length) + `SSSS` (low
//        nibble = magnitude size).
//     2. `SSSS == 0`:
//        - `RRRR == 0` → EOB, all remaining ACs are zero.
//        - `RRRR == 15` → ZRL, skip 16 zeros and continue.
//     3. Otherwise: skip `RRRR` zeros, read `SSSS` magnitude bits,
//        EXTEND, place in next coefficient.
//
// Output is returned in **natural** (row-major) order — we
// reverse the zig-zag here so callers don't have to.

import Foundation

/// One 8×8 block of quantised DCT coefficients in natural
/// (row-major) order. Position 0 is the DC term; positions 1..63
/// are the AC terms.
package struct JPEGCoefficientBlock: Sendable, Equatable {
    package var coefficients: [Int32]  // length 64
    package init(_ c: [Int32] = Array(repeating: 0, count: 64)) {
        precondition(c.count == 64,
            "JPEGCoefficientBlock requires 64 coefficients")
        self.coefficients = c
    }
}

/// Per-component DC differential predictor — the running value
/// that successive DC magnitudes add to. Initialised to 0 at the
/// start of each scan AND after every RST marker (per
/// §F.2.1.3.1).
package struct JPEGDCPredictor: Sendable, Equatable {
    package var value: Int32 = 0
    package init() {}
    package mutating func reset() { value = 0 }
}

/// Standard JPEG 8×8 zig-zag scan order (ITU-T T.81 Figure A.6).
/// `zigZag[i]` is the natural-order index of the i-th zig-zag
/// position. Inverse mapping (`natural → zig-zag`) is its
/// reflection.
package enum JPEGZigZag {
    package static let order: [Int] = [
        0,  1,  8, 16,  9,  2,  3, 10,
       17, 24, 32, 25, 18, 11,  4,  5,
       12, 19, 26, 33, 40, 48, 41, 34,
       27, 20, 13,  6,  7, 14, 21, 28,
       35, 42, 49, 56, 57, 50, 43, 36,
       29, 22, 15, 23, 30, 37, 44, 51,
       58, 59, 52, 45, 38, 31, 39, 46,
       53, 60, 61, 54, 47, 55, 62, 63
    ]
}

/// Decode one 8×8 quantised DCT block from a JPEG entropy stream.
package enum JPEGBlockDecoder {

    /// Decode a single block.
    /// - Parameters:
    ///   - reader: Bit reader, positioned at the start of the
    ///     block's DC magnitude category byte.
    ///   - dcCodebook / dcHuffvals: DC Huffman table + symbol array.
    ///   - acCodebook / acHuffvals: AC Huffman table + symbol array.
    ///   - dcPredictor: in-out per-component DC predictor.
    /// - Returns: 64 quantised DCT coefficients in natural order.
    /// - Throws: `JPEGBitReaderError` for stream-level problems,
    ///   `JPEGBlockDecodeError` for malformed coefficient tokens.
    package static func decode(
        from reader: inout JPEGBitReader,
        dcCodebook: JPEGHuffmanCodebook,
        dcHuffvals: [UInt8],
        acCodebook: JPEGHuffmanCodebook,
        acHuffvals: [UInt8],
        dcPredictor: inout JPEGDCPredictor
    ) throws -> JPEGCoefficientBlock {
        var natural = Array<Int32>(repeating: 0, count: 64)

        // --- DC ---
        guard let sByte = decodeSymbol(
            using: dcCodebook, huffvals: dcHuffvals,
            reader: &reader)
        else {
            throw JPEGBlockDecodeError.malformedDCSymbol
        }
        let s = Int(sByte)
        guard s <= 15 else {
            throw JPEGBlockDecodeError.dcSizeOutOfRange(s)
        }
        let dcDelta = try readExtendedMagnitude(
            bits: s, from: &reader)
        dcPredictor.value &+= dcDelta
        natural[0] = dcPredictor.value

        // --- AC ---
        var pos = 1
        while pos < 64 {
            guard let token = decodeSymbol(
                using: acCodebook, huffvals: acHuffvals,
                reader: &reader)
            else {
                throw JPEGBlockDecodeError.malformedACSymbol
            }
            let rrrr = Int(token >> 4)
            let ssss = Int(token & 0x0F)
            if ssss == 0 {
                if rrrr == 0 {
                    // EOB — remaining ACs stay zero.
                    break
                }
                if rrrr == 15 {
                    // ZRL — skip 16 zeros (which they already are).
                    pos += 16
                    if pos > 64 {
                        throw JPEGBlockDecodeError.runOverflow
                    }
                    continue
                }
                // Reserved combination (RRRR ∈ 1..14, SSSS == 0)
                // is not a valid AC token in baseline JPEG.
                throw JPEGBlockDecodeError.invalidACToken(token)
            }
            // Skip RRRR zeros, then place an EXTEND(value, SSSS)
            // at the next position.
            pos += rrrr
            if pos >= 64 {
                throw JPEGBlockDecodeError.runOverflow
            }
            let value = try readExtendedMagnitude(
                bits: ssss, from: &reader)
            natural[JPEGZigZag.order[pos]] = value
            pos += 1
        }

        return JPEGCoefficientBlock(natural)
    }

    /// Inline `JPEGHuffmanCodebook.decodeSymbol` adapter that
    /// pulls bits from a `JPEGBitReader` — saves a closure
    /// allocation per Huffman decode. Internal so the progressive
    /// scan decoder (`JPEGScanDecoder.decodeProgressive`) can reuse
    /// the same primitive.
    static func decodeSymbol(
        using book: JPEGHuffmanCodebook,
        huffvals: [UInt8],
        reader: inout JPEGBitReader
    ) -> UInt8? {
        var codeAcc: Int = 0
        for L in 1...16 {
            let b: Int
            do { b = try reader.readBit() }
            catch { return nil }
            codeAcc = (codeAcc << 1) | b
            if codeAcc <= book.maxcode[L - 1] {
                let idx = book.valoffset[L - 1] + codeAcc
                guard idx >= 0, idx < huffvals.count else {
                    return nil
                }
                return huffvals[idx]
            }
        }
        return nil
    }

    /// Read `s` magnitude bits MSB-first and apply the §F.2.2.1
    /// EXTEND function (Figure F.12): negative values are
    /// represented as the bit pattern of `(value + (1 << s) - 1)`,
    /// so the high bit of the raw magnitude distinguishes sign.
    /// `s == 0` yields 0. Internal so the progressive scan decoder
    /// can reuse the same EXTEND primitive.
    static func readExtendedMagnitude(
        bits s: Int, from reader: inout JPEGBitReader
    ) throws -> Int32 {
        if s == 0 { return 0 }
        let raw = try reader.readBits(s)
        let high = (raw >> UInt32(s - 1)) & 1
        if high == 1 {
            return Int32(raw)
        }
        // Negative: value = raw - ((1 << s) - 1).
        let bias = (Int32(1) << Int32(s)) - 1
        return Int32(raw) &- bias
    }
}

/// Errors raised when the entropy stream's coefficient tokens
/// don't make sense — distinct from `JPEGBitReaderError`
/// (stream-level) and `JPEGParseError` (segment-level).
package enum JPEGBlockDecodeError: Error, Sendable, Equatable,
                                  LocalizedError {
    /// Hit EOF or a non-RST marker while reading the DC
    /// magnitude-category byte.
    case malformedDCSymbol
    /// DC magnitude category > 15 — out of spec range for
    /// baseline JPEG (DC magnitudes are 0..11 in 8-bit, ≤ 15
    /// otherwise).
    case dcSizeOutOfRange(Int)
    /// Hit EOF or a non-RST marker while reading an AC token.
    case malformedACSymbol
    /// ZRL or zero-run pushed `pos` past 63.
    case runOverflow
    /// AC token had `SSSS == 0` with an `RRRR` other than 0 or 15.
    case invalidACToken(UInt8)

    package var errorDescription: String? {
        switch self {
        case .malformedDCSymbol:
            return "JPEG block decode: malformed DC symbol"
        case .dcSizeOutOfRange(let s):
            return "JPEG block decode: DC size \(s) out of range"
        case .malformedACSymbol:
            return "JPEG block decode: malformed AC symbol"
        case .runOverflow:
            return "JPEG block decode: zero-run overflows block"
        case .invalidACToken(let t):
            let hex = String(t, radix: 16, uppercase: true)
            return "JPEG block decode: invalid AC token 0x\(hex)"
        }
    }
}
