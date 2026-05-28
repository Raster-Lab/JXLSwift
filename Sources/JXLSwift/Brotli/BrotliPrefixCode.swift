// `Brotli/BrotliPrefixCode.swift` — Brotli's prefix code (canonical
// Huffman) reader. RFC 7932 §3 defines two formats:
//
//   • **Simple** (§3.4) — 1 to 4 symbols, encoded explicitly with
//     fixed-width symbol fields. Used when the alphabet is small or
//     the tree is trivial.
//   • **Complex** (§3.5) — full canonical Huffman with run-length-
//     encoded code lengths over an alphabet of `[0..alphabet_size)`.
//     Uses a 5-bit "HSKIP" prefix selector and an alphabet of 18
//     code-length symbols (lengths 0..15 plus run-length 16/17).
//
// Both formats are recognised via a 2-bit selector:
//   `00` ⇒ complex, HSKIP = 0
//   `01` ⇒ simple
//   `10` ⇒ complex, HSKIP = 2
//   `11` ⇒ complex, HSKIP = 3
//
// (RFC 7932 §3.4 — "the first two bits select between the two
// formats and the HSKIP value for the complex format".)
//
// Phase J step 5c. v0.12.0fz scaffold + canonical-Huffman decode +
// simple format + complex format.

import Foundation

/// A Brotli prefix (Huffman) code, decoded from the bitstream.
/// Symbol-to-bit-length mapping plus the canonical-Huffman tables
/// derived from it. Decoded values are in `[0, alphabetSize)`.
public struct BrotliPrefixCode: Sendable {
    /// Number of distinct symbols this code can produce.
    public let alphabetSize: Int
    /// Per-symbol bit length (0 = symbol not used). Length =
    /// `alphabetSize`.
    public let codeLengths: [UInt8]
    /// Codes assigned to each symbol via the canonical-Huffman
    /// algorithm. Symbols with `codeLengths[i] == 0` are unused
    /// and the corresponding entry is 0 (sentinel).
    public let codes: [UInt32]
    /// Special-case marker for single-symbol trees: when only one
    /// symbol has a non-zero code length (or all lengths are zero
    /// signalling a 1-symbol code per RFC 7932 §3.4 NSYM=0), every
    /// read of this code yields the same symbol without consuming
    /// bits. Stored here for fast-path dispatch.
    public let singleSymbol: UInt32?

    /// Build a canonical-Huffman code from per-symbol bit lengths.
    /// Mirrors RFC 1951 §3.2.2 (Deflate) — same algorithm Brotli
    /// uses (RFC 7932 §3.2).
    ///
    ///   bl_count[N]: count of codes with length N
    ///   next_code[N]: next code value for length N (canonical)
    ///
    /// Validates the Kraft inequality (sum of 2^-len = 1 for a
    /// complete code) — throws `malformedPrefixCode` otherwise.
    /// A single non-zero entry is treated as a 1-symbol code with
    /// 0-bit lookup (the singleSymbol fast path).
    public init(
        alphabetSize: Int, codeLengths: [UInt8]
    ) throws {
        precondition(codeLengths.count == alphabetSize,
            "BrotliPrefixCode: codeLengths.count must == alphabetSize")
        self.alphabetSize = alphabetSize
        self.codeLengths = codeLengths

        let maxLen = 15  // Brotli prefix codes max at 15 bits
        var blCount = [Int](repeating: 0, count: maxLen + 1)
        var nonZeroCount = 0
        var lastNonZero: UInt32 = 0
        for (i, l) in codeLengths.enumerated() {
            let L = Int(l)
            if L > maxLen {
                throw BrotliError.malformedPrefixCode(
                    "code length \(L) > 15 at symbol \(i)")
            }
            if L > 0 {
                blCount[L] += 1
                nonZeroCount += 1
                lastNonZero = UInt32(i)
            }
        }
        // Single non-zero symbol → 0-bit code that always selects
        // that symbol. RFC 7932 §3.4 NSYM=0 produces exactly this.
        if nonZeroCount == 0 {
            // No symbols at all — unusable code. Surface clearly.
            throw BrotliError.malformedPrefixCode(
                "all code lengths are 0 (no usable symbol)")
        }
        if nonZeroCount == 1 {
            // 0-bit code (single symbol).
            self.codes = [UInt32](repeating: 0, count: alphabetSize)
            self.singleSymbol = lastNonZero
            return
        }
        // Canonical-Huffman code assignment.
        var nextCode = [UInt32](repeating: 0, count: maxLen + 2)
        var code: UInt32 = 0
        blCount[0] = 0
        for bits in 1...maxLen {
            code = (code + UInt32(blCount[bits - 1])) << 1
            nextCode[bits] = code
        }
        // Validate Kraft inequality — `code + blCount[maxLen]` must
        // exactly equal `1 << maxLen` (perfectly-packed canonical
        // tree). Allow the slack case where the tree is complete
        // earlier.
        // For canonical Huffman this is equivalent to:
        //   sum(blCount[N] * 2^(maxLen - N)) == 2^maxLen
        var kraft: UInt64 = 0
        for N in 1...maxLen {
            kraft += UInt64(blCount[N]) << (maxLen - N)
        }
        if kraft != UInt64(1) << maxLen {
            throw BrotliError.malformedPrefixCode(
                "Kraft inequality not satisfied: sum = \(kraft), "
                + "expected \(UInt64(1) << maxLen)")
        }
        var assigned = [UInt32](repeating: 0, count: alphabetSize)
        for (n, l) in codeLengths.enumerated() {
            let L = Int(l)
            if L > 0 {
                assigned[n] = nextCode[L]
                nextCode[L] += 1
            }
        }
        self.codes = assigned
        self.singleSymbol = nil
    }

    /// Decode the next symbol from `r` using this prefix code.
    /// Walks the canonical Huffman tree bit-by-bit. Returns the
    /// symbol index in `[0, alphabetSize)`.
    ///
    /// Bit-walk strategy: accumulate bits MSB-first into a code
    /// value, growing one bit per step. At each length, check
    /// whether any code of that length matches the accumulator;
    /// if so, look up the matching symbol.
    ///
    /// This is the simplest correct decoder — O(maxLen) per symbol
    /// with linear scan over the symbol list at each step. A LUT
    /// optimisation is a follow-on bite once correctness is proven
    /// (libjxl uses a 9-bit root LUT + secondary tables).
    public func decodeSymbol(
        from r: inout BitReader
    ) throws -> UInt32 {
        if let s = singleSymbol { return s }
        // Walk one bit at a time, growing a code value MSB-first.
        // Brotli reads bits LSB-first from the stream — we need to
        // reverse the bit order within the code length to match
        // canonical-Huffman MSB-first code construction. Equivalent
        // implementation: read bits and reverse-add to accumulator.
        var code: UInt32 = 0
        for len in 1...15 {
            let bit: UInt32
            do { bit = try r.read(bits: 1) }
            catch let e as BitstreamError {
                throw BrotliError.bitstream(e)
            }
            code = (code << 1) | bit
            // Linear scan — find a symbol with this code at this
            // bit length. Slow but correct; LUT optimisation later.
            for (sym, l) in codeLengths.enumerated() {
                if Int(l) == len && codes[sym] == code {
                    return UInt32(sym)
                }
            }
        }
        // 16 bits consumed without a hit — the code or the input
        // stream is malformed. Brotli prefix codes max at 15 bits.
        throw BrotliError.malformedPrefixCode(
            "decodeSymbol: no match within 15 bits "
            + "(accumulator 0x\(String(code, radix: 16)))")
    }
}

public enum BrotliPrefixCodeReader {

    /// Read a prefix code from the bitstream. Dispatches on the
    /// 2-bit format selector at the head:
    ///
    ///   00 ⇒ complex, HSKIP = 0
    ///   01 ⇒ simple
    ///   10 ⇒ complex, HSKIP = 2
    ///   11 ⇒ complex, HSKIP = 3
    ///
    /// `alphabetSize` is determined by the surrounding context
    /// (literal alphabet = 256, insert-and-copy = 704, distance =
    /// 16 + NDIRECT + (48 << NPOSTFIX), block-type = NBLTYPES + 2,
    /// etc.) and bounds the largest symbol the reader will accept.
    public static func read(
        from r: inout BitReader,
        alphabetSize: Int
    ) throws -> BrotliPrefixCode {
        guard alphabetSize >= 1 && alphabetSize <= 704 else {
            throw BrotliError.malformedPrefixCode(
                "alphabetSize \(alphabetSize) outside [1, 704]")
        }
        let selector: UInt32
        do { selector = try r.read(bits: 2) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
        switch selector {
        case 0b01:
            return try readSimple(
                from: &r, alphabetSize: alphabetSize)
        case 0b00:
            return try readComplex(
                from: &r, hskip: 0, alphabetSize: alphabetSize)
        case 0b10:
            return try readComplex(
                from: &r, hskip: 2, alphabetSize: alphabetSize)
        case 0b11:
            return try readComplex(
                from: &r, hskip: 3, alphabetSize: alphabetSize)
        default:
            throw BrotliError.malformedPrefixCode(
                "unreachable selector \(selector)")
        }
    }

    /// RFC 7932 §3.4 — **simple prefix code**.
    ///
    /// ```
    /// NSYM:    2 bits, value in 0..3 ⇒ 1..4 symbols
    /// symbols: NSYM symbols, each `ceil(log2(alphabet_size))` bits
    /// tree-select: 1 bit (only if NSYM == 3) — picks between two
    ///   2-3-3 code-length assignments
    /// ```
    ///
    /// The code-length assignments per NSYM:
    /// - NSYM=0 (1 symbol):  length = [0] — symbol always wins, 0 bits.
    /// - NSYM=1 (2 symbols): lengths = [1, 1].
    /// - NSYM=2 (3 symbols): lengths = [1, 2, 2] (sorted).
    /// - NSYM=3, tree-select=0 (4 symbols): lengths = [2, 2, 2, 2].
    /// - NSYM=3, tree-select=1 (4 symbols): lengths = [1, 2, 3, 3].
    ///
    /// Symbols must be distinct and strictly increasing within the
    /// 4-symbol case (the spec says the encoder writes them in
    /// strictly ascending order); we validate this on read.
    public static func readSimple(
        from r: inout BitReader,
        alphabetSize: Int
    ) throws -> BrotliPrefixCode {
        let nsymRaw: UInt32
        do { nsymRaw = try r.read(bits: 2) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
        let nsym = Int(nsymRaw) + 1
        let bitsPerSymbol = ceilLog2(UInt32(alphabetSize))
        var symbols: [UInt32] = []
        symbols.reserveCapacity(nsym)
        for _ in 0..<nsym {
            let s: UInt32
            do { s = try r.read(bits: Int(bitsPerSymbol)) }
            catch let e as BitstreamError {
                throw BrotliError.bitstream(e)
            }
            guard s < UInt32(alphabetSize) else {
                throw BrotliError.malformedPrefixCode(
                    "simple-code symbol \(s) ≥ alphabetSize "
                    + "\(alphabetSize)")
            }
            symbols.append(s)
        }
        // Per the brotli reference (`ReadSimpleHuffmanSymbols`),
        // only DISTINCT is required for NSYM ≥ 1, NOT strict ascending.
        if nsym >= 2 {
            for i in 0..<symbols.count {
                for j in (i + 1)..<symbols.count {
                    if symbols[i] == symbols[j] {
                        throw BrotliError.malformedPrefixCode(
                            "simple-code duplicate symbol "
                            + "\(symbols[i]): \(symbols)")
                    }
                }
            }
        }
        // Length assignment — exact port of brotli reference
        // `BrotliBuildSimpleHuffmanTable`. Source-order matters for
        // NSYM=3 + treeSelect=1 (val[0] gets length 1, val[1] gets
        // length 2; only val[2..3] are sorted).
        var lengths = [UInt8](repeating: 0, count: alphabetSize)
        switch nsym {
        case 1:
            // Single symbol — 0-bit code (singleSymbol fast path).
            lengths[Int(symbols[0])] = 1
        case 2:
            // 2 symbols, both length 1.
            lengths[Int(symbols[0])] = 1
            lengths[Int(symbols[1])] = 1
        case 3:
            // 3 symbols, lengths 1, 2, 2 — sorted by value.
            let sorted = symbols.sorted()
            lengths[Int(sorted[0])] = 1
            lengths[Int(sorted[1])] = 2
            lengths[Int(sorted[2])] = 2
        case 4:
            let treeSelect: UInt32
            do { treeSelect = try r.read(bits: 1) }
            catch let e as BitstreamError {
                throw BrotliError.bitstream(e)
            }
            if treeSelect == 0 {
                // 2,2,2,2 — sort all 4 (brotli reference sorts but
                // the lengths are identical so result is the same).
                for s in symbols { lengths[Int(s)] = 2 }
            } else {
                // 1,2,3,3 — val[0] length 1 (source order),
                // val[1] length 2 (source order), val[2..3] sorted
                // among themselves with length 3 each.
                lengths[Int(symbols[0])] = 1
                lengths[Int(symbols[1])] = 2
                // Sort symbols[2..3] between themselves.
                let last2 = [symbols[2], symbols[3]].sorted()
                lengths[Int(last2[0])] = 3
                lengths[Int(last2[1])] = 3
            }
        default:
            // Unreachable per `nsym = nsymRaw + 1`, nsymRaw ∈ 0..3.
            throw BrotliError.malformedPrefixCode(
                "unreachable nsym \(nsym)")
        }
        return try BrotliPrefixCode(
            alphabetSize: alphabetSize, codeLengths: lengths)
    }

    /// RFC 7932 §3.5 — **complex prefix code**.
    ///
    /// Encoding has two levels:
    ///
    /// 1. **Code-length code** — 18 symbols (lengths 0..15 plus
    ///    run-length 16 (repeat previous), 17 (run of zeros)). Each
    ///    code-length-code's *own* length is a 2/3/4-bit field. The
    ///    fields are emitted in a specific permutation order:
    ///
    ///    ```
    ///    permutation = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9,
    ///                   10, 11, 12, 13, 14, 15]
    ///    ```
    ///
    ///    HSKIP (0/2/3, set by the 2-bit selector at the front)
    ///    skips the leading `HSKIP` entries (they're treated as
    ///    length 0). Reading stops early once the sum of (32 >>
    ///    length) reaches 32 (Kraft completeness) — RFC 7932 says
    ///    "the loop terminates when the sum equals 32, or after all
    ///    18 entries are processed".
    ///
    ///    Each non-zero entry's length is read via a small 2/3/4-bit
    ///    canonical code (see `kCodeLengthCodeLengthFieldBits`).
    ///
    /// 2. **Alphabet code lengths** — decoded using the 18-symbol
    ///    code from step 1. Reads `alphabet_size` lengths total.
    ///    Symbols 0..15 are absolute lengths; symbol 16 is "repeat
    ///    previous non-zero length, count = 3 + read(2)"; symbol 17
    ///    is "run of zeros, count = 3 + read(3)". After each 16/17
    ///    symbol the `count` extra-bits include a back-reference to
    ///    the previous 16/17 (RFC 7932 §3.5 "Extra State"):
    ///
    ///    ```
    ///    repeat_16 = (((repeat - 3) << 2) + read(2)) + 3
    ///    repeat_17 = (((repeat - 3) << 3) + read(3)) + 3
    ///    ```
    ///
    ///    where `repeat` carries over from the previous same-symbol
    ///    occurrence (reset to 0 when a different symbol arrives).
    ///
    /// After decoding, the 15-bit max canonical Huffman code is
    /// built via `BrotliPrefixCode.init`.
    public static func readComplex(
        from r: inout BitReader,
        hskip: Int,
        alphabetSize: Int
    ) throws -> BrotliPrefixCode {
        // RFC 7932 §3.5 permutation order for the 18 code-length
        // codes. Index into this array is the order on the wire;
        // value is the code-length-symbol it labels.
        let permutation: [Int] = [
            1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9,
            10, 11, 12, 13, 14, 15,
        ]
        // Field-width lookup for the per-symbol length-of-length:
        // RFC 7932 §3.5 — table 3.
        //
        //   length-of-length  field bits
        //   0                 2  (00)
        //   1                 4  (0111)
        //   2                 3  (011)
        //   3                 2  (10)
        //   4                 2  (01)
        //   5                 4  (1111)
        //
        // Encoded as a 5-bit prefix:
        //   00     ⇒ 0
        //   0111   ⇒ 1
        //   011    ⇒ 2
        //   10     ⇒ 3
        //   01     ⇒ 4
        //   1111   ⇒ 5
        //
        // The decoder walks bit-by-bit through this fixed table.
        // (Encoded canonically: lengths {2,4,3,2,2,4} for symbols
        // {0,1,2,3,4,5}.)
        let codeLengthLengthLengths: [UInt8] = [2, 4, 3, 2, 2, 4]
        // Build a 6-symbol prefix code over {0..5} from the static
        // lengths above. Reuse the `BrotliPrefixCode` constructor.
        let codeLengthCode = try BrotliPrefixCode(
            alphabetSize: 6, codeLengths: codeLengthLengthLengths)

        // Read the per-symbol lengths-of-lengths in permutation
        // order, skipping `hskip` leading entries (treated as 0).
        // Stop early once Kraft sum (32 >> length, length > 0)
        // reaches 32.
        var codeLengthCodeLengths = [UInt8](
            repeating: 0, count: 18)
        var spaceLeft: Int = 32
        var idx = hskip
        var numNonZero = 0
        while idx < 18 && spaceLeft > 0 {
            let v = try codeLengthCode.decodeSymbol(from: &r)
            let l = UInt8(v)
            codeLengthCodeLengths[permutation[idx]] = l
            idx += 1
            if l != 0 {
                spaceLeft -= 32 >> Int(l)
                numNonZero += 1
                if numNonZero == 1 && spaceLeft == 0 {
                    // Single-length non-zero code — fill remainder
                    // with zeros and exit.
                    break
                }
                if spaceLeft < 0 {
                    throw BrotliError.malformedPrefixCode(
                        "complex code-length Kraft overflow")
                }
            }
        }
        if spaceLeft != 0 && numNonZero > 1 {
            throw BrotliError.malformedPrefixCode(
                "complex code-length Kraft under-fill: "
                + "remaining \(spaceLeft)")
        }
        let codeLengthSymbolCode = try BrotliPrefixCode(
            alphabetSize: 18,
            codeLengths: codeLengthCodeLengths)

        // Now decode the symbol lengths using the 18-symbol code,
        // handling run-length symbols 16/17 per RFC 7932 §3.5.
        //
        // Exact port of libbrotli `ReadSymbolCodeLengths` +
        // `ProcessRepeatedCodeLength` (decode.c). Two details the
        // earlier draft got wrong, both of which surface only on
        // large run-heavy codes (e.g. a 256-symbol literal code in a
        // big metadata block):
        //
        //  1. **Repeat accumulation subtracts 2, not 3.** A run of
        //     16s/17s grows the count geometrically:
        //       repeat = ((repeat − 2) << extra_bits) + extra + 3
        //     and the number emitted this round is the *delta*
        //     `repeat − old_repeat`. The reset rule is keyed on the
        //     *repeated length* (`new_len`): code 16 repeats
        //     `prev_code_len`, code 17 repeats 0, and any literal —
        //     or a switch between the two repeat lengths — resets the
        //     running counter to 0.
        //
        //  2. **Kraft `space` budget early-stop.** The loop runs only
        //     while `space > 0`, where `space` starts at 2^15 and
        //     each assigned length L consumes `2^15 >> L` (a run of
        //     `delta` symbols of length `new_len` consumes
        //     `delta << (15 − new_len)`; length-0 entries consume
        //     nothing). Once the code is complete the encoder stops
        //     emitting and every remaining symbol is length 0 —
        //     reading further would consume bits belonging to the
        //     next code and drift the whole stream.
        var alphabetLengths = [UInt8](
            repeating: 0, count: alphabetSize)
        var i = 0
        var prevCodeLen: Int = 8        // BROTLI_INITIAL_REPEATED_CODE_LENGTH
        var rep: Int = 0                // running repeat counter
        var repeatCodeLen: Int = 0      // length currently being repeated
        var space: Int = 1 << 15        // Kraft budget over 15-bit codes
        while i < alphabetSize && space > 0 {
            let sym = try codeLengthSymbolCode.decodeSymbol(from: &r)
            if sym < 16 {
                // Literal length — resets any pending repeat run.
                rep = 0
                alphabetLengths[i] = UInt8(sym)
                i += 1
                if sym != 0 {
                    prevCodeLen = Int(sym)
                    space -= (1 << 15) >> Int(sym)
                }
            } else if sym == 16 || sym == 17 {
                let extraBits = (sym == 16) ? 2 : 3
                let newLen = (sym == 16) ? prevCodeLen : 0
                let extra: UInt32
                do { extra = try r.read(bits: extraBits) }
                catch let e as BitstreamError {
                    throw BrotliError.bitstream(e)
                }
                if repeatCodeLen != newLen {
                    rep = 0
                    repeatCodeLen = newLen
                }
                let oldRepeat = rep
                if rep > 0 {
                    rep -= 2
                    rep <<= extraBits
                }
                rep += Int(extra) + 3
                let repeatDelta = rep - oldRepeat
                if i + repeatDelta > alphabetSize {
                    throw BrotliError.malformedPrefixCode(
                        "complex code repeat-\(sym) overflows alphabet "
                        + "(i=\(i), count=\(repeatDelta), "
                        + "N=\(alphabetSize))")
                }
                let fill = UInt8(newLen)
                for _ in 0..<repeatDelta {
                    alphabetLengths[i] = fill
                    i += 1
                }
                if newLen != 0 {
                    space -= repeatDelta << (15 - newLen)
                }
            } else {
                throw BrotliError.malformedPrefixCode(
                    "complex code symbol \(sym) > 17")
            }
        }
        // Symbols beyond the Kraft-complete prefix stay length 0
        // (the array is pre-zeroed) — do NOT keep reading.
        return try BrotliPrefixCode(
            alphabetSize: alphabetSize,
            codeLengths: alphabetLengths)
    }
}
