// Dequantize — quant-weights → coefficient amplitudes.
//
// libjxl `dec_modular.cc` and the VarDCT pixel pipeline both walk
// per-coefficient quant *weights* alongside the dequantised
// integer coefficients to recover float DCT amplitudes. This file
// supplies just the multiply layer; the upstream call sites pull
// integer coefficients from the AC entropy stream and per-frame
// `quantizer_scale` from the frame header (we don't model that
// here yet — single-block tests pass a synthetic scale).
//
// Spec: ISO/IEC 18181-1 §K.7. libjxl: `lib/jxl/dequant_matrices.cc`,
// `lib/jxl/dec_xyb.cc`.

import Foundation

package enum Dequantize {

    /// Multiply per-coefficient `weights` (e.g. from
    /// `QuantWeights.getQuantWeights`) by integer `coefficients`
    /// and a global `scale` — the libjxl quantiser scale carried
    /// in the frame header. Returns float amplitudes ready for
    /// IDCT.
    ///
    /// `weights` is `rows × cols` for one channel (caller picks
    /// the channel's slice from the 3-channel table). `coefficients`
    /// is the same length as `weights`. Output has the same shape.
    package static func dequantize(
        coefficients: [Int32], weights: [Float],
        scale: Float
    ) -> [Float] {
        precondition(coefficients.count == weights.count,
                     "coefficients and weights must have same length")
        var out = [Float](repeating: 0, count: coefficients.count)
        for i in 0..<coefficients.count {
            // libjxl's per-coefficient amplitude:
            //     amp = quant_int * weight * scale
            // (the weight already encodes the inverse: smaller weight
            //  ⇒ coarser quantisation. Multiplying by `weight` here
            //  recovers the original DCT amplitude.)
            out[i] = Float(coefficients[i]) * weights[i] * scale
        }
        return out
    }

    /// Encoder-side inverse: divide DCT amplitudes by per-coefficient
    /// weights and a global scale, then round to the nearest
    /// integer. Mirrors libjxl `enc_quant_weights.cc::Quantize`.
    package static func quantize(
        amplitudes: [Float], weights: [Float], scale: Float
    ) -> [Int32] {
        precondition(amplitudes.count == weights.count)
        var out = [Int32](repeating: 0, count: amplitudes.count)
        for i in 0..<amplitudes.count {
            let q = amplitudes[i] / (weights[i] * scale)
            out[i] = Int32(q.rounded())
        }
        return out
    }
}
