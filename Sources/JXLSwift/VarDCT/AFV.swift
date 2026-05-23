// AFV — Asymmetric Frequency Variable transform foundation.
//
// JPEG XL ships 4 AFV variants (AFV0/1/2/3) — each is an 8×8 cell
// strategy with a SPECIAL transform basis for the 4×4 corner where
// luminance has high local frequency content. The remaining
// non-corner regions use IDCT4×4 and IDCT4×8.
//
// **What this file ships**: the 16×16 AFV basis matrix
// (`k4x4AFVBasis`) and the `AFVIDCT4x4` primitive — a direct port
// of libjxl `dec_transforms-inl.h::AFVIDCT4x4`. The full per-AFV-
// kind overlay (DC decomposition + corner placement + IDCT4x4 +
// IDCT4x8 dispatch) lands in a future bite; this file provides the
// foundation primitive that overlay will call.
//
// Mathematically: `pixels[i] = sum_j coeffs[j] * basis[j][i]`,
// i.e. `pixels = basis^T * coeffs` viewed as a 16×16 matrix-vector
// multiply. The basis is orthonormal with the first row being
// constant-DC (`= 1/4 = 0.25`).
//
// Spec reference: ISO/IEC 18181-1 §C.9. libjxl: `lib/jxl/
// dec_transforms-inl.h::AFVIDCT4x4`, `lib/jxl/cms` / `lib/jxl/dct`
// — basis values are libjxl-frozen and have no closed-form
// derivation in the spec text.

import Foundation

public enum AFV {

    /// 16×16 AFV basis matrix (libjxl `k4x4AFVBasis`). Indexed
    /// `[basisFunctionIndex][pixelIndex]` — row j holds the `j`-th
    /// basis function's contribution to each of the 16 pixel
    /// positions in a 4×4 block (row-major, so pixel index
    /// `iy * 4 + ix`). Row 0 is the DC basis (constant 0.25).
    public static let k4x4AFVBasis: [[Float]] = [
        // Row 0: DC (constant = 1/4).
        [0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25,
         0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25],
        // Row 1.
        [0.876902929799142, 0.2206518106944235, -0.10140050393753763,
         -0.1014005039375375, 0.2206518106944236, -0.10140050393753777,
         -0.10140050393753772, -0.10140050393753763, -0.10140050393753758,
         -0.10140050393753769, -0.1014005039375375, -0.10140050393753768,
         -0.10140050393753768, -0.10140050393753759, -0.10140050393753763,
         -0.10140050393753741],
        // Row 2.
        [0.0, 0.0, 0.40670075830260755, 0.44444816619734445,
         0.0, 0.0, 0.19574399372042936, 0.2929100136981264,
         -0.40670075830260716, -0.19574399372042872, 0.0,
         0.11379074460448091, -0.44444816619734384, -0.29291001369812636,
         -0.1137907446044814, 0.0],
        // Row 3.
        [0.0, 0.0, -0.21255748058288748, 0.3085497062849767,
         0.0, 0.4706702258572536, -0.1621205195722993, 0.0,
         -0.21255748058287047, -0.16212051957228327, -0.47067022585725277,
         -0.1464291867126764, 0.3085497062849487, 0.0,
         -0.14642918671266536, 0.4251149611657548],
        // Row 4.
        [0.0, -0.7071067811865474, 0.0, 0.0, 0.7071067811865476,
         0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        // Row 5.
        [-0.4105377591765233, 0.6235485373547691, -0.06435071657946274,
         -0.06435071657946266, 0.6235485373547694, -0.06435071657946284,
         -0.0643507165794628, -0.06435071657946274, -0.06435071657946272,
         -0.06435071657946279, -0.06435071657946266, -0.06435071657946277,
         -0.06435071657946277, -0.06435071657946273, -0.06435071657946274,
         -0.0643507165794626],
        // Row 6.
        [0.0, 0.0, -0.4517556589999482, 0.15854503551840063, 0.0,
         -0.04038515160822202, 0.0074182263792423875, 0.39351034269210167,
         -0.45175565899994635, 0.007418226379244351, 0.1107416575309343,
         0.08298163094882051, 0.15854503551839705, 0.3935103426921022,
         0.0829816309488214, -0.45175565899994796],
        // Row 7.
        [0.0, 0.0, -0.304684750724869, 0.5112616136591823, 0.0, 0.0,
         -0.290480129728998, -0.06578701549142804, 0.304684750724884,
         0.2904801297290076, 0.0, -0.23889773523344604,
         -0.5112616136592012, 0.06578701549142545, 0.23889773523345467,
         0.0],
        // Row 8.
        [0.0, 0.0, 0.3017929516615495, 0.25792362796341184, 0.0,
         0.16272340142866204, 0.09520022653475037, 0.0, 0.3017929516615503,
         0.09520022653475055, -0.16272340142866173, -0.35312385449816297,
         0.25792362796341295, 0.0, -0.3531238544981624, -0.6035859033230976],
        // Row 9.
        [0.0, 0.0, 0.40824829046386274, 0.0, 0.0, 0.0, 0.0,
         -0.4082482904638628, -0.4082482904638635, 0.0, 0.0,
         -0.40824829046386296, 0.0, 0.4082482904638634, 0.408248290463863,
         0.0],
        // Row 10.
        [0.0, 0.0, 0.1747866975480809, 0.0812611176717539, 0.0, 0.0,
         -0.3675398009862027, -0.307882213957909, -0.17478669754808135,
         0.3675398009862011, 0.0, 0.4826689115059883, -0.08126111767175039,
         0.30788221395790305, -0.48266891150598584, 0.0],
        // Row 11.
        [0.0, 0.0, -0.21105601049335784, 0.18567180916109802, 0.0, 0.0,
         0.49215859013738733, -0.38525013709251915, 0.21105601049335806,
         -0.49215859013738905, 0.0, 0.17419412659916217,
         -0.18567180916109904, 0.3852501370925211, -0.1741941265991621,
         0.0],
        // Row 12.
        [0.0, 0.0, -0.14266084808807264, -0.3416446842253372, 0.0,
         0.7367497537172237, 0.24627107722075148, -0.08574019035519306,
         -0.14266084808807344, 0.24627107722075137, 0.14883399227113567,
         -0.04768680350229251, -0.3416446842253373, -0.08574019035519267,
         -0.047686803502292804, -0.14266084808807242],
        // Row 13.
        [0.0, 0.0, -0.13813540350758585, 0.3302282550303788, 0.0,
         0.08755115000587084, -0.07946706605909573, -0.4613374887461511,
         -0.13813540350758294, -0.07946706605910261, 0.49724647109535086,
         0.12538059448563663, 0.3302282550303805, -0.4613374887461554,
         0.12538059448564315, -0.13813540350758452],
        // Row 14.
        [0.0, 0.0, -0.17437602599651067, 0.0702790691196284, 0.0,
         -0.2921026642334881, 0.3623817333531167, 0.0,
         -0.1743760259965108, 0.36238173335311646, 0.29210266423348785,
         -0.4326608024727445, 0.07027906911962818, 0.0,
         -0.4326608024727457, 0.34875205199302267],
        // Row 15.
        [0.0, 0.0, 0.11354987314994337, -0.07417504595810355, 0.0,
         0.19402893032594343, -0.435190496523228, 0.21918684838857466,
         0.11354987314994257, -0.4351904965232251, 0.5550443808910661,
         -0.25468277124066463, -0.07417504595810233, 0.2191868483885728,
         -0.25468277124066413, 0.1135498731499429],
    ]

    /// Apply the AFV 4×4 inverse transform: pixels = basis^T · coeffs
    /// viewed as a 16-element matrix-vector multiply. `coeffs` and
    /// `pixels` are each length-16 (the 16 basis function indices /
    /// the 16 pixel positions in a 4×4 block, row-major).
    ///
    /// Direct port of libjxl `dec_transforms-inl.h::AFVIDCT4x4`.
    public static func idct4x4(_ coeffs: [Float], _ pixels: inout [Float]) {
        precondition(coeffs.count == 16, "AFV coeffs must be 16 floats")
        precondition(pixels.count == 16, "AFV pixels must be 16 floats")
        for i in 0..<16 {
            var pixel: Float = 0
            for j in 0..<16 {
                pixel += coeffs[j] * k4x4AFVBasis[j][i]
            }
            pixels[i] = pixel
        }
    }

    /// Apply the AFV 4×4 forward transform: coeffs = basis · pixels.
    /// Exact inverse of `idct4x4` — the basis is orthonormal, so the
    /// forward direction is the same matrix viewed as `(row-vector
    /// of basis function j) · pixels`.
    public static func fdct4x4(_ pixels: [Float], _ coeffs: inout [Float]) {
        precondition(pixels.count == 16, "AFV pixels must be 16 floats")
        precondition(coeffs.count == 16, "AFV coeffs must be 16 floats")
        for j in 0..<16 {
            var c: Float = 0
            for i in 0..<16 {
                c += pixels[i] * k4x4AFVBasis[j][i]
            }
            coeffs[j] = c
        }
    }

    /// Apply the full AFV inverse transform for a single 8×8 cell to
    /// pixel-domain output. Direct port of libjxl
    /// `dec_transforms-inl.h::AFVTransformToPixels<afv_kind>`.
    ///
    /// AFV breaks an 8×8 cell into three sub-regions:
    /// - 4×4 corner using the AFV basis (`AFV.idct4x4`)
    /// - 4×4 corner using a standard `IDCT4×4`
    /// - 4×8 half using a standard `IDCT4×8`
    ///
    /// The 4 AFV variants (afvKind ∈ {0, 1, 2, 3}) place the AFV
    /// corner in a different quadrant of the 8×8 cell:
    ///
    ///     afvKind=0: AFV at (top, left)
    ///     afvKind=1: AFV at (top, right)
    ///     afvKind=2: AFV at (bottom, left)
    ///     afvKind=3: AFV at (bottom, right)
    ///
    /// `coefficients` is the 8×8 dequantised float block (length 64).
    /// `pixels` is a 64-element output buffer for the 8×8 pixel cell.
    /// Both row-major.
    ///
    /// The first three coefficients carry "DC-like" information that's
    /// decomposed into three sub-DCs:
    ///
    ///     dcs[0] = (block[0,0] + block[0,1] + block[1,0]) * 4   // AFV  4×4 DC
    ///     dcs[1] = block[0,0] + block[1,0] - block[0,1]         // IDCT 4×4 DC
    ///     dcs[2] = block[0,0] - block[1,0]                      // IDCT 4×8 DC
    ///
    /// **`idct4x4Backend`** and **`idct4x8Backend`** must apply the
    /// libjxl-convention 2-D scaled IDCT to a 16-coefficient (4×4) or
    /// 32-coefficient (4×8) block in-place. Callers typically pass
    /// `LibjxlIDCT.idct2D` / `AccelerateDCT.idct2D` adapters.
    public static func transformToPixels(
        afvKind: Int,
        coefficients: [Float],
        pixels: inout [Float],
        idct4x4Backend: (inout [Float]) -> Void,
        idct4x8Backend: (inout [Float]) -> Void
    ) {
        precondition(afvKind >= 0 && afvKind < 4, "afvKind must be 0..3")
        precondition(coefficients.count == 64,
                     "AFV coefficients must be 64 floats")
        precondition(pixels.count == 64,
                     "AFV pixels must be 64 floats")
        let afvX = afvKind & 1
        let afvY = afvKind / 2

        // 1) Three sub-DCs from the LLF coefficients.
        let block00 = coefficients[0]
        let block01 = coefficients[1]
        let block10 = coefficients[8]
        let dc0: Float = (block00 + block10 + block01) * 4.0
        let dc1: Float = block00 + block10 - block01
        let dc2: Float = block00 - block10

        // 2) AFV 4×4 corner. Pulls coefficients at (even, even)
        //    positions from the 8×8 block.
        var afvCoeffs = [Float](repeating: 0, count: 16)
        afvCoeffs[0] = dc0
        for iy in 0..<4 {
            for ix in 0..<4 {
                if ix == 0 && iy == 0 { continue }
                afvCoeffs[iy * 4 + ix] = coefficients[iy * 2 * 8 + ix * 2]
            }
        }
        var afvPix = [Float](repeating: 0, count: 16)
        idct4x4(afvCoeffs, &afvPix)
        // Place at quadrant (afvY * 4, afvX * 4) with conditional flip.
        for iy in 0..<4 {
            for ix in 0..<4 {
                let srcY = (afvY == 1) ? (3 - iy) : iy
                let srcX = (afvX == 1) ? (3 - ix) : ix
                pixels[(iy + afvY * 4) * 8 + afvX * 4 + ix] =
                    afvPix[srcY * 4 + srcX]
            }
        }

        // 3) IDCT 4×4 in (odd, even) positions.
        var idctBlock4x4 = [Float](repeating: 0, count: 16)
        idctBlock4x4[0] = dc1
        for iy in 0..<4 {
            for ix in 0..<4 {
                if ix == 0 && iy == 0 { continue }
                idctBlock4x4[iy * 4 + ix] =
                    coefficients[iy * 2 * 8 + ix * 2 + 1]
            }
        }
        idct4x4Backend(&idctBlock4x4)
        // Place at row-range (afvY * 4 .. +4), col-range opposite afvX.
        let idct4x4ColOrigin = (afvX == 1) ? 0 : 4
        for iy in 0..<4 {
            for ix in 0..<4 {
                pixels[(iy + afvY * 4) * 8 + idct4x4ColOrigin + ix] =
                    idctBlock4x4[iy * 4 + ix]
            }
        }

        // 4) IDCT 4×8 — fills the OTHER half of the 8×8 cell along
        //    the y-axis (the half NOT covered by the 4×4 patches).
        var idctBlock4x8 = [Float](repeating: 0, count: 32)
        idctBlock4x8[0] = dc2
        for iy in 0..<4 {
            for ix in 0..<8 {
                if ix == 0 && iy == 0 { continue }
                idctBlock4x8[iy * 8 + ix] =
                    coefficients[(1 + iy * 2) * 8 + ix]
            }
        }
        idct4x8Backend(&idctBlock4x8)
        let idct4x8RowOrigin = (afvY == 1) ? 0 : 4
        for iy in 0..<4 {
            for ix in 0..<8 {
                pixels[(iy + idct4x8RowOrigin) * 8 + ix] =
                    idctBlock4x8[iy * 8 + ix]
            }
        }
    }
}
