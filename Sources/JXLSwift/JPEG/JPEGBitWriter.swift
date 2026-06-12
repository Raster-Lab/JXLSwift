// `JPEG/JPEGBitWriter.swift` — MSB-first bit writer over JPEG
// entropy-coded data. The inverse of `JPEGBitReader`.
//
// JPEG entropy data is big-endian bit-packed inside bytes (§F.2.2.5).
// A literal 0xFF byte in the output is **byte-stuffed** as
// `0xFF 0x00` so it can't be mistaken for a marker (§F.1.2.3).
//
// Phase J step 5i support — needed by `JPEGBlockEncoder` to write
// the SOS payload during JXL → JPEG reverse transcode.
//
// We intentionally keep this distinct from the JXL `BitWriter`
// (LSB-first, no byte-stuffing). The two orderings would muddy the
// abstraction.

import Foundation

/// MSB-first bit writer over a growing byte buffer. Handles JPEG
/// 0xFF byte-stuffing automatically — callers don't need to think
/// about marker collisions. Bits collect in a 64-bit accumulator
/// and drain as whole bytes, so `writeBits` is a single shift per
/// call with the stuffing branch running per byte, not per bit.
package struct JPEGBitWriter {
    /// Output bytes accumulated so far. Byte-stuffing is already
    /// applied.
    private var bytes: [UInt8]
    /// Bit accumulator — the low `bitsPending` bits are queued for
    /// output, MSB-first (always < 8 between mutations: whole
    /// bytes drain eagerly).
    private var accumulator: UInt64 = 0
    /// Number of bits queued in `accumulator` (0..7).
    private var bitsPending: Int = 0

    /// Output buffer being accumulated. Byte-stuffing is already
    /// applied; callers can read `data` directly when emitting an
    /// SOS payload.
    package var data: Data { Data(bytes) }

    package init(capacityHint: Int = 0) {
        var b = [UInt8]()
        if capacityHint > 0 { b.reserveCapacity(capacityHint) }
        self.bytes = b
    }

    /// Write a single bit (0 or 1). MSB-first packing.
    package mutating func writeBit(_ bit: Int) {
        precondition(bit == 0 || bit == 1,
            "JPEGBitWriter.writeBit: bit must be 0 or 1")
        accumulator = (accumulator << 1) | UInt64(bit)
        bitsPending += 1
        drainWholeBytes()
    }

    /// Write `n` bits (1..32) MSB-first. Value's low-order `n` bits
    /// are the ones emitted; higher bits are ignored.
    package mutating func writeBits(_ value: UInt32, count n: Int) {
        precondition(n >= 0 && n <= 32,
            "JPEGBitWriter.writeBits: n must be 0...32")
        if n == 0 { return }
        let mask: UInt64 = (1 << UInt64(n)) - 1
        accumulator = (accumulator << UInt64(n))
            | (UInt64(value) & mask)
        bitsPending += n
        drainWholeBytes()
    }

    /// Pad the current partial byte to a full byte with 1-bits, then
    /// finalise — used at the end of a scan / before an RST marker.
    /// The padding bits being 1s matches what most JPEG encoders
    /// emit; libjxl's jbrd box can record the exact padding pattern
    /// for byte-identical reconstruction (see `JBRDBox.paddingBits`).
    package mutating func flushPaddingOnes() {
        let pad = padBitsNeeded
        if pad > 0 {
            writeBits((1 << UInt32(pad)) - 1, count: pad)
        }
    }

    /// Pad with a caller-supplied sequence of 0/1 bits.
    /// `bits.count` must match `8 - bitsPending` (or this method
    /// asserts). Used to restore byte-identical padding from a
    /// jbrd box's `paddingBits` field.
    package mutating func flushPadding(bits: [Int]) {
        precondition(bits.count == padBitsNeeded,
            "JPEGBitWriter.flushPadding: bits.count "
            + "\(bits.count) ≠ needed \(padBitsNeeded)")
        for b in bits {
            writeBit(b)
        }
    }

    /// Number of bits a `flushPadding` call would consume to reach
    /// the next byte boundary (0 if already aligned).
    package var padBitsNeeded: Int {
        bitsPending == 0 ? 0 : 8 - bitsPending
    }

    /// Drain every complete byte out of the accumulator with 0xFF
    /// byte-stuffing. Internal helper.
    private mutating func drainWholeBytes() {
        while bitsPending >= 8 {
            bitsPending -= 8
            let b = UInt8(
                truncatingIfNeeded: accumulator >> UInt64(bitsPending))
            bytes.append(b)
            if b == 0xFF {
                // Byte-stuff: insert a 0x00 after every emitted 0xFF.
                bytes.append(0x00)
            }
        }
    }

    /// Append raw bytes to the output **without** byte-stuffing.
    /// Used to emit RST markers (`0xFF Dn`) at restart-interval
    /// boundaries — the caller has already flushed the bit
    /// accumulator (typically via `flushPaddingOnes`) and is
    /// emitting a real marker that should NOT be stuffed.
    ///
    /// Precondition: bit accumulator is byte-aligned (call
    /// `flushPaddingOnes` or `flushPadding(bits:)` first).
    package mutating func appendRawMarker(_ bytes: [UInt8]) {
        precondition(bitsPending == 0,
            "JPEGBitWriter.appendRawMarker: must be byte-aligned "
            + "(bitsPending = \(bitsPending))")
        self.bytes.append(contentsOf: bytes)
    }
}
