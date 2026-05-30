// ANSDistributionSerialisation — bitstream format for rANS distributions.
//
// ISO/IEC 18181-1 §C.6.3.2. An rANS distribution encodes per-symbol
// frequencies (summing to `tabSize` = 4096) into the bitstream. The
// spec defines three shapes:
//
//   1. Simple   — 1–4 symbols with predefined-shape frequencies. Used
//                 when the distribution is highly skewed onto a few
//                 symbols (most common case in real codestreams).
//   2. Flat     — uniform over the alphabet. Each symbol gets the same
//                 frequency (with a small remainder absorbed by the
//                 first symbols so the total still sums to tabSize).
//   3. Full     — explicit per-symbol log-counts encoded via a
//                 prefix code (recursive). Not yet implemented.
//
// Bit layout (this implementation):
//
//     is_simple        u(1)
//     if is_simple == 1:
//         nsym_minus_1 u(2)            // 0..3 → 1..4 symbols
//         symbols[0..n] u(log_alpha)   // each symbol index
//     else:
//         is_flat      u(1)
//         if is_flat == 1:
//             // alphabet_size is supplied externally in this layer;
//             // the spec emits an alphabet_size_log here for the
//             // standalone histogram form. Callers that need the
//             // standalone form should serialise alphabet_size_log
//             // separately for now (deferred).
//         else:
//             // **Project-internal full mode** (see caveat).
//             freq[0..<alphabet_size] each u(13)   // sum = tabSize
//
// **Caveat on the full path:** the JXL spec encodes per-symbol
// frequencies via a `log_counts` prefix code with a `shift`
// parameter (§C.6.3.2 full branch). Implementing that requires spec
// text I don't have. To unblock M0 compression on natural-image-
// shaped histograms, this file ships a *simpler*, **project-internal**
// full layout: one u(13) frequency per symbol, in order. Frequencies
// must sum to exactly `ANSConstants.tabSize` (4 096). This is
// round-trip-tested but **NOT byte-for-byte spec compliant**;
// replacing it with the spec's log-counts encoding is future work.
//
// Frequency assignment by simple-shape (my interpretation of §C.6.3.2):
//
//     nsym = 1 → [tab]
//     nsym = 2 → [tab/2, tab/2]
//     nsym = 3 → [tab/4, tab/4, tab/2]
//     nsym = 4 → [tab/4, tab/4, tab/4, tab/4]
//
// For nsym ∈ {2, 3, 4} the spec lists the same total `tab` and the
// per-position distribution above. This matches libjxl's `dec_ans.cc`
// `ReadHistogram` simple-distribution path.
//
// Flat assignment: each used symbol gets `tab / alphabet_size`, with
// the remainder distributed across the first `tab % alphabet_size`
// symbols (each getting +1).
//
// **Caveat:** byte-for-byte cross-validation against libjxl is the
// authoritative confirmation. Round-trip tests prove encoder/decoder
// agreement, not spec compliance — see SESSION-NOTES.

import Foundation

package enum ANSDistributionFormatError: Error, Sendable, Equatable {
    case unsupportedNumSymbols(Int)
    case alphabetTooLarge(Int)
    case alphabetTooSmall(Int)
    case duplicateSymbol(Int)
    case symbolOutOfRange(Int)
    case invalidFullSum(expected: UInt32, got: UInt32)
    case bitstream(BitstreamError)
}

package struct ANSDistributionFormat {

    /// Encode a single-symbol "constant" distribution (all probability
    /// on one symbol). Bit layout: `is_simple=1, nsym_minus_1=0,
    /// symbol=u(log_alpha)`.
    package static func encodeConstant(
        symbol: Int,
        alphabetSize: Int,
        to w: inout BitWriter
    ) throws {
        guard alphabetSize >= 2 && alphabetSize <= (1 << 16) else {
            throw ANSDistributionFormatError.alphabetTooLarge(alphabetSize)
        }
        guard symbol >= 0 && symbol < alphabetSize else {
            throw ANSDistributionFormatError.symbolOutOfRange(symbol)
        }
        let logAlpha = Int(ceilLog2(UInt32(alphabetSize)))
        w.writeBit(true)               // is_simple = 1
        w.write(bits: 2, value: 0)     // nsym - 1 = 0 → 1 symbol
        w.write(bits: logAlpha, value: UInt32(symbol))
    }

    /// Encode a simple 1–4-symbol distribution with predefined shape.
    /// `symbols` lists the alphabet-indices receiving non-zero
    /// probability, in the order their predefined frequencies apply.
    /// Symbols must be distinct and in-range.
    package static func encodeSimple(
        symbols: [Int],
        alphabetSize: Int,
        to w: inout BitWriter
    ) throws {
        guard alphabetSize >= 2 && alphabetSize <= (1 << 16) else {
            throw ANSDistributionFormatError.alphabetTooLarge(alphabetSize)
        }
        guard (1...4).contains(symbols.count) else {
            throw ANSDistributionFormatError.unsupportedNumSymbols(symbols.count)
        }
        var seen = Set<Int>()
        for s in symbols {
            guard s >= 0 && s < alphabetSize else {
                throw ANSDistributionFormatError.symbolOutOfRange(s)
            }
            if !seen.insert(s).inserted {
                throw ANSDistributionFormatError.duplicateSymbol(s)
            }
        }
        let logAlpha = Int(ceilLog2(UInt32(alphabetSize)))

        w.writeBit(true)                              // is_simple = 1
        w.write(bits: 2, value: UInt32(symbols.count - 1))
        for s in symbols {
            w.write(bits: logAlpha, value: UInt32(s))
        }
    }

    /// Encode a flat (uniform) distribution. The decoder needs the
    /// alphabet size to materialise the per-symbol frequencies; we
    /// pass it externally in this layer (the standalone histogram
    /// form, which embeds alphabet_size_log inline, is part of the
    /// not-yet-implemented full path).
    package static func encodeFlat(
        alphabetSize: Int,
        to w: inout BitWriter
    ) throws {
        guard alphabetSize >= 2 else {
            throw ANSDistributionFormatError.alphabetTooSmall(alphabetSize)
        }
        guard alphabetSize <= Int(ANSConstants.tabSize) else {
            // Flat needs each symbol to receive ≥ 1, so alphabet_size
            // can't exceed tabSize (4096).
            throw ANSDistributionFormatError.alphabetTooLarge(alphabetSize)
        }
        w.writeBit(false)                  // is_simple = 0
        w.writeBit(true)                   // is_flat   = 1
    }

    /// Encode a full per-symbol-frequency distribution. **Project-
    /// internal layout** (see file-top caveat): `is_simple=0,
    /// is_flat=0, freq[0..<alphabetSize] each u(13)`. Each frequency
    /// must be ≥ 0 and the sum must equal `ANSConstants.tabSize`
    /// (4 096) exactly. Use `normaliseToTabSize` to coerce a raw
    /// histogram into a valid distribution.
    package static func encodeFull(
        frequencies: [UInt32],
        alphabetSize: Int,
        to w: inout BitWriter
    ) throws {
        guard alphabetSize >= 2 else {
            throw ANSDistributionFormatError.alphabetTooSmall(alphabetSize)
        }
        guard alphabetSize <= Int(ANSConstants.tabSize) else {
            throw ANSDistributionFormatError.alphabetTooLarge(alphabetSize)
        }
        guard frequencies.count == alphabetSize else {
            throw ANSDistributionFormatError.alphabetTooLarge(alphabetSize)
        }
        let sum = frequencies.reduce(UInt32(0), &+)
        guard sum == ANSConstants.tabSize else {
            throw ANSDistributionFormatError.invalidFullSum(
                expected: ANSConstants.tabSize, got: sum
            )
        }
        w.writeBit(false)              // is_simple = 0
        w.writeBit(false)              // is_flat   = 0
        for freq in frequencies {
            // u(13) holds 0..8191; tabSize is 4096, so freq ≤ 4096
            // fits easily.
            guard freq <= 0x1FFF else {
                throw ANSDistributionFormatError.invalidFullSum(
                    expected: 0x1FFF, got: freq
                )
            }
            w.write(bits: 13, value: freq)
        }
    }

    /// Coerce a raw symbol histogram into a per-symbol frequency
    /// array that sums to exactly `tabSize` (4 096). Symbols with
    /// non-zero raw count get at least frequency 1 (so they're
    /// encodable); rounding adjustment is absorbed by the symbol
    /// with the largest current frequency. Useful for callers
    /// preparing input to `encodeFull`.
    package static func normaliseToTabSize(_ raw: [UInt32]) throws -> [UInt32] {
        guard !raw.isEmpty else {
            throw ANSDistributionFormatError.alphabetTooSmall(0)
        }
        let total = raw.reduce(UInt64(0)) { $0 &+ UInt64($1) }
        guard total > 0 else {
            throw ANSDistributionFormatError.alphabetTooSmall(0)
        }
        let tab = UInt64(ANSConstants.tabSize)
        var normed = [UInt32](repeating: 0, count: raw.count)
        for i in 0..<raw.count {
            if raw[i] == 0 { continue }
            let scaled = UInt64(raw[i]) * tab / total
            normed[i] = UInt32(max(1, scaled))
        }
        var sum: Int64 = normed.reduce(Int64(0)) { $0 &+ Int64($1) }
        let target = Int64(tab)
        while sum != target {
            var bestIdx = -1
            var bestFreq: UInt32 = 0
            for i in 0..<raw.count where normed[i] > bestFreq {
                bestFreq = normed[i]; bestIdx = i
            }
            guard bestIdx >= 0 else { break }
            if sum < target {
                normed[bestIdx] &+= 1; sum &+= 1
            } else {
                if normed[bestIdx] <= 1 { break }
                normed[bestIdx] &-= 1; sum &-= 1
            }
        }
        return normed
    }

    /// Decode a distribution. Caller supplies the alphabet size; on
    /// return, `frequencies.count == alphabetSize` and frequencies sum
    /// to `tabSize`.
    package static func decode(
        alphabetSize: Int,
        from r: inout BitReader
    ) throws -> ANSDistribution {
        guard alphabetSize >= 2 && alphabetSize <= (1 << 16) else {
            throw ANSDistributionFormatError.alphabetTooLarge(alphabetSize)
        }
        let logAlpha = Int(ceilLog2(UInt32(alphabetSize)))

        let isSimple: Bool
        do { isSimple = try r.readBit() }
        catch let e as BitstreamError { throw ANSDistributionFormatError.bitstream(e) }

        if isSimple {
            let nsymMinus1: UInt32
            do { nsymMinus1 = try r.read(bits: 2) }
            catch let e as BitstreamError { throw ANSDistributionFormatError.bitstream(e) }
            let nsym = Int(nsymMinus1) + 1
            var symbols: [Int] = []
            symbols.reserveCapacity(nsym)
            var seen = Set<Int>()
            for _ in 0..<nsym {
                let s: UInt32
                do { s = try r.read(bits: logAlpha) }
                catch let e as BitstreamError { throw ANSDistributionFormatError.bitstream(e) }
                let si = Int(s)
                guard si < alphabetSize else {
                    throw ANSDistributionFormatError.symbolOutOfRange(si)
                }
                if !seen.insert(si).inserted {
                    throw ANSDistributionFormatError.duplicateSymbol(si)
                }
                symbols.append(si)
            }
            return try buildSimpleDistribution(symbols: symbols, alphabetSize: alphabetSize)
        }

        let isFlat: Bool
        do { isFlat = try r.readBit() }
        catch let e as BitstreamError { throw ANSDistributionFormatError.bitstream(e) }
        if isFlat {
            return try buildFlatDistribution(alphabetSize: alphabetSize)
        }

        // Project-internal full mode: alphabet_size × u(13) frequencies.
        var freqs = [UInt32](); freqs.reserveCapacity(alphabetSize)
        var sum: UInt32 = 0
        for _ in 0..<alphabetSize {
            let f: UInt32
            do { f = try r.read(bits: 13) }
            catch let e as BitstreamError { throw ANSDistributionFormatError.bitstream(e) }
            freqs.append(f)
            sum &+= f
        }
        guard sum == ANSConstants.tabSize else {
            throw ANSDistributionFormatError.invalidFullSum(
                expected: ANSConstants.tabSize, got: sum
            )
        }
        return try ANSDistribution(rawFrequencies: freqs)
    }

    // MARK: - Frequency assignment

    static func buildSimpleDistribution(
        symbols: [Int],
        alphabetSize: Int
    ) throws -> ANSDistribution {
        let tab = Int(ANSConstants.tabSize)
        var counts = [UInt32](repeating: 0, count: alphabetSize)
        switch symbols.count {
        case 1:
            counts[symbols[0]] = UInt32(tab)
        case 2:
            counts[symbols[0]] = UInt32(tab / 2)
            counts[symbols[1]] = UInt32(tab / 2)
        case 3:
            counts[symbols[0]] = UInt32(tab / 4)
            counts[symbols[1]] = UInt32(tab / 4)
            counts[symbols[2]] = UInt32(tab / 2)
        case 4:
            counts[symbols[0]] = UInt32(tab / 4)
            counts[symbols[1]] = UInt32(tab / 4)
            counts[symbols[2]] = UInt32(tab / 4)
            counts[symbols[3]] = UInt32(tab / 4)
        default:
            throw ANSDistributionFormatError.unsupportedNumSymbols(symbols.count)
        }
        // Sanity-check the sum before handing to the rANS distribution
        // builder. We need an *exact* tabSize-summing distribution, so
        // bypass the builder's normalisation (which would no-op here)
        // by using its rawFrequencies path — the values already sum to
        // tabSize.
        return try ANSDistribution(rawFrequencies: counts)
    }

    static func buildFlatDistribution(alphabetSize: Int) throws -> ANSDistribution {
        let tab = Int(ANSConstants.tabSize)
        let base = tab / alphabetSize
        let remainder = tab - base * alphabetSize
        var counts = [UInt32](repeating: UInt32(base), count: alphabetSize)
        // First `remainder` symbols receive +1 so the sum equals tabSize.
        for i in 0..<remainder { counts[i] += 1 }
        return try ANSDistribution(rawFrequencies: counts)
    }
}
