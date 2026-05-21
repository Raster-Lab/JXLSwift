// IdentityTransform — the IDENTITY ("hornuss") VarDCT transform.
//
// IDENTITY (AC strategy 1) encodes an 8×8 cell almost without a
// frequency transform: the cell is split into four 4×4 quadrants,
// each carrying a 2×2-DCT-combined block DC plus 15 spatial
// residuals. It is selected by the encoder for blocky / flat-ish
// content where a full DCT would waste bits.
//
// Direct port of libjxl `dec_transforms-inl.h::TransformToPixels`
// `case Type::IDENTITY`. Spec: ISO/IEC 18181-1 §K.9.
//
// There is no `ComputeScaledDCT`/`IDCT` step here, so — unlike the
// DCT strategies — the coefficient block needs no transpose.

import Foundation

public enum IdentityTransform {

    /// Inverse IDENTITY transform: a dequantised 8×8 coefficient
    /// block → an 8×8 row-major pixel block.
    ///
    /// `coefficients` is the 64-entry dequantised block (DC at
    /// index 0, residuals elsewhere). Returns 64 row-major pixels.
    public static func transformToPixels(_ coefficients: [Float]) -> [Float] {
        precondition(coefficients.count == 64,
                     "IDENTITY transform needs a 64-entry block")
        var pixels = [Float](repeating: 0, count: 64)
        let stride = 8

        // The four quadrant DCs come from a 2×2 DCT of the
        // top-left 2×2 coefficients.
        let block00 = coefficients[0]
        let block01 = coefficients[1]
        let block10 = coefficients[8]
        let block11 = coefficients[9]
        let dcs: [Float] = [
            block00 + block01 + block10 + block11,
            block00 + block01 - block10 - block11,
            block00 - block01 + block10 - block11,
            block00 - block01 - block10 + block11,
        ]

        for y in 0..<2 {
            for x in 0..<2 {
                let blockDC = dcs[y * 2 + x]
                // Sum of the quadrant's 15 non-DC residuals.
                var residualSum: Float = 0
                for iy in 0..<4 {
                    for ix in 0..<4 {
                        if ix == 0 && iy == 0 { continue }
                        residualSum +=
                            coefficients[(y + iy * 2) * 8 + x + ix * 2]
                    }
                }
                // The quadrant centre pixel carries the DC minus the
                // mean residual.
                let center = blockDC - residualSum * (1.0 / 16.0)
                pixels[(4 * y + 1) * stride + 4 * x + 1] = center
                // Every other pixel is its residual plus the centre.
                for iy in 0..<4 {
                    for ix in 0..<4 {
                        if ix == 1 && iy == 1 { continue }
                        pixels[(y * 4 + iy) * stride + x * 4 + ix] =
                            coefficients[(y + iy * 2) * 8 + x + ix * 2]
                            + center
                    }
                }
                // The quadrant's (0,0) pixel uses a different
                // coefficient slot (libjxl re-uses [(y+2)*8+x+2]).
                pixels[y * 4 * stride + x * 4] =
                    coefficients[(y + 2) * 8 + x + 2] + center
            }
        }
        return pixels
    }
}
