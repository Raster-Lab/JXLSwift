// LowestFrequenciesFromDC — derive multi-block LLF coefficients from
// the per-cell DC plane. libjxl `dec_transforms-inl.h::
// LowestFrequenciesFromDC` + `dct-inl.h::ComputeScaledDCT`.
//
// For a multi-cell AC strategy (e.g., DCT16x16, which covers 2×2 8×8
// cells), the encoder stores ONE DC value per covered 8×8 cell. The
// "actual" LLF coefficients of the full WxH transform are derived
// from those DC values by a small forward DCT (`ComputeScaledDCT<
// LF_ROWS, LF_COLS>`) then multiplied by per-axis "resample scales"
// (`DCTTotalResampleScale<LF_DIM, FULL_DIM>`).
//
// libjxl's 1-D DCT-2 family is **not** orthonormal: the 1-D primitive
// is `(x0+x1, x0-x1)` followed by a divide-by-N scale. So a forward
// `ComputeScaledDCT<2,2>` of constant input `c` gives `(c, 0, 0, 0)`
// rather than the orthonormal `(2c, 0, 0, 0)`. This is convenient
// here: it directly maps "DC = mean" between the cell-level DC plane
// and the LLF region of the full transform.
//
// **Status**: DCT16x16 only. Other multi-cell strategies follow the
// same template — port on demand as the strategy plane needs them.
//
// Spec: ISO/IEC 18181-1 §K.9. libjxl: lib/jxl/dec_transforms-inl.h.

import Foundation

public enum LowestFrequenciesFromDC {

    /// libjxl `dct_scales.h::DCTResampleScales<2, 16>::kScales`.
    /// Used to scale the 2×2 forward-DCT outputs when reinterpreting
    /// them as the LLF region of a 16×16 transform.
    private static let kScales2to16: [Float] = [
        1.0,
        0.901764195028874394,
    ]

    /// DCT16x16 path: 4 DC values from the 2×2 covered cells →
    /// 4 LLF coefficients (positions (0,0), (1,0), (0,1), (1,1) of
    /// the 16×16 coefficient grid).
    ///
    /// `dc[0..3]` is in row-major order:
    ///     dc[0] = dc(bx, by)
    ///     dc[1] = dc(bx+1, by)
    ///     dc[2] = dc(bx, by+1)
    ///     dc[3] = dc(bx+1, by+1)
    ///
    /// Returns 4 LLF coefficients in the SAME row-major order. The
    /// caller writes them to natural-order positions [0..4) of the
    /// flat 256-entry coefficient block (which match (0,0), (1,0),
    /// (0,1), (1,1) in the 16×16 coef grid — same indices as our
    /// `naturalCoeffOrder` LLF prefix).
    public static func dct16x16(dc: [Float]) -> [Float] {
        precondition(dc.count == 4, "DCT16x16 LLF needs 4 DC values")
        let d00 = dc[0]
        let d01 = dc[1]
        let d10 = dc[2]
        let d11 = dc[3]
        // 2×2 forward "scaled" DCT (libjxl convention; 1-D primitive
        // is `(a+b)/N, (a-b)/N` for N=2 → divide by 2).
        let s00 = (d00 + d01 + d10 + d11) * 0.25
        let s01 = (d00 - d01 + d10 - d11) * 0.25
        let s10 = (d00 + d01 - d10 - d11) * 0.25
        let s11 = (d00 - d01 - d10 + d11) * 0.25
        // Apply per-axis resample scales for `<2, 16>`. (x, y)
        // indices map to (col, row) in the 2×2 LLF region.
        let sX0 = kScales2to16[0]
        let sX1 = kScales2to16[1]
        let sY0 = kScales2to16[0]
        let sY1 = kScales2to16[1]
        return [
            s00 * sX0 * sY0,
            s01 * sX1 * sY0,
            s10 * sX0 * sY1,
            s11 * sX1 * sY1,
        ]
    }
}
