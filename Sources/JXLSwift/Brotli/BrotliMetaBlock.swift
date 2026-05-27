// `Brotli/BrotliMetaBlock.swift` — Brotli stream header + per-meta-
// block header reader. RFC 7932 §9.
//
// Stream structure (§9.1, §9.2):
//
//   stream:    WBITS  meta-block*
//   meta-block:
//     ISLAST           1 bit
//     if ISLAST:
//       ISLAST_EMPTY   1 bit
//       if ISLAST_EMPTY: return (no more meta-blocks)
//     MNIBBLES         2 bits      (4, 5, or 6 nibbles ⇒ 4/16/64K range)
//     if MNIBBLES == 3 (binary 11):
//       reserved       1 bit       (must be 0)
//       MSKIPBYTES     2 bits      (1, 2, 3, 4)
//       MSKIPLEN       8*MSKIPBYTES bits
//       jump to next byte boundary; skip MSKIPLEN+1 bytes (verbatim
//       payload, no decompression), then continue with next meta-block.
//     else:
//       MLEN           MNIBBLES*4 bits, MLEN+1 is the uncompressed-
//                      payload byte count produced by this meta-block.
//       if !ISLAST:
//         ISUNCOMPRESSED  1 bit
//         if ISUNCOMPRESSED:
//           jump to next byte boundary; copy MLEN+1 bytes verbatim.
//
// WBITS encoding (RFC 7932 §9.1):
//
//   bit 0 = 0 ⇒ WBITS = 16, followed by 3 bits for offset
//                (the 0 bit + 3 bits decode as 16..23 via a small
//                 lookup table)
//   bit 0 = 1 ⇒ extended formats:
//     next 3 bits select WBITS = 17..24, etc.
//
// The exact WBITS table (RFC 7932 §9.1):
//
//   read 1 bit. If 0 → WBITS = 16.
//   Else read 3 bits.
//     If those 3 bits are 0 → reserved (error).
//     Else WBITS = 17 + extra, but the exact mapping uses a small
//     lookup. See `readWBITS` for the canonical table.
//
// Phase J step 5d. v0.12.0fz scaffold.

import Foundation

/// Brotli stream header. Carries the window-size and the boundary
/// between the header and the first meta-block.
public struct BrotliStreamHeader: Sendable, Equatable {
    /// Window bits — `WBITS` from RFC 7932 §9.1. Valid range:
    /// 10..24 (the small-window 16 case + extended).
    public let windowBits: Int
    /// Byte position after the WBITS field — every meta-block's
    /// bit reader starts here.
    public let bitsConsumed: Int
}

/// Per-meta-block header. Carries the kind of block (compressed,
/// last/empty, uncompressed) and its uncompressed payload size.
public struct BrotliMetaBlockHeader: Sendable, Equatable {
    /// True if this is the final meta-block in the stream.
    public let isLast: Bool
    /// True if `isLast` is set and the empty bit is also set —
    /// signals end-of-stream with no payload.
    public let isLastEmpty: Bool
    /// True if the meta-block is uncompressed (literal byte run).
    public let isUncompressed: Bool
    /// Uncompressed payload size in bytes (MLEN + 1). Zero for
    /// `isLastEmpty == true`.
    public let payloadSize: Int
}

public enum BrotliMetaBlockReader {

    /// RFC 7932 §9.1 — read the stream header (`WBITS`). Returns
    /// the window size and the bit position after it.
    ///
    /// The encoding (derived from RFC 7932 §9.1 and verified against
    /// `brotli --lgwin=N` output for N ∈ {10..24}):
    ///
    /// ```
    /// read 1 bit (bit0)
    /// if bit0 == 0:   WBITS = 16
    /// else:
    ///     read 3 bits (M)
    ///     if M != 0:  WBITS = 17 + M             (= 18..24)
    ///     else:
    ///         read 3 bits (N)
    ///         if N == 0:  WBITS = 17  (canonical encoding for 17)
    ///         if N == 1:  reserved (would imply WBITS=9, < min 10)
    ///         else:       WBITS = 8 + N           (= 10..15)
    /// ```
    ///
    /// Verified empirically against `brotli --lgwin=N`:
    ///   N=10..15 ⇒ first byte 0x21, 0x31, 0x41, 0x51, 0x61, 0x71
    ///   N=16     ⇒ 0x00
    ///   N=17     ⇒ 0x01
    ///   N=18..24 ⇒ 0x03, 0x05, 0x07, 0x09, 0x0B, 0x0D, 0x0F
    public static func readStreamHeader(
        from r: inout BitReader
    ) throws -> BrotliStreamHeader {
        let startBit = r.position
        let bit0: UInt32
        do { bit0 = try r.read(bits: 1) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
        if bit0 == 0 {
            return BrotliStreamHeader(
                windowBits: 16, bitsConsumed: r.position - startBit)
        }
        let m: UInt32
        do { m = try r.read(bits: 3) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
        if m != 0 {
            // WBITS = 17 + m, range 18..24.
            return BrotliStreamHeader(
                windowBits: Int(17 + m),
                bitsConsumed: r.position - startBit)
        }
        // m == 0: read 3 more bits to disambiguate WBITS=17 vs
        // small-window WBITS=10..15.
        let n: UInt32
        do { n = try r.read(bits: 3) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
        if n == 0 {
            return BrotliStreamHeader(
                windowBits: 17, bitsConsumed: r.position - startBit)
        }
        if n == 1 {
            // Would encode WBITS=9 (below the minimum). Reserved.
            throw BrotliError.invalidWindowSize(9)
        }
        // n in 2..7 ⇒ WBITS = 8 + n (= 10..15).
        return BrotliStreamHeader(
            windowBits: Int(8 + n),
            bitsConsumed: r.position - startBit)
    }

    /// RFC 7932 §9.2 — read a meta-block header. The bit reader is
    /// positioned at the meta-block boundary (right after the
    /// previous meta-block's data, or right after the stream header
    /// for the first meta-block).
    ///
    /// For uncompressed meta-blocks the bit reader is **byte-aligned**
    /// after this call; callers should then read `payloadSize` bytes
    /// directly from the data buffer.
    public static func readMetaBlockHeader(
        from r: inout BitReader
    ) throws -> BrotliMetaBlockHeader {
        let isLast: Bool
        do { isLast = try r.readBit() }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
        var isLastEmpty = false
        if isLast {
            do { isLastEmpty = try r.readBit() }
            catch let e as BitstreamError {
                throw BrotliError.bitstream(e)
            }
            if isLastEmpty {
                return BrotliMetaBlockHeader(
                    isLast: true, isLastEmpty: true,
                    isUncompressed: false, payloadSize: 0)
            }
        }
        // MNIBBLES — 2 bits.
        let mnibblesRaw: UInt32
        do { mnibblesRaw = try r.read(bits: 2) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
        if mnibblesRaw == 3 {
            // RFC 7932 §9.2 — empty meta-block / skip-length branch.
            // 1 bit reserved (must be 0), 2 bits MSKIPBYTES (1..4),
            // 8 * MSKIPBYTES bits MSKIPLEN.
            let reserved: UInt32
            do { reserved = try r.read(bits: 1) }
            catch let e as BitstreamError {
                throw BrotliError.bitstream(e)
            }
            if reserved != 0 {
                throw BrotliError.reservedBitNonZero
            }
            let mskipBytesRaw: UInt32
            do { mskipBytesRaw = try r.read(bits: 2) }
            catch let e as BitstreamError {
                throw BrotliError.bitstream(e)
            }
            let mskipBytes = Int(mskipBytesRaw) + 1
            let mskipLen: UInt32
            do { mskipLen = try r.read(bits: mskipBytes * 8) }
            catch let e as BitstreamError {
                throw BrotliError.bitstream(e)
            }
            // Per RFC 7932: MSKIPLEN nominally encodes "skip 0 bytes"
            // sentinel if all the high bits are 0, but the spec
            // forbids the canonical empty case (MSKIPBYTES=2 with
            // MSKIPLEN=0). We accept and pass through; callers
            // align-to-byte then skip `mskipLen + 1` bytes.
            // Stored as `payloadSize = mskipLen + 1` with the
            // `isUncompressed = true` flag so the caller treats it
            // like an uncompressed run.
            return BrotliMetaBlockHeader(
                isLast: isLast, isLastEmpty: false,
                isUncompressed: true,
                payloadSize: Int(mskipLen) + 1)
        }
        let mnibbles = Int(mnibblesRaw) + 4
        let mlen: UInt32
        do { mlen = try r.read(bits: mnibbles * 4) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
        // RFC 7932 §9.2 — MLEN's top nibble must be non-zero
        // (unless MNIBBLES == 4 and MLEN == 0, which is invalid).
        // Validate.
        let payloadSize = Int(mlen) + 1
        if mnibbles > 4 {
            let topNibble = (mlen >> ((mnibbles - 1) * 4)) & 0xF
            if topNibble == 0 {
                throw BrotliError.invalidMetaBlockLength(
                    "MNIBBLES=\(mnibbles) but top nibble of MLEN is 0")
            }
        }
        var isUncompressed = false
        if !isLast {
            do { isUncompressed = try r.readBit() }
            catch let e as BitstreamError {
                throw BrotliError.bitstream(e)
            }
        }
        return BrotliMetaBlockHeader(
            isLast: isLast, isLastEmpty: false,
            isUncompressed: isUncompressed,
            payloadSize: payloadSize)
    }
}
