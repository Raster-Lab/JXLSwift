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

/// MSB-first bit writer over a growing `Data` buffer. Handles JPEG
/// 0xFF byte-stuffing automatically — callers don't need to think
/// about marker collisions.
public struct JPEGBitWriter {
    /// Output buffer being accumulated. Byte-stuffing is already
    /// applied; callers can read `data` directly when emitting an
    /// SOS payload.
    public private(set) var data: Data
    /// Current partial byte being filled. Bits are packed MSB-first.
    private var current: UInt8 = 0
    /// Number of bits *already* packed into `current` (0..7).
    private var bitsInCurrent: Int = 0

    public init(capacityHint: Int = 0) {
        var d = Data()
        if capacityHint > 0 { d.reserveCapacity(capacityHint) }
        self.data = d
    }

    /// Write a single bit (0 or 1). MSB-first packing.
    public mutating func writeBit(_ bit: Int) {
        precondition(bit == 0 || bit == 1,
            "JPEGBitWriter.writeBit: bit must be 0 or 1")
        current = (current << 1) | UInt8(bit)
        bitsInCurrent += 1
        if bitsInCurrent == 8 {
            appendCurrent()
        }
    }

    /// Write `n` bits (1..32) MSB-first. Value's low-order `n` bits
    /// are the ones emitted; higher bits are ignored.
    public mutating func writeBits(_ value: UInt32, count n: Int) {
        precondition(n >= 0 && n <= 32,
            "JPEGBitWriter.writeBits: n must be 0...32")
        if n == 0 { return }
        for i in stride(from: n - 1, through: 0, by: -1) {
            let b = Int((value >> UInt32(i)) & 1)
            writeBit(b)
        }
    }

    /// Pad the current partial byte to a full byte with 1-bits, then
    /// finalise — used at the end of a scan / before an RST marker.
    /// The padding bits being 1s matches what most JPEG encoders
    /// emit; libjxl's jbrd box can record the exact padding pattern
    /// for byte-identical reconstruction (see `JBRDBox.paddingBits`).
    public mutating func flushPaddingOnes() {
        while bitsInCurrent != 0 {
            writeBit(1)
        }
    }

    /// Pad with a caller-supplied sequence of 0/1 bits.
    /// `bits.count` must match `8 - bitsInCurrent` (or this method
    /// asserts). Used to restore byte-identical padding from a
    /// jbrd box's `paddingBits` field.
    public mutating func flushPadding(bits: [Int]) {
        precondition(bits.count == padBitsNeeded,
            "JPEGBitWriter.flushPadding: bits.count "
            + "\(bits.count) ≠ needed \(padBitsNeeded)")
        for b in bits {
            writeBit(b)
        }
    }

    /// Number of bits a `flushPadding` call would consume to reach
    /// the next byte boundary (0 if already aligned).
    public var padBitsNeeded: Int {
        bitsInCurrent == 0 ? 0 : 8 - bitsInCurrent
    }

    /// Append `current` to the buffer with 0xFF byte-stuffing, then
    /// reset the bit accumulator. Internal helper.
    private mutating func appendCurrent() {
        data.append(current)
        if current == 0xFF {
            // Byte-stuff: insert a 0x00 after every emitted 0xFF.
            data.append(0x00)
        }
        current = 0
        bitsInCurrent = 0
    }
}
