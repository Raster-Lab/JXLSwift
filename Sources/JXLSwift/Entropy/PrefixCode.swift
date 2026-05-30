// PrefixCode — canonical-Huffman alphabet codec used as one of the two
// entropy-coder choices in JPEG XL (the other being rANS).
//
// ISO/IEC 18181-1 §C.6.2. JXL prefix codes are standard canonical
// Huffman codes built from a per-symbol "code length" array `lengths`:
//   - lengths[s] == 0  means symbol s does not appear in the alphabet.
//   - lengths[s]  > 0  is the bit length of the codeword for s.
//
// The codewords are assigned canonically: sort symbols first by length
// ascending, then by symbol index ascending; then assign sequential
// codewords starting from 0.
//
// Maximum code length per the spec is 15 bits (small enough that an
// O(2^15) decoding LUT is feasible; we use that approach).

import Foundation

package enum PrefixCodeError: Error, Sendable, Equatable {
    case invalidLengths(String)
    case oversubscribed(maxBits: Int, sumOfWeights: Int)
    case undersubscribed(maxBits: Int, sumOfWeights: Int)
    case missingSymbol(Int)
    case bitstream(BitstreamError)
}

/// Canonical-Huffman table built from a per-symbol code-length array.
/// Provides O(1) decoding via a flat lookup table indexed by the next
/// `maxLength` bits of the bitstream, and O(1) encoding via a per-
/// symbol (codeword, length) pair.
package struct PrefixCodeTable: Sendable {
    /// Maximum code length per JXL spec.
    package static let maxBits: Int = 15

    /// `codeword[s]` = the bits of symbol `s`'s codeword, MSB-first, in
    /// the lower `length[s]` bits. Zero when `length[s] == 0`.
    package let codewords: [UInt32]
    /// `lengths[s]` = bit length of symbol `s`'s codeword, 0 if absent.
    package let lengths: [UInt8]
    /// Effective alphabet size (length of `lengths`).
    package var alphabetSize: Int { lengths.count }
    /// Maximum length actually used. ≤ `maxBits`.
    package let usedMaxLength: Int

    /// Decoding LUT. Indexed by the next `usedMaxLength` bits of the
    /// bitstream (LSB-first when read from the bitstream — see decode
    /// for the bit-order handling). Each entry is the symbol that
    /// matches at this prefix, and the bit length to consume from the
    /// reader.
    fileprivate let decodeLUT: [(symbol: UInt32, length: UInt8)]

    /// Build a prefix code from a per-symbol code-length array.
    /// Validates Kraft's inequality: ∑ 2^(maxBits - lengths[s]) must
    /// equal exactly 2^maxBits when there are ≥ 2 symbols. (A single
    /// symbol with length 0 is a degenerate "always emit symbol 0"
    /// case and is allowed.)
    package init(lengths: [UInt8]) throws {
        if lengths.isEmpty {
            throw PrefixCodeError.invalidLengths("empty lengths array")
        }
        for (i, l) in lengths.enumerated() where l > UInt8(Self.maxBits) {
            throw PrefixCodeError.invalidLengths(
                "symbol \(i) has length \(l) > maxBits (\(Self.maxBits))"
            )
        }

        let nonZero = lengths.lazy.filter { $0 > 0 }
        let nonZeroCount = nonZero.count
        // Single-symbol degenerate case: zero-length code, always emits
        // the lone symbol regardless of bitstream.
        if nonZeroCount <= 1 {
            // Zero-length codewords for everyone, decode LUT empty.
            self.codewords = [UInt32](repeating: 0, count: lengths.count)
            self.lengths = lengths
            self.usedMaxLength = 0
            self.decodeLUT = []
            return
        }

        // Verify Kraft's inequality.
        var sumOfWeights = 0
        for l in lengths where l > 0 {
            sumOfWeights += 1 << (Self.maxBits - Int(l))
        }
        let kraftLimit = 1 << Self.maxBits
        if sumOfWeights > kraftLimit {
            throw PrefixCodeError.oversubscribed(maxBits: Self.maxBits, sumOfWeights: sumOfWeights)
        }
        if sumOfWeights < kraftLimit {
            throw PrefixCodeError.undersubscribed(maxBits: Self.maxBits, sumOfWeights: sumOfWeights)
        }

        // Canonical Huffman assignment:
        //   1. Sort symbols by (length asc, symbol index asc).
        //   2. Assign sequential codewords; when length increases, shift
        //      the next codeword left to fill the new bit positions.
        let sortedSymbols = (0..<lengths.count)
            .filter { lengths[$0] > 0 }
            .sorted { (a, b) in
                if lengths[a] != lengths[b] { return lengths[a] < lengths[b] }
                return a < b
            }

        var codewords = [UInt32](repeating: 0, count: lengths.count)
        var code: UInt32 = 0
        var prevLen: UInt8 = lengths[sortedSymbols[0]]
        var maxLen: UInt8 = 0
        for sym in sortedSymbols {
            let l = lengths[sym]
            if l > prevLen {
                code <<= UInt32(l - prevLen)
                prevLen = l
            }
            codewords[sym] = code
            if l > maxLen { maxLen = l }
            code += 1
        }
        self.codewords = codewords
        self.lengths = lengths
        self.usedMaxLength = Int(maxLen)

        // Build the decoding LUT.
        // Each entry is indexed by the maxLen bits read MSB-first from
        // the canonical-Huffman stream. We register every codeword
        // pattern by extending it with all possible suffixes up to maxLen.
        let lutSize = 1 << Int(maxLen)
        var lut = [(symbol: UInt32, length: UInt8)](repeating: (UInt32.max, 0), count: lutSize)
        for sym in sortedSymbols {
            let l = lengths[sym]
            let cw = codewords[sym]
            // The codeword occupies the top `l` bits of a maxLen-bit window.
            // For every possible suffix value, fill the LUT entry.
            let prefix = cw << UInt32(maxLen - l)
            let suffixCount = 1 << Int(maxLen - l)
            for s in 0..<suffixCount {
                let idx = Int(prefix) | s
                lut[idx] = (UInt32(sym), l)
            }
        }
        self.decodeLUT = lut
    }

    /// Emit a symbol's codeword to the bit writer. The codeword is
    /// written MSB-first — i.e. the high bit of `codewords[s]` goes
    /// into the bitstream first. Note: `BitWriter` itself is LSB-first
    /// within bytes, so we reverse the codeword bits before passing it
    /// to `write(bits:value:)`.
    package func encode(_ symbol: Int, to w: inout BitWriter) throws {
        guard symbol >= 0 && symbol < lengths.count else {
            throw PrefixCodeError.missingSymbol(symbol)
        }
        let l = lengths[symbol]
        if l == 0 && lengths.contains(where: { $0 > 0 }) {
            // Symbol marked absent in a non-degenerate code.
            throw PrefixCodeError.missingSymbol(symbol)
        }
        if l == 0 {
            // Single-symbol degenerate code; nothing to emit.
            return
        }
        // Reverse the codeword bits: codewords are canonical / MSB-first,
        // but `BitWriter.write` packs the LSB of `value` first. To make
        // the canonical pattern come out MSB-first in the on-disk bytes,
        // we mirror the bit order before emitting.
        let cw = codewords[symbol]
        let reversed = reverseBits(cw, count: Int(l))
        w.write(bits: Int(l), value: reversed)
    }

    /// Decode a single symbol from `r`. Reads up to `usedMaxLength` bits
    /// (peek N, look up symbol, consume only the codeword length).
    package func decode(from r: inout BitReader) throws -> Int {
        if usedMaxLength == 0 {
            // Single-symbol degenerate code.
            return lengths.firstIndex(where: { $0 > 0 })
                ?? lengths.firstIndex(where: { _ in true }) ?? 0
        }
        let need = usedMaxLength
        guard r.bitsRemaining >= 1 else {
            throw PrefixCodeError.bitstream(.outOfBounds(needed: 1, remaining: 0))
        }
        let take = min(need, r.bitsRemaining)
        let raw: UInt32
        do { raw = try r.peek(bits: take) }
        catch let e as BitstreamError {
            throw PrefixCodeError.bitstream(e)
        }
        let mirrored = reverseBits(raw, count: take) << UInt32(need - take)
        let entry = decodeLUT[Int(mirrored)]
        let consumed = Int(entry.length)
        do { try r.skip(bits: consumed) }
        catch let e as BitstreamError {
            throw PrefixCodeError.bitstream(e)
        }
        return Int(entry.symbol)
    }
}

/// Reverse the low `count` bits of `value`. Higher bits are zero.
@inline(__always)
private func reverseBits(_ value: UInt32, count: Int) -> UInt32 {
    var v = value
    var out: UInt32 = 0
    for _ in 0..<count {
        out = (out << 1) | (v & 1)
        v >>= 1
    }
    return out
}
