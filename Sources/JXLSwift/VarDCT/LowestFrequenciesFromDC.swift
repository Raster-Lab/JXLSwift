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
    /// them as the LLF region of a 16×16 transform. (The upscale
    /// `<LF, FULL>` direction — ascending, not the `<FULL, LF>`
    /// downscale.)
    private static let kScales2to16: [Float] = [
        1.0,
        1.108937353592731823,
    ]

    /// libjxl `dct_scales.h::DCTResampleScales<1, 8>::kScales`.
    /// Trivially `[1.0]` — included for clarity at call sites that
    /// scale rectangular LLF regions where one axis stays at 1 cell.
    private static let kScales1to8: [Float] = [1.0]

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
        // is `(a+b)/N, (a-b)/N` for N=2 → divide by 2). This is the
        // vanilla DCT; libjxl's `ComputeScaledDCT<2,2>` (ROWS≥COLS)
        // emits the TRANSPOSED layout, so `s01` and `s10` swap
        // positions in the output below.
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
            s10 * sX1 * sY0,
            s01 * sX0 * sY1,
            s11 * sX1 * sY1,
        ]
    }

    /// Inverse of `dct16x16` — the **encoder** direction. Given a
    /// DCT16x16 block's 4 LLF coefficients (the coefficients at grid
    /// positions (0,0), (1,0), (0,1), (1,1)), recover the 4 DC-plane
    /// cell values the encoder must store so the decoder's
    /// `dct16x16` reconstructs those same LLF coefficients.
    ///
    /// `llf[0..3]` and the returned `dc[0..3]` are both row-major
    /// over the 2×2 covered cells — exactly the layout `dct16x16`
    /// consumes/produces, so `dct16x16(dcFromLowestFrequencies16x16(
    /// llf)) == llf` (within float epsilon).
    public static func dcFromLowestFrequencies16x16(
        llf: [Float]
    ) -> [Float] {
        precondition(llf.count == 4,
                     "DCT16x16 LLF needs 4 coefficients")
        // Undo the per-axis `<2, 16>` resample scales applied by the
        // forward direction (`s00·1`, `s10·sX1`, `s01·sY1`,
        // `s11·sX1·sY1`).
        let sX1 = kScales2to16[1]
        let sY1 = kScales2to16[1]
        let s00 = llf[0]
        let s10 = llf[1] / sX1
        let s01 = llf[2] / sY1
        let s11 = llf[3] / (sX1 * sY1)
        // Invert the 2×2 scaled DCT. The forward sign matrix `M`
        // (`s = M·d / 4`) is symmetric with `M·M = 4·I`, so the
        // inverse is simply `d = M·s`.
        return [
            s00 + s01 + s10 + s11,    // d(0,0)
            s00 - s01 + s10 - s11,    // d(1,0)
            s00 + s01 - s10 - s11,    // d(0,1)
            s00 - s01 - s10 + s11,    // d(1,1)
        ]
    }

    /// DCT16x8 / DCT8x16 (libjxl ord 4) path: 2 DC values from the
    /// 2 covered cells (vertically stacked for DCT16x8, horizontally
    /// stacked for DCT8x16) reinterpret to 2 LLF coefficients at
    /// natural-order positions 0 and 1 of the 8×16 (or 16×8) coef
    /// block.
    ///
    /// Both libjxl `Type::DCT16X8` (ROWS=2, COLS=1) and `Type::DCT8X16`
    /// (ROWS=1, COLS=2) use the same 1-D forward DCT-2 + per-axis
    /// scale formula:
    ///
    ///     LLF[0] = (dc[0] + dc[1]) / 2
    ///     LLF[1] = (dc[0] - dc[1]) / 2 * 0.901764195
    ///
    /// where `dc[0]`, `dc[1]` are the two covered cells in the
    /// strategy's natural order (top-then-bottom for DCT16x8 stacking
    /// 2 cells vertically, left-then-right for DCT8x16 stacking 2
    /// cells horizontally).
    public static func ord4Pair(dc: [Float]) -> [Float] {
        precondition(dc.count == 2, "ord 4 LLF needs 2 DC values")
        let s0 = (dc[0] + dc[1]) * 0.5
        let s1 = (dc[0] - dc[1]) * 0.5
        return [s0 * kScales2to16[0], s1 * kScales2to16[1]]
    }

    /// Inverse of `ord4Pair` — the **encoder** direction. Recovers
    /// the 2 DC-plane cell values (in the strategy's natural cell
    /// order: top-then-bottom for DCT16x8, left-then-right for
    /// DCT8x16) from a block's 2 LLF coefficients.
    /// `ord4Pair(dcFromLowestFrequenciesOrd4Pair(llf)) == llf`
    /// within float epsilon.
    public static func dcFromLowestFrequenciesOrd4Pair(
        llf: [Float]
    ) -> [Float] {
        precondition(llf.count == 2,
                     "ord 4 LLF needs 2 coefficients")
        // Undo the per-axis `<2, 16>` resample (scale 0 is 1, so a
        // no-op; scale 1 is √(1 + 1/√2)).
        let s0 = llf[0] / kScales2to16[0]
        let s1 = llf[1] / kScales2to16[1]
        // Invert the 2×2 Hadamard (`s0 = (d0+d1)/2`, `s1 = (d0-d1)/2`).
        return [s0 + s1, s0 - s1]
    }

    /// libjxl `dct_scales.h::DCTResampleScales<4, 32>::kScales`
    /// (the `<LF, FULL>` upscale direction — ascending).
    static let kScales4to32: [Float] = [
        1.0,
        1.025760096781116015,
        1.108937353592731823,
        1.270559368765487251,
    ]

    /// libjxl `dct_scales.h::DCTResampleScales<2, 16>` indexed
    /// table; alias for `kScales2to16` to keep ord 6 maths readable.
    private static let kScales2to32: [Float] = [
        1.0,
        1.108937353592731823,
    ]

    /// 1-D forward "scaled" DCT-4 in libjxl's convention. The
    /// `dct_for_test.h::DCT1D` per-coefficient scale is
    /// `alpha(u) · √2/N` (`alpha(0) = 1/√2`, `alpha(u>0) = 1`).
    /// For N=4 that resolves to `1/4` for the even-index
    /// coefficients (0, 2 — whose cosines collapse to ±1 / ±√2⁄2
    /// in the simplified sums below) and `√2/4` for the odd-index
    /// coefficients (1, 3).
    @inline(__always)
    static func scaledDCT4(_ x: [Float]) -> [Float] {
        precondition(x.count == 4)
        // cos(π/8), cos(3π/8) — the standard DCT-4 angle constants.
        let c1: Float = 0.9238795325112867   // cos(π/8)
        let c3: Float = 0.3826834323650898   // cos(3π/8)
        let s0 = (x[0] + x[1] + x[2] + x[3])
        let s2 = (x[0] - x[1] - x[2] + x[3])
        let d03 = x[0] - x[3]
        let d12 = x[1] - x[2]
        let s1 = d03 * c1 + d12 * c3
        let s3 = d03 * c3 - d12 * c1
        let invEven: Float = 0.25                  // 1/N
        let invOdd: Float = 0.3535533905932738     // √2/N
        return [s0 * invEven, s1 * invOdd, s2 * invEven, s3 * invOdd]
    }

    /// Inverse of `scaledDCT4` — the 4-point scaled IDCT-4.
    /// Recovers `x` from `X = scaledDCT4(x)`. Used by the encoder
    /// to invert the DCT32×32 LLF transform.
    @inline(__always)
    static func inverseScaledDCT4(_ X: [Float]) -> [Float] {
        precondition(X.count == 4)
        let c1: Float = 0.9238795325112867   // cos(π/8)
        let c3: Float = 0.3826834323650898   // cos(3π/8)
        let invOdd: Float = 0.3535533905932738
        // X0 = (x0+x1+x2+x3)/4, X2 = (x0-x1-x2+x3)/4, so
        //   a = x0+x3 = 2(X0+X2), b = x1+x2 = 2(X0-X2).
        let a = 2 * (X[0] + X[2])
        let b = 2 * (X[0] - X[2])
        // X1 / X3 carry (x0-x3, x1-x2) through an orthogonal 2×2
        // map (`[[c1,c3],[c3,-c1]]`, its own inverse since
        // `c1² + c3² = 1`) scaled by `invOdd`.
        let u = X[1] / invOdd
        let v = X[3] / invOdd
        let p = c1 * u + c3 * v     // x0 - x3
        let q = c3 * u - c1 * v     // x1 - x2
        return [(a + p) / 2, (b + q) / 2, (b - q) / 2, (a - p) / 2]
    }

    /// DCT32x16 / DCT16x32 (libjxl ord 6) path: 8 DC values from the
    /// covered 4×2 (or 2×4) cells reinterpret to 8 LLF coefficients
    /// at the top-left 4×2 corner of the 32×16 coef block.
    ///
    /// `dc` is in row-major coef-layout order: 4 cols × 2 rows for
    /// the coefficient layout (after `CoefficientLayout` swap):
    ///
    ///     dc[0] dc[1] dc[2] dc[3]    ← row 0
    ///     dc[4] dc[5] dc[6] dc[7]    ← row 1
    ///
    /// Returns 8 LLF values in the same row-major order. Per libjxl
    /// `LowestFrequenciesFromDC<DCT32X16>`: ROWS=4, COLS=2 →
    /// `ComputeScaledDCT<4, 2>` then resample with
    /// `DCTTotalResampleScale<4, 32>(y) * DCTTotalResampleScale<2, 16>(x)`.
    /// (For DCT16x32 it's ROWS=2, COLS=4 with axes swapped — the
    /// final LLF positions in the natural-order 4×2 LF region come
    /// out the same after symmetric handling.)
    public static func ord6Block(dc: [Float]) -> [Float] {
        precondition(dc.count == 8, "ord 6 LLF needs 8 DC values")
        // Step 1: 1-D DCT-4 along COLUMNS (process each col across
        // the 2 rows? No — we have ROWS=4 in coef layout, which means
        // we need a 4-point DCT along the "covered_blocks_y=4"
        // dimension, then a 2-point DCT along covered_blocks_x=2.
        // For DCT32X16 in libjxl: input is laid out 2 rows × 4 cols.
        // ComputeScaledDCT<4, 2> does DCT-4 along rows (4 elements
        // per col, 2 cols), then DCT-2 along cols.
        // Our `dc` here is the libjxl `dc` with stride: dc[y*stride+x]
        // for y in covered_y, x in covered_x.
        //
        // Re-cast our row-major dc[] (4 cols × 2 rows) as a (rows=2,
        // cols=4) input. ComputeScaledDCT<4, 2> takes a rows=4×cols=2
        // input — so we need the transposed view: input[r, c] for
        // r in 0..4, c in 0..2 = dc[c * 4 + r] (transposed).
        //
        // Simpler: walk libjxl's natural layout. For DCT32X16
        // (covered_x=2, covered_y=4), the DC values fill a 2-col × 4-
        // row region. We feed them to ComputeScaledDCT<4, 2>.
        //
        // For DCT16X32 (covered_x=4, covered_y=2), the DC values fill
        // a 4-col × 2-row region. We feed them to ComputeScaledDCT
        // <2, 4> (different signature but same final placement after
        // resample).
        //
        // To keep this helper unified for both strategies, we accept
        // `dc` as a flat 8-array in COEF-LAYOUT row-major (4 cols × 2
        // rows after `CoefficientLayout` swap). The math below works
        // out the same either way because libjxl's resample scales
        // are symmetric under axis swap.

        // Apply 1-D DCT-2 along the 2-row axis (so for each of 4
        // columns, combine the 2 rows):
        // tmp[0, x] = (dc[0, x] + dc[1, x]) / 2
        // tmp[1, x] = (dc[0, x] - dc[1, x]) / 2
        var tmp = [Float](repeating: 0, count: 8)
        for x in 0..<4 {
            let d0 = dc[x]            // row 0
            let d1 = dc[4 + x]        // row 1
            tmp[x]     = (d0 + d1) * 0.5
            tmp[4 + x] = (d0 - d1) * 0.5
        }
        // Apply 1-D DCT-4 along the 4-col axis (for each of 2 rows):
        var out = [Float](repeating: 0, count: 8)
        for y in 0..<2 {
            let row = [tmp[y * 4 + 0], tmp[y * 4 + 1],
                       tmp[y * 4 + 2], tmp[y * 4 + 3]]
            let dctRow = scaledDCT4(row)
            for x in 0..<4 {
                out[y * 4 + x] = dctRow[x]
            }
        }
        // Resample scales: per-row uses kScales2to32[y], per-col
        // uses kScales4to32[x].
        var result = [Float](repeating: 0, count: 8)
        for y in 0..<2 {
            for x in 0..<4 {
                result[y * 4 + x] = out[y * 4 + x]
                    * kScales4to32[x] * kScales2to32[y]
            }
        }
        return result
    }

    /// Inverse of `ord6Block` — the **encoder** direction. Recovers
    /// the 8 DC-plane cell values (laid out as the `ord6Block` input
    /// expects: row-major over the 4-col × 2-row coef cell grid)
    /// from a DCT32×16 / DCT16×32 block's 8 LLF coefficients.
    /// `ord6Block(dcFromLowestFrequenciesOrd6Block(llf)) == llf`
    /// within float epsilon.
    public static func dcFromLowestFrequenciesOrd6Block(
        llf: [Float]
    ) -> [Float] {
        precondition(llf.count == 8,
                     "ord 6 LLF needs 8 coefficients")
        // Undo the per-axis `<4, 32>` × `<2, 32>` resample.
        var out = [Float](repeating: 0, count: 8)
        for y in 0..<2 {
            for x in 0..<4 {
                out[y * 4 + x] = llf[y * 4 + x]
                    / (kScales4to32[x] * kScales2to32[y])
            }
        }
        // Undo the 1-D scaled DCT-4 along rows.
        var tmp = [Float](repeating: 0, count: 8)
        for y in 0..<2 {
            let inv = inverseScaledDCT4([
                out[y * 4 + 0], out[y * 4 + 1],
                out[y * 4 + 2], out[y * 4 + 3]])
            for x in 0..<4 { tmp[y * 4 + x] = inv[x] }
        }
        // Undo the 1-D DCT-2 along the 2-row axis
        // (`tmp[x] = (d0+d1)/2`, `tmp[4+x] = (d0-d1)/2`).
        var dc = [Float](repeating: 0, count: 8)
        for x in 0..<4 {
            dc[x] = tmp[x] + tmp[4 + x]
            dc[4 + x] = tmp[x] - tmp[4 + x]
        }
        return dc
    }

    /// DCT64x32 / DCT32x64 (libjxl ord 8) path: 32 DC values from
    /// the covered 8×4 (or 4×8) cells reinterpret to 32 LLF coefs
    /// at the top-left 8×4 corner of the 64×32 coef block.
    ///
    /// Per libjxl: `ComputeScaledDCT<4, 8>` (4 rows × 8 cols input)
    /// then per-axis `DCTTotalResampleScale<4, 32>(y) *
    /// DCTTotalResampleScale<8, 64>(x)`.
    public static func ord8Block(dc: [Float]) -> [Float] {
        precondition(dc.count == 32, "ord 8 LLF needs 32 DC values")
        // 2-D forward scaled DCT on 4 rows × 8 cols input.
        var scaled = dc
        AccelerateDCT.dct2D(&scaled, rows: 4, cols: 8)
        // Per-axis resample.
        var result = [Float](repeating: 0, count: 32)
        for y in 0..<4 {
            for x in 0..<8 {
                result[y * 8 + x] = scaled[y * 8 + x]
                    * kScales8to64[x] * kScales4to32[y]
            }
        }
        return result
    }

    /// libjxl `dct_scales.h::DCTResampleScales<8, 64>::kScales`.
    static let kScales8to64: [Float] = [
        1.0000000000000000,
        1.0063534990068217,
        1.0257600967811158,
        1.0593017296817173,
        1.1089373535927318,
        1.1777765381970435,
        1.2705593687654873,
        1.3944898413647777,
    ]

    /// DCT64x64 (libjxl ord 7) path: 64 DC values from the 8×8
    /// covered cells reinterpret to 64 LLF coefficients at the
    /// top-left 8×8 corner of the 64×64 coef block.
    ///
    /// `dc` is in row-major coef-layout order (8 cols × 8 rows).
    /// Per libjxl `LowestFrequenciesFromDC<DCT64X64>`: ROWS=8,
    /// COLS=8 → `ComputeScaledDCT<8, 8>` (separable 8-point DCT-2)
    /// then per-axis `DCTTotalResampleScale<8, 64>` resample.
    ///
    /// We use `AccelerateDCT.dct2D` (≡ `LibjxlDCT.dct2D` byte-
    /// equivalent on Apple Silicon) for the 8×8 forward — that
    /// IS the libjxl scaled-DCT primitive applied at this size.
    public static func dct64x64(dc: [Float]) -> [Float] {
        precondition(dc.count == 64, "DCT64x64 LLF needs 64 DC values")
        // 2-D forward scaled DCT-8 on the 8×8 DC values.
        var scaled = dc
        AccelerateDCT.dct2D(&scaled, size: 8)
        // Per-axis resample with kScales<8, 64>, then transpose:
        // libjxl's `ComputeScaledDCT<8,8>` (ROWS≥COLS) emits the
        // transposed layout.
        var result = [Float](repeating: 0, count: 64)
        for y in 0..<8 {
            for x in 0..<8 {
                result[x * 8 + y] = scaled[y * 8 + x]
                    * kScales8to64[x] * kScales8to64[y]
            }
        }
        return result
    }

    /// DCT32x32 (libjxl ord 3) path: 16 DC values from the 4×4
    /// covered cells reinterpret to 16 LLF coefficients at the
    /// top-left 4×4 corner of the 32×32 coef block.
    ///
    /// `dc` is in row-major coef-layout order (4 cols × 4 rows).
    /// Per libjxl `LowestFrequenciesFromDC<DCT32X32>`: ROWS=4,
    /// COLS=4 → `ComputeScaledDCT<4, 4>` (separable 4-point DCT-2)
    /// then per-axis `DCTTotalResampleScale<4, 32>` resample.
    public static func dct32x32(dc: [Float]) -> [Float] {
        precondition(dc.count == 16, "DCT32x32 LLF needs 16 DC values")
        // 1-D scaled DCT-4 along COLUMNS (process each col across 4 rows).
        var tmp = [Float](repeating: 0, count: 16)
        for x in 0..<4 {
            let col = [dc[0 * 4 + x], dc[1 * 4 + x],
                       dc[2 * 4 + x], dc[3 * 4 + x]]
            let dctCol = scaledDCT4(col)
            for y in 0..<4 {
                tmp[y * 4 + x] = dctCol[y]
            }
        }
        // 1-D scaled DCT-4 along ROWS (process each row across 4 cols).
        var dct = [Float](repeating: 0, count: 16)
        for y in 0..<4 {
            let row = [tmp[y * 4 + 0], tmp[y * 4 + 1],
                       tmp[y * 4 + 2], tmp[y * 4 + 3]]
            let dctRow = scaledDCT4(row)
            for x in 0..<4 {
                dct[y * 4 + x] = dctRow[x]
            }
        }
        // Per-axis resample with kScales<4, 32>, then transpose:
        // libjxl's `ComputeScaledDCT<4,4>` (ROWS≥COLS) emits the
        // transposed layout.
        var result = [Float](repeating: 0, count: 16)
        for y in 0..<4 {
            for x in 0..<4 {
                result[x * 4 + y] = dct[y * 4 + x]
                    * kScales4to32[x] * kScales4to32[y]
            }
        }
        return result
    }

    /// Inverse of `dct32x32` — the **encoder** direction. Recovers
    /// the 16 DC-plane cell values (row-major over the 4×4 covered
    /// cells) from a DCT32×32 block's 16 LLF coefficients, so the
    /// decoder's `dct32x32` reconstructs those same coefficients.
    /// `dct32x32(dcFromLowestFrequencies32x32(llf)) == llf` within
    /// float epsilon.
    public static func dcFromLowestFrequencies32x32(
        llf: [Float]
    ) -> [Float] {
        precondition(llf.count == 16,
                     "DCT32x32 LLF needs 16 coefficients")
        // Undo the transpose + per-axis `<4, 32>` resample.
        var dct = [Float](repeating: 0, count: 16)
        for y in 0..<4 {
            for x in 0..<4 {
                dct[y * 4 + x] = llf[x * 4 + y]
                    / (kScales4to32[x] * kScales4to32[y])
            }
        }
        // Undo the 1-D scaled DCT-4 along rows.
        var tmp = [Float](repeating: 0, count: 16)
        for y in 0..<4 {
            let inv = inverseScaledDCT4([
                dct[y * 4 + 0], dct[y * 4 + 1],
                dct[y * 4 + 2], dct[y * 4 + 3]])
            for x in 0..<4 { tmp[y * 4 + x] = inv[x] }
        }
        // Undo the 1-D scaled DCT-4 along columns.
        var dc = [Float](repeating: 0, count: 16)
        for x in 0..<4 {
            let inv = inverseScaledDCT4([
                tmp[0 * 4 + x], tmp[1 * 4 + x],
                tmp[2 * 4 + x], tmp[3 * 4 + x]])
            for y in 0..<4 { dc[y * 4 + x] = inv[y] }
        }
        return dc
    }
}
