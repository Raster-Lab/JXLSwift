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
    case invalidHistogram(String)
    case invalidRLE(String)
}

/// Hard-coded 7-bit Huffman lookup table for per-position log-counts
/// in the complex `ReadHistogram` path. Indexed by 7 peeked bits;
/// each entry is `(bits_to_consume, decoded_logcount)`. Mirrors the
/// `huff` table at libjxl `dec_ans.cc:101`.
fileprivate let kComplexLogCountHuff: [(consume: Int, value: Int)] = [
    (3, 10), (7, 12), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
    (3, 10), (4, 4),  (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
    (3, 10), (5, 0),  (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
    (3, 10), (4, 4),  (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
    (3, 10), (6, 11), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
    (3, 10), (4, 4),  (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
    (3, 10), (5, 0),  (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
    (3, 10), (4, 4),  (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
    (3, 10), (7, 13), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
    (3, 10), (4, 4),  (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
    (3, 10), (5, 0),  (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
    (3, 10), (4, 4),  (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
    (3, 10), (6, 11), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
    (3, 10), (4, 4),  (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
    (3, 10), (5, 0),  (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
    (3, 10), (4, 4),  (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
]

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

    // MARK: - Complex path
    //
    // Layout (libjxl `dec_ans.cc::ReadHistogram`, the `else` branch):
    //
    //   shift : variable-length unary + tail
    //     upper_bound_log = floor_log2(precisionBits + 1)         // = 3 for 12
    //     log = number of leading 1 bits before a 0 (or until upper_bound_log)
    //     shift = (read(log) | (1 << log)) - 1
    //   length : DecodeVarLenUint8 + 3
    //   for i in 0..<length:
    //     logcount = 7-bit Huffman lookup
    //     if logcount == 13 (= ANS_LOG_TAB_SIZE+1):
    //       rle_length = DecodeVarLenUint8
    //       same[i] = rle_length + 5    // mark RLE start
    //       i += rle_length + 3
    //   omit_pos = position of highest logcount
    //   reconstruct counts:
    //     skip omit_pos
    //     for i:
    //       if RLE: copy prev count
    //       else if logcount == 0: count = 0
    //       else if logcount == 1: count = 1
    //       else: bitcount = clamp(logcount - 1 - shift, 0, 12 - shift)
    //             count = (1 << (logcount - 1)) +
    //                     (read(bitcount) << (logcount - 1 - bitcount))
    //   counts[omit_pos] = range - sum(other counts)

    private static func readComplex(
        from r: inout BitReader, range: Int32, precisionBits: Int
    ) throws -> [Int32] {
        // Read shift.
        let upperBoundLog = floorLog2Nonzero(UInt32(precisionBits + 1))
        var log = 0
        while log < upperBoundLog {
            if try !r.readBit() { break }
            log += 1
        }
        let extra = log == 0 ? UInt32(0) : try r.read(bits: log)
        let shift = Int32(extra | (UInt32(1) &<< UInt32(log))) - 1
        if shift > Int32(precisionBits + 1) {
            throw SpecANSDistributionError.invalidShift(UInt32(shift))
        }

        // Length = VarLenUint8 + 3.
        let lengthRaw = try r.readVarLenUint8()
        let length = Int(lengthRaw) + 3
        guard length > 0 else {
            throw SpecANSDistributionError.invalidHistogram("zero length")
        }

        var logcounts = [Int](repeating: 0, count: length)
        // `same[i]` = RLE run length starting at `i` (0 means no RLE).
        var same = [Int](repeating: 0, count: length)
        var omitLog = -1
        var omitPos = -1
        var i = 0
        while i < length {
            // Lookup the next logcount via the 7-bit Huffman table.
            // We need 7 bits to peek; the file may end on fewer, so
            // pad with zeros.
            let peekBits = min(7, r.bitsRemaining)
            var idx: UInt32 = 0
            if peekBits > 0 {
                let peeked = try r.peek(bits: peekBits)
                idx = peeked  // upper bits implicitly 0
            }
            let entry = kComplexLogCountHuff[Int(idx) & 0x7F]
            try r.skip(bits: entry.consume)
            logcounts[i] = entry.value

            if entry.value == precisionBits + 1 {
                // RLE marker (= ANS_LOG_TAB_SIZE+1 = 13).
                let rleLength = Int(try r.readVarLenUint8())
                same[i] = rleLength + 5
                let advance = rleLength + 3
                if i + advance >= length {
                    throw SpecANSDistributionError.invalidRLE(
                        "RLE run extends past length"
                    )
                }
                i += advance + 1
                continue
            }
            if entry.value > omitLog {
                omitLog = entry.value
                omitPos = i
            }
            i += 1
        }
        if omitPos < 0 {
            throw SpecANSDistributionError.invalidHistogram(
                "no valid logcount entries"
            )
        }
        // libjxl: an RLE entry at omit_pos+1 with logcount == range+1
        // is invalid. We don't reach that since we require omitPos to
        // be the position of a non-RLE entry.
        if omitPos + 1 < length && logcounts[omitPos + 1] == precisionBits + 1 {
            throw SpecANSDistributionError.invalidHistogram(
                "RLE adjacent to omit position"
            )
        }

        // Reconstruct counts.
        var counts = [Int32](repeating: 0, count: length)
        var totalCount: Int32 = 0
        var prev: Int32 = 0
        var numSame = 0
        for j in 0..<length {
            if same[j] != 0 {
                numSame = same[j] - 1
                prev = j > 0 ? counts[j - 1] : 0
            }
            if numSame > 0 {
                counts[j] = prev
                numSame -= 1
                totalCount &+= counts[j]
                continue
            }
            let code = logcounts[j]
            if j == omitPos { continue }
            if code == 0 { continue }
            if code == 1 {
                counts[j] = 1
                totalCount &+= 1
                continue
            }
            let bitcount = getPopulationCountPrecision(
                Int32(code - 1), shift, logTabSize: Int32(precisionBits)
            )
            let extraBits: UInt32 = bitcount > 0
                ? try r.read(bits: bitcount) : 0
            let cnt = Int32(1) << Int32(code - 1)
                &+ Int32(bitPattern: extraBits) << Int32(code - 1 - bitcount)
            counts[j] = cnt
            totalCount &+= cnt
        }
        // The omit position absorbs whatever's needed to reach `range`.
        counts[omitPos] = range &- totalCount
        if counts[omitPos] <= 0 {
            throw SpecANSDistributionError.invalidHistogram(
                "omit-position count non-positive (range=\(range), other=\(totalCount))"
            )
        }
        return counts
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

/// libjxl `GetPopulationCountPrecision`. Returns the number of extra
/// bits to refine a logcount-only count value:
///
///     r = min(logcount, shift - ((ANS_LOG_TAB_SIZE - logcount) >> 1))
///     return max(r, 0)
///
/// (The previous incorrect implementation used `max(val - shift, 0),
/// min(raw, logTabSize - shift)`, which gave wrong bit counts for
/// most inputs and thus consumed wrong bits during histogram
/// reconstruction — silently breaking byte-equality with cjxl.)
@inline(__always)
private func getPopulationCountPrecision(
    _ val: Int32, _ shift: Int32, logTabSize: Int32
) -> Int {
    let term = shift &- ((logTabSize &- val) &>> 1)
    let r = min(val, term)
    return Int(max(r, 0))
}

/// Floor of log2 for nonzero positive values (returns 0 for value=1).
@inline(__always)
private func floorLog2Nonzero(_ value: UInt32) -> Int {
    if value == 0 { return 0 }
    return 31 - Int(value.leadingZeroBitCount)
}
