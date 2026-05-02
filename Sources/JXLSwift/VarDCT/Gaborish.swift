// Gaborish — VarDCT post-DCT smoothing filter.
//
// One pass of a 3×3 separable-style convolution applied to each
// reconstructed channel after IDCT. Reduces DCT-block ringing
// artefacts; the encoder side applies the inverse so that decoding
// + Gaborish ≈ original (modulo quantisation).
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
}
