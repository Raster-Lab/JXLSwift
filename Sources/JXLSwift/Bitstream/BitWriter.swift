// BitWriter — LSB-first bit writer for JPEG XL bitstreams.
//
// Mirror of `BitReader`. Buffers a `Data` object; the producer pushes
// values via `write(bits:value:)` and finalises with `finishToData()`
// (or `flushByte()` if intermediate access is needed).
//
// Spec: ISO/IEC 18181-1 §2.4. Each call appends `count` low-order bits
// of `value`, with the LSB of the new value placed in the next free bit
// of the current byte. Bits past the topmost in `value` are discarded.

import Foundation

/// Bitwise writer producing a byte-aligned `Data` payload.
public struct BitWriter: Sendable {
    public private(set) var bytes: [UInt8] = []
    /// Bits already written *into* the current incomplete byte (0..<8).
    /// `bytes.last` is the in-progress byte when `partial > 0`.
    public private(set) var partial: Int = 0

    public init() {}

    /// Total bits emitted so far.
    public var bitCount: Int { bytes.count * 8 - (partial == 0 ? 0 : 8 - partial) }

    /// Append `count` bits of `value` (LSB-first). 0 ≤ count ≤ 32.
    public mutating func write(bits count: Int, value: UInt32) {
        precondition(count >= 0 && count <= 32, "bit count must be 0...32")
        if count == 0 { return }
        // Mask `value` to its low `count` bits. Compute via UInt64 to avoid
        // the (1 << 32) corner case on UInt32 (which masks the shift count
        // to 0 and produces 0 instead of 0xFFFFFFFF).
        let mask: UInt32 = count == 32 ? .max : UInt32((UInt64(1) << UInt64(count)) - 1)
        var v = value & mask
        var remaining = count
        while remaining > 0 {
            if partial == 0 {
                bytes.append(0)
            }
            let space = 8 - partial
            let take = min(space, remaining)
            let mask: UInt32 = (1 &<< UInt32(take)) - 1
            let chunk = UInt8(v & mask)
            // OR into the current byte at `partial` bit offset.
            bytes[bytes.count - 1] |= chunk &<< UInt8(partial)
            v &>>= UInt32(take)
            partial = (partial + take) % 8
            remaining -= take
        }
    }

    /// Convenience for single-bit writes.
    public mutating func writeBit(_ bit: Bool) {
        write(bits: 1, value: bit ? 1 : 0)
    }

    /// Write up to 64 bits.
    public mutating func write64(bits count: Int, value: UInt64) {
        precondition(count >= 0 && count <= 64, "bit count must be 0...64")
        if count <= 32 {
            write(bits: count, value: UInt32(truncatingIfNeeded: value))
            return
        }
        write(bits: 32, value: UInt32(truncatingIfNeeded: value))
        write(bits: count - 32, value: UInt32(truncatingIfNeeded: value &>> 32))
    }

    /// Pad the current byte with zero bits up to the next byte boundary.
    public mutating func alignToByte() {
        if partial != 0 {
            partial = 0
        }
    }

    /// Append raw bytes — only valid when the writer is byte-aligned.
    public mutating func appendBytes(_ data: Data) {
        precondition(partial == 0, "appendBytes requires byte alignment")
        bytes.append(contentsOf: data)
    }

    public mutating func appendBytes(_ data: [UInt8]) {
        precondition(partial == 0, "appendBytes requires byte alignment")
        bytes.append(contentsOf: data)
    }

    /// Finalise the buffer — pads any trailing partial byte with zeros and
    /// returns the resulting `Data`.
    public mutating func finishToData() -> Data {
        partial = 0
        return Data(bytes)
    }
}
