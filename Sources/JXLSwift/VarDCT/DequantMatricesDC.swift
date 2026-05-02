// DequantMatricesDC — VarDCT's DC-coefficient dequantisers.
//
// One float per channel (3 total). Multiplies the integer DC
// value out of the modular sub-image by the per-channel
// `dc_quant` scale to produce a float DC amplitude. Bitstream:
// 1-bit `all_default` flag, then 3 `F16` floats if not default.
//
// Spec: ISO/IEC 18181-1 §K.7.3. libjxl: `lib/jxl/quant_weights.cc::
// DequantMatrices::DecodeDC`.
//
// **Status**: parser-only. The full DequantMatrices.Decode (the
// AC quant matrices) is the much larger sibling that comes after.

import Foundation

public struct DequantMatricesDC: Sendable {
    /// Per-channel DC quant scale. libjxl multiplies the F16 read
    /// value by `1.0f / 128.0f`; the default values are
    /// `[1.0/128, 1.0/128, 1.0/128]` (no per-channel adjustment).
    public var dcQuant: (Float, Float, Float)

    public init(dcQuant: (Float, Float, Float) = (1.0 / 128, 1.0 / 128, 1.0 / 128)) {
        self.dcQuant = dcQuant
    }

    /// Reciprocals — what callers actually multiply by during DC
    /// dequantisation. Cached so `[Float]` and `[Float]` aren't
    /// computed per-pixel.
    public var invDcQuant: (Float, Float, Float) {
        return (1.0 / dcQuant.0, 1.0 / dcQuant.1, 1.0 / dcQuant.2)
    }

    public static func read(from r: inout BitReader) throws -> DequantMatricesDC {
        let allDefault: Bool
        do { allDefault = try r.readBit() }
        catch let e as BitstreamError {
            throw DequantMatricesDCError.bitstream(e)
        }
        if allDefault {
            return DequantMatricesDC()
        }
        var values: (Float, Float, Float) = (0, 0, 0)
        for c in 0..<3 {
            let bits16: UInt32
            do { bits16 = try r.read(bits: 16) }
            catch let e as BitstreamError {
                throw DequantMatricesDCError.bitstream(e)
            }
            let f = halfToFloat(UInt16(bits16)) * (1.0 / 128.0)
            // libjxl rejects subnormal/zero: dc_quant must be > kAlmostZero.
            guard f > 1e-8 else {
                throw DequantMatricesDCError.invalidDcQuant(c, value: f)
            }
            switch c {
            case 0: values.0 = f
            case 1: values.1 = f
            default: values.2 = f
            }
        }
        return DequantMatricesDC(dcQuant: values)
    }
}

public enum DequantMatricesDCError: Error, Sendable {
    case bitstream(BitstreamError)
    case invalidDcQuant(Int, value: Float)
}

/// `DequantMatrices.Decode` — the AC quant matrices for all 17
/// strategies. libjxl reads a 1-bit `all_default` flag; when set,
/// every strategy uses its `QuantEncoding::Library<0>()` predefined
/// table (the spec-default parametric distance bands lifted in
/// `DefaultQuantBands`). When clear, 17 sequential `QuantEncoding`
/// blobs follow, each with one of 8 quant modes — the dominant
/// piece of section-0 bitstream complexity.
///
/// **Status**: all-default reader + `notDefault` throw for the
/// long-form path. Per-strategy `QuantEncoding` parsing lives at
/// the next session-sized bite.
public enum DequantMatricesAC {

    /// Read the 1-bit `all_default` flag. Returns `true` if every
    /// AC strategy uses its library default; throws `notDefault`
    /// otherwise.
    public static func readDefaultOrThrow(
        from r: inout BitReader
    ) throws -> Bool {
        let allDefault: Bool
        do { allDefault = try r.readBit() }
        catch let e as BitstreamError {
            throw DequantMatricesACError.bitstream(e)
        }
        if allDefault { return true }
        throw DequantMatricesACError.notDefault
    }
}

public enum DequantMatricesACError: Error, Sendable {
    case bitstream(BitstreamError)
    case notDefault
}
