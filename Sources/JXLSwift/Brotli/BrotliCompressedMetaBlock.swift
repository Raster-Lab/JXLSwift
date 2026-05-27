// `Brotli/BrotliCompressedMetaBlock.swift` — header fields for a
// **compressed** meta-block body (RFC 7932 §9.2). Read once after
// the basic meta-block header (ISLAST, ISUNCOMPRESSED, MLEN) and
// once for each of L (literal), I (insert-and-copy), D (distance).
//
// Status (v0.12.0gk): header fields shipping (NBLTYPES + block-type
// trees + NPOSTFIX + NDIRECT + context modes + NTREES). Context map
// decoding + per-tree prefix code decoding + LZ77 loop pending.

import Foundation

/// Per-stream block-type metadata (L, I, or D).
public struct BrotliBlockTypeMetadata: Sendable {
    /// Number of block types for this stream. `1` means the stream
    /// has only one block type — the block-type tree and block-
    /// length tree are NOT emitted.
    public let nbltypes: Int
    /// If `nbltypes > 1`, the block-type symbol prefix code.
    /// Alphabet size = `nbltypes + 2`. Otherwise nil.
    public let btypeTree: BrotliPrefixCode?
    /// If `nbltypes > 1`, the block-length prefix code (alphabet 26).
    public let blenTree: BrotliPrefixCode?
    /// The first block-length value (only present if `nbltypes > 1`).
    public let firstBlockLength: UInt32?
}

/// Full per-meta-block header bits read once per compressed body.
public struct BrotliMetaBlockBodyHeader: Sendable {
    public let literal: BrotliBlockTypeMetadata
    public let insertCopy: BrotliBlockTypeMetadata
    public let distance: BrotliBlockTypeMetadata
    /// `NPOSTFIX` ∈ 0..3 — distance alphabet postfix bits.
    public let npostfix: Int
    /// `NDIRECT` raw 4-bit value; the *real* number of direct distance
    /// codes is `ndirect << npostfix`.
    public let ndirect: Int
    /// Per-literal-block-type context mode (2 bits each).
    /// `contextModes[i]` ∈ 0..3 selects between
    ///   LSB6 / MSB6 / UTF8 / Signed context-mode tables (RFC 7932 §7.1).
    public let contextModes: [UInt8]
    /// Number of context trees for literals.
    public let ntreesl: Int
    /// Number of context trees for distances.
    public let ntreesd: Int
}

public enum BrotliCompressedMetaBlockHeader {

    /// Read the compressed meta-block body header (everything between
    /// the basic meta-block header and the L/I/D prefix code section).
    ///
    /// Order per RFC 7932 §9.2:
    ///   1. block-type metadata for L (NBLTYPESL [+ btype tree, blen
    ///      tree, first BLEN if NBLTYPESL > 1])
    ///   2. block-type metadata for I (NBLTYPESI)
    ///   3. block-type metadata for D (NBLTYPESD)
    ///   4. NPOSTFIX (2 bits)
    ///   5. NDIRECT (4 bits)
    ///   6. NBLTYPESL × 2-bit context mode
    ///   7. NTREESL (VarLenU8)
    ///   8. CMAPL (context map; size = NBLTYPESL × 64) — read by
    ///      caller after this function returns, only if NTREESL > 1
    ///   9. NTREESD (VarLenU8)
    ///   10. CMAPD (size = NBLTYPESD × 4) — caller reads after, only
    ///       if NTREESD > 1
    public static func read(
        from r: inout BitReader
    ) throws -> BrotliMetaBlockBodyHeader {
        let lit = try readBlockType(from: &r)
        let ic  = try readBlockType(from: &r)
        let dist = try readBlockType(from: &r)
        let npostfix: UInt32
        let ndirect: UInt32
        do {
            npostfix = try r.read(bits: 2)
            ndirect = try r.read(bits: 4)
        } catch let e as BitstreamError {
            throw BrotliError.bitstream(e)
        }
        // Per-literal-block-type context modes (2 bits each).
        var modes: [UInt8] = []
        modes.reserveCapacity(lit.nbltypes)
        for _ in 0..<lit.nbltypes {
            do {
                let m = try r.read(bits: 2)
                modes.append(UInt8(m))
            } catch let e as BitstreamError {
                throw BrotliError.bitstream(e)
            }
        }
        // NTREESL + NTREESD (VarLenU8).
        let ntreesl = Int(try BrotliBitReader.readVarLenU8(from: &r))
        let ntreesd = Int(try BrotliBitReader.readVarLenU8(from: &r))
        return BrotliMetaBlockBodyHeader(
            literal: lit, insertCopy: ic, distance: dist,
            npostfix: Int(npostfix), ndirect: Int(ndirect),
            contextModes: modes,
            ntreesl: ntreesl, ntreesd: ntreesd)
    }

    /// Read one per-stream block-type metadata trio: NBLTYPESX +
    /// (if NBLTYPESX > 1) HTREE_BTYPE_X + HTREE_BLEN_X + first BLEN_X.
    private static func readBlockType(
        from r: inout BitReader
    ) throws -> BrotliBlockTypeMetadata {
        let n = Int(try BrotliBitReader.readVarLenU8(from: &r))
        if n == 1 {
            return BrotliBlockTypeMetadata(
                nbltypes: 1,
                btypeTree: nil, blenTree: nil,
                firstBlockLength: nil)
        }
        // For NBLTYPESX > 1: read the block-type prefix tree
        // (alphabet n+2), the block-length prefix tree (alphabet 26),
        // and the first block-length value.
        let btypeTree = try BrotliPrefixCodeReader.read(
            from: &r, alphabetSize: n + 2)
        let blenTree = try BrotliPrefixCodeReader.read(
            from: &r, alphabetSize: 26)
        // Decode the first block-length symbol then read its extra
        // bits per RFC 7932 §6 (kBlockLengthPrefixCode table).
        let blenSym = try blenTree.decodeSymbol(from: &r)
        let firstBlen = try decodeBlockLength(
            symbol: Int(blenSym), from: &r)
        return BrotliBlockTypeMetadata(
            nbltypes: n,
            btypeTree: btypeTree, blenTree: blenTree,
            firstBlockLength: firstBlen)
    }

    /// RFC 7932 §6 (Table 1) — block-length prefix code: 26 symbols
    /// with `(baseLength, extraBits)` pairs. Reads `extraBits` extra
    /// bits and returns `baseLength + extra`.
    private static func decodeBlockLength(
        symbol s: Int, from r: inout BitReader
    ) throws -> UInt32 {
        // Tables from RFC 7932 §6.
        let bases: [UInt32] = [
            1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113,
            145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289,
            4337, 8433, 16625,
        ]
        let extraBits: [Int] = [
            2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5,
            6, 6, 7, 8, 9, 10, 11, 12, 13, 24,
        ]
        guard s >= 0 && s < 26 else {
            throw BrotliError.malformedPrefixCode(
                "block-length symbol \(s) outside [0, 26)")
        }
        let extra: UInt32
        do { extra = try r.read(bits: extraBits[s]) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
        return bases[s] + extra
    }
}
