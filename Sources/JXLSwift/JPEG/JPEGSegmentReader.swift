// Walk a JPEG byte stream segment-by-segment. First step on the
// Phase J (JXL ↔ JPEG reversible transcoding) road — high-level
// structural fields (dimensions, baseline/progressive, component
// count, JFIF / EXIF presence) all sit on top of this reader.
//
// JPEG marker layout, per ITU-T T.81 §B.1:
//   - A marker is `0xFF`+ followed by one non-0xFF, non-0x00 byte
//     (the "marker identifier"). Any number of preceding 0xFF
//     bytes are "fill" and ignored (§B.1.1.2).
//   - Stand-alone markers (SOI, EOI, RSTn, TEM) have no payload.
//   - Every other marker is followed by a 2-byte big-endian length
//     `Ls` that **counts itself** (so payload length = Ls − 2).
//   - SOS is followed by entropy-coded data that runs until the
//     next non-RST marker. Inside entropy data, 0xFF is
//     byte-stuffed as 0xFF 0x00 (§F.1.2.3).
//
// This reader intentionally does NOT decode entropy data — it
// just walks past it by finding the next marker boundary while
// honouring 0xFF 0x00 byte-stuffing and RST markers. That keeps
// it simple and lets the structural walk land before the much
// larger Huffman / DCT machinery does.

import Foundation

/// Error raised when the JPEG byte stream is malformed at the
/// marker / segment-length level. The reader is forgiving about
/// unknown marker codes (it preserves them and skips by length)
/// but strict about structural integrity.
package enum JPEGParseError: Error, Sendable, Equatable,
                            LocalizedError {
    /// File didn't start with a `0xFF 0xD8` SOI marker.
    case missingSOI
    /// Hit end-of-data while looking for the next marker.
    case truncated(at: Int)
    /// A non-stand-alone marker had a length less than 2 bytes
    /// (the length field counts itself, so values < 2 are
    /// impossible).
    case invalidSegmentLength(marker: UInt8, length: Int)
    /// A segment claimed more bytes than remain in the file.
    case segmentRunsPastEnd(marker: UInt8, declaredLength: Int,
                            bytesAvailable: Int)
    /// Saw a non-0xFF byte where a marker should start.
    case expectedMarkerPrefix(at: Int, found: UInt8)

    package var errorDescription: String? {
        switch self {
        case .missingSOI:
            return "not a JPEG file: missing 0xFF 0xD8 SOI marker"
        case .truncated(let at):
            return "truncated JPEG: out of data at byte \(at)"
        case .invalidSegmentLength(let m, let l):
            return "marker 0x\(String(m, radix: 16, uppercase: true)) "
                + "declared length \(l) (must be ≥ 2)"
        case .segmentRunsPastEnd(let m, let dl, let avail):
            return "marker 0x\(String(m, radix: 16, uppercase: true)) "
                + "declared length \(dl) but only \(avail) bytes "
                + "remain"
        case .expectedMarkerPrefix(let at, let f):
            return "expected 0xFF marker prefix at byte \(at); "
                + "found 0x\(String(f, radix: 16, uppercase: true))"
        }
    }
}

/// One marker + its payload bytes (an empty slice for stand-alone
/// markers). `payload` is the bytes AFTER the 2-byte length field
/// — i.e. `Ls − 2` bytes, exactly as the SOFn / DQT / DHT / SOS
/// parsers want them. `byteOffset` is the offset of the leading
/// 0xFF in the original file, useful for diagnostics.
package struct JPEGSegment: Sendable {
    package let kind: JPEGMarkerKind
    package let markerByte: UInt8
    package let payload: Data
    package let byteOffset: Int
}

/// Forward-only walker over a JPEG byte stream. Use either the
/// `.next()` iterator-style call or `.readAll(_:)` to collect
/// every segment up to EOI.
///
/// Entropy data between SOS and the next non-RST marker is NOT
/// returned as a segment — call `entropyDataBetween(...)` against
/// the raw input bytes if a caller (eventually the transcoder)
/// needs it. The structural-info layer doesn't.
package struct JPEGSegmentReader {
    private let data: Data
    private var position: Int

    package init(_ data: Data) {
        self.data = data
        self.position = 0
    }

    /// Current byte position. Settable so a caller can re-anchor
    /// the reader after manually consuming entropy data.
    package var byteOffset: Int { position }

    /// Read the next marker + payload. Returns `nil` after EOI.
    /// Throws `JPEGParseError` if the stream is malformed.
    package mutating func next() throws -> JPEGSegment? {
        if position == 0 {
            try expectSOI()
        }
        // After SOS, skip past entropy-coded data to the next
        // non-RST marker. We DO NOT emit the entropy data — caller
        // can pull it from the raw `Data` if they need it.
        // Detection here: position-1 is the start of entropy data
        // iff the last marker we emitted was SOS. We track that by
        // checking the last emitted marker via a small flag.
        if afterSOS {
            try skipEntropyData()
            afterSOS = false
        }
        if position >= data.count { return nil }

        let markerStart = position
        let markerByte = try findNextMarker()
        let kind = JPEGMarkerKind.from(markerByte: markerByte)

        if kind == .endOfImage {
            let seg = JPEGSegment(
                kind: kind, markerByte: markerByte,
                payload: Data(), byteOffset: markerStart)
            // Don't advance — EOI is the terminator.
            return seg
        }

        if kind.isStandalone {
            return JPEGSegment(
                kind: kind, markerByte: markerByte,
                payload: Data(), byteOffset: markerStart)
        }

        // Read 2-byte big-endian length.
        guard position + 1 < data.count else {
            throw JPEGParseError.truncated(at: position)
        }
        let hi = Int(data[position])
        let lo = Int(data[position + 1])
        let length = (hi << 8) | lo
        position += 2

        guard length >= 2 else {
            throw JPEGParseError.invalidSegmentLength(
                marker: markerByte, length: length)
        }
        let payloadCount = length - 2
        guard position + payloadCount <= data.count else {
            throw JPEGParseError.segmentRunsPastEnd(
                marker: markerByte, declaredLength: length,
                bytesAvailable: data.count - position)
        }
        let payload = data.subdata(
            in: position..<(position + payloadCount))
        position += payloadCount

        if kind == .startOfScan {
            afterSOS = true
        }
        return JPEGSegment(
            kind: kind, markerByte: markerByte,
            payload: payload, byteOffset: markerStart)
    }

    /// Collect every segment up to and including EOI.
    package mutating func readAll() throws -> [JPEGSegment] {
        var out: [JPEGSegment] = []
        while let seg = try next() {
            out.append(seg)
            if seg.kind == .endOfImage { break }
        }
        return out
    }

    // MARK: - private

    private var afterSOS = false

    private mutating func expectSOI() throws {
        guard data.count >= 2 else {
            throw JPEGParseError.missingSOI
        }
        guard data[0] == 0xFF, data[1] == 0xD8 else {
            throw JPEGParseError.missingSOI
        }
        // Don't advance past SOI — `findNextMarker` will land on
        // it as the first marker we report (kind = .startOfImage).
    }

    /// Move `position` past any 0xFF padding and return the
    /// distinguishing marker byte. Advances `position` to point
    /// just past the marker.
    private mutating func findNextMarker() throws -> UInt8 {
        guard position < data.count else {
            throw JPEGParseError.truncated(at: position)
        }
        // Find the leading 0xFF. Most callers land here exactly
        // on a 0xFF; if not (defensive), scan forward looking
        // for one.
        if data[position] != 0xFF {
            throw JPEGParseError.expectedMarkerPrefix(
                at: position, found: data[position])
        }
        // Skip any run of 0xFF padding bytes.
        var i = position
        while i < data.count, data[i] == 0xFF { i += 1 }
        guard i < data.count else {
            throw JPEGParseError.truncated(at: i)
        }
        let m = data[i]
        // A 0xFF run followed by 0x00 is byte-stuffing inside
        // entropy data, not a marker — but we should not see that
        // here (skipEntropyData consumes it). Defensive guard:
        if m == 0x00 {
            throw JPEGParseError.expectedMarkerPrefix(
                at: i, found: 0x00)
        }
        position = i + 1
        return m
    }

    /// Skip entropy-coded data following an SOS marker. Honours
    /// 0xFF 0x00 byte-stuffing and the RSTn markers (any of
    /// 0xFFD0..0xFFD7) embedded mid-scan. Stops with `position`
    /// pointing at the leading 0xFF of the next non-RST marker.
    private mutating func skipEntropyData() throws {
        var i = position
        while i < data.count {
            if data[i] != 0xFF {
                i += 1
                continue
            }
            // Run of 0xFF — find the distinguishing byte.
            var j = i + 1
            while j < data.count, data[j] == 0xFF { j += 1 }
            guard j < data.count else {
                throw JPEGParseError.truncated(at: j)
            }
            let m = data[j]
            if m == 0x00 {
                // Byte-stuffing. Continue past the stuffed pair.
                i = j + 1
                continue
            }
            if (0xD0...0xD7).contains(m) {
                // RSTn — restart marker; valid mid-scan. Skip
                // past it.
                i = j + 1
                continue
            }
            // Real marker — stop with `position` at the leading
            // 0xFF.
            position = i
            return
        }
        // Ran off the end without finding a terminator.
        throw JPEGParseError.truncated(at: i)
    }
}

extension JPEGSegmentReader {
    /// Quick magic-byte detector — returns `true` iff `data`
    /// starts with the JPEG SOI marker (`0xFF 0xD8`). Useful for
    /// CLI input-type routing before constructing a reader.
    package static func looksLikeJPEG(_ data: Data) -> Bool {
        return data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8
    }
}
