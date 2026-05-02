// QuantizerParams — VarDCT frame's global quantiser scale + DC
// quantiser. Two `U32`-encoded fields at the very start of the
// VarDCT DC global section.
//
// Spec: ISO/IEC 18181-1 §K.7.2. libjxl: `lib/jxl/quantizer.cc::
// Quantizer::Decode` + `QuantizerParams::VisitFields`.
//
// **Status**: parser-only. The encoder side will mirror this in
// the lossy-encode push.

import Foundation

public struct QuantizerParams: Sendable, Equatable {
    /// libjxl `global_scale`, a per-frame integer scaler that
    /// modulates every dequant weight uniformly. Range typically
    /// 1..2^16; default 1.
    public var globalScale: UInt32
    /// `quant_dc`, the DC-coefficient-specific quantiser. Default
    /// 16 (libjxl's `Val(16)` first selector).
    public var quantDC: UInt32

    public init(globalScale: UInt32 = 1, quantDC: UInt32 = 16) {
        self.globalScale = globalScale
        self.quantDC = quantDC
    }

    /// Parse one `QuantizerParams` from the current bit position.
    /// Mirrors libjxl `QuantizerParams::VisitFields` byte-for-byte:
    ///   • `global_scale` U32(1+u(11), 2049+u(11), 4097+u(12), 8193+u(16))
    ///   • `quant_dc`     U32(16, 1+u(5), 1+u(8), 1+u(16))
    public static func read(from r: inout BitReader) throws -> QuantizerParams {
        let gs: UInt32
        let qdc: UInt32
        do {
            gs = try r.readU32((
                .offset(constant: 1, extraBits: 11),
                .offset(constant: 2049, extraBits: 11),
                .offset(constant: 4097, extraBits: 12),
                .offset(constant: 8193, extraBits: 16)
            ))
            qdc = try r.readU32((
                .literal(16),
                .offset(constant: 1, extraBits: 5),
                .offset(constant: 1, extraBits: 8),
                .offset(constant: 1, extraBits: 16)
            ))
        } catch let e as BitstreamError {
            throw QuantizerParamsError.bitstream(e)
        }
        return QuantizerParams(globalScale: gs, quantDC: qdc)
    }

    public func write(to w: inout BitWriter) throws {
        do {
            try w.writeU32(globalScale, distributions: (
                .offset(constant: 1, extraBits: 11),
                .offset(constant: 2049, extraBits: 11),
                .offset(constant: 4097, extraBits: 12),
                .offset(constant: 8193, extraBits: 16)
            ))
            try w.writeU32(quantDC, distributions: (
                .literal(16),
                .offset(constant: 1, extraBits: 5),
                .offset(constant: 1, extraBits: 8),
                .offset(constant: 1, extraBits: 16)
            ))
        } catch let e as BitstreamError {
            throw QuantizerParamsError.bitstream(e)
        }
    }
}

public enum QuantizerParamsError: Error, Sendable {
    case bitstream(BitstreamError)
}
