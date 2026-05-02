// DCPredictor — VarDCT's DC-plane gradient prediction.
//
// Each reconstructed 8×8 block contributes one DC sample (the
// frequency-[0,0] coefficient before quantisation). Across the
// frame these form a `(xsize/8) × (ysize/8)` low-resolution DC
// plane. Compression of this plane uses the same Gradient
// predictor as Modular: `clamp(W + N − NW, min(W,N), max(W,N))`,
// which is well-tuned to slowly-varying signals.
//
// Spec: ISO/IEC 18181-1 §K.6 (DC reconstruction). libjxl:
// `lib/jxl/dec_dc.cc::DecodeDC` plus the property-19 modular
// branch — for the simplest case both encoder and decoder agree
// on `Gradient` over the reconstructed DC plane and emit residuals
// (`actual - gradient`) into the AC global section's modular
// stream.
//
// **Status**: standalone math. The predictor itself (forward +
// residual computation) is the same `applyLibjxlPredictor` raw=5
// branch used by Modular. This wrapper exists to make the
// VarDCT-specific ergonomics — quant-step scaling and the
// DC-plane buffer layout — explicit.

import Foundation

public enum DCPredictor {

    /// Predict pixel `(x, y)` from the already-decoded DC plane
    /// using ClampedGradient (libjxl raw predictor 5). Edge fall-
    /// backs follow `Neighbourhood(at:y:in:width:)` — same rules
    /// as Modular.
    @inline(__always)
    public static func predict(
        at x: Int, _ y: Int,
        in dc: [Int32], width: Int
    ) -> Int32 {
        let nbh = Neighbourhood(at: x, y, in: dc, width: width)
        return Predictor.gradient.apply(to: nbh)
    }

    /// Walk every position of the DC plane and yield the residual
    /// `actual - predicted`. Output is the same shape as `dc`.
    /// Useful at encode time before zig-zag-pack + entropy coding.
    public static func residuals(
        of dc: [Int32], width: Int, height: Int
    ) -> [Int32] {
        precondition(dc.count == width * height,
                     "dc buffer must be width*height")
        var out = [Int32](repeating: 0, count: dc.count)
        for y in 0..<height {
            for x in 0..<width {
                let p = predict(at: x, y, in: dc, width: width)
                out[y * width + x] = dc[y * width + x] &- p
            }
        }
        return out
    }

    /// Reconstruct a DC plane from its residual buffer. Must be
    /// called in row-major order so each prediction reads only
    /// already-reconstructed neighbours; the function handles the
    /// ordering internally.
    public static func reconstruct(
        residuals res: [Int32], width: Int, height: Int
    ) -> [Int32] {
        precondition(res.count == width * height,
                     "residuals buffer must be width*height")
        var out = [Int32](repeating: 0, count: res.count)
        for y in 0..<height {
            for x in 0..<width {
                let p = predict(at: x, y, in: out, width: width)
                out[y * width + x] = res[y * width + x] &+ p
            }
        }
        return out
    }
}
