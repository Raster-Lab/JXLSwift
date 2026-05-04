// Gaborish — VarDCT post-DCT smoothing filter.
//
// One pass of a 3×3 separable-style convolution applied to each
// reconstructed channel after IDCT. Reduces DCT-block ringing
// artefacts; the encoder side applies a *separately-calibrated*
// 5×5 inverse-Gaborish sharpening kernel BEFORE the forward DCT
// (`GaborishInverse5x5` below) so that the encoder-decoder pair,
// while not mathematically inverse, produces visually pleasing
// rate-distortion behaviour (the libjxl 5×5 kernel constants were
// butteraugli-optimised).
//
// Spec: ISO/IEC 18181-1 §K.4.1. libjxl: `lib/jxl/render_pipeline/
// stage_gaborish.cc`. Per-channel weights are carried in
// `LoopFilter.gab_*_weight{1,2}`; the spec defaults reproduce the
// 1.1× scaling of libjxl's hardcoded `0.104699568f` /
// `0.055680538f` for x/y/b weight1 / weight2 — we expose the
// constants here as `defaultWeight1` / `defaultWeight2`.
//
// Kernel (per-pixel):
//
//     out = w0·center
//         + w1·(top + bottom + left + right)
//         + w2·(tl + tr + bl + br)
//
// where (`w1`, `w2`) come from `(gab_*_weight1, gab_*_weight2)`
// and `w0` is set so the kernel sums to 1: `w0 + 4·(w1 + w2) = 1`.
//
// **Status**: forward (decode-side) filter only. Encoder-side
// inverse-Gaborish (libjxl `enc_gaborish.cc`) lands when the lossy
// encode path catches up; for now we test the decode-side filter
// in isolation against expected smoothing behaviour.

import Foundation

public enum Gaborish {

    /// libjxl spec-default `gab_*_weight1` for all three planes.
    /// Decoder honours the LoopFilter-carried per-plane weights;
    /// we expose the default for callers that don't have a
    /// custom LoopFilter handy.
    public static let defaultWeight1: Float = 1.1 * 0.104699568   // ≈ 0.1151694247
    /// libjxl spec-default `gab_*_weight2` for all three planes.
    public static let defaultWeight2: Float = 1.1 * 0.055680538   // ≈ 0.0612486

    /// Apply Gaborish to a single channel's pixel buffer in-place.
    /// `pixels` is row-major float32 length `width*height`. Border
    /// pixels mirror the nearest in-image neighbour (libjxl's
    /// `kInOut` mode does the same with replicate-1 padding).
    public static func apply(
        to pixels: inout [Float],
        width: Int, height: Int,
        weight1: Float = defaultWeight1,
        weight2: Float = defaultWeight2
    ) {
        precondition(pixels.count == width * height,
                     "buffer must equal width*height")
        precondition(width > 0 && height > 0)
        let div = 1 + 4 * (weight1 + weight2)
        let w0 = 1.0 / div
        let w1 = weight1 / div
        let w2 = weight2 / div
        var out = pixels
        for y in 0..<height {
            for x in 0..<width {
                let xL = max(0, x - 1)
                let xR = min(width - 1, x + 1)
                let yT = max(0, y - 1)
                let yB = min(height - 1, y + 1)
                let center = pixels[y * width + x]
                let top    = pixels[yT * width + x]
                let bottom = pixels[yB * width + x]
                let left   = pixels[y * width + xL]
                let right  = pixels[y * width + xR]
                let tl = pixels[yT * width + xL]
                let tr = pixels[yT * width + xR]
                let bl = pixels[yB * width + xL]
                let br = pixels[yB * width + xR]
                let sum1 = top + bottom + left + right
                let sum2 = tl + tr + bl + br
                out[y * width + x] = w0 * center + w1 * sum1 + w2 * sum2
            }
        }
        pixels = out
    }

    /// libjxl's encoder-side 5×5 inverse-Gaborish sharpening kernel
    /// applied to opsin pixels before the forward DCT.
    /// Direct port of `enc_gaborish.cc::GaborishInverse`.
    ///
    /// **NOT** a mathematical inverse of `apply(...)`. It's a
    /// 6-distance-class symmetric 5×5 kernel calibrated by
    /// butteraugli optimisation across the libjxl encoder/decoder
    /// pair. The constants here are libjxl-frozen.
    ///
    /// Layout (per `convolve.h::WeightsSymmetric5`):
    ///
    ///     D L R L D
    ///     L d r d L
    ///     R r c r R       ← c = centre, normalize = 1/sum
    ///     L d r d L
    ///     D L R L D
    ///
    /// where the 5 named offset weights map to libjxl's
    /// `kGaborish[0..4]` via:
    /// `r = kGab[0]`, `d = kGab[1]`, `R = kGab[2]`, `L = kGab[3]`,
    /// `D = kGab[4]`.
    public static let kGaborishInverse5x5: [Float] = [
        -0.09495815671340026,    // axis-1   (r)
        -0.041031725066768575,   // diagonal (d)
         0.013710004822696948,   // axis-2   (R)
         0.006510206083837737,   // knight   (L)
        -0.0014789063378272242,  // corner   (D)
    ]

    /// Apply the 5×5 inverse-Gaborish kernel to a single channel's
    /// pixel buffer in-place. `mul` defaults to 1.0 (the libjxl
    /// encoder's standard call). Border pixels mirror the nearest
    /// in-image neighbour (libjxl `Symmetric5` boundary mode).
    public static func applyInverse5x5(
        to pixels: inout [Float],
        width: Int, height: Int,
        mul: Float = 1.0
    ) {
        precondition(pixels.count == width * height,
                     "buffer must equal width*height")
        precondition(width >= 1 && height >= 1)
        let g = kGaborishInverse5x5
        let sum = 1.0 + mul * 4.0 *
            (g[0] + g[1] + g[2] + g[4] + 2 * g[3])
        let normalize = 1.0 / sum
        let nm = mul * normalize
        let wCenter = normalize
        let wAxis1  = nm * g[0]
        let wDiag1  = nm * g[1]
        let wAxis2  = nm * g[2]
        let wKnight = nm * g[3]
        let wCorner = nm * g[4]

        @inline(__always)
        func clamp(_ i: Int, _ limit: Int) -> Int {
            if i < 0 { return -i }
            if i >= limit { return 2 * limit - 2 - i }
            return i
        }

        var out = pixels
        for y in 0..<height {
            for x in 0..<width {
                @inline(__always) func px(_ dy: Int, _ dx: Int) -> Float {
                    let ny = clamp(y + dy, height)
                    let nx = clamp(x + dx, width)
                    return pixels[ny * width + nx]
                }
                var v: Float = wCenter * px(0, 0)
                v += wAxis1 *
                    (px(-1, 0) + px(1, 0) + px(0, -1) + px(0, 1))
                v += wDiag1 *
                    (px(-1, -1) + px(-1, 1) + px(1, -1) + px(1, 1))
                v += wAxis2 *
                    (px(-2, 0) + px(2, 0) + px(0, -2) + px(0, 2))
                v += wKnight * (
                    px(-2, -1) + px(-2, 1) + px(2, -1) + px(2, 1) +
                    px(-1, -2) + px(-1, 2) + px(1, -2) + px(1, 2)
                )
                v += wCorner *
                    (px(-2, -2) + px(-2, 2) + px(2, -2) + px(2, 2))
                out[y * width + x] = v
            }
        }
        pixels = out
    }
}
