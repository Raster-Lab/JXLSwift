// Adaptive DC smoothing — a 3×3 edge-preserving low-pass applied to
// the dequantised DC plane of a VarDCT frame, between DC-group decode
// and AC-group decode.
//
// Port of libjxl `lib/jxl/compressed_dc.cc::AdaptiveDCSmoothing` /
// `ComputePixel`. The decoder runs this on the full-frame DC plane
// unless the frame header sets `kSkipAdaptiveDCSmoothing` (flag bit
// 7) or `kUseDcFrame` (bit 5). Skipping it leaves a low-frequency
// drift on large textured frames: the DC feeds `LowestFrequenciesFromDC`,
// so an unsmoothed DC shifts every multi-block transform's LLF.
//
// Spec reference: ISO/IEC 18181-1 §K.4 (the DC group). libjxl
// `compressed_dc.cc`.

import Foundation

/// Adaptive DC smoothing of the dequantised DC plane.
public enum AdaptiveDCSmoothing {

    /// libjxl `compressed_dc.cc` smoothing weights — a 3×3 kernel
    /// `[[w2,w1,w2],[w1,w0,w1],[w2,w1,w2]]` whose weights sum to 1.
    public static let w1: Float = 0.20345139757231578
    public static let w2: Float = 0.0334829185968739
    public static let w0: Float = 1.0 - 4.0 * (w1 + w2)

    /// Smooth the three DC planes in place. `dc` holds the dequantised,
    /// CfL-applied DC for the X/Y/B channels (each `width × height`,
    /// row-major). `dcFactors` is the per-channel `MulDC` quantiser
    /// step used to normalise the local-contrast gap.
    ///
    /// Each interior pixel is replaced by `mc + (sm − mc)·factor`,
    /// where `sm` is the 3×3 weighted average, `mc` the centre, and
    /// `factor = max(0, 3 − 4·gap)` with `gap` the largest normalised
    /// centre-vs-smoothed deviation across the three channels (seeded
    /// at 0.5, so `factor ∈ [0, 1]`). Smooth regions get fully
    /// averaged; sharp DC edges are left untouched. Borders are
    /// copied through unchanged. A no-op for planes ≤ 2 in either
    /// dimension (libjxl early-return).
    public static func apply(
        dc: inout [[Float]], width: Int, height: Int,
        dcFactors: [Float]
    ) {
        precondition(dc.count == 3, "DC smoothing needs 3 planes")
        precondition(dcFactors.count == 3, "need 3 channel DC factors")
        guard height > 2, width > 2 else { return }   // libjxl early-out
        // Non-in-place: the kernel reads the original plane and
        // writes a fresh copy (borders pass through verbatim).
        var smoothed = dc
        let inv: [Float] = [1.0 / dcFactors[0],
                            1.0 / dcFactors[1],
                            1.0 / dcFactors[2]]
        for y in 1..<(height - 1) {
            let rowT = (y - 1) * width
            let rowM = y * width
            let rowB = (y + 1) * width
            for x in 1..<(width - 1) {
                var mc = (Float(0), Float(0), Float(0))
                var sm = (Float(0), Float(0), Float(0))
                var gap: Float = 0.5
                for c in 0..<3 {
                    let p = dc[c]
                    let tl = p[rowT + x - 1]
                    let tc = p[rowT + x]
                    let tr = p[rowT + x + 1]
                    let ml = p[rowM + x - 1]
                    let centre = p[rowM + x]
                    let mr = p[rowM + x + 1]
                    let bl = p[rowB + x - 1]
                    let bc = p[rowB + x]
                    let br = p[rowB + x + 1]
                    let corner = (tl + tr) + (bl + br)
                    let side = (ml + mr) + (tc + bc)
                    let s = corner * w2 + side * w1 + centre * w0
                    let dev = abs((centre - s) * inv[c])
                    if dev > gap { gap = dev }
                    switch c {
                    case 0: mc.0 = centre; sm.0 = s
                    case 1: mc.1 = centre; sm.1 = s
                    default: mc.2 = centre; sm.2 = s
                    }
                }
                var factor: Float = 3.0 - 4.0 * gap
                if factor < 0 { factor = 0 }
                smoothed[0][rowM + x] = mc.0 + (sm.0 - mc.0) * factor
                smoothed[1][rowM + x] = mc.1 + (sm.1 - mc.1) * factor
                smoothed[2][rowM + x] = mc.2 + (sm.2 - mc.2) * factor
            }
        }
        dc = smoothed
    }
}
