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

    /// Apply all enabled EPF stages to three XYB plane buffers in
    /// place, gated by `params.epfIters`:
    ///
    ///     epf_iters >= 1 → EPF1 (5×5 plus, 4 neighbours)
    ///     epf_iters >= 2 → EPF2 (3×3 plus, 4 neighbours)
    ///     epf_iters >= 3 → EPF0 (7×7 plus-with-diagonals, 12 neighbours)
    ///
    /// Per libjxl `dec_cache.cc::PreparePipeline`. Each stage is its own
    /// pass over the planes; intermediate results are written to scratch
    /// buffers and ping-pong'd. Per-block `inv_sigma` is recomputed
    /// from `sharpnessField`, `perBlockQF`, and `quantScale`.
    public static func applyAllStages(
        planeX: inout [Float], planeY: inout [Float], planeB: inout [Float],
        width: Int, height: Int,
        sharpnessField: [UInt8],
        perBlockQF: [Int32],
        quantScale: Float,
        params: EPFParams
    ) throws {
        guard params.epfIters > 0 else { return }
        precondition(planeX.count == width * height
                     && planeY.count == width * height
                     && planeB.count == width * height,
                     "plane buffers must be exactly width*height")

        let blocksX = (width + 7) / 8
        let blocksY = (height + 7) / 8
        precondition(sharpnessField.count >= blocksX * blocksY,
                     "sharpness field must cover the block grid")
        precondition(perBlockQF.count >= blocksX * blocksY,
                     "perBlockQF must cover the block grid")

        // Build the per-block inv_sigma table.
        var invSigmaPerBlock = [Float](repeating: 0,
                                        count: blocksX * blocksY)
        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                let bi = by * blocksX + bx
                invSigmaPerBlock[bi] = computeInvSigma(
                    sharpness: sharpnessField[bi],
                    rowQuant: perBlockQF[bi],
                    quantScale: quantScale,
                    params: params
                )
            }
        }

        // Stage application order per libjxl. Run EPF1 first (always
        // applied), then EPF2 (iters >= 2), then EPF0 (iters >= 3).
        if params.epfIters >= 1 {
            applyEPF1(planeX: &planeX, planeY: &planeY, planeB: &planeB,
                      width: width, height: height,
                      blocksX: blocksX, invSigmaPerBlock: invSigmaPerBlock,
                      params: params)
        }
        if params.epfIters >= 2 {
            applyEPF2(planeX: &planeX, planeY: &planeY, planeB: &planeB,
                      width: width, height: height,
                      blocksX: blocksX, invSigmaPerBlock: invSigmaPerBlock,
                      params: params)
        }
        if params.epfIters >= 3 {
            applyEPF0(planeX: &planeX, planeY: &planeY, planeB: &planeB,
                      width: width, height: height,
                      blocksX: blocksX, invSigmaPerBlock: invSigmaPerBlock,
                      params: params)
        }
    }

    // MARK: - EPF1 (5×5 plus, 4 neighbours, 3×3-plus SAD per neighbour)

    /// EPF1 stage. For each pixel: compute 4 SADs (one per cardinal
    /// neighbour, summed over 3 channels weighted by
    /// `epf_channel_scale`), use them as bilateral weights to
    /// produce a weighted average of the centre + 4 neighbours.
    /// Border pixels mirror.
    static func applyEPF1(
        planeX: inout [Float], planeY: inout [Float], planeB: inout [Float],
        width: Int, height: Int,
        blocksX: Int, invSigmaPerBlock: [Float],
        params: EPFParams
    ) {
        let inX = planeX, inY = planeY, inB = planeB
        var outX = inX
        var outY = inY
        var outB = inB
        let sm: Float = 1.65
        let bsm: Float = sm * params.borderSadMul
        // sad_mul at position (ix, iy) within the 8×8 block — borders
        // get the smaller multiplier (border_sad_mul).
        @inline(__always)
        func sadMul(ix: Int, iy: Int) -> Float {
            if iy == 0 || iy == 7 { return bsm }
            return (ix == 0 || ix == 7) ? bsm : sm
        }
        @inline(__always)
        func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
            return v < lo ? lo : (v > hi ? hi : v)
        }
        let scaleX = params.channelScale.0
        let scaleY = params.channelScale.1
        let scaleB = params.channelScale.2
        let zeroFlush = params.pass1ZeroFlush
        _ = zeroFlush  // libjxl's `Weight` ignores `thres`; kept for symmetry

        for y in 0..<height {
            for x in 0..<width {
                let bx = x / 8, by = y / 8
                let invSigmaBase = invSigmaPerBlock[by * blocksX + bx]
                if invSigmaBase < kMinSigma {
                    outX[y * width + x] = inX[y * width + x]
                    outY[y * width + x] = inY[y * width + x]
                    outB[y * width + x] = inB[y * width + x]
                    continue
                }
                let invSigma = invSigmaBase * sadMul(ix: x % 8, iy: y % 8)

                // Mirror-clamped pixel fetch.
                @inline(__always)
                func get(_ p: [Float], _ xx: Int, _ yy: Int) -> Float {
                    let cx = clamp(xx, 0, width - 1)
                    let cy = clamp(yy, 0, height - 1)
                    return p[cy * width + cx]
                }
                // Compute 4 SADs for top, left, right, bottom neighbours.
                // Each SAD sums |a - b| over a small set of pixel pairs
                // that form a 3×3-plus shape between centre and neighbour.
                @inline(__always)
                func sadFor(dx: Int, dy: Int) -> Float {
                    let nx = x + dx, ny = y + dy
                    var sX: Float = 0, sY: Float = 0, sB: Float = 0
                    // 5 pixel pairs (mirroring libjxl's per-direction
                    // SAD layout): pair the 3×3-plus around centre with
                    // the matching 3×3-plus around the neighbour.
                    for (dxC, dyC) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let ax = x + dxC, ay = y + dyC
                        let bx2 = nx + dxC, by2 = ny + dyC
                        sX += abs(get(inX, ax, ay) - get(inX, bx2, by2))
                        sY += abs(get(inY, ax, ay) - get(inY, bx2, by2))
                        sB += abs(get(inB, ax, ay) - get(inB, bx2, by2))
                    }
                    return sX * scaleX + sY * scaleY + sB * scaleB
                }
                let sadTop = sadFor(dx: 0, dy: -1)
                let sadLeft = sadFor(dx: -1, dy: 0)
                let sadRight = sadFor(dx: 1, dy: 0)
                let sadBot = sadFor(dx: 0, dy: 1)
                @inline(__always)
                func weight(_ sad: Float) -> Float {
                    return max(0, sad * invSigma + 1)
                }
                let wT = weight(sadTop)
                let wL = weight(sadLeft)
                let wR = weight(sadRight)
                let wBo = weight(sadBot)
                var wSum: Float = 1
                var aX: Float = inX[y * width + x]
                var aY: Float = inY[y * width + x]
                var aB: Float = inB[y * width + x]
                // top
                wSum += wT
                aX += wT * get(inX, x, y - 1)
                aY += wT * get(inY, x, y - 1)
                aB += wT * get(inB, x, y - 1)
                // left
                wSum += wL
                aX += wL * get(inX, x - 1, y)
                aY += wL * get(inY, x - 1, y)
                aB += wL * get(inB, x - 1, y)
                // right
                wSum += wR
                aX += wR * get(inX, x + 1, y)
                aY += wR * get(inY, x + 1, y)
                aB += wR * get(inB, x + 1, y)
                // bottom
                wSum += wBo
                aX += wBo * get(inX, x, y + 1)
                aY += wBo * get(inY, x, y + 1)
                aB += wBo * get(inB, x, y + 1)
                let invW = 1.0 / wSum
                outX[y * width + x] = aX * invW
                outY[y * width + x] = aY * invW
                outB[y * width + x] = aB * invW
            }
        }
        planeX = outX
        planeY = outY
        planeB = outB
    }

    // MARK: - EPF2 (3×3 plus, 4 neighbours, single-pixel diff per neighbour)

    /// EPF2 stage. Same structure as EPF1 but the per-neighbour SAD
    /// is just the absolute difference of centre vs neighbour (1 pair
    /// per neighbour, summed over 3 channels). Border-mirror.
    static func applyEPF2(
        planeX: inout [Float], planeY: inout [Float], planeB: inout [Float],
        width: Int, height: Int,
        blocksX: Int, invSigmaPerBlock: [Float],
        params: EPFParams
    ) {
        let inX = planeX, inY = planeY, inB = planeB
        var outX = inX
        var outY = inY
        var outB = inB
        let sm: Float = params.pass2SigmaScale
        let bsm: Float = sm * params.borderSadMul
        @inline(__always)
        func sadMul(ix: Int, iy: Int) -> Float {
            if iy == 0 || iy == 7 { return bsm }
            return (ix == 0 || ix == 7) ? bsm : sm
        }
        @inline(__always)
        func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
            return v < lo ? lo : (v > hi ? hi : v)
        }
        let scaleX = params.channelScale.0
        let scaleY = params.channelScale.1
        let scaleB = params.channelScale.2

        for y in 0..<height {
            for x in 0..<width {
                let bx = x / 8, by = y / 8
                let invSigmaBase = invSigmaPerBlock[by * blocksX + bx]
                if invSigmaBase < kMinSigma {
                    outX[y * width + x] = inX[y * width + x]
                    outY[y * width + x] = inY[y * width + x]
                    outB[y * width + x] = inB[y * width + x]
                    continue
                }
                let invSigma = invSigmaBase * sadMul(ix: x % 8, iy: y % 8)
                @inline(__always)
                func get(_ p: [Float], _ xx: Int, _ yy: Int) -> Float {
                    let cx = clamp(xx, 0, width - 1)
                    let cy = clamp(yy, 0, height - 1)
                    return p[cy * width + cx]
                }
                let cX = inX[y * width + x]
                let cY = inY[y * width + x]
                let cB = inB[y * width + x]
                @inline(__always)
                func sadFor(_ nX: Float, _ nY: Float, _ nB: Float) -> Float {
                    return abs(cX - nX) * scaleX
                         + abs(cY - nY) * scaleY
                         + abs(cB - nB) * scaleB
                }
                @inline(__always)
                func weight(_ sad: Float) -> Float {
                    return max(0, sad * invSigma + 1)
                }
                // 4 cardinal neighbours.
                let txN = get(inX, x, y - 1), tyN = get(inY, x, y - 1), tbN = get(inB, x, y - 1)
                let lxN = get(inX, x - 1, y), lyN = get(inY, x - 1, y), lbN = get(inB, x - 1, y)
                let rxN = get(inX, x + 1, y), ryN = get(inY, x + 1, y), rbN = get(inB, x + 1, y)
                let bxN = get(inX, x, y + 1), byN = get(inY, x, y + 1), bbN = get(inB, x, y + 1)
                let wT = weight(sadFor(txN, tyN, tbN))
                let wL = weight(sadFor(lxN, lyN, lbN))
                let wR = weight(sadFor(rxN, ryN, rbN))
                let wBo = weight(sadFor(bxN, byN, bbN))
                let wSum = 1 + wT + wL + wR + wBo
                let invW = 1.0 / wSum
                outX[y * width + x] = (cX + wT * txN + wL * lxN + wR * rxN + wBo * bxN) * invW
                outY[y * width + x] = (cY + wT * tyN + wL * lyN + wR * ryN + wBo * byN) * invW
                outB[y * width + x] = (cB + wT * tbN + wL * lbN + wR * rbN + wBo * bbN) * invW
            }
        }
        planeX = outX
        planeY = outY
        planeB = outB
    }

    // MARK: - EPF0 (7×7 plus-with-diagonals, 12 neighbours, 3×3-plus SAD per neighbour)

    /// EPF0 stage — the largest of the three EPF passes; only emitted
    /// when `epf_iters >= 3` (less common than EPF1/EPF2).
    ///
    /// Same template as EPF1: per-pixel weighted bilateral average,
    /// where the weight per neighbour comes from a SAD between two
    /// 3×3-plus shapes (centre-plus and neighbour-plus). The
    /// difference vs EPF1 is the neighbour set:
    ///
    ///     EPF1: 4 neighbours at offsets (0,±1), (±1,0)
    ///     EPF0: 12 neighbours forming a 5×5 plus shape:
    ///           (-2,0), (-1,-1), (-1,0), (-1,1),
    ///           (0,-2), (0,-1), (0,1), (0,2),
    ///           (1,-1), (1,0), (1,1), (2,0)
    ///
    /// Plus a different sigma scale (`epf_pass0_sigma_scale * 1.65`).
    /// libjxl: `render_pipeline/stage_epf.cc::EPF0Stage`.
    static func applyEPF0(
        planeX: inout [Float], planeY: inout [Float], planeB: inout [Float],
        width: Int, height: Int,
        blocksX: Int, invSigmaPerBlock: [Float],
        params: EPFParams
    ) {
        let inX = planeX, inY = planeY, inB = planeB
        var outX = inX
        var outY = inY
        var outB = inB
        let sm: Float = params.pass0SigmaScale * 1.65
        let bsm: Float = sm * params.borderSadMul
        @inline(__always)
        func sadMul(ix: Int, iy: Int) -> Float {
            if iy == 0 || iy == 7 { return bsm }
            return (ix == 0 || ix == 7) ? bsm : sm
        }
        @inline(__always)
        func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
            return v < lo ? lo : (v > hi ? hi : v)
        }
        let scaleX = params.channelScale.0
        let scaleY = params.channelScale.1
        let scaleB = params.channelScale.2

        // 12 neighbour offsets forming a 5×5 plus (sads_off in libjxl).
        let neighbourOffsets: [(Int, Int)] = [
            (-2,  0), (-1, -1), (-1,  0), (-1,  1),
            ( 0, -2), ( 0, -1), ( 0,  1), ( 0,  2),
            ( 1, -1), ( 1,  0), ( 1,  1), ( 2,  0),
        ]
        // 5 pixel pairs forming the 3×3-plus SAD shape (plus_off).
        let plusOffsets: [(Int, Int)] = [
            (0, 0), (-1, 0), (0, -1), (1, 0), (0, 1),
        ]

        for y in 0..<height {
            for x in 0..<width {
                let bx = x / 8, by = y / 8
                let invSigmaBase = invSigmaPerBlock[by * blocksX + bx]
                if invSigmaBase < kMinSigma {
                    outX[y * width + x] = inX[y * width + x]
                    outY[y * width + x] = inY[y * width + x]
                    outB[y * width + x] = inB[y * width + x]
                    continue
                }
                let invSigma = invSigmaBase * sadMul(ix: x % 8, iy: y % 8)

                @inline(__always)
                func get(_ p: [Float], _ xx: Int, _ yy: Int) -> Float {
                    let cx = clamp(xx, 0, width - 1)
                    let cy = clamp(yy, 0, height - 1)
                    return p[cy * width + cx]
                }
                @inline(__always)
                func sadFor(dx: Int, dy: Int) -> Float {
                    let nx = x + dx, ny = y + dy
                    var sX: Float = 0, sY: Float = 0, sB: Float = 0
                    for (dxC, dyC) in plusOffsets {
                        let ax = x + dxC, ay = y + dyC
                        let bx2 = nx + dxC, by2 = ny + dyC
                        sX += abs(get(inX, ax, ay) - get(inX, bx2, by2))
                        sY += abs(get(inY, ax, ay) - get(inY, bx2, by2))
                        sB += abs(get(inB, ax, ay) - get(inB, bx2, by2))
                    }
                    return sX * scaleX + sY * scaleY + sB * scaleB
                }
                @inline(__always)
                func weight(_ sad: Float) -> Float {
                    return max(0, sad * invSigma + 1)
                }

                let cX = inX[y * width + x]
                let cY = inY[y * width + x]
                let cB = inB[y * width + x]
                var accX = cX
                var accY = cY
                var accB = cB
                var wSum: Float = 1
                for (dx, dy) in neighbourOffsets {
                    let nX = get(inX, x + dx, y + dy)
                    let nY = get(inY, x + dx, y + dy)
                    let nB = get(inB, x + dx, y + dy)
                    let w = weight(sadFor(dx: dx, dy: dy))
                    accX += w * nX
                    accY += w * nY
                    accB += w * nB
                    wSum += w
                }
                let invW = 1.0 / wSum
                outX[y * width + x] = accX * invW
                outY[y * width + x] = accY * invW
                outB[y * width + x] = accB * invW
            }
        }
        planeX = outX
        planeY = outY
        planeB = outB
    }
}
