// Build a runtime Huffman code table from a `JPEGHuffmanTable` —
// the §C.2 canonical-code algorithm from ITU-T T.81 Annex C.
// Fifth step on the Phase J road: turns the parsed DHT segment
// data into something the entropy decoder can actually query bit
// by bit.
//
// The §C.2 algorithm:
//   1. Build a HUFFSIZE list: for each symbol in `huffvals`, the
//      length is the index `L` of the `bits[L-1]` band it falls
//      into (i.e. `bits[0]` symbols have length 1, `bits[1]`
//      symbols have length 2, …).
//   2. Walk symbols in order, assigning each one the next
//      canonical code at its length. The starting code at length
//      L is `(code-from-end-of-length-(L-1)) << (L - (L-1))`.
//
// We materialise the codebook as a `[symbol, code, length]`
// record per symbol plus the precomputed `mincode[L]` /
// `maxcode[L]` / `valptr[L]` tables described in §C.2 Figure F.15,
// so the decoder loop is a tight branch-free comparison.

import Foundation

/// One Huffman code → symbol entry in the runtime codebook.
package struct JPEGHuffmanCode: Sendable, Equatable {
    /// The 8-bit symbol value (DC magnitude category, or
    /// AC `run << 4 | size` byte).
    package let symbol: UInt8
    /// The canonical Huffman code value, right-aligned in
    /// `length` bits.
    package let code: UInt32
    /// Bit length of `code`, 1..16.
    package let length: Int
}

/// Runtime Huffman codebook ready to drive an entropy decoder.
package struct JPEGHuffmanCodebook: Sendable {
    /// Per-symbol code, in input order — i.e. `codes[i]`
    /// corresponds to `table.huffvals[i]`. Empty for tables with
    /// no symbols (degenerate but spec-legal).
    package let codes: [JPEGHuffmanCode]
    /// `maxcode[L-1]` is the largest canonical code value of
    /// length L, or `-1` if no codes of that length exist. Used
    /// by §C.2 Figure F.15's decode loop: if the accumulated bits
    /// (interpreted as an L-bit integer) are `≤ maxcode[L-1]`,
    /// the symbol is `huffvals[valoffset[L-1] + (bits - mincode[L-1])]`.
    package let maxcode: [Int]
    /// `mincode[L-1]` — the smallest canonical code value of
    /// length L. Undefined when `maxcode[L-1] == -1`.
    package let mincode: [Int]
    /// `valoffset[L-1]` — offset into `huffvals` where length-L
    /// symbols begin.
    package let valoffset: [Int]
    /// 256-entry 8-bit lookahead table: indexed by the next 8
    /// stream bits (MSB-first), each entry packs
    /// `(huffvals index << 8) | code length` for codes of ≤ 8
    /// bits, or 0 when the code needs more than 8 bits (resolve
    /// via the §C.2 Figure F.16 walk instead). One probe replaces
    /// the per-bit maxcode loop for the overwhelming majority of
    /// symbols.
    package let fastLookup: [UInt16]
}

extension JPEGHuffmanTable {
    /// Build the §C.2 canonical Huffman codebook for this table.
    /// Throws `JPEGParseError.invalidSegmentLength` if the
    /// length-count array `bits` overruns the 16-bit code space
    /// (a malformed DHT segment).
    package func buildCodebook() throws -> JPEGHuffmanCodebook {
        // §C.2 Figure F.15: generate HUFFSIZE, then HUFFCODE.
        // Then collapse into mincode/maxcode/valoffset.
        precondition(bits.count == 16,
            "JPEG Huffman BITS must have exactly 16 entries")
        // Build huffsize: for each band L = 1..16, append L
        // `bits[L-1]` times. Symbol count is sum(bits).
        var huffsize: [Int] = []
        huffsize.reserveCapacity(huffvals.count)
        for L in 1...16 {
            for _ in 0..<Int(bits[L - 1]) {
                huffsize.append(L)
            }
        }
        guard huffsize.count == huffvals.count else {
            // The DHT parser guarantees this invariant, but we
            // re-check defensively in case a caller hand-built a
            // JPEGHuffmanTable.
            throw JPEGParseError.invalidSegmentLength(
                marker: 0xC4, length: huffvals.count + 2)
        }
        // Build huffcode: walk huffsize, emitting the next
        // canonical code at each step. When the length increases,
        // shift the running code left by the difference.
        var huffcode: [UInt32] = []
        huffcode.reserveCapacity(huffsize.count)
        var code: UInt32 = 0
        var si = huffsize.first ?? 0
        for k in 0..<huffsize.count {
            while huffsize[k] != si {
                code <<= 1
                si += 1
            }
            // Range check: code must fit in `si` bits.
            if si <= 32, code >= (UInt32(1) << UInt32(si)) {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xC4, length: huffvals.count + 2)
            }
            huffcode.append(code)
            code &+= 1
        }
        // Compose JPEGHuffmanCode records.
        var codes: [JPEGHuffmanCode] = []
        codes.reserveCapacity(huffvals.count)
        for k in 0..<huffvals.count {
            codes.append(JPEGHuffmanCode(
                symbol: huffvals[k],
                code: huffcode[k],
                length: huffsize[k]))
        }
        // Build mincode/maxcode/valoffset per §C.2 Figure F.15.
        // Initialised to "no codes of this length" sentinels.
        var maxcode = Array(repeating: -1, count: 16)
        var mincode = Array(repeating: 0, count: 16)
        var valoffset = Array(repeating: 0, count: 16)
        var k = 0
        for L in 1...16 {
            let count = Int(bits[L - 1])
            if count == 0 { continue }
            valoffset[L - 1] = k - Int(huffcode[k])
            mincode[L - 1] = Int(huffcode[k])
            maxcode[L - 1] = Int(huffcode[k + count - 1])
            k += count
        }
        // 8-bit lookahead table: every length ≤ 8 code fills the
        // 2^(8-L) entries that share its prefix. At most 256 leaves
        // exist in the 8-bit code space, so the huffvals index of
        // any such code fits a packed byte.
        var fastLookup = Array<UInt16>(repeating: 0, count: 256)
        for j in 0..<huffvals.count {
            let len = huffsize[j]
            guard len <= 8 else { break }
            let base = Int(huffcode[j]) << (8 - len)
            let entry = (UInt16(j) << 8) | UInt16(len)
            for slot in base..<(base + (1 << (8 - len))) {
                fastLookup[slot] = entry
            }
        }
        return JPEGHuffmanCodebook(
            codes: codes,
            maxcode: maxcode, mincode: mincode,
            valoffset: valoffset,
            fastLookup: fastLookup)
    }
}

extension JPEGHuffmanCodebook {
    /// Decode one symbol from a stream of bits. `nextBit` is
    /// called repeatedly; the caller is responsible for
    /// byte-stuffing handling on top of the raw JPEG entropy
    /// bytes. Returns `nil` if no codeword of length ≤ 16
    /// matches (treat as a stream error in the caller).
    ///
    /// §C.2 Figure F.16: accumulate bits into `code`; at each
    /// length L, compare against `maxcode[L-1]`. When the
    /// accumulated value fits inside maxcode for that length, the
    /// symbol is `huffvals[valoffset[L-1] + (code - mincode[L-1])]`.
    /// Falling through all 16 lengths means the stream is
    /// malformed.
    package func decodeSymbol(
        nextBit: () -> Int?,
        huffvals: [UInt8]
    ) -> UInt8? {
        var codeAcc: Int = 0
        for L in 1...16 {
            guard let b = nextBit(), (b == 0 || b == 1) else {
                return nil
            }
            codeAcc = (codeAcc << 1) | b
            if codeAcc <= maxcode[L - 1] {
                let idx = valoffset[L - 1] + codeAcc
                guard idx >= 0, idx < huffvals.count else {
                    return nil
                }
                return huffvals[idx]
            }
        }
        return nil
    }

    /// Decode one symbol straight from a `JPEGBitReader` — the
    /// shared fast path for every entropy-decode caller. Probes
    /// `fastLookup` with 8 lookahead bits (resolving codes of ≤ 8
    /// bits in one step); codes longer than 8 bits, or streams
    /// with fewer than 8 bits left before a marker / end of data,
    /// fall back to the §C.2 Figure F.16 walk above. Returns `nil`
    /// on the same conditions as `decodeSymbol(nextBit:huffvals:)`.
    package func decodeSymbol(
        from reader: inout JPEGBitReader,
        huffvals: [UInt8]
    ) -> UInt8? {
        let (bits, count) = reader.peekBits8()
        if count == 8 {
            let entry = fastLookup[bits]
            let len = Int(entry & 0xFF)
            if len != 0 {
                reader.consumePeekedBits(len)
                let idx = Int(entry >> 8)
                guard idx < huffvals.count else { return nil }
                return huffvals[idx]
            }
        }
        // Rare path: peeking doesn't consume, so the slow walk
        // re-reads the same bits and consumes exactly the matched
        // code length (or fails part-way, as before).
        var r = reader
        defer { reader = r }
        return decodeSymbol(
            nextBit: { try? r.readBit() }, huffvals: huffvals)
    }
}
