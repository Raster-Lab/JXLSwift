// BitDepth — sample format declaration.
//
// ISO/IEC 18181-1 §C.3.5. Encodes whether samples are integers (with
// `bits_per_sample` bits, 1…32) or IEEE 754 floating-point (with
// `bits_per_sample` total bits and `exponent_bits_per_sample` of those
// in the exponent field).
//
// Bit-level layout (per the spec):
//   floating_point_sample : 1 bit
//   if floating_point:
//       bits_per_sample          U32(32, 16, 24, u(6) + 1)   range 1…64
//       exponent_bits_per_sample U32(8, 5, 10, u(4) + 1)
//   else (integer):
//       bits_per_sample          U32(8, 10, 12, u(6) + 1)    range 1…64
//
// (libjxl additionally enforces that floating point ⇒ exponent_bits ≥ 2.)

import Foundation

public struct BitDepth: Sendable, Equatable {
    /// True for IEEE-754 sample format; false for unsigned integer.
    public let floatingPoint: Bool
    /// Total bit width per sample. 1 ≤ bits ≤ 32 in practice.
    public let bitsPerSample: UInt32
    /// Number of exponent bits (only meaningful when `floatingPoint`).
    public let exponentBitsPerSample: UInt32

    public init(floatingPoint: Bool, bitsPerSample: UInt32, exponentBitsPerSample: UInt32 = 0) {
        self.floatingPoint = floatingPoint
        self.bitsPerSample = bitsPerSample
        self.exponentBitsPerSample = exponentBitsPerSample
    }

    /// The default for files that don't override: 8-bit unsigned integer.
    public static let standard = BitDepth(
        floatingPoint: false, bitsPerSample: 8, exponentBitsPerSample: 0
    )

    /// U32 distribution for the exponent field of a float `BitDepth`.
    /// Spec §C.3.5: `(literal(2), literal(5), literal(10), 7 + u(4))`.
    /// The named selectors are uncommon exponent values (2 bits,
    /// 5 bits = float16, 10 bits = some custom). Selector 3 is the
    /// general path covering 7..22 and is what cjxl uses for the
    /// most common case (float32 with 8 exponent bits, encoded as
    /// `7 + u(4) = 7+1 = 8`).
    private static let expDistribution: (UInt32Distribution, UInt32Distribution,
                                         UInt32Distribution, UInt32Distribution) = (
        .literal(2), .literal(5), .literal(10),
        .offset(constant: 7, extraBits: 4)
    )

    public static func read(from r: inout BitReader) throws -> BitDepth {
        let isFloat = try r.readBit()
        if isFloat {
            let bps = try r.readU32((
                .literal(32), .literal(16), .literal(24),
                .offset(constant: 1, extraBits: 6)
            ))
            let exp = try r.readU32(expDistribution)
            return BitDepth(floatingPoint: true, bitsPerSample: bps, exponentBitsPerSample: exp)
        } else {
            let bps = try r.readU32((
                .literal(8), .literal(10), .literal(12),
                .offset(constant: 1, extraBits: 6)
            ))
            return BitDepth(floatingPoint: false, bitsPerSample: bps, exponentBitsPerSample: 0)
        }
    }

    public func write(to w: inout BitWriter) throws {
        w.writeBit(floatingPoint)
        if floatingPoint {
            try w.writeU32(bitsPerSample, distributions: (
                .literal(32), .literal(16), .literal(24),
                .offset(constant: 1, extraBits: 6)
            ))
            try w.writeU32(exponentBitsPerSample, distributions: BitDepth.expDistribution)
        } else {
            try w.writeU32(bitsPerSample, distributions: (
                .literal(8), .literal(10), .literal(12),
                .offset(constant: 1, extraBits: 6)
            ))
        }
    }
}
