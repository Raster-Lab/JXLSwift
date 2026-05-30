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
package struct JPEGBitReader {
    private let data: Data
    private var byteOffset: Int
    private var currentByte: UInt8 = 0
    private var bitsRemainingInByte: Int = 0
    /// Set when an RST or non-RST marker was encountered. Caller
    /// inspects + clears as appropriate.
    package private(set) var markerSeen: UInt8? = nil

    package init(_ data: Data, startingAt offset: Int = 0) {
        self.data = data
        self.byteOffset = data.startIndex + offset
    }

    /// Current byte cursor — moves forward as bits are consumed.
    package var sourceByteOffset: Int { byteOffset }

    /// Read one bit (returns 0 or 1). Throws on truncation or
    /// when a non-RST marker is encountered. RST markers
    /// (0xFF D0..D7) are silently skipped and `markerSeen` is
    /// set so the caller can drive DC-differential reset.
    package mutating func readBit() throws -> Int {
        if bitsRemainingInByte == 0 {
            try fillByte()
        }
        bitsRemainingInByte -= 1
        return Int((currentByte >> UInt8(bitsRemainingInByte)) & 1)
    }

    /// Read N bits (1..32) as an MSB-first unsigned integer.
    /// Convenience over a loop of `readBit()`.
    package mutating func readBits(_ n: Int) throws -> UInt32 {
        precondition(n >= 0 && n <= 32,
                     "JPEGBitReader.readBits: n must be 0...32")
        var v: UInt32 = 0
        for _ in 0..<n {
            v = (v << 1) | UInt32(try readBit())
        }
        return v
    }

    /// Throw away enough bits to land on a byte boundary. JPEG
    /// scans don't pad-align internally but some callers (RST
    /// resync) want this.
    package mutating func alignToByte() {
        bitsRemainingInByte = 0
    }

    // MARK: - private

    private mutating func fillByte() throws {
        guard byteOffset < data.endIndex else {
            throw JPEGBitReaderError.truncated
        }
        var b = data[byteOffset]
        byteOffset += 1
        if b == 0xFF {
            // §F.1.2.3 byte-stuffing OR a marker.
            guard byteOffset < data.endIndex else {
                throw JPEGBitReaderError.truncated
            }
            let next = data[byteOffset]
            byteOffset += 1
            switch next {
            case 0x00:
                // Stuffed FF — the literal byte is 0xFF.
                b = 0xFF
            case 0xD0...0xD7:
                // RSTn — silently skip + signal. Recurse to fetch
                // the next entropy byte. RST markers can appear
                // back-to-back if a previous interval was empty;
                // handle that by re-entering the loop. The
                // bit-reader state is reset at the byte boundary
                // before the marker (callers must do their own
                // DC-differential reset).
                markerSeen = next
                try fillByte()
                return
            default:
                // Real marker (DNL, EOI, DRI, etc.) — entropy
                // data has ended. Push the marker pair back so
                // the caller can re-read at the byte cursor.
                byteOffset -= 2
                throw JPEGBitReaderError.sawMarker(
                    markerByte: next)
            }
        }
        currentByte = b
        bitsRemainingInByte = 8
    }
}
