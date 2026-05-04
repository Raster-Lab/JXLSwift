// ACQuantize — encoder-side per-block AC quantization.
//
// The bridge between forward DCT (`ComputeScaledDCT` → float
// coefficients in libjxl-transposed layout) and `ACEncoder.encodeBlock`
// (which tokenises Int32 quantized coefficients).
//
// Direct port of libjxl `enc_group.cc::QuantizeBlockAC`.
//
// libjxl's quantization formula:
//
//     val = coef[k] * weight[k] * Scale * quant * qm_multiplier
//     quantized[k] = round(val)
//
// where:
// - `coef[k]` is the post-DCT, post-CFL float coefficient.
// - `weight[k]` is the per-coefficient quant weight (= libjxl
//   `InvDequantMatrix(c, k)` = `1 / dequant_matrix[k]`).
// - `Scale` = `global_scale / 65536` (the encoder's reciprocal of
//   the decoder's `inv_global_scale`).
// - `quant` is the per-block quantization factor (the QF stored in
//   ACMeta channel 2 of the bitstream).
// - `qm_multiplier` is per-channel: `1.0` for Y, `enc_state->x_qm_multiplier`
//   for X, `enc_state->b_qm_multiplier` for B (defaults: 1.25 / 1.0,
//   inverse of the decoder's 0.8 / 1.0 `dm_multiplier`s such that
//   `qm_multiplier × dm_multiplier = 1` for round-trip identity).
//
// Chroma channels also apply a per-quadrant non-zero THRESHOLD:
// coefficients with `|val| < threshold` round to 0 (saves bits at
// minimal visual cost). Y channel never thresholds.
//
// Spec reference: ISO/IEC 18181-1 §K.7. libjxl: `lib/jxl/enc_group.cc`.

import Foundation

/// Encoder-side per-block AC quantization. Pure float-in,
/// `Int32`-out. The output is the input to `ACEncoder.encodeBlock`
/// (after CFL has been undone — see comment).
public enum ACQuantize {

    /// libjxl's default per-quadrant chroma thresholds for `c != 1`
    /// (X and B). The 4 entries correspond to the 4 quadrants of
    /// an 8×8 block in raster order. Y channel uses `[0, 0, 0, 0]`
    /// (no thresholding — full precision retained).
    public static let kDefaultChromaThresholds: [Float] =
        [0.58, 0.62, 0.62, 0.62]

    /// Quantize one channel's worth of AC coefficients for an
    /// `xsize × ysize`-block strategy (in cell units, e.g.,
    /// `xsize=ysize=1` for DCT8x8, `xsize=ysize=2` for DCT16x16).
    ///
    /// - Parameters:
    ///   - blockIn: input float coefficients, length
    ///     `xsize * ysize * 64`. Layout: `block[y * 8*xsize + x]`
    ///     in libjxl convention (transposed for ROWS≥COLS strategies).
    ///     The DC position (block[0]) is preserved as-is in the
    ///     output (caller is responsible for handling DC separately
    ///     before calling this).
    ///   - weights: per-coefficient quant weights, same length as
    ///     `blockIn`. Typically `1 / qweights[k]` from
    ///     `QuantWeights.getQuantWeights`.
    ///   - quant: per-block quantization factor (QF + 1). Same as
    ///     decoder's `blockInvQuantAC` denominator.
    ///   - scale: encoder-side `Scale` = `global_scale / 65536`.
    ///   - qmMultiplier: per-channel multiplier (`1.0` for Y; libjxl
    ///     defaults `1.25` for X, `1.0` for B).
    ///   - thresholds: 4-quadrant non-zero thresholds. Pass
    ///     `[0, 0, 0, 0]` for Y (no thresholding).
    /// - Returns: `[Int32]` quantized coefficients, same length as
    ///   `blockIn`. AC positions are quantized; non-AC positions
    ///   (the LLF coefficients for multi-block strategies) are also
    ///   passed through the same formula — caller is responsible
    ///   for restoring DC if needed.
    public static func quantizeBlock(
        blockIn: [Float],
        weights: [Float],
        quant: Float, scale: Float, qmMultiplier: Float,
        xsize: Int, ysize: Int,
        thresholds: [Float] = [0, 0, 0, 0]
    ) -> [Int32] {
        let size = xsize * ysize * 64
        precondition(blockIn.count == size,
                     "blockIn length must equal xsize*ysize*64")
        precondition(weights.count == size,
                     "weights length must match blockIn")
        precondition(thresholds.count == 4, "thresholds is 4 quadrants")
        precondition(xsize >= 1 && ysize >= 1)

        var out = [Int32](repeating: 0, count: size)
        let quantv = quant * scale * qmMultiplier
        let halfWidth = xsize * 4   // 4 cells per kBlockDim/2
        let halfHeight = ysize * 4
        let stride = xsize * 8

        for y in 0..<(ysize * 8) {
            // yfix: 0 for top half, 2 for bottom half (selects
            // thresholds[0..1] vs thresholds[2..3]).
            let yfix = y >= halfHeight ? 2 : 0
            for x in 0..<stride {
                let off = y * stride + x
                let q = weights[off] * quantv
                let val = q * blockIn[off]
                // Threshold: chroma channels zero out small
                // coefficients. Y channel passes threshold = 0 so
                // every non-zero value passes through.
                let thresholdIdx = yfix + (x >= halfWidth ? 1 : 0)
                let threshold = thresholds[thresholdIdx]
                if abs(val) < threshold {
                    out[off] = 0
                } else {
                    out[off] = Int32(val.rounded())
                }
            }
        }
        return out
    }
}
