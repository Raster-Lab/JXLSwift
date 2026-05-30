// `Brotli/BrotliDistance.swift` — distance code decoder
// (RFC 7932 §4). Ports `google/brotli` `c/dec/decode.c::CalculateDistanceLut`
// + `TakeDistanceFromRingBuffer` + `ReadDistanceInternal`.
//
// Distance encoding layers:
//
//   • Short codes 0..15 — reference past distances in a 4-element
//     ring buffer.
//   • Direct codes 16..(16+NDIRECT-1) — distance = (code - 16 + 1).
//   • Regular codes (16+NDIRECT)..(alphabet_size - 1) — distance
//     derived from `offset + (extra_bits << NPOSTFIX)` where
//     `offset` and `extra_bits` come from a pre-computed LUT.
//
// Phase J step 5g. v0.12.0gm.

import Foundation

/// Number of short codes in the distance alphabet (RFC 7932 §4).
package let kBrotliNumDistanceShortCodes: Int = 16

/// Computed distance-code lookup table for a given NPOSTFIX/NDIRECT
/// combination + alphabet size. Indices 0..15 (short codes) are
/// not stored — they go through the ring buffer.
package struct BrotliDistanceLut: Sendable {
    package let npostfix: Int
    package let ndirect: Int
    /// Per-code extra-bit count. Indexed by full distance code
    /// (0..alphabet_size-1); entries 0..15 are unused (ring buffer
    /// handled separately).
    package let extraBits: [UInt8]
    /// Per-code base offset.
    package let offsets: [UInt32]
}

package enum BrotliDistance {

    /// Build the LUT for a given NPOSTFIX (0..3), NDIRECT (raw value
    /// before shift), and `alphabet_size_limit`. Mirrors libjxl
    /// `CalculateDistanceLut`.
    ///
    /// The "real" NDIRECT = `ndirectRaw << npostfix` per RFC 7932 §4.
    package static func buildLut(
        npostfix: Int, ndirectShifted: Int,
        alphabetSizeLimit: Int
    ) -> BrotliDistanceLut {
        let postfix = 1 << npostfix
        var extraBits = [UInt8](
            repeating: 0, count: alphabetSizeLimit)
        var offsets = [UInt32](
            repeating: 0, count: alphabetSizeLimit)
        var i = kBrotliNumDistanceShortCodes
        // Direct codes: distance = j + 1 for j in 0..<ndirect.
        for j in 0..<ndirectShifted where i < alphabetSizeLimit {
            extraBits[i] = 0
            offsets[i] = UInt32(j + 1)
            i += 1
        }
        // Regular codes: alternating "half" {0, 1} with growing bits.
        var bits = 1
        var half = 0
        while i < alphabetSizeLimit {
            let base = ndirectShifted
                + (((2 + half) << bits) - 4) << npostfix
                + 1
            for j in 0..<postfix where i < alphabetSizeLimit {
                extraBits[i] = UInt8(bits)
                offsets[i] = UInt32(base + j)
                i += 1
            }
            bits = bits + half
            half = half ^ 1
        }
        return BrotliDistanceLut(
            npostfix: npostfix, ndirect: ndirectShifted,
            extraBits: extraBits, offsets: offsets)
    }

    /// Distance-code alphabet size for given NPOSTFIX + NDIRECT.
    /// Per RFC 7932 §4: `16 + NDIRECT + (maxDistBits << (NPOSTFIX+1))`.
    /// libjxl uses maxDistBits=24 for the standard "window=22" case.
    package static func alphabetSize(
        npostfix: Int, ndirectShifted: Int,
        maxDistBits: Int = 24
    ) -> Int {
        return kBrotliNumDistanceShortCodes + ndirectShifted
            + (maxDistBits << (npostfix + 1))
    }

    /// Resolve a short-code (0..15) distance through the ring buffer.
    /// Returns the actual distance value plus the updated
    /// `(ringBuffer, ringBufferIdx)`. Mirrors libjxl
    /// `TakeDistanceFromRingBuffer`.
    package static func resolveShortCode(
        code: Int,
        ringBuffer: inout [Int],
        ringBufferIdx: inout Int
    ) -> Int {
        precondition(ringBuffer.count == 4,
            "Brotli distance ring buffer must have 4 entries")
        if code <= 3 {
            // Use one of the last 4 distances.
            let context = (1 >> code) & 1
            let dist = ringBuffer[
                (ringBufferIdx - (code - 3)) & 3]
            ringBufferIdx -= context
            return dist
        }
        // Codes 4..15: tweaked offsets via packed nibble table 0x605142.
        let indexDelta: Int
        let base: Int
        if code < 10 {
            base = code - 4
            indexDelta = 3
        } else {
            base = code - 10
            indexDelta = 2
        }
        let delta = Int((0x605142 >> (4 * base)) & 0xF) - 3
        return ringBuffer[(ringBufferIdx + indexDelta) & 3] + delta
    }

    /// Read one distance from the bitstream. Returns the resolved
    /// distance (already through the ring buffer if a short code
    /// was used) **plus the `distance_context`** the caller needs to
    /// compensate the ring-buffer roll on the static-dictionary path
    /// (libjxl `ReadDistanceInternal`: `distance_context` is reset to
    /// 0, then set to `1 >> code` for short codes 0...3 — i.e. it is
    /// 1 only for short code 0, and 0 for every other code).
    ///
    /// Caller maintains `ringBuffer` (4 entries, most-recent-last)
    /// and `ringBufferIdx`. For short code 0 this decrements
    /// `ringBufferIdx` (the "double-roll" the reference later undoes
    /// either by the normal-copy push or by `ringBufferIdx += context`
    /// on the dictionary path).
    package static func readDistance(
        from r: inout BitReader,
        prefixCode: BrotliPrefixCode,
        lut: BrotliDistanceLut,
        ringBuffer: inout [Int],
        ringBufferIdx: inout Int
    ) throws -> (distance: Int, context: Int) {
        let code = Int(try prefixCode.decodeSymbol(from: &r))
        let context = (code == 0) ? 1 : 0
        if code < kBrotliNumDistanceShortCodes {
            let distance = resolveShortCode(
                code: code,
                ringBuffer: &ringBuffer,
                ringBufferIdx: &ringBufferIdx)
            return (distance, context)
        }
        // Direct + regular codes: distance from LUT + extra bits.
        let extra: UInt32
        do {
            extra = try r.read(
                bits: Int(lut.extraBits[code]))
        } catch let e as BitstreamError {
            throw BrotliError.bitstream(e)
        }
        let distance = Int(lut.offsets[code])
            + (Int(extra) << lut.npostfix)
        return (distance, 0)
    }
}
