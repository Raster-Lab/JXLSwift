// Spec-defined variable-width integer codings used throughout the
// JPEG XL bitstream.
//
// The JXL bitstream layer in ISO/IEC 18181-1 §C.2 introduces two
// patterns — `U32(d0, d1, d2, d3)` and `U64()` — that wrap a small
// number of distributions over an integer field. Header fields like
// `xsize` / `ysize` / `bits_per_sample` use these to balance the
// common case (small numbers, few bits) against the rare case (full
// 32- or 64-bit values).

import Foundation

extension BitReader {

    /// Decode a `U32(d0, d1, d2, d3)` value as defined in ISO/IEC
    /// 18181-1 §C.2.4.  Reads a 2-bit selector, then either a literal
    /// constant `dN[0]` or `dN[0] + read(bits: dN[1])`.
    ///
    /// `distributions` is a 4-element array of `(constant, extra_bits)`
    /// pairs. Selector `i` returns `constant_i + read(extra_bits_i)`.
    public mutating func readU32(_ distributions: (
        UInt32Distribution, UInt32Distribution, UInt32Distribution, UInt32Distribution
    )) throws -> UInt32 {
        let selector = try read(bits: 2)
        let dist: UInt32Distribution
        switch selector {
        case 0: dist = distributions.0
        case 1: dist = distributions.1
        case 2: dist = distributions.2
        case 3: dist = distributions.3
        default: throw BitstreamError.malformedValue("U32 selector > 3")
        }
        let extra = dist.extraBits == 0 ? 0 : try read(bits: dist.extraBits)
        return dist.constant &+ extra
    }

    /// Decode a `U64()` value as defined in ISO/IEC 18181-1 §C.2.5.
    /// Selector cases:
    ///   0 → 0
    ///   1 → 1 + read(4 bits)
    ///   2 → 17 + read(8 bits)
    ///   3 → read(12 bits) + chunks of (read(1)? read(8) shift up : stop)
    ///         until the continuation bit is zero.
    public mutating func readU64() throws -> UInt64 {
        let selector = try read(bits: 2)
        switch selector {
        case 0: return 0
        case 1: return 1 + UInt64(try read(bits: 4))
        case 2: return 17 + UInt64(try read(bits: 8))
        case 3:
            var value = UInt64(try read(bits: 12))
            var shift = 12
            while try readBit() {
                if shift + 8 > 64 {
                    throw BitstreamError.malformedValue("U64 exceeds 64 bits")
                }
                let chunk = UInt64(try read(bits: 8))
                value |= chunk &<< UInt64(shift)
                shift += 8
            }
            return value
        default:
            throw BitstreamError.malformedValue("U64 selector > 3")
        }
    }

    /// Decode an enum from the spec's "Enum()" pattern (ISO/IEC 18181-1
    /// §C.2.6 — see also libjxl `Visitor::Enum`): `U32(0, 1, 2+u(4),
    /// 18+u(6))`. The four selector cases:
    ///
    ///   • `00`        → 0           (kUnknown / first reserved value)
    ///   • `01`        → 1           (most common — usually default value)
    ///   • `10xxxx`    → 2..17       (general path for medium values)
    ///   • `11yyyyyy`  → 18..81      (extended path for higher enum values)
    ///
    /// This is what carries values like TransferFunction.HLG (=18) and
    /// .DCI-P3 (=17) which a `1+u(4)` distribution cannot reach.
    public mutating func readEnum() throws -> UInt32 {
        try readU32((
            .literal(0), .literal(1),
            .offset(constant: 2, extraBits: 4),
            .offset(constant: 18, extraBits: 6)
        ))
    }
}

extension BitWriter {

    /// Encode a `U32(d0, d1, d2, d3)` value. Picks the lowest selector
    /// whose distribution can represent `value` exactly; throws if no
    /// distribution can.
    public mutating func writeU32(
        _ value: UInt32,
        distributions: (UInt32Distribution, UInt32Distribution, UInt32Distribution, UInt32Distribution)
    ) throws {
        let dists = [distributions.0, distributions.1, distributions.2, distributions.3]
        for (i, d) in dists.enumerated() {
            if let extra = d.encode(value) {
                write(bits: 2, value: UInt32(i))
                if d.extraBits > 0 { write(bits: d.extraBits, value: extra) }
                return
            }
        }
        throw BitstreamError.malformedValue("U32 value \(value) does not fit any distribution")
    }

    /// Encode an enum value via the spec's "Enum()" pattern (ISO/IEC
    /// 18181-1 §C.2.6 — see also libjxl `Visitor::Enum`):
    /// `U32(0, 1, 2+u(4), 18+u(6))`. Reachable range is 0..81. Throws
    /// `BitstreamError.malformedValue` for values outside that range.
    public mutating func writeEnum(_ value: UInt32) throws {
        try writeU32(value, distributions: (
            .literal(0), .literal(1),
            .offset(constant: 2, extraBits: 4),
            .offset(constant: 18, extraBits: 6)
        ))
    }

    /// Encode a `U64()` value (ISO/IEC 18181-1 §C.2.5).
    public mutating func writeU64(_ value: UInt64) {
        if value == 0 {
            write(bits: 2, value: 0)
        } else if value >= 1 && value <= 16 {
            write(bits: 2, value: 1)
            write(bits: 4, value: UInt32(value - 1))
        } else if value >= 17 && value <= 272 {
            write(bits: 2, value: 2)
            write(bits: 8, value: UInt32(value - 17))
        } else {
            write(bits: 2, value: 3)
            write(bits: 12, value: UInt32(value & 0xFFF))
            var shift: UInt64 = 12
            var v = value &>> 12
            while v > 0 {
                writeBit(true)
                write(bits: 8, value: UInt32(v & 0xFF))
                v &>>= 8
                shift += 8
            }
            writeBit(false)
            _ = shift
        }
    }
}

/// One of the four distributions in a `U32(d0, d1, d2, d3)` field.
public struct UInt32Distribution: Sendable, Equatable {
    /// Base constant added to `extraBits` of variable.
    public let constant: UInt32
    /// Number of additional bits read (0 → `value == constant`).
    public let extraBits: Int

    /// Produce a fixed-value distribution (no extra bits).
    public static func literal(_ value: UInt32) -> Self {
        Self(constant: value, extraBits: 0)
    }
    /// Distribution emitting `constant + read(extraBits)`.
    public static func offset(constant: UInt32, extraBits: Int) -> Self {
        Self(constant: constant, extraBits: extraBits)
    }
    /// Distribution emitting `read(bits)` directly (no offset).
    public static func bits(_ count: Int) -> Self {
        Self(constant: 0, extraBits: count)
    }

    /// If `value` is encodable in this distribution, return the extra
    /// bits to write; otherwise return nil.
    func encode(_ value: UInt32) -> UInt32? {
        if extraBits == 0 {
            return value == constant ? 0 : nil
        }
        if value < constant { return nil }
        let offset = value - constant
        let max: UInt32 = (1 &<< UInt32(extraBits)) &- 1
        if offset > max { return nil }
        return offset
    }
}
