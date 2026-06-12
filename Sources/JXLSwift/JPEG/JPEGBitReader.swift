// MSB-first bit reader over JPEG entropy-coded data — sixth step
// on the Phase J road. JPEG entropy data is big-endian bit-packed
// inside bytes (most-significant bit first, §F.2.2.5), and a
// literal 0xFF byte inside the entropy stream is byte-stuffed as
// `0xFF 0x00` so it can't be mistaken for a marker (§F.1.2.3).
// RST markers (0xFF D0..D7) appear at restart intervals and must
// not be returned to the entropy decoder.
//
// This reader handles all three concerns:
//   1. **MSB-first bit packing** — `readBit()` returns bit 7 of
//      the current byte first, then bit 6, etc.
//   2. **0xFF 0x00 unstuffing** — when the input byte stream has
//      `0xFF`, the next byte must be `0x00` (consumed silently)
//      or a marker (the bit reader signals end-of-segment).
//   3. **RST marker detection** — `0xFF D0..D7` is detected when
//      encountered and either silently skipped (via
//      `readBit(allowRST:)`) or surfaced as `markerSeen` for
//      callers that want to drive DC-differential reset.
//
// We intentionally don't share `Sources/JXLSwift/Bitstream/BitReader`
// (LSB-first, no byte-stuffing) — the two orderings would muddy
// the abstraction. Keeping JPEG-specific bit reading in its own
// type lets the JXL BitReader stay clean.

import Foundation

/// Errors raised by the JPEG bit reader. Distinct from
/// `JPEGParseError` (which covers structural / marker-level
/// problems) — these are bit-stream-level surprises.
package enum JPEGBitReaderError: Error, Sendable, Equatable,
                                LocalizedError {
    /// Ran off the end of the entropy data without finding the
    /// expected marker terminator.
    case truncated
    /// Saw `0xFF` followed by a non-`0x00`, non-RSTn byte — the
    /// entropy data has ended at the start of a real marker.
    case sawMarker(markerByte: UInt8)
    /// `0xFF 0x00` byte-stuffing was malformed.
    case invalidStuffing

    package var errorDescription: String? {
        switch self {
        case .truncated:
            return "JPEG entropy stream truncated"
        case .sawMarker(let m):
            let hex = String(m, radix: 16, uppercase: true)
            return "unexpected marker 0x\(hex) inside entropy data"
        case .invalidStuffing:
            return "invalid 0xFF byte-stuffing inside entropy data"
        }
    }
}

/// Forward-only MSB-first bit reader over JPEG entropy-coded
/// bytes. Tracks the source byte cursor so a caller can split a
/// scan across multiple bit-reader instances (e.g. one per
/// restart interval).
///
/// Internally a 64-bit lookahead accumulator over a contiguous
/// byte buffer (copied once at init): the unstuffing / marker
/// branches run per refill, not per bit, and `readBits` is a
/// single shift-and-mask in the common case.
package struct JPEGBitReader {
    private let bytes: [UInt8]
    /// `data.startIndex` of the original `Data` — `bytes` is
    /// 0-based, so reported offsets add this back.
    private let indexBase: Int
    /// Next byte of `bytes` to load into the accumulator. Never
    /// advanced past an unconsumed non-RST marker.
    private var byteOffset: Int
    /// Lookahead accumulator — the low `bitCount` bits are valid;
    /// the next bit to consume is bit `bitCount - 1` (MSB-first).
    private var acc: UInt64 = 0
    private var bitCount: Int = 0
    /// Set when an RST or non-RST marker was encountered. Caller
    /// inspects + clears as appropriate.
    package private(set) var markerSeen: UInt8? = nil

    package init(_ data: Data, startingAt offset: Int = 0) {
        self.bytes = [UInt8](data)
        self.indexBase = data.startIndex
        self.byteOffset = offset
    }

    /// Current byte cursor — moves forward as bits are buffered.
    /// May run ahead of the consumed-bit position by the lookahead
    /// (≤ 8 bytes); exact at marker / end-of-data stalls, so a
    /// caller catching `.sawMarker` can re-read the marker pair
    /// here.
    package var sourceByteOffset: Int { indexBase + byteOffset }

    /// Read one bit (returns 0 or 1). Throws on truncation or
    /// when a non-RST marker is encountered. RST markers
    /// (0xFF D0..D7) are silently skipped and `markerSeen` is
    /// set so the caller can drive DC-differential reset.
    package mutating func readBit() throws -> Int {
        if bitCount == 0 {
            refill()
            if bitCount == 0 { throw stallError() }
        }
        bitCount -= 1
        return Int((acc >> UInt64(bitCount)) & 1)
    }

    /// Read N bits (1..32) as an MSB-first unsigned integer.
    package mutating func readBits(_ n: Int) throws -> UInt32 {
        precondition(n >= 0 && n <= 32,
                     "JPEGBitReader.readBits: n must be 0...32")
        if bitCount >= n {
            bitCount -= n
            let mask: UInt32 = n == 32 ? .max : (1 << UInt32(n)) - 1
            return UInt32(truncatingIfNeeded: acc >> UInt64(bitCount))
                & mask
        }
        return try readBitsSlow(n)
    }

    /// Throw away enough bits to land on a byte boundary. JPEG
    /// scans don't pad-align internally but some callers (RST
    /// resync) want this.
    package mutating func alignToByte() {
        bitCount -= bitCount % 8
    }

    /// Peek the next ≤ 8 bits MSB-first without consuming,
    /// refilling the accumulator as needed. `count < 8` means
    /// fewer than 8 bits remain before a marker / end of data —
    /// callers fall back to bit-by-bit reads. Never throws; never
    /// skips an RST marker while unconsumed bits precede it.
    package mutating func peekBits8() -> (bits: Int, count: Int) {
        if bitCount < 8 { refill() }
        let c = min(bitCount, 8)
        guard c > 0 else { return (0, 0) }
        let v = (acc >> UInt64(bitCount - c)) & ((1 << UInt64(c)) - 1)
        return (Int(truncatingIfNeeded: v), c)
    }

    /// Consume `n` bits previously surfaced by `peekBits8`.
    /// Precondition: `n` ≤ the `count` that peek returned.
    package mutating func consumePeekedBits(_ n: Int) {
        precondition(n >= 0 && n <= bitCount,
            "JPEGBitReader.consumePeekedBits: n exceeds buffered bits")
        bitCount -= n
    }

    // MARK: - private

    /// Top the accumulator up to > 56 valid bits, applying
    /// §F.1.2.3 0xFF 0x00 unstuffing. Stops (without consuming)
    /// at a non-RST marker or end of data; skips an RST marker
    /// (setting `markerSeen`) only once every bit before it has
    /// been consumed — matching the byte-at-a-time semantics where
    /// markers are crossed exactly when the preceding byte drains.
    private mutating func refill() {
        let end = bytes.count
        while bitCount <= 56 {
            guard byteOffset < end else { return }
            let b = bytes[byteOffset]
            if b != 0xFF {
                acc = (acc << 8) | UInt64(b)
                bitCount += 8
                byteOffset += 1
                continue
            }
            // §F.1.2.3 byte-stuffing OR a marker.
            guard byteOffset + 1 < end else { return }
            let next = bytes[byteOffset + 1]
            switch next {
            case 0x00:
                // Stuffed FF — the literal byte is 0xFF.
                acc = (acc << 8) | 0xFF
                bitCount += 8
                byteOffset += 2
            case 0xD0...0xD7:
                // RSTn — defer until the accumulator drains so
                // `markerSeen` timing matches consumption, then
                // silently skip + signal. Back-to-back RSTs
                // (empty intervals) fall out of the loop.
                if bitCount > 0 { return }
                markerSeen = next
                byteOffset += 2
            default:
                // Real marker (DNL, EOI, DRI, etc.) — entropy
                // data has ended. Leave the cursor on the marker
                // pair so the caller can re-read it.
                return
            }
        }
    }

    /// Why the last refill couldn't supply a demanded bit: a real
    /// marker pair at the cursor, else truncation (including a
    /// trailing lone 0xFF).
    private func stallError() -> JPEGBitReaderError {
        if byteOffset + 1 < bytes.count,
           bytes[byteOffset] == 0xFF {
            let next = bytes[byteOffset + 1]
            if next != 0x00, !(0xD0...0xD7).contains(next) {
                return .sawMarker(markerByte: next)
            }
        }
        return .truncated
    }

    /// `readBits` remainder when the accumulator can't satisfy `n`
    /// in one extraction — drains, refills (possibly crossing RST
    /// markers, like the bit-at-a-time path did), and stitches the
    /// pieces MSB-first.
    private mutating func readBitsSlow(_ n: Int) throws -> UInt32 {
        var v: UInt32 = 0
        var remaining = n
        while remaining > 0 {
            if bitCount == 0 {
                refill()
                if bitCount == 0 { throw stallError() }
            }
            let take = min(remaining, bitCount)
            bitCount -= take
            let mask: UInt32 =
                take == 32 ? .max : (1 << UInt32(take)) - 1
            let piece =
                UInt32(truncatingIfNeeded: acc >> UInt64(bitCount))
                & mask
            v = (v << UInt32(take)) | piece
            remaining -= take
        }
        return v
    }
}
