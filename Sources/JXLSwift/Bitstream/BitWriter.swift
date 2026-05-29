// BitWriter — LSB-first bit writer for JPEG XL bitstreams.
//
// Mirror of `BitReader`. Buffers a `[UInt8]`; the producer pushes values via
// `write(bits:value:)` and finalises with `finishToData()`.
//
// Spec: ISO/IEC 18181-1 §2.4. Each call appends `count` low-order bits of
// `value`, with the LSB of the new value placed in the next free bit of the
// current byte. Bits past the topmost in `value` are discarded.
//
// **Implementation (v0.13.0):** a 64-bit accumulator. New bits are OR'd into
// `acc` at the current sub-byte offset; complete bytes are flushed to `bytes`
// in a tight loop. This avoids the per-bit-chunk `append` + bounds-checked
// subscript of the previous implementation while emitting the **identical**
// byte stream — the only state that differs is that the in-progress partial
// byte lives in `acc` (not yet in `bytes`) until a byte completes or the
// writer is aligned/finalised. `bitCount` and `partial` are preserved exactly,
// so the cost-gating that measures candidate sizes via `bitCount` is
// unaffected. (No caller reads `bytes` mid-stream.)

import Foundation

/// Bitwise writer producing a byte-aligned `Data` payload.
public struct BitWriter: Sendable {
    /// Completed bytes. The in-progress partial byte (if any) is held in `acc`
    /// until it fills or the writer is aligned/finalised.
    public private(set) var bytes: [UInt8] = []
    /// Pending bits: the low `accBits` bits of `acc`, LSB-first.
    private var acc: UInt64 = 0
    /// Number of valid pending bits in `acc` (kept in 0..<8 after each call).
    private var accBits: Int = 0

    public init() {}

    /// Pre-reserve the backing byte buffer. Pure optimisation — semantically
    /// identical to `init()`, it only avoids geometric-growth reallocations
    /// when the eventual size is roughly known. Over-estimating is harmless;
    /// reserving never changes the emitted bytes.
    public init(reservingBytes n: Int) {
        if n > 0 { bytes.reserveCapacity(n) }
    }

    /// Bits already written *into* the current incomplete byte (0..<8).
    public var partial: Int { accBits }

    /// Total bits emitted so far.
    public var bitCount: Int { bytes.count * 8 + accBits }

    /// Append `count` bits of `value` (LSB-first). 0 ≤ count ≤ 32.
    public mutating func write(bits count: Int, value: UInt32) {
        precondition(count >= 0 && count <= 32, "bit count must be 0...32")
        if count == 0 { return }
        // Mask `value` to its low `count` bits, then shift into place above the
        // existing `accBits` pending bits. `accBits` ≤ 7 and `count` ≤ 32, so
        // the result occupies < 40 bits — well within `UInt64`.
        let mask: UInt64 = count == 32 ? 0xFFFF_FFFF
            : (UInt64(1) << UInt64(count)) - 1
        acc |= (UInt64(value) & mask) << UInt64(accBits)
        accBits += count
        while accBits >= 8 {
            bytes.append(UInt8(acc & 0xFF))
            acc &>>= 8
            accBits -= 8
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
        if accBits > 0 {
            // Flush the partial byte; unused high bits are already 0.
            bytes.append(UInt8(acc & 0xFF))
            acc = 0
            accBits = 0
        }
    }

    /// Append raw bytes — only valid when the writer is byte-aligned.
    public mutating func appendBytes(_ data: Data) {
        precondition(accBits == 0, "appendBytes requires byte alignment")
        bytes.append(contentsOf: data)
    }

    public mutating func appendBytes(_ data: [UInt8]) {
        precondition(accBits == 0, "appendBytes requires byte alignment")
        bytes.append(contentsOf: data)
    }

    /// Finalise the buffer — pads any trailing partial byte with zeros and
    /// returns the resulting `Data`.
    public mutating func finishToData() -> Data {
        if accBits > 0 {
            bytes.append(UInt8(acc & 0xFF))
            acc = 0
            accBits = 0
        }
        return Data(bytes)
    }
}
