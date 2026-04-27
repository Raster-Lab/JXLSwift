// SizeHeader — encodes the image's xsize and ysize.
//
// ISO/IEC 18181-1 §C.3.2. After the 2-byte signature, the codestream
// begins with a SizeHeader. Two encodings:
//
//   • "small" mode (1 bit = 1): two 5-bit values shifted up by 3 +
//     constant — produces sizes 8, 16, 24, …, 256 (multiples of 8).
//   • "large" mode (1 bit = 0): a 2-bit "div8" selector plus a U32
//     for both ysize and xsize.
//
// Plus an optional aspect-ratio mode where `xsize` is derived from
// `ysize` via a 3-bit ratio code.

import Foundation

public struct SizeHeader: Sendable, Equatable {
    /// Decoded width.  1 ≤ xsize ≤ 2^30 (per spec §C.3.2).
    public let xsize: UInt32
    /// Decoded height. 1 ≤ ysize ≤ 2^30.
    public let ysize: UInt32

    public init(xsize: UInt32, ysize: UInt32) {
        precondition(xsize > 0 && ysize > 0, "size must be positive")
        self.xsize = xsize
        self.ysize = ysize
    }

    /// Read a SizeHeader from a bit reader positioned just after the
    /// codestream signature.
    public static func read(from reader: inout BitReader) throws -> SizeHeader {
        let small = try reader.readBit()
        if small {
            // Small mode: ysize_div8 = u(5) + 1 (range 1…32 → 8…256).
            let yDiv8 = try reader.read(bits: 5)
            let ysize = (yDiv8 + 1) &* 8
            // Aspect-ratio code (3 bits), 0 means "explicit xsize".
            let ratio = try reader.read(bits: 3)
            let xsize: UInt32
            if ratio == 0 {
                let xDiv8 = try reader.read(bits: 5)
                xsize = (xDiv8 + 1) &* 8
            } else {
                xsize = try aspectXsize(ysize: ysize, ratio: ratio)
            }
            return SizeHeader(xsize: xsize, ysize: ysize)
        } else {
            // Large mode: 2-bit ysize_div8 selector + U32, then ratio + xsize.
            let ysize = try readSizeField(&reader)
            let ratio = try reader.read(bits: 3)
            let xsize: UInt32
            if ratio == 0 {
                xsize = try readSizeField(&reader)
            } else {
                xsize = try aspectXsize(ysize: ysize, ratio: ratio)
            }
            return SizeHeader(xsize: xsize, ysize: ysize)
        }
    }

    /// Write a SizeHeader. Picks small mode when both dimensions are
    /// multiples of 8 in 8…256 — that's the encoding cjxl uses, and
    /// keeps the bytes compact + (apparently) more spec-pedantic
    /// for downstream tools. Otherwise falls back to large mode.
    public func write(to writer: inout BitWriter) throws {
        let canSmall = ysize >= 8 && ysize <= 256 && ysize % 8 == 0
                     && xsize >= 8 && xsize <= 256 && xsize % 8 == 0
        if canSmall {
            writer.writeBit(true)                         // small_pic = 1
            writer.write(bits: 5, value: (ysize / 8) - 1)
            // Aspect-ratio code: 0 for explicit, 1 for square. Use
            // square shortcut when xsize == ysize to match cjxl.
            if xsize == ysize {
                writer.write(bits: 3, value: 1)           // square
            } else {
                writer.write(bits: 3, value: 0)           // explicit
                writer.write(bits: 5, value: (xsize / 8) - 1)
            }
            return
        }
        writer.writeBit(false) // large mode
        try writeSizeField(&writer, value: ysize)
        writer.write(bits: 3, value: 0) // explicit xsize follows
        try writeSizeField(&writer, value: xsize)
    }
}

/// Per-spec aspect-ratio table for "ratio != 0" sizes (§C.3.2).
private let aspectRatios: [(num: UInt32, den: UInt32)] = [
    (0, 0),       // 0 — explicit xsize, never used here
    (1, 1),       // 1 — square
    (12, 10),     // 2
    (4, 3),       // 3
    (3, 2),       // 4
    (16, 9),      // 5
    (5, 4),       // 6
    (2, 1)        // 7
]

private func aspectXsize(ysize: UInt32, ratio: UInt32) throws -> UInt32 {
    guard ratio >= 1 && ratio <= 7 else {
        throw BitstreamError.malformedValue("aspect ratio code out of range: \(ratio)")
    }
    let r = aspectRatios[Int(ratio)]
    let prod = UInt64(ysize) &* UInt64(r.num)
    return UInt32(prod / UInt64(r.den))
}

/// Read a U32 size field used by SizeHeader. Spec §C.3.2 distributions:
///     U32(1+u(9), 1+u(13), 1+u(18), 1+u(30))
private func readSizeField(_ reader: inout BitReader) throws -> UInt32 {
    return try reader.readU32((
        .offset(constant: 1, extraBits: 9),
        .offset(constant: 1, extraBits: 13),
        .offset(constant: 1, extraBits: 18),
        .offset(constant: 1, extraBits: 30)
    ))
}

/// Inverse of `readSizeField`.
private func writeSizeField(_ writer: inout BitWriter, value: UInt32) throws {
    try writer.writeU32(value, distributions: (
        .offset(constant: 1, extraBits: 9),
        .offset(constant: 1, extraBits: 13),
        .offset(constant: 1, extraBits: 18),
        .offset(constant: 1, extraBits: 30)
    ))
}
