// JPEG XL container format (ISO/IEC 18181-2).
//
// A `.jxl` file may take one of two forms:
//
//   1. A "naked codestream" starting with the 2-byte signature
//      `FF 0A`. Used for the simplest cases — no metadata, single
//      animation frame, no JPEG reconstruction support.
//
//   2. An ISOBMFF container starting with the signature box:
//
//          00 00 00 0C  J X L (space)  0D 0A 87 0A
//
//      followed by a stream of boxes:
//
//          • ftyp       file-type box (always present)
//          • jxll       JXL level (optional)
//          • jxli       frame-index (optional)
//          • Exif       EXIF metadata (optional)
//          • xml        XMP metadata (optional)
//          • jbrd       JPEG bitstream reconstruction (optional)
//          • jxlc       complete codestream (when small enough)
//                       — OR —
//          • jxlp x N   partial codestream chunks (large files)
//          • jxll       container-level metadata
//          • brob       Brotli-compressed metadata
//
// Each box is `[size: u32 BE][type: 4 ASCII][payload …]`. A size of 0
// means "extends to end of file"; size 1 means an extended 8-byte size
// follows the type field. See ISO/IEC 14496-12 §4.2 for the underlying
// rules.

import Foundation

public enum ContainerError: Error, Equatable, Sendable {
    case truncated(String)
    case missingSignature
    case missingFTYP
    case unsupportedExtendedSize
    case malformedBox(String)
}

/// A parsed ISOBMFF box from a JXL container.
public struct JXLBox: Sendable, Equatable {
    /// 4-character ASCII box type (`jxlc`, `jxlp`, `Exif`, `xml `, …).
    public let type: String
    /// Byte range of the payload within the original buffer (does not
    /// include the box header).
    public let payloadRange: Range<Int>

    public init(type: String, payloadRange: Range<Int>) {
        self.type = type
        self.payloadRange = payloadRange
    }
}

/// The 12-byte JXL container signature box (always at offset 0 when the
/// file is in container form).
public let jxlContainerSignature: [UInt8] = [
    0x00, 0x00, 0x00, 0x0C,       // box size = 12
    0x4A, 0x58, 0x4C, 0x20,       // 'JXL '
    0x0D, 0x0A, 0x87, 0x0A        // codestream marker
]

/// The 2-byte naked-codestream signature.
public let jxlCodestreamSignature: [UInt8] = [0xFF, 0x0A]

/// Whether `data` looks like a JXL byte stream (either naked codestream
/// or ISOBMFF container).
public func isJXL(_ data: Data) -> Bool {
    if data.count >= 2 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0x0A {
        return true
    }
    if data.count >= 12 {
        for i in 0..<12 where data[data.startIndex + i] != jxlContainerSignature[i] {
            return false
        }
        return true
    }
    return false
}

public enum JXLContainerForm: Sendable, Equatable {
    /// Naked codestream — the entire file IS the codestream.
    case naked
    /// ISOBMFF container with a list of boxes.
    case iso(boxes: [JXLBox])
}

/// Parse a JXL byte stream into either a naked codestream or a list of
/// ISOBMFF boxes. Does not validate codestream contents.
public func parseJXLContainer(_ data: Data) throws -> JXLContainerForm {
    guard data.count >= 2 else {
        throw ContainerError.truncated("file too small to be JXL")
    }

    // Naked codestream?
    if data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0x0A {
        return .naked
    }

    // ISOBMFF: must start with the 12-byte signature box.
    guard data.count >= 12 else {
        throw ContainerError.missingSignature
    }
    for i in 0..<12 where data[data.startIndex + i] != jxlContainerSignature[i] {
        throw ContainerError.missingSignature
    }

    var cursor = 12
    var boxes: [JXLBox] = []
    while cursor < data.count {
        guard cursor + 8 <= data.count else {
            throw ContainerError.truncated("partial box header at offset \(cursor)")
        }
        let sizeRaw = uint32BigEndian(data, offset: cursor)
        let typeBytes = data.subdata(in: (cursor + 4)..<(cursor + 8))
        guard let type = String(data: typeBytes, encoding: .ascii) else {
            throw ContainerError.malformedBox("non-ASCII box type at offset \(cursor)")
        }
        let payloadStart: Int
        let boxEnd: Int
        switch sizeRaw {
        case 0:
            // Extends to end of file.
            payloadStart = cursor + 8
            boxEnd = data.count
        case 1:
            // 8-byte extended size follows.
            guard cursor + 16 <= data.count else {
                throw ContainerError.truncated("extended-size box header at offset \(cursor)")
            }
            let extSize = uint64BigEndian(data, offset: cursor + 8)
            guard extSize >= 16 && extSize <= UInt64(Int.max) else {
                throw ContainerError.unsupportedExtendedSize
            }
            payloadStart = cursor + 16
            boxEnd = cursor + Int(extSize)
        default:
            guard sizeRaw >= 8 else {
                throw ContainerError.malformedBox("size \(sizeRaw) < 8 at offset \(cursor)")
            }
            payloadStart = cursor + 8
            boxEnd = cursor + Int(sizeRaw)
        }
        guard boxEnd <= data.count else {
            throw ContainerError.truncated("box '\(type)' extends past EOF")
        }
        boxes.append(JXLBox(type: type, payloadRange: payloadStart..<boxEnd))
        cursor = boxEnd
    }
    return .iso(boxes: boxes)
}

/// Locate and concatenate the codestream from a parsed container.
/// Looks for a single `jxlc` box or a sequence of `jxlp` partials.
public func extractCodestream(from boxes: [JXLBox], in data: Data) throws -> Data {
    if let jxlc = boxes.first(where: { $0.type == "jxlc" }) {
        return data.subdata(in: jxlc.payloadRange)
    }
    let partials = boxes.filter { $0.type == "jxlp" }
    guard !partials.isEmpty else {
        throw ContainerError.malformedBox("container has no jxlc or jxlp box")
    }
    // Each `jxlp` payload begins with a 4-byte big-endian sequence number;
    // the high bit (0x8000_0000) indicates the final partial. Sort by
    // sequence and concatenate the rest.
    var ordered: [(seq: UInt32, range: Range<Int>, last: Bool)] = []
    for box in partials {
        guard box.payloadRange.count >= 4 else {
            throw ContainerError.malformedBox("jxlp box too small")
        }
        let raw = uint32BigEndian(data, offset: box.payloadRange.lowerBound)
        let seq = raw & 0x7FFF_FFFF
        let last = (raw & 0x8000_0000) != 0
        let payload = (box.payloadRange.lowerBound + 4)..<box.payloadRange.upperBound
        ordered.append((seq, payload, last))
    }
    ordered.sort { $0.seq < $1.seq }
    var combined = Data()
    for (_, range, _) in ordered {
        combined.append(data.subdata(in: range))
    }
    return combined
}

/// Find an ISOBMFF metadata box of the given 4-character type
/// (`Exif`, `xml `, `jumb`, etc.) in a parsed JXL container,
/// transparently unwrapping `brob` (Brotli-compressed box) wrappers
/// when the box is stored compressed.
///
/// `brob` payload layout (libjxl `BrotliBoxes`):
/// ```
///   4 bytes:    original box type (e.g. "Exif")
///   N bytes:    Brotli-compressed contents of the original box's
///               payload
/// ```
///
/// Returns the decompressed payload bytes when found, or `nil` if
/// no box of that type (either direct or inside a brob wrapper)
/// exists in the container.
///
/// **Status (v0.12.0gj).** Handles direct boxes + brob-wrapped boxes
/// for the uncompressed-Brotli case. Compressed-Brotli brob payloads
/// throw `notImplemented` (consistent with `BrotliDecoder`).
public func extractMetadataBox(
    type wantedType: String,
    from boxes: [JXLBox], in data: Data
) throws -> Data? {
    // Direct box match.
    if let box = boxes.first(where: { $0.type == wantedType }) {
        return data.subdata(in: box.payloadRange)
    }
    // brob-wrapped box match.
    let brobBoxes = boxes.filter { $0.type == "brob" }
    for brob in brobBoxes {
        guard brob.payloadRange.count >= 4 else { continue }
        let typeBytes = data.subdata(
            in: brob.payloadRange.lowerBound
                ..< (brob.payloadRange.lowerBound + 4))
        guard let innerType = String(
            data: typeBytes, encoding: .ascii)
        else { continue }
        if innerType == wantedType {
            let brotliPayload = data.subdata(
                in: (brob.payloadRange.lowerBound + 4)
                    ..< brob.payloadRange.upperBound)
            // Decompress.
            return try BrotliDecoder.decode(brotliPayload)
        }
    }
    return nil
}

/// Extract the `jbrd` (JPEG Bitstream Reconstruction Data) box
/// payload from an ISOBMFF JXL container.
///
/// The `jbrd` box is optional — it only appears when the JXL was
/// produced by a JPEG-bridge encoder that wanted to preserve enough
/// metadata for byte-identical reverse transcoding to JPEG.
///
/// - Returns: the payload bytes of the `jbrd` box, or `nil` when
///   the container has no such box.
/// - Throws: `ContainerError.malformedBox` if multiple `jbrd` boxes
///   are present (the format allows at most one).
public func extractJBRDBox(from boxes: [JXLBox], in data: Data)
    throws -> Data?
{
    let jbrdBoxes = boxes.filter { $0.type == "jbrd" }
    guard let jbrd = jbrdBoxes.first else { return nil }
    if jbrdBoxes.count > 1 {
        throw ContainerError.malformedBox(
            "container has \(jbrdBoxes.count) jbrd boxes "
            + "(at most one allowed)")
    }
    return data.subdata(in: jbrd.payloadRange)
}

/// Build an ISOBMFF container around a single codestream payload.
/// Emits: signature box → `ftyp` box → `jxlc` box. Suitable for files
/// that don't need split partials, EXIF, JPEG-reconstruct, etc.
public func buildJXLContainer(codestream: Data) -> Data {
    var out = Data()
    out.append(contentsOf: jxlContainerSignature)
    // ftyp box: major = 'jxl ', minor = 0, compat = 'jxl '
    let ftypPayload: [UInt8] = [
        0x6A, 0x78, 0x6C, 0x20,  // major 'jxl '
        0x00, 0x00, 0x00, 0x00,  // minor 0
        0x6A, 0x78, 0x6C, 0x20   // compat 'jxl '
    ]
    out.append(box(type: "ftyp", payload: Data(ftypPayload)))
    out.append(box(type: "jxlc", payload: codestream))
    return out
}

/// Pack `payload` into an ISOBMFF box of `type`.
/// Uses 32-bit size for boxes ≤ 2^32-9 bytes; extended-size otherwise.
private func box(type: String, payload: Data) -> Data {
    precondition(type.count == 4, "box type must be 4 ASCII chars")
    var data = Data()
    let total = 8 + payload.count
    if total < 0xFFFF_FFFF {
        data.append(contentsOf: uint32BE(UInt32(total)))
        data.append(type.data(using: .ascii)!)
    } else {
        data.append(contentsOf: uint32BE(1))
        data.append(type.data(using: .ascii)!)
        data.append(contentsOf: uint64BE(UInt64(16 + payload.count)))
    }
    data.append(payload)
    return data
}

@inline(__always)
private func uint32BigEndian(_ data: Data, offset: Int) -> UInt32 {
    let b0 = UInt32(data[data.startIndex + offset])
    let b1 = UInt32(data[data.startIndex + offset + 1])
    let b2 = UInt32(data[data.startIndex + offset + 2])
    let b3 = UInt32(data[data.startIndex + offset + 3])
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

@inline(__always)
private func uint64BigEndian(_ data: Data, offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 {
        value = (value << 8) | UInt64(data[data.startIndex + offset + i])
    }
    return value
}

@inline(__always)
private func uint32BE(_ value: UInt32) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
}

@inline(__always)
private func uint64BE(_ value: UInt64) -> [UInt8] {
    var v = value
    var out = [UInt8](repeating: 0, count: 8)
    for i in (0..<8).reversed() {
        out[i] = UInt8(v & 0xFF)
        v >>= 8
    }
    return out
}
