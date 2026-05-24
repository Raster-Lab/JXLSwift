// JPEG inverse DCT — tenth step on the Phase J road. Turns one
// dequantised `JPEGCoefficientBlock` (Int32 in natural row-major
// order) into 8×8 reconstructed sample bytes (UInt8 after level
// shift + clamp).
//
// JPEG's IDCT (ITU-T T.81 §A.3.3):
//
//     s(y,x) = (1/4) Σ_{u,v=0..7} C_u·C_v · S(v,u)
//              · cos((2x+1)uπ/16) · cos((2y+1)vπ/16)
//     where C_0 = 1/√2,  C_k = 1 for k > 0
//
// This is mathematically identical to the orthonormal Type-II DCT
// inverse implemented by `DCT2D.inverse(_:size:8)`:
//   α(0)·α(0) = 1/8      = (1/4)·(1/√2)·(1/√2)
//   α(0)·α(k) = 1/(4√2)  = (1/4)·(1/√2)·1
//   α(k)·α(l) = 1/4      = (1/4)·1·1
//
// So we delegate the actual transform to `DCT2D` and just add the
// JPEG-specific post-processing: §A.3.1 level shift (samples are
// stored as signed values centred at 0 inside the codec, then
// shifted by +2^(P-1) on output — +128 for 8-bit precision) and
// the [0, 2^P − 1] clamp.

import Foundation

/// JPEG block → 8×8 reconstructed sample bytes.
public enum JPEGIDCT {

    /// Run the inverse DCT on a dequantised 8×8 block and return
    /// 64 sample values in row-major order. Samples are clamped
    /// to `[0, 2^precision − 1]` after the level shift; at the
    /// default 8-bit precision that's `[0, 255]` and the output
    /// fits in `UInt8`.
    ///
    /// `precision` is the SOFn `P` field (typically 8; 12 for
    /// extended-precision JPEGs). The returned `[Int32]` makes
    /// callers free to handle 12-bit outputs without truncation.
    public static func inverseTransform(
        _ block: JPEGCoefficientBlock,
        precision: Int = 8
    ) -> [Int32] {
        var f = [Float](repeating: 0, count: 64)
        for i in 0..<64 {
            f[i] = Float(block.coefficients[i])
        }
        DCT2D.inverse(&f, size: 8)
        let levelShift = Int32(1) << Int32(precision - 1)
        let maxSample = (Int32(1) << Int32(precision)) - 1
        var out = [Int32](repeating: 0, count: 64)
        for i in 0..<64 {
            // Round-to-nearest (JPEG §A.3.3 doesn't specify a
            // rounding mode but real-world decoders all use
            // half-away-from-zero or banker's rounding; we use
            // half-away because it matches `lroundf`).
            let r = f[i].rounded(.toNearestOrAwayFromZero)
            var v = Int32(r) &+ levelShift
            if v < 0 { v = 0 }
            if v > maxSample { v = maxSample }
            out[i] = v
        }
        return out
    }

    /// 8-bit convenience: returns `[UInt8]` directly. Callers
    /// who know they're decoding 8-bit JPEGs (the common case)
    /// can skip the `Int32 → UInt8` narrowing themselves.
    public static func inverseTransform8Bit(
        _ block: JPEGCoefficientBlock
    ) -> [UInt8] {
        let s = inverseTransform(block, precision: 8)
        return s.map { UInt8($0) }
    }
}
