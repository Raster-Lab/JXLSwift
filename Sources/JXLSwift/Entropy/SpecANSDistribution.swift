// SpecANSDistribution — spec-compliant per-cluster ANS distribution
// reader (libjxl `lib/jxl/dec_ans.cc::ReadHistogram`).
//
// This file decodes the *body* of a single ANS distribution — what
// follows the per-cluster `HybridUintConfig` in the wider entropy
// section. The body is one of three shapes:
//
//   • **Simple** (`u(1) = 1`): 1 or 2 explicit symbols decoded via
//     `DecodeVarLenUint8`. The 1-symbol form puts the entire `range`
//     count on one symbol; the 2-symbol form splits via a precision-
//     bit u-field.
//
//   • **Flat** (`u(1, 0) = 0, 1`): an alphabet size via
//     `DecodeVarLenUint8 + 1`, and a uniform distribution.
//
//   • **Complex** (`u(1, 0) = 0, 0`): a `shift` field, then per-
//     position log-counts via a hard-coded 7-bit lookup table, then
//     RLE for symbol 17 (zero-run), then per-position bit-count
//     packing for the actual frequencies. **NOT YET IMPLEMENTED** —
//     the caller gets `.complexPathNotImplemented` for now.
//
// The simple+flat paths cover ~80 % of cjxl-emitted small-alphabet
// histograms (e.g. the Modular tree's 6-context section often uses
// flat distributions for low-entropy contexts). Full coverage of
// the complex path is the next milestone in this chain.
//
// Result: a fully-populated `[Int32]` count array summing to
// `range = 1 << precisionBits`.

import Foundation

public enum SpecANSDistributionError: Error, Sendable, Equatable {
    case bitstream(BitstreamError)
    case duplicateSymbol(Int)
    case complexPathNotImplemented
    case invalidShift(UInt32)
    case alphabetTooLarge(Int)
}

public enum SpecANSDistribution {

    /// Read one per-cluster distribution. `precisionBits` is the
    /// log of the rANS table size (always `ANS_LOG_TAB_SIZE = 12`
    /// for JXL); `range = 1 << precisionBits = 4096`.
    public static func readHistogram(
        from r: inout BitReader,
        precisionBits: Int = 12
    ) throws -> [Int32] {
        let range = Int32(1) << Int32(precisionBits)
        do {
            let isSimple = try r.readBit()
            if isSimple {
                return try readSimple(from: &r, range: range)
            }
            let isFlat = try r.readBit()
            if isFlat {
                return try readFlat(from: &r, range: range)
            }
            return try readComplex(
                from: &r, range: range, precisionBits: precisionBits
            )
        } catch let e as BitstreamError {
            throw SpecANSDistributionError.bitstream(e)
        }
    }

    // MARK: - Simple path

    private static func readSimple(
        from r: inout BitReader, range: Int32
    ) throws -> [Int32] {
        let twoSymbol = try r.readBit()
        let numSymbols = twoSymbol ? 2 : 1
        var symbols = [Int]()
        symbols.reserveCapacity(numSymbols)
        var maxSymbol = 0
        for _ in 0..<numSymbols {
            let s = Int(try r.readVarLenUint8())
            symbols.append(s)
            if s > maxSymbol { maxSymbol = s }
        }
        var counts = [Int32](repeating: 0, count: maxSymbol + 1)
        if numSymbols == 1 {
            counts[symbols[0]] = range
            return counts
        }
        if symbols[0] == symbols[1] {
            throw SpecANSDistributionError.duplicateSymbol(symbols[0])
        }
        // The two symbols share `range` total. The first symbol's
        // count is read as `precisionBits` raw bits; the second gets
        // the remainder. (libjxl uses the surrounding `precision_bits`
        // value the call site passed to `ReadHistogram`.)
        let bits = Int(31 - UInt32(range).leadingZeroBitCount) // = log2(range)
        let firstCount = Int32(try r.read(bits: bits))
        counts[symbols[0]] = firstCount
        counts[symbols[1]] = range - firstCount
        return counts
    }

    // MARK: - Flat path

    private static func readFlat(
        from r: inout BitReader, range: Int32
    ) throws -> [Int32] {
        let alphabetSize = Int(try r.readVarLenUint8()) + 1
        guard alphabetSize <= range else {
            throw SpecANSDistributionError.alphabetTooLarge(alphabetSize)
        }
        // CreateFlatHistogram from libjxl ans_common.cc — divides
        // `range` into `alphabetSize` equal parts. The first
        // `range mod alphabetSize` symbols get one extra count.
        let base = range / Int32(alphabetSize)
        let leftover = range - base * Int32(alphabetSize)
        var counts = [Int32](repeating: base, count: alphabetSize)
        for i in 0..<Int(leftover) { counts[i] &+= 1 }
        return counts
    }

    // MARK: - Complex path (NOT YET IMPLEMENTED)

    private static func readComplex(
        from r: inout BitReader, range: Int32, precisionBits: Int
    ) throws -> [Int32] {
        throw SpecANSDistributionError.complexPathNotImplemented
    }

    // MARK: - Writer (simple + flat only)

    /// Write a histogram. Picks the smallest encoding that fits:
    /// 1-symbol simple if only one symbol has non-zero count; 2-symbol
    /// simple if exactly two; flat if all entries within ±1 of each
    /// other; otherwise throws `.complexPathNotImplemented`.
    public static func writeHistogram(
        _ counts: [Int32],
        to w: inout BitWriter,
        precisionBits: Int = 12
    ) throws {
        let range = Int32(1) << Int32(precisionBits)
        let nonzero = counts.enumerated().filter { $0.element > 0 }
        if nonzero.count == 1 {
            try writeSimpleOne(symbol: nonzero[0].offset, to: &w)
            return
        }
        if nonzero.count == 2 {
            try writeSimpleTwo(
                symbol0: nonzero[0].offset,
                count0: nonzero[0].element,
                symbol1: nonzero[1].offset,
                to: &w, precisionBits: precisionBits
            )
            return
        }
        // Flat detection — every count is base or base+1, with the
        // first `range mod alphabetSize` entries being base+1.
        if isFlat(counts: counts, range: range) {
            try writeFlat(alphabetSize: counts.count, to: &w)
            return
        }
        throw SpecANSDistributionError.complexPathNotImplemented
    }

    private static func writeSimpleOne(symbol: Int, to w: inout BitWriter) throws {
        w.writeBit(true)            // simple_code = 1
        w.writeBit(false)           // num_symbols - 1 = 0
        try w.writeVarLenUint8(UInt32(symbol))
    }

    private static func writeSimpleTwo(
        symbol0: Int, count0: Int32, symbol1: Int,
        to w: inout BitWriter, precisionBits: Int
    ) throws {
        w.writeBit(true)            // simple_code = 1
        w.writeBit(true)            // num_symbols - 1 = 1
        try w.writeVarLenUint8(UInt32(symbol0))
        try w.writeVarLenUint8(UInt32(symbol1))
        // `counts[symbol0]` as `precisionBits` raw bits.
        w.write(bits: precisionBits, value: UInt32(count0))
    }

    private static func writeFlat(alphabetSize: Int, to w: inout BitWriter) throws {
        w.writeBit(false)           // simple_code = 0
        w.writeBit(true)            // is_flat = 1
        try w.writeVarLenUint8(UInt32(alphabetSize - 1))
    }

    /// True iff `counts` is the flat distribution for its alphabet
    /// size — i.e. matches `CreateFlatHistogram(alphabetSize, range)`.
    public static func isFlat(counts: [Int32], range: Int32) -> Bool {
        let alphabetSize = Int32(counts.count)
        if alphabetSize == 0 { return false }
        let base = range / alphabetSize
        let leftover = range - base * alphabetSize
        for (i, c) in counts.enumerated() {
            let expected = (Int32(i) < leftover) ? (base &+ 1) : base
            if c != expected { return false }
        }
        return true
    }
}
