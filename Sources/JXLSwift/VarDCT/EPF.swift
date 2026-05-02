// EPF — VarDCT edge-preserving filter (loop filter, post-Gaborish).
//
// ISO/IEC 18181-1 §C.9.2. libjxl: `lib/jxl/render_pipeline/stage_epf.cc` +
// `lib/jxl/epf.cc::ComputeSigma`. Up to **three iterations** (`epf_iters`
// ∈ {0, 1, 2, 3}, default 2) of a Sum-of-Absolute-Differences (SAD)
// based bilateral filter with per-pixel weights derived from a per-block
// sigma image:
//
//     EPF0 — 7×7 (plus-with-diagonals: 12 neighbours, each 3×3-plus SAD)
//     EPF1 — 5×5 (plus-only: 4 neighbours, each 3×3-plus SAD)
//     EPF2 — 3×3 (plus-only: 4 neighbours, single-pixel diff)
//
// The weight per neighbour is `max(0, sad · inv_sigma + 1)` where
// `inv_sigma` is **negative** (so larger SAD → smaller weight, with a
// floor of zero). The center pixel always contributes weight 1.
//
// **Sigma computation** (per 8×8 block):
//     sigma_quant = epf_quant_mul / (quant_scale · row_quant · kInvSigmaNum)
//     sigma       = sigma_quant · epf_sharp_lut[sharpness]   // sharpness ∈ 0..7
//     sigma       = min(-1e-4, sigma)                        // clamp to negative
//     stored      = 1 / sigma                                // inv_sigma
//
// **kMinSigma early-exit**: if `inv_sigma < kMinSigma`, the block's
// pixels pass through unchanged. For typical cjxl-emitted fixtures
// with `epf_sharp_lut[0] = 0` (default LUT) and `sharpness = 0`,
// the LUT lookup is 0 → sigma is clamped to -1e-4 → inv_sigma is
// -10000 → which is far below `kMinSigma = -3.905`, so EPF is a
// **no-op for sharp content**. Real-world fixtures with non-zero
// sharpness exercise the full bilateral kernel.
//
// **Status**: structural framework + sigma computation + the
// no-op fast path are wired up. The bilateral kernel itself is
// stubbed — it throws `unsupportedNonZeroSharpness` when hit, so
// the rest of the v0.6.0 pipeline can land without blocking on
// the (~200 line) full EPF implementation. A future commit lands
// the kernel once a fixture forces non-zero sharpness.

import Foundation

public enum EPFError: Error, Sendable, Equatable {
    /// A block's sigma is above the kMinSigma early-exit threshold,
    /// meaning the bilateral kernel would actually apply. The full
    /// kernel is not yet implemented — pin this down first with a
    /// fixture that exercises non-zero sharpness.
    case unsupportedNonZeroSharpness(blockX: Int, blockY: Int, invSigma: Float)
}

/// Per-block parameters needed by `EPF.compute*`.
public struct EPFParams: Sendable {
    /// Number of iterations to apply (0..3). 0 = skip EPF entirely.
    public let epfIters: Int
    /// libjxl `epf_quant_mul` (default 0.46).
    public let quantMul: Float
    /// libjxl `epf_sharp_lut[0..7]` — default `[i/7 for i in 0..7]`.
    public let sharpLut: [Float]
    /// Per-channel SAD scales — default `[X=40, Y=5, B=3.5]`.
    public let channelScale: (Float, Float, Float)
    /// Pass-1 / pass-2 weight floors.
    public let pass1ZeroFlush: Float
    public let pass2ZeroFlush: Float
    /// libjxl `epf_pass0_sigma_scale` (default 0.9).
    public let pass0SigmaScale: Float
    /// libjxl `epf_pass2_sigma_scale` (default 6.5).
    public let pass2SigmaScale: Float
    /// libjxl `epf_border_sad_mul` (default 0.667).
    public let borderSadMul: Float

    public static let `default` = EPFParams(
        epfIters: 2,
        quantMul: 0.46,
        sharpLut: (0..<8).map { Float($0) / 7.0 },
        channelScale: (40.0, 5.0, 3.5),
        pass1ZeroFlush: 0.45,
        pass2ZeroFlush: 0.6,
        pass0SigmaScale: 0.9,
        pass2SigmaScale: 6.5,
        borderSadMul: 2.0 / 3.0
    )
}

public enum EPF {

    /// libjxl `epf.h::kInvSigmaNum`. Used in the per-block sigma
    /// formula to derive `sigma_quant` from `quant_scale × row_quant`.
    public static let kInvSigmaNum: Float = -1.1715728752538099024

    /// libjxl `epf.h::kMinSigma`. Per-block sigma values strictly
    /// below this floor cause the EPF stage to early-exit (pixel
    /// pass-through). The `<` in the comparison means values *more
    /// negative* than this floor get the pass-through; values
    /// closer to zero (or positive) trigger the bilateral kernel.
    public static let kMinSigma: Float = -3.90524291751269967465540850526868

    /// Compute per-block `inv_sigma` from the EPF sharpness and
    /// quantiser state. Returns the value libjxl stores in its
    /// `sigma_` image (which is actually `1/sigma`, i.e., inverse).
    /// The caller samples this value when filtering each pixel.
    public static func computeInvSigma(
        sharpness: UInt8,
        rowQuant: Int32,
        quantScale: Float,
        params: EPFParams
    ) -> Float {
        // libjxl `epf.cc::ComputeSigma`:
        //
        //     sigma_quant = epf_quant_mul / (quant_scale * row_quant * kInvSigmaNum)
        //     sigma       = sigma_quant * epf_sharp_lut[sharpness]
        //     sigma       = min(-1e-4, sigma)         // always negative
        //     stored      = 1 / sigma                 // inv_sigma
        let sigmaQuant = params.quantMul
            / (quantScale * Float(rowQuant) * kInvSigmaNum)
        let lutIdx = min(Int(sharpness), params.sharpLut.count - 1)
        var sigma = sigmaQuant * params.sharpLut[lutIdx]
        sigma = min(-1e-4, sigma)
        return 1.0 / sigma
    }

    /// Decide whether EPF would be a no-op for a per-block
    /// `inv_sigma`. libjxl: `if (row_sigma[bx] < kMinSigma) → pass
    /// through`. For our fixture with default LUT and sharpness=0,
    /// the LUT lookup is 0, sigma clamps to -1e-4, inv_sigma is
    /// -10000 — far below kMinSigma — so this returns `true` and
    /// no filtering is applied.
    @inline(__always)
    public static func isNoOp(invSigma: Float) -> Bool {
        return invSigma < kMinSigma
    }

    /// Apply EPF to three XYB plane buffers in place. Each plane is
    /// `width × height` row-major Float. The implementation walks
    /// blocks of `kBlockDim = 8` pixels, computes per-block
    /// `inv_sigma`, and either passes through (no-op fast path) or
    /// throws `unsupportedNonZeroSharpness` (kernel not yet wired).
    ///
    /// libjxl applies up to three stages (EPF0 → EPF1 → EPF2)
    /// gated by `epf_iters`; we currently only structure-out the
    /// "is the kernel needed?" decision so the v0.5.0 pipeline can
    /// route through EPF without changing pixels for sharpness=0
    /// fixtures.
    public static func applyAllStages(
        planeX: inout [Float], planeY: inout [Float], planeB: inout [Float],
        width: Int, height: Int,
        sharpnessField: [UInt8],
        rowQuant: Int32, quantScale: Float,
        params: EPFParams
    ) throws {
        guard params.epfIters > 0 else { return }
        precondition(planeX.count == width * height
                     && planeY.count == width * height
                     && planeB.count == width * height,
                     "plane buffers must be exactly width*height")

        // Block grid is `ceil(width/8) × ceil(height/8)`.
        let blocksX = (width + 7) / 8
        let blocksY = (height + 7) / 8
        precondition(sharpnessField.count >= blocksX * blocksY,
                     "sharpness field must cover the block grid")

        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                let sharpness = sharpnessField[by * blocksX + bx]
                let invSigma = computeInvSigma(
                    sharpness: sharpness,
                    rowQuant: rowQuant,
                    quantScale: quantScale,
                    params: params
                )
                if isNoOp(invSigma: invSigma) {
                    // Block passes through unchanged. Continue to next.
                    continue
                }
                // Non-trivial filter required — full bilateral kernel
                // (12-neighbour SAD-weighted average for EPF0, etc.) is
                // not yet implemented. The first fixture that triggers
                // this branch is what we'll use to drive the implementation.
                throw EPFError.unsupportedNonZeroSharpness(
                    blockX: bx, blockY: by, invSigma: invSigma
                )
            }
        }
    }
}
