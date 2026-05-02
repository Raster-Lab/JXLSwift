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
// the consumed-bit count `position` modulo 8 within the current byte.
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
public struct BitReader: Sendable {
    public let data: Data
    /// Bit position in the stream (0 = LSB of first byte).
    public private(set) var position: Int

    public init(_ data: Data, startingAt position: Int = 0) {
        self.data = data
        self.position = position
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
    public var totalBits: Int { data.count * 8 }
    public var bitsRemaining: Int { totalBits - position }
    public var isExhausted: Bool { position >= totalBits }

    /// Read `count` bits as a `UInt32` (1...32 bits).
    public mutating func read(bits count: Int) throws -> UInt32 {
        guard count >= 0 && count <= 32 else {
            throw BitstreamError.tooManyBits(requested: count, max: 32)
        }
        if count == 0 { return 0 }
        guard position + count <= totalBits else {
            throw BitstreamError.outOfBounds(needed: count, remaining: bitsRemaining)
        }
        let startPos = position
        var value: UInt32 = 0
        var shift = 0
        var pos = position
        var remaining = count
        while remaining > 0 {
            let byteIndex = pos / 8
            let bitOffset = pos % 8
            let take = min(8 - bitOffset, remaining)
            let mask: UInt32 = (1 &<< UInt32(take)) - 1
            let byteVal = UInt32(data[data.startIndex + byteIndex])
            let chunk = (byteVal &>> UInt32(bitOffset)) & mask
            value |= chunk &<< UInt32(shift)
            shift += take
            pos += take
            remaining -= take
        }
        position += count
        emitTrace(start: startPos, count: count, value: UInt64(value))
        return value
    }

    /// Read 1 bit as a Bool.
    public mutating func readBit() throws -> Bool {
        try read(bits: 1) == 1
    }

    /// Peek `count` bits (1...32) without advancing the position. The
    /// caller is expected to follow up with `skip(bits:)` to consume
    /// however many bits the lookup-table entry asked for. Used by
    /// libjxl-style fixed-table Huffman decoders (e.g. ReadHistogram's
    /// 7-bit logcount table).
    public func peek(bits count: Int) throws -> UInt32 {
        guard count >= 0 && count <= 32 else {
            throw BitstreamError.tooManyBits(requested: count, max: 32)
        }
        if count == 0 { return 0 }
        guard position + count <= totalBits else {
            throw BitstreamError.outOfBounds(needed: count, remaining: bitsRemaining)
        }
        var value: UInt32 = 0
        var shift = 0
        var pos = position
        var remaining = count
        while remaining > 0 {
            let byteIndex = pos / 8
            let bitOffset = pos % 8
            let take = min(8 - bitOffset, remaining)
            let mask: UInt32 = (1 &<< UInt32(take)) - 1
            let byteVal = UInt32(data[data.startIndex + byteIndex])
            let chunk = (byteVal &>> UInt32(bitOffset)) & mask
            value |= chunk &<< UInt32(shift)
            shift += take
            pos += take
            remaining -= take
        }
        return value
    }

    /// Read a 64-bit value (0 ≤ count ≤ 64).
    public mutating func read64(bits count: Int) throws -> UInt64 {
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
    public mutating func skip(bits count: Int) throws {
        guard count >= 0 else {
            throw BitstreamError.malformedValue("negative skip")
        }
        guard position + count <= totalBits else {
            throw BitstreamError.outOfBounds(needed: count, remaining: bitsRemaining)
        }
        let startPos = position
        position += count
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
    public mutating func alignToByte() throws {
        let pad = (8 - (position % 8)) % 8
        try skip(bits: pad)
    }

    /// Variant of `alignToByte` that asserts the consumed padding bits
    /// are all zero (per spec).
    public mutating func expectZeroPadding() throws {
        let pad = (8 - (position % 8)) % 8
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
