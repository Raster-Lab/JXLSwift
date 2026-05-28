// PrefixCodeSerialisation — bitstream format for prefix-code tables.
//
// ISO/IEC 18181-1 §C.6.2.1. A prefix-code table is encoded in one of
// two ways: "simple" (1–4 explicit symbols with predefined lengths) or
// "complex" (a per-symbol lengths array, itself entropy-coded by a
// small meta-Huffman over the code-length values 0–18 with run-length
// symbols 16/17 for repetitions).
//
// Both formats are implemented here. The shared 2-bit `hskip` header
// selects between them: hskip == 1 → simple; hskip ∈ {0, 2, 3} →
// complex (with the value indicating how many of the first 18
// code-length-code lengths to skip).
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
            // Single-symbol code: `symbols[0]` is the only symbol and
            // is always emitted with a zero-bit codeword. Mark it with
            // a non-zero length so `PrefixCodeTable`'s degenerate
            // branch routes the decode to `symbols[0]` — it returns
            // the first non-zero-length symbol. A plain all-zero
            // array would wrongly always decode to symbol 0 (the bug
            // that broke `used_orders≠0` AC streams whose single-
            // symbol clusters select a symbol other than 0).
            lengths[symbols[0]] = 1
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

// MARK: - Unified prefix-code decoder

public enum PrefixCodeFormatError: Error, Sendable, Equatable {
    case simple(SimplePrefixCodeError)
    case complex(ComplexPrefixCodeError)
    case zeroAlphabet
}

/// Decode a prefix-code table from a bitstream. Picks between the
/// simple and complex sub-formats by peeking the leading 2-bit
/// `hskip` field — `hskip == 1` selects simple, otherwise complex.
/// Returns a ready-to-use `PrefixCodeTable`.
///
/// Mirrors libjxl `PrefixCodeData::ReadFromBitStream`.
public enum PrefixCodeFormat {

    /// Single-entry decode: returns a `PrefixCodeTable` for a code
    /// with `alphabetSize` symbols. Caller must position the reader
    /// at the `hskip` header bits.
    public static func decode(
        from r: inout BitReader, alphabetSize: Int
    ) throws -> PrefixCodeTable {
        guard alphabetSize >= 1 else {
            throw PrefixCodeFormatError.zeroAlphabet
        }
        // Special case: single-symbol alphabets emit zero header bits
        // and have a trivial decode (always emit symbol 0).
        if alphabetSize == 1 {
            // PrefixCodeTable requires lengths.count == alphabetSize
            // and at least one zero entry — synthesise.
            do {
                return try PrefixCodeTable(lengths: [0])
            } catch let e as PrefixCodeError {
                throw PrefixCodeFormatError.complex(.prefixCode(e))
            }
        }
        // Peek the 2-bit hskip to decide which sub-format to use,
        // *without* advancing the reader (each sub-format reads its
        // own hskip).
        let hskip: UInt32
        do { hskip = try r.peek(bits: 2) }
        catch let e as BitstreamError {
            throw PrefixCodeFormatError.complex(.bitstream(e))
        }
        if hskip == 1 {
            let lengths: [UInt8]
            do {
                lengths = try SimplePrefixCodeFormat.decode(
                    from: &r, alphabetSize: alphabetSize
                )
            } catch let e as SimplePrefixCodeError {
                throw PrefixCodeFormatError.simple(e)
            }
            do { return try PrefixCodeTable(lengths: lengths) }
            catch let e as PrefixCodeError {
                throw PrefixCodeFormatError.complex(.prefixCode(e))
            }
        }
        let lengths: [UInt8]
        do {
            lengths = try ComplexPrefixCodeFormat.decode(
                from: &r, alphabetSize: alphabetSize
            )
        } catch let e as ComplexPrefixCodeError {
            throw PrefixCodeFormatError.complex(e)
        }
        do { return try PrefixCodeTable(lengths: lengths) }
        catch let e as PrefixCodeError {
            throw PrefixCodeFormatError.complex(.prefixCode(e))
        }
    }

    /// Encode a prefix-code table from its `lengths` array. Inverse
    /// of `decode`. Picks `SimplePrefixCodeFormat.encode` when the
    /// alphabet has 1–4 non-zero-length symbols and the implied
    /// length pattern matches one of the simple shapes
    /// ({0}, {1,1}, {1,2,2}, {2,2,2,2}, {1,2,3,3}); otherwise falls
    /// back to `ComplexPrefixCodeFormat.encode`. Single-symbol
    /// alphabets emit zero bits — they're a degenerate case
    /// declared by `alphabet_size == 1` in the surrounding codebook.
    public static func encode(
        to w: inout BitWriter,
        lengths: [UInt8],
        alphabetSize: Int
    ) throws {
        guard alphabetSize >= 1 else {
            throw PrefixCodeFormatError.zeroAlphabet
        }
        if alphabetSize == 1 {
            // Trivial single-symbol code emits no bits — the surrounding
            // codebook already declared `alphabet_size == 1`, which the
            // decoder uses to skip table reading entirely.
            return
        }
        // Try the simple shapes. Collect non-zero-length symbols in
        // ascending length order.
        let nonzero = lengths.enumerated()
            .filter { $0.element > 0 }
            .map { (symbol: $0.offset, length: $0.element) }
            .sorted { $0.length < $1.length }
        if let symbols = simpleShapeMatch(
            nonzero: nonzero, alphabetSize: alphabetSize
        ) {
            do {
                try SimplePrefixCodeFormat.encode(
                    to: &w, symbols: symbols.symbols,
                    alphabetSize: alphabetSize,
                    useLongCodewords: symbols.useLongCodewords
                )
                return
            } catch let e as SimplePrefixCodeError {
                throw PrefixCodeFormatError.simple(e)
            }
        }
        // Fall back to the complex format.
        do {
            try ComplexPrefixCodeFormat.encode(to: &w, lengths: lengths)
        } catch let e as ComplexPrefixCodeError {
            throw PrefixCodeFormatError.complex(e)
        }
    }

    /// Decide whether `nonzero` (sorted by ascending code length)
    /// matches one of the simple-code shapes. Returns the symbol list
    /// in canonical order (length-1, length-2, length-3...) plus the
    /// `useLongCodewords` bit for the 4-symbol case, or nil if a
    /// complex code is needed.
    private static func simpleShapeMatch(
        nonzero: [(symbol: Int, length: UInt8)],
        alphabetSize: Int
    ) -> (symbols: [Int], useLongCodewords: Bool)? {
        switch nonzero.count {
        case 1 where nonzero[0].length == 0:
            // Degenerate. We already returned for alphabetSize == 1
            // above, so this case shouldn't reach here in practice;
            // fall through to "no simple match".
            return nil
        case 2 where nonzero[0].length == 1 && nonzero[1].length == 1:
            return (symbols: [nonzero[0].symbol, nonzero[1].symbol],
                    useLongCodewords: false)
        case 3 where nonzero[0].length == 1
                  && nonzero[1].length == 2 && nonzero[2].length == 2:
            return (symbols: [nonzero[0].symbol,
                              nonzero[1].symbol, nonzero[2].symbol],
                    useLongCodewords: false)
        case 4:
            // {2,2,2,2} → useLongCodewords=false.
            if nonzero[0].length == 2 && nonzero[1].length == 2
                && nonzero[2].length == 2 && nonzero[3].length == 2 {
                return (symbols: nonzero.map { $0.symbol },
                        useLongCodewords: false)
            }
            // {1,2,3,3} → useLongCodewords=true.
            if nonzero[0].length == 1 && nonzero[1].length == 2
                && nonzero[2].length == 3 && nonzero[3].length == 3 {
                return (symbols: nonzero.map { $0.symbol },
                        useLongCodewords: true)
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Complex prefix-code-table format (§C.6.2.1, complex branch)
//
// When the `hskip` header is 0, 2, or 3, the prefix-code-table is
// encoded via a meta-Huffman code over a 19-symbol alphabet (0..18):
//
//     symbols 0..15  → literal code length (the next output length)
//     symbol 16      → repeat the previous non-zero length 3 + u(2) times
//     symbol 17      → emit a zero-run of 3 + u(3) zero lengths
//     symbol 18      → reserved (rare, not yet supported)
//
// The meta-Huffman is itself built from 18 "code-length-code lengths"
// (cll[0..17]). Those 18 cll values are read from the bitstream in a
// fixed re-ordered sequence (kCodeLengthCodeOrder below), with the
// first `hskip` of them treated as zero (most-common values appear
// last in the order so skipping doesn't hurt).
//
// Each cll value is read as a raw u(3) — values 0..5 are valid lengths;
// values 6 and 7 are reserved. Note: this is one defensible reading of
// the spec text; libjxl byte-for-byte cross-validation should confirm
// before treating it as authoritative.

public enum ComplexPrefixCodeError: Error, Sendable, Equatable {
    case wrongHeader(gotHskip: Int)
    case reservedCLL(value: Int)
    case reservedSymbol(value: Int)
    case lengthsArrayOverflow(emittedCount: Int, alphabetSize: Int)
    case bitstream(BitstreamError)
    case prefixCode(PrefixCodeError)
}

/// Order in which the 18 code-length-code lengths are read from the
/// bitstream. Permits skipping the first `hskip` values to save bits
/// when those are zero (the spec-recommended common case). Mirrors
/// libjxl `dec_huffman.cc::kCodeLengthCodeOrder` exactly.
let kCodeLengthCodeOrder: [Int] = [
    1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15
]

/// Static Huffman table for the 6 valid cll (code-length-code-length)
/// values. Indexed by 4 peeked LSB-first bits; each entry is
/// `(bits_to_consume, decoded_cll)`. From libjxl `dec_huffman.cc:206`.
fileprivate let kCLLHuffman: [(consume: Int, value: UInt8)] = [
    (2, 0), (2, 4), (2, 3), (3, 2), (2, 0), (2, 4), (2, 3), (4, 1),
    (2, 0), (2, 4), (2, 3), (3, 2), (2, 0), (2, 4), (2, 3), (4, 5),
]

/// Inverse of `kCLLHuffman` — codeword and length per cll value 0..5.
/// LSB-first patterns: 0→"00", 1→"1110", 2→"110", 3→"01", 4→"10",
/// 5→"1111".
fileprivate let kCLLEncodings: [(codeword: UInt32, length: Int)?] = [
    /* 0 */ (0b00,   2),
    /* 1 */ (0b0111, 4),
    /* 2 */ (0b011,  3),
    /* 3 */ (0b10,   2),
    /* 4 */ (0b01,   2),
    /* 5 */ (0b1111, 4),
]

@inline(__always)
fileprivate func writeCLLValue(_ v: UInt8, to w: inout BitWriter) throws {
    guard v < kCLLEncodings.count, let enc = kCLLEncodings[Int(v)] else {
        throw ComplexPrefixCodeError.reservedCLL(value: Int(v))
    }
    w.write(bits: enc.length, value: enc.codeword)
}

/// The complex format, mirror of `SimplePrefixCodeFormat`. Decoder is
/// implemented; encoder uses a deliberately simple ("no-run-length-
/// compression") emission strategy — every literal length is emitted
/// as itself, with no symbol-16 / symbol-17 runs. This is correct but
/// not size-optimal; an optimising encoder is future work.
public struct ComplexPrefixCodeFormat {

    /// Decode a complex prefix code into a complete lengths array of
    /// size `alphabetSize`. Reader must be positioned at the `hskip`
    /// header bits when called.
    public static func decode(
        from r: inout BitReader,
        alphabetSize: Int
    ) throws -> [UInt8] {
        let hskip = Int(try r.read(bits: 2))
        guard hskip == 0 || hskip == 2 || hskip == 3 else {
            throw ComplexPrefixCodeError.wrongHeader(gotHskip: hskip)
        }

        // Read the 18 cll values in spec order, skipping the first
        // hskip. Each cll is encoded by the static 16-entry Huffman
        // table `kCLLHuffman` — values 0..5 with codeword lengths
        // 2..4 bits — peeked from the next 4 bits of the stream.
        //
        // The loop terminates EARLY when the Kraft budget `space`
        // (initialised to 32 = 2^5) hits zero — each non-zero cll
        // value `v` consumes `32 >> v` of the budget. This matches
        // libjxl `dec_huffman.cc::ReadFromBitStream` line 210, and
        // is what stops short codes from forming an oversubscribed
        // meta-Huffman.
        var cll = [UInt8](repeating: 0, count: 18)
        var space = 32
        for i in hskip..<18 where space > 0 {
            let peekBits = min(4, r.bitsRemaining)
            var idx: UInt32 = 0
            if peekBits > 0 {
                idx = try r.peek(bits: peekBits)
            }
            let entry = kCLLHuffman[Int(idx) & 0x0F]
            try r.skip(bits: entry.consume)
            let v = entry.value
            cll[kCodeLengthCodeOrder[i]] = v
            if v != 0 {
                space &-= 32 &>> Int(v)
            }
        }

        // Build the meta-Huffman code over alphabet 0..18.
        let metaTable: PrefixCodeTable
        do {
            metaTable = try PrefixCodeTable(lengths: cll)
        } catch let e as PrefixCodeError {
            throw ComplexPrefixCodeError.prefixCode(e)
        }

        // Decode the actual lengths array. Faithful port of libjxl
        // `dec_huffman.cc::ReadHuffmanCodeLengths`: the loop stops
        // when the Kraft budget `space` (2^15) reaches 0 — NOT when
        // `alphabetSize` symbols have been read — and the repeat
        // codes (16/17) **accumulate** across consecutive uses of
        // the same repeat kind. (A previous draft read all
        // `alphabetSize` lengths with a naive `3 + extra` repeat;
        // that is correct only for short, run-free codes and
        // produced oversubscribed lengths for large run-heavy codes
        // like the codestream ICC's 523-symbol alphabet.)
        var actual = [UInt8](repeating: 0, count: alphabetSize)
        var symbol = 0
        var prevCodeLen: UInt8 = 8          // kDefaultCodeLength
        var rep = 0
        var repeatCodeLen: UInt8 = 0
        var lenSpace = 32768                 // 2^15 Kraft budget

        while symbol < alphabetSize && lenSpace > 0 {
            let sym: Int
            do {
                sym = try metaTable.decode(from: &r)
            } catch let e as BitstreamError {
                throw ComplexPrefixCodeError.bitstream(e)
            }
            if sym < 16 {
                rep = 0
                actual[symbol] = UInt8(sym)
                symbol += 1
                if sym != 0 {
                    prevCodeLen = UInt8(sym)
                    lenSpace -= 32768 >> sym
                }
            } else if sym == 16 || sym == 17 {
                let extraBits = sym - 14         // 16→2, 17→3
                let newLen: UInt8 = (sym == 16) ? prevCodeLen : 0
                if repeatCodeLen != newLen {
                    rep = 0
                    repeatCodeLen = newLen
                }
                let oldRepeat = rep
                if rep > 0 {
                    rep -= 2
                    rep <<= extraBits
                }
                let extra = try r.read(bits: extraBits)
                rep += Int(extra) + 3
                let delta = rep - oldRepeat
                guard symbol + delta <= alphabetSize else {
                    throw ComplexPrefixCodeError.lengthsArrayOverflow(
                        emittedCount: symbol + delta,
                        alphabetSize: alphabetSize)
                }
                for _ in 0..<delta {
                    actual[symbol] = repeatCodeLen
                    symbol += 1
                }
                if repeatCodeLen != 0 {
                    lenSpace -= delta << (15 - Int(repeatCodeLen))
                }
            } else {
                throw ComplexPrefixCodeError.reservedSymbol(value: sym)
            }
        }
        // Remaining symbols (past the point the Kraft budget filled)
        // are zero-length — already zero-initialised.
        return actual
    }

    /// Encode a lengths array using the complex format. This
    /// implementation is correct but **not size-optimal** — it emits
    /// every length as a literal symbol (0..15) and never uses
    /// run-length symbols 16 or 17. The output is decodable by our
    /// own decoder above; an optimising encoder would search for runs
    /// and emit shorter representations.
    ///
    /// The encoder builds the meta-Huffman from a histogram of the
    /// literal lengths used in `lengths`, then emits each length as
    /// its meta-Huffman codeword.
    public static func encode(
        to w: inout BitWriter,
        lengths: [UInt8]
    ) throws {
        // hskip = 0 → emit all 18 cll values literally (no shortcut).
        w.write(bits: 2, value: 0)

        // Compute literal-symbol histogram (only 0..15 since we don't
        // emit 16/17/18).
        var histo = [Int](repeating: 0, count: 19)
        for l in lengths {
            precondition(l <= 15, "length \(l) exceeds the 15-bit maximum")
            histo[Int(l)] += 1
        }

        // Build a canonical Huffman over alphabet 0..18 from the histogram,
        // capped at length 5 (the cll constraint). The standard Huffman
        // construction may produce longer codes for skewed distributions;
        // we use a simple length-limited fallback: if any length > 5, fall
        // back to a flat code over the symbols actually used.
        let metaLengths = lengthLimitedCanonicalHuffman(
            counts: histo, maxLength: 5, alphabetSize: 19
        )
        // cll values are written in the prescribed order, via the
        // static-Huffman codewords (`kCLLEncodings`) the spec
        // mandates. We stop early once the Kraft budget `space`
        // (initialised to 32) hits zero — the decoder uses the same
        // termination, so writing more would desync the cursors.
        var space = 32
        for i in 0..<18 where space > 0 {
            let v = metaLengths[kCodeLengthCodeOrder[i]]
            try writeCLLValue(v, to: &w)
            if v != 0 {
                space &-= 32 &>> Int(v)
            }
        }

        // Build the meta-Huffman from the just-emitted cll values, then
        // encode each input length using it.
        let metaTable: PrefixCodeTable
        do {
            metaTable = try PrefixCodeTable(lengths: metaLengths)
        } catch let e as PrefixCodeError {
            throw ComplexPrefixCodeError.prefixCode(e)
        }
        for l in lengths {
            try metaTable.encode(Int(l), to: &w)
        }
    }
}

/// Build a canonical-Huffman lengths table from a symbol-frequency
/// histogram, capped at `maxLength` bits. Uses a flat-Kraft assignment:
/// for `n` used symbols, places `(cap - n)` of them at depth `L - 1`
/// and `(2n - cap)` of them at depth `L`, where `L = ceil(log2(n))`
/// and `cap = 2^L`. Most-frequent symbols get the shorter codes.
///
/// Kraft check (PrefixCodeTable enforces it):
///   `(cap - n) * 2^(maxLength - (L-1)) + (2n - cap) * 2^(maxLength - L)`
///   = `2^(maxLength - L) * ((cap - n) * 2 + (2n - cap))`
///   = `2^(maxLength - L) * cap`
///   = `2^maxLength` ✓
///
/// Edge cases:
///   - 0 used symbols → all-zero lengths (caller handles the
///     "no entropy code needed" case).
///   - 1 used symbol → pad with symbol 0 at length 1 so the meta-
///     Huffman has at least 2 symbols (PrefixCodeTable requires ≥ 2
///     for Kraft).
///   - n exceeds 2^maxLength → cap at maxLength for every used
///     symbol; caller's responsibility to ensure that's correctable.
///
/// This is intentionally simple — a true length-limited Huffman
/// (e.g. package-merge) would compress better on skewed
/// distributions, but the resulting bit budget for the meta-Huffman
/// is small either way.
func lengthLimitedCanonicalHuffman(
    counts: [Int],
    maxLength: Int,
    alphabetSize: Int
) -> [UInt8] {
    var lengths = [UInt8](repeating: 0, count: alphabetSize)
    let used = (0..<alphabetSize).filter { counts[$0] > 0 }
    if used.isEmpty {
        return lengths
    }
    if used.count == 1 {
        // Pad with symbol 0 (or symbol 1 if symbol 0 is the used one)
        // so we have 2 symbols both at length 1 — Kraft balanced.
        lengths[used[0]] = 1
        let padIdx = (used[0] == 0) ? 1 : 0
        lengths[padIdx] = 1
        return lengths
    }
    if used.count == 2 {
        lengths[used[0]] = 1
        lengths[used[1]] = 1
        return lengths
    }

    let n = used.count
    let baseL = Int(ceilLog2(UInt32(n)))
    if baseL > maxLength {
        // n > 2^maxLength: cap every used symbol; Kraft will fail.
        for s in used { lengths[s] = UInt8(maxLength) }
        return lengths
    }
    let cap = 1 << baseL
    if n == cap {
        // Power-of-two count: every used symbol gets length baseL.
        for s in used { lengths[s] = UInt8(baseL) }
        return lengths
    }
    // (cap - n) short symbols at length (baseL - 1); the rest at baseL.
    let shortCount = cap - n
    let sorted = used.sorted { counts[$0] > counts[$1] }
    for (i, s) in sorted.enumerated() {
        lengths[s] = UInt8(i < shortCount ? baseL - 1 : baseL)
    }
    return lengths
}
