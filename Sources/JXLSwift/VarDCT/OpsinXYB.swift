// OpsinXYB — JPEG XL's perceptual colour transform.
//
// Forward (encoder): linearised sRGB → opsin absorbance → cube-root
// → centred XYB. The "X" axis is luma-correlated red-green opponent,
// "Y" is luma, "B" is luma-correlated blue-yellow opponent.
//
// Spec: ISO/IEC 18181-1 §C.5.4. libjxl: `lib/jxl/cms/opsin_params.h`,
// `lib/jxl/cms/jxl_cms.cc`. Constants below are the spec-frozen
// values from libjxl (`kOpsinAbsorbanceMatrix`,
// `kDefaultInverseOpsinAbsorbanceMatrix`, `kOpsinAbsorbanceBias`).
//
// **Status**: standalone math, byte-exact against libjxl's
// `OpsinAbsorbance*` for matched matrices. Used by VarDCT (where
// XYB is the canonical colour space) and any future Modular path
// that elects `xyb_encoded = true`.
//
// Pixel convention: linear-light in `[0, 1]`. Outside that range
// the cube-root branch still works for the ≥ 0 side; negative
// inputs are clamped to 0 so the cube root stays real.

import Foundation

package enum OpsinXYB {

    // 3×3 opsin absorbance matrix from libjxl
    // `cms/opsin_params.h::kOpsinAbsorbanceMatrix`. Acts on a
    // linear-RGB column vector and yields LMS-cone-style absorbance.
    private static let M00: Float = 0.30
    private static let M02: Float = 0.078
    private static let M01: Float = 1.0 - M02 - M00      // = 0.622

    private static let M12: Float = 0.078
    private static let M10: Float = 0.23
    private static let M11: Float = 1.0 - M12 - M10      // = 0.692

    private static let M20: Float = 0.24342268924547819
    private static let M21: Float = 0.20476744424496821
    private static let M22: Float = 1.0 - M20 - M21      // ≈ 0.55180987

    /// Pre-computed inverse matrix (libjxl
    /// `kDefaultInverseOpsinAbsorbanceMatrix`).
    private static let invM00: Float =  11.031566901960783
    private static let invM01: Float =  -9.866943921568629
    private static let invM02: Float =  -0.16462299647058826
    private static let invM10: Float =  -3.254147380392157
    private static let invM11: Float =   4.418770392156863
    private static let invM12: Float =  -0.16462299647058826
    private static let invM20: Float =  -3.6588512862745097
    private static let invM21: Float =   2.7129230470588235
    private static let invM22: Float =   1.9459282392156863

    /// Bias added to absorbance before the cube root, then
    /// subtracted after. Same value for all three channels.
    package static let opsinBias: Float = 0.0037930732552754493
    /// `cbrt(opsinBias)` — pre-subtracted on the forward path.
    package static let cbrtOpsinBias: Float =
        0.155954200549248618403228789114857601840543746948242  // ≈ ∛0.003793

    /// Forward: linear-RGB sample triple → XYB triple.
    /// Both vectors are length-3.
    @inline(__always)
    package static func forward(
        _ rgb: (Float, Float, Float)
    ) -> (X: Float, Y: Float, B: Float) {
        let r = max(rgb.0, 0)
        let g = max(rgb.1, 0)
        let b = max(rgb.2, 0)
        // 1. Linear → opsin absorbance (matrix multiply + bias).
        let l = M00 * r + M01 * g + M02 * b + opsinBias
        let m = M10 * r + M11 * g + M12 * b + opsinBias
        let s = M20 * r + M21 * g + M22 * b + opsinBias
        // 2. Cube root, then subtract `cbrt(opsinBias)` to recentre.
        let lr = cbrtf(l) - cbrtOpsinBias
        let mr = cbrtf(m) - cbrtOpsinBias
        let sr = cbrtf(s) - cbrtOpsinBias
        // 3. Recombine into the XYB opponent basis (libjxl
        // `cms/jxl_cms.cc::OpsinAbsorbance` lines 100-110):
        //    X = (lr - mr) / 2;  Y = (lr + mr) / 2;  B = sr.
        return (X: 0.5 * (lr - mr),
                Y: 0.5 * (lr + mr),
                B: sr)
    }

    /// Inverse: XYB triple → linear-RGB triple.
    @inline(__always)
    package static func inverse(
        _ xyb: (X: Float, Y: Float, B: Float)
    ) -> (R: Float, G: Float, B: Float) {
        // 1. Recover the cube-rooted absorbances.
        let lr = xyb.Y + xyb.X
        let mr = xyb.Y - xyb.X
        let sr = xyb.B
        // 2. Add the bias back, undo the cube root.
        let l = (lr + cbrtOpsinBias) * (lr + cbrtOpsinBias) * (lr + cbrtOpsinBias) - opsinBias
        let m = (mr + cbrtOpsinBias) * (mr + cbrtOpsinBias) * (mr + cbrtOpsinBias) - opsinBias
        let s = (sr + cbrtOpsinBias) * (sr + cbrtOpsinBias) * (sr + cbrtOpsinBias) - opsinBias
        // 3. Inverse opsin absorbance matrix.
        let r = invM00 * l + invM01 * m + invM02 * s
        let g = invM10 * l + invM11 * m + invM12 * s
        let b = invM20 * l + invM21 * m + invM22 * s
        return (R: r, G: g, B: b)
    }
}
