// BitReader — LSB-first bit reader for JPEG XL bitstreams.
//
// Per ISO/IEC 18181-1 §2.4 ("Bitstream conventions"), bits are packed
// least-significant-bit first within each byte. A 4-bit value `0b1011`
// followed by a 5-bit value `0b10110` placed at byte boundary look like
// this in memory:
//
//     bit position: 7 6 5 4 3 2 1 0   |   7 6 5 4 3 2 1 0
//     byte 0:       0 1 1 0 1 0 1 1   |   …
//                   ^ second value's   ^ first value
//                     low 4 bits
//
// i.e. the LSB of each new value goes into the next free bit. We track
// the consumed-bit count `position` as an absolute bit offset into the
// buffer.
//
// Reads are served from a 64-bit lookahead accumulator (`bitBuf`,
// holding the next `bitCount` stream bits LSB-first) refilled from a
// contiguous `[UInt8]` copy of the input made once at init — this keeps
// the per-read cost to a couple of shifts instead of per-byte
// bounds-checked `Data` subscripts.
//
// All readers throw `BitstreamError.outOfBounds` on EOF rather than
// trapping, so malformed inputs surface cleanly.

import Foundation

public enum BitstreamError: Error, Equatable, Sendable {
    /// Tried to read past the end of the buffer.
    case outOfBounds(needed: Int, remaining: Int)
    /// Requested too many bits for the underlying integer width.
    case tooManyBits(requested: Int, max: Int)
    /// A field's value violated the spec's range/encoding constraints.
    case malformedValue(String)
}

/// Bitwise reader for byte-backed buffers. LSB-first within each byte.
package struct BitReader: Sendable {
    package let data: Data
    /// Contiguous copy of `data` (copied once at init) — the hot read
    /// path indexes this instead of going through `Data` subscripts.
    private let bytes: [UInt8]
    /// Absolute bit position in the stream (0 = LSB of first byte).
    /// Source of truth for bounds checks.
    private var pos: Int
    /// Lookahead accumulator: the next `bitCount` stream bits starting
    /// at `pos`, LSB-first (the bit at `pos` is bit 0 of `bitBuf`).
    private var bitBuf: UInt64
    /// Number of valid bits in `bitBuf`.
    private var bitCount: Int
    /// Next index in `bytes` to load into the accumulator.
    private var nextByte: Int

    /// Bit position in the stream (0 = LSB of first byte).
    package var position: Int { pos }

    package init(_ data: Data, startingAt position: Int = 0) {
        self.data = data
        self.bytes = [UInt8](data)
        self.pos = position
        self.bitBuf = 0
        self.bitCount = 0
        self.nextByte = 0
        resync()
    }

    /// Re-point the reader at an absolute bit position, reusing the
    /// already-copied byte buffer. Cheaper than constructing a new
    /// `BitReader` over the same bytes (which would re-copy the data).
    package mutating func seek(toBitPosition newPosition: Int) {
        pos = newPosition
        resync()
    }

    /// Rebuild the accumulator so it holds the stream bits starting at
    /// `pos`. Out-of-range positions leave the accumulator empty (reads
    /// then throw `outOfBounds`).
    private mutating func resync() {
        bitBuf = 0
        bitCount = 0
        let byteIdx = pos >> 3
        guard byteIdx >= 0 && byteIdx < bytes.count else {
            nextByte = bytes.count
            return
        }
        nextByte = byteIdx
        refill()
        let drop = pos & 7
        bitBuf &>>= UInt64(drop)
        bitCount &-= drop
    }

    /// Top up the accumulator from `bytes` (to ≥ 57 bits, or to EOF).
    @inline(__always)
    private mutating func refill() {
        while bitCount <= 56 && nextByte < bytes.count {
            bitBuf |= UInt64(bytes[nextByte]) &<< UInt64(bitCount)
            nextByte &+= 1
            bitCount &+= 8
        }
    }

    @inline(__always)
    private static var bitTrace: Int32 {
        // Read once on first access, cached process-wide. 0 = off,
        // 1 = absolute bitstream position, otherwise = subtract this
        // offset before emitting (so we can align with libjxl's
        // section-relative BitReader positions).
        BitReaderTraceCache.mode
    }

    @inline(__always)
    private func emitTrace(start: Int, count: Int, value: UInt64) {
        let mode = BitReader.bitTrace
        if mode == 0 || count == 0 { return }
        let p = mode == 1 ? start : start - Int(mode)
        if p < 0 { return }
        let line = "TRACE pos=\(p) read \(count) bits = 0x\(String(value, radix: 16))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Total bits available in the underlying buffer.
    package var totalBits: Int { bytes.count * 8 }
    package var bitsRemaining: Int { totalBits - pos }
    package var isExhausted: Bool { pos >= totalBits }

    /// Read `count` bits as a `UInt32` (1...32 bits).
    package mutating func read(bits count: Int) throws -> UInt32 {
        guard count >= 0 && count <= 32 else {
            throw BitstreamError.tooManyBits(requested: count, max: 32)
        }
        if count == 0 { return 0 }
        if count > bitCount { refill() }
        guard count <= bitCount else {
            throw BitstreamError.outOfBounds(needed: count, remaining: bitsRemaining)
        }
        let mask = (UInt64(1) &<< UInt64(count)) &- 1
        let value = UInt32(truncatingIfNeeded: bitBuf & mask)
        bitBuf &>>= UInt64(count)
        bitCount &-= count
        pos &+= count
        emitTrace(start: pos - count, count: count, value: UInt64(value))
        return value
    }

    /// Read 1 bit as a Bool.
    package mutating func readBit() throws -> Bool {
        try read(bits: 1) == 1
    }

    /// Peek `count` bits (1...32) without advancing the position. The
    /// caller is expected to follow up with `skip(bits:)` to consume
    /// however many bits the lookup-table entry asked for. Used by
    /// libjxl-style fixed-table Huffman decoders (e.g. ReadHistogram's
    /// 7-bit logcount table).
    package func peek(bits count: Int) throws -> UInt32 {
        guard count >= 0 && count <= 32 else {
            throw BitstreamError.tooManyBits(requested: count, max: 32)
        }
        if count == 0 { return 0 }
        guard pos + count <= totalBits else {
            throw BitstreamError.outOfBounds(needed: count, remaining: bitsRemaining)
        }
        let mask = (UInt64(1) &<< UInt64(count)) &- 1
        if count <= bitCount {
            return UInt32(truncatingIfNeeded: bitBuf & mask)
        }
        // Accumulator runs short (peek is non-mutating, so it cannot
        // refill in place) — extend a local copy from `bytes`.
        var buf = bitBuf
        var have = bitCount
        var idx = nextByte
        while have < count && idx < bytes.count {
            buf |= UInt64(bytes[idx]) &<< UInt64(have)
            idx &+= 1
            have &+= 8
        }
        return UInt32(truncatingIfNeeded: buf & mask)
    }

    /// Read a 64-bit value (0 ≤ count ≤ 64).
    package mutating func read64(bits count: Int) throws -> UInt64 {
        guard count >= 0 && count <= 64 else {
            throw BitstreamError.tooManyBits(requested: count, max: 64)
        }
        if count <= 32 {
            return UInt64(try read(bits: count))
        }
        let lo = UInt64(try read(bits: 32))
        let hi = UInt64(try read(bits: count - 32))
        return lo | (hi &<< 32)
    }

    /// Skip ahead by `count` bits.
    package mutating func skip(bits count: Int) throws {
        guard count >= 0 else {
            throw BitstreamError.malformedValue("negative skip")
        }
        guard pos + count <= totalBits else {
            throw BitstreamError.outOfBounds(needed: count, remaining: bitsRemaining)
        }
        let startPos = pos
        pos &+= count
        if count <= bitCount {
            bitBuf &>>= UInt64(count)
            bitCount &-= count
        } else {
            resync()
        }
        // Trace as a normal "read" of unknown value so the cumulative
        // bit position lines up with libjxl's trace; we don't have the
        // value here (skip is value-blind) so emit `0x?` as a sentinel.
        let mode = BitReader.bitTrace
        if mode != 0 && count > 0 {
            let p = mode == 1 ? startPos : startPos - Int(mode)
            if p >= 0 {
                let line = "TRACE pos=\(p) skip \(count) bits\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }

    /// Align forward to the next byte boundary by consuming up to 7
    /// padding bits. Per the JXL spec the padding bits must be zero;
    /// callers can verify this with `expectZeroPadding`.
    package mutating func alignToByte() throws {
        let pad = (8 - (pos % 8)) % 8
        try skip(bits: pad)
    }

    /// Variant of `alignToByte` that asserts the consumed padding bits
    /// are all zero (per spec).
    package mutating func expectZeroPadding() throws {
        let pad = (8 - (pos % 8)) % 8
        if pad == 0 { return }
        let bits = try read(bits: pad)
        if bits != 0 {
            throw BitstreamError.malformedValue("non-zero padding bits before byte alignment")
        }
    }
}

/// Process-wide cache for the `JXL_BIT_TRACE` env var. Set to "1" to
/// emit each `BitReader.read(bits:)` call as a libjxl-style trace
/// line (`TRACE pos=N read C bits = 0xV`) using absolute bitstream
/// positions. Set to a positive integer N to subtract N from each
/// position before emitting (so reads can be aligned with libjxl
/// section-relative BitReader positions for diffing).
enum BitReaderTraceCache {
    static let mode: Int32 = {
        guard let raw = ProcessInfo.processInfo.environment["JXL_BIT_TRACE"],
              let v = Int32(raw) else { return 0 }
        return v
    }()
}
