// AdjustQuantBias — per-coefficient bias for AC dequantisation.
//
// libjxl applies a small per-coefficient bias to quantised AC
// integers BEFORE multiplying by the dequant matrix. The bias
// compensates for the fact that integer quantisation maps a
// continuous range of source values to a single integer; the
// "best guess" reverse value isn't exactly the integer itself
// but a slightly biased estimate based on the modelled
// coefficient distribution (`1/(1+x²)`-like).
//
// libjxl decision tree (per `quantizer-inl.h::AdjustQuantBias`):
//
//     |q| == 0:  return 0
//     |q| == 1:  return ±biases[c]            (sign of q)
//     |q| >= 2:  return q − biases[3] / q
//
// The decoder's `biases[0..2]` are the per-channel `|q| == 1`
// values from libjxl `kDefaultQuantBias` (`image_metadata.cc`
// seeds `opsin_params.quant_biases` from this array, and the
// bitstream does not override it for LIBRARY-mode fixtures);
// `biases[3]` is the bias *numerator* (`0.145`). These are NOT
// the encoder-side `kZeroBiasDefault = {0.5, 0.5, 0.5}`
// thresholds — that array drives `enc_group.cc` quantisation
// thresholds, not the decoder's dequant bias. (Verified against
// an instrumented djxl 0.11.2 `DequantLane` trace.)
//
// Spec: ISO/IEC 18181-1 §F.2.4 and §K.7. libjxl:
// `lib/jxl/quantizer.h::kDefaultQuantBias`,
// `lib/jxl/quantizer-inl.h::AdjustQuantBias`.

import Foundation

public enum AdjustQuantBias {

    /// Per-XYB-channel `|q| == 1` dequant bias — libjxl
    /// `quantizer.h::kDefaultQuantBias[0..2]`. Indexed by XYB
    /// channel (0=X, 1=Y, 2=B).
    public static let kDefaultQuantBias: [Float] = [
        1.0 - 0.05465007330715401,    // X → 0.94534992…
        1.0 - 0.07005449891748593,    // Y → 0.92994550…
        1.0 - 0.049935103337343655,   // B → 0.95006490…
    ]

    /// Per-XYB-channel zero bias (libjxl `kZeroBiasDefault`) —
    /// the *encoder*-side quantisation threshold. Kept for
    /// reference; the decoder dequant uses `kDefaultQuantBias`.
    public static let kZeroBiasDefault: [Float] = [0.5, 0.5, 0.5]

    /// Bias numerator for `|q| >= 2` (libjxl `kBiasNumerator`).
    public static let kBiasNumerator: Float = 0.145

    /// Apply libjxl-style quant bias to a single integer
    /// quantised AC coefficient. `channel` is the XYB channel
    /// (0=X, 1=Y, 2=B). The returned float is what callers
    /// should multiply by the dequant matrix entry, in place
    /// of `Float(quant)`.
    @inlinable
    public static func adjust(
        channel: Int, quant: Int32,
        zeroBias: [Float] = kDefaultQuantBias,
        biasNumerator: Float = kBiasNumerator
    ) -> Float {
        if quant == 0 { return 0 }
        let absQ = quant < 0 ? -quant : quant
        if absQ == 1 {
            return quant > 0 ? zeroBias[channel] : -zeroBias[channel]
        }
        let qf = Float(quant)
        return qf - biasNumerator / qf
    }
}
