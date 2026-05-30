// ACGroupDecoder — orchestrate per-block AC decode + dequant + IDCT
// across an entire AC group for a single channel.
//
// VarDCT splits each frame into AC groups (libjxl: 256×256 pixels by
// default = 32×32 8×8 cells). Inside each group the AC tokens for
// every channel × every block are interleaved in a specific order:
// for each cell in raster order, decode each channel's block. This
// file provides the per-channel sub-loop — the wider per-group
// orchestration that interleaves three channels in a single
// tokenstream lives one layer up (where it can also feed
// ChromaFromLuma re-correlation between channels).
//
// **Status**: single-channel, DCT8x8-only loop. Larger AC strategies
// require sizing the per-block buffer to `coveredBlocks * 64` and
// emitting tokens once per multi-cell block instead of once per
// 8×8 cell. The skeleton is ready — the loop signature already
// takes `coveredBlocks`/`log2CoveredBlocks` — but the per-strategy
// scan-order tables (`coeff_orders[ord, c]`) need to land first
// (libjxl `coeff_order.cc` precomputes them).
//
// Spec: ISO/IEC 18181-1 §K.8 + §K.9. libjxl: `lib/jxl/dec_group.cc`.

import Foundation

package enum ACGroupDecoderError: Error, Sendable {
    case sizeMismatch(String)
    case acDecode(ACDecoderError)
}

package enum ACGroupDecoder {

    /// Decode one channel's worth of an AC group: walk every 8×8
    /// cell in raster order, call `ACDecoder.decodeBlock`,
    /// dequantise, IDCT, and place the resulting 8×8 pixel block
    /// into the output buffer at the cell's position.
    ///
    /// - Parameters:
    ///   - groupX, groupY: cell-grid dimensions of the group (e.g.
    ///     32×32 for a 256×256 group).
    ///   - dcPlane: cell-grid DC values (length `groupX * groupY`).
    ///     Each cell's DC coefficient pre-loads block[0] before
    ///     `decodeBlock` adds AC residuals (libjxl convention).
    ///   - weights: per-coefficient quant weights for this channel,
    ///     length 64 (DCT8x8 quantisation table for the channel).
    ///   - scale: global quantiser scale (frame-level).
    ///   - channel: 0=X, 1=Y, 2=B (used for `BlockCtxMap.context`).
    ///   - ctxMap: the frame's BlockCtxMap.
    ///   - ctxOffset: per-pass ANS context offset (0 for non-
    ///     progressive single-pass frames).
    ///   - stream / r: positioned at the start of the channel's AC
    ///     tokens for this group.
    /// - Returns: row-major float pixel buffer of length
    ///   `(groupX * 8) * (groupY * 8)`, ready for inverse colour
    ///   transform / Gaborish.
    package static func decodeChannel(
        groupX: Int, groupY: Int,
        dcPlane: [Int32],
        weights: [Float], scale: Float,
        channel: Int, ctxMap: BlockCtxMap, ctxOffset: Int,
        stream: inout TokenStreamReader,
        from r: inout BitReader
    ) throws -> [Float] {
        guard dcPlane.count == groupX * groupY else {
            throw ACGroupDecoderError.sizeMismatch(
                "dcPlane: got \(dcPlane.count), want \(groupX * groupY)"
            )
        }
        guard weights.count == 64 else {
            throw ACGroupDecoderError.sizeMismatch(
                "weights: got \(weights.count), want 64 (DCT8x8)"
            )
        }
        let pixelW = groupX * 8
        let pixelH = groupY * 8
        var pixels = [Float](repeating: 0, count: pixelW * pixelH)

        // libjxl tracks "nzeros per cell row" for the nnz prediction
        // (top + left neighbour averaging). One Int32 per cell.
        var rowAbove: [Int32]? = nil
        var rowCurrent = [Int32](repeating: 0, count: groupX)

        // Default DCT8x8 setup.
        let coveredBlocks = 1
        let log2CoveredBlocks = 0
        let order = kDCT8x8NaturalOrder

        for by in 0..<groupY {
            for bx in 0..<groupX {
                // Per-block context — assume default qf=0, dc bucket=0.
                // Production decode pulls qf from the frame's quant
                // field plane and dc from the bucketised DC value.
                let blockCtx = ctxMap.context(
                    dcIdx: 0, qf: 0, ord: 0, c: channel
                )
                let predicted = ACDecoder.predictNnz(
                    rowAbove: rowAbove, rowCurrent: rowCurrent, bx: bx
                )
                // Pre-populate block[0] with the DC value (libjxl
                // accumulates AC `+=` into this).
                var block = [Int32](repeating: 0, count: 64)
                block[0] = dcPlane[by * groupX + bx]
                do {
                    try ACDecoder.decodeBlock(
                        block: &block, order: order,
                        coveredBlocks: coveredBlocks,
                        log2CoveredBlocks: log2CoveredBlocks,
                        blockCtx: blockCtx, predictedNnz: predicted,
                        ctxOffset: ctxOffset, ctxMap: ctxMap,
                        stream: &stream, from: &r
                    )
                } catch let e as ACDecoderError {
                    throw ACGroupDecoderError.acDecode(e)
                }
                // After decode: count nzeros in this block for next-
                // row prediction (libjxl tracks the *post*-decode
                // value, scaled by 1/coveredBlocks for multi-cell
                // strategies).
                var nzeros: Int32 = 0
                for k in 1..<64 where block[k] != 0 { nzeros += 1 }
                rowCurrent[bx] = nzeros
                // Dequantise this block's coefficients to float
                // amplitudes.
                let amps = Dequantize.dequantize(
                    coefficients: block, weights: weights, scale: scale
                )
                // IDCT into an 8×8 pixel block.
                var pixelBlock = amps
                DCT2D.inverse(&pixelBlock, size: 8)
                // Stitch into the group's pixel buffer at the cell's
                // position.
                let originX = bx * 8
                let originY = by * 8
                for ry in 0..<8 {
                    let dstRow = (originY + ry) * pixelW + originX
                    for rx in 0..<8 {
                        pixels[dstRow + rx] = pixelBlock[ry * 8 + rx]
                    }
                }
            }
            // Roll the nzeros window forward.
            rowAbove = rowCurrent
            rowCurrent = [Int32](repeating: 0, count: groupX)
        }
        return pixels
    }
}

/// Multi-channel result. One float pixel buffer per colour plane,
/// already inverse-DCT'd back to the (DC + AC IDCT) domain.
package struct ACGroupRGBResult: Sendable {
    package let xPlane: [Float]
    package let yPlane: [Float]
    package let bPlane: [Float]
}

extension ACGroupDecoder {

    /// Three-channel AC group decode for VarDCT-XYB frames. Each
    /// 8×8 cell's tokens stream out per-channel in (Y, X, B) order
    /// — libjxl's convention so the Y plane is available for the
    /// chroma-from-luma re-correlation that follows on X and B.
    ///
    /// Coefficient-level CfL: given per-cell `Y_to_X` / `Y_to_B`
    /// slopes, the dequantised coefficient tables look like
    ///     X_dequant = X_decoded + Y_dequant · YtoX_slope
    /// applied per-coefficient *before* the IDCT.
    ///
    /// `cfl: nil` skips the CfL re-correlation entirely (useful
    /// for tests + sRGB-input-as-XYB-stub frames).
    package static func decodeRGB(
        groupX: Int, groupY: Int,
        dcPlaneX: [Int32], dcPlaneY: [Int32], dcPlaneB: [Int32],
        weightsX: [Float], weightsY: [Float], weightsB: [Float],
        scale: Float,
        ctxMap: BlockCtxMap, ctxOffset: Int,
        cfl: ColorCorrelationMap? = nil,
        stream: inout TokenStreamReader,
        from r: inout BitReader
    ) throws -> ACGroupRGBResult {
        let n = groupX * groupY
        guard dcPlaneX.count == n, dcPlaneY.count == n, dcPlaneB.count == n
        else {
            throw ACGroupDecoderError.sizeMismatch(
                "DC planes must each be groupX*groupY = \(n)"
            )
        }
        guard weightsX.count == 64, weightsY.count == 64, weightsB.count == 64
        else {
            throw ACGroupDecoderError.sizeMismatch(
                "weights buffers must each be 64 (DCT8x8)"
            )
        }
        let pixelW = groupX * 8
        let pixelH = groupY * 8
        var xPx = [Float](repeating: 0, count: pixelW * pixelH)
        var yPx = [Float](repeating: 0, count: pixelW * pixelH)
        var bPx = [Float](repeating: 0, count: pixelW * pixelH)

        // Per-channel nzeros prediction state.
        var rowAboveY: [Int32]? = nil
        var rowAboveX: [Int32]? = nil
        var rowAboveB: [Int32]? = nil
        var rowCurrentY = [Int32](repeating: 0, count: groupX)
        var rowCurrentX = [Int32](repeating: 0, count: groupX)
        var rowCurrentB = [Int32](repeating: 0, count: groupX)

        let order = kDCT8x8NaturalOrder

        for by in 0..<groupY {
            for bx in 0..<groupX {
                let cellIdx = by * groupX + bx
                // Per-channel block decoding. libjxl emits Y first
                // so X and B can re-correlate against the just-
                // decoded Y coefficients.
                let blockY = try decodeOneBlock(
                    dcValue: dcPlaneY[cellIdx], channel: 1,
                    rowAbove: rowAboveY, rowCurrent: rowCurrentY,
                    bx: bx, ctxMap: ctxMap, ctxOffset: ctxOffset,
                    order: order, stream: &stream, from: &r
                )
                rowCurrentY[bx] = countNzeros(blockY)
                let blockX = try decodeOneBlock(
                    dcValue: dcPlaneX[cellIdx], channel: 0,
                    rowAbove: rowAboveX, rowCurrent: rowCurrentX,
                    bx: bx, ctxMap: ctxMap, ctxOffset: ctxOffset,
                    order: order, stream: &stream, from: &r
                )
                rowCurrentX[bx] = countNzeros(blockX)
                let blockB = try decodeOneBlock(
                    dcValue: dcPlaneB[cellIdx], channel: 2,
                    rowAbove: rowAboveB, rowCurrent: rowCurrentB,
                    bx: bx, ctxMap: ctxMap, ctxOffset: ctxOffset,
                    order: order, stream: &stream, from: &r
                )
                rowCurrentB[bx] = countNzeros(blockB)

                // Dequantise to float amplitudes.
                var ampsY = Dequantize.dequantize(
                    coefficients: blockY, weights: weightsY, scale: scale
                )
                var ampsX = Dequantize.dequantize(
                    coefficients: blockX, weights: weightsX, scale: scale
                )
                var ampsB = Dequantize.dequantize(
                    coefficients: blockB, weights: weightsB, scale: scale
                )
                // Optional CfL re-correlation (per-coefficient
                // multiply-add of `Y · slope`). The cell's slope is
                // looked up by its top-left pixel coordinate.
                if let cmap = cfl {
                    let pixelX = bx * 8
                    let pixelY = by * 8
                    let yToX = cmap.base.ytoXRatio(
                        slope: cmap.ytoxAt(pixelX, pixelY)
                    )
                    let yToB = cmap.base.ytoBRatio(
                        slope: cmap.ytobAt(pixelX, pixelY)
                    )
                    for k in 0..<64 {
                        ampsX[k] += ampsY[k] * yToX
                        ampsB[k] += ampsY[k] * yToB
                    }
                }
                // IDCT each plane's block to pixels.
                DCT2D.inverse(&ampsY, size: 8)
                DCT2D.inverse(&ampsX, size: 8)
                DCT2D.inverse(&ampsB, size: 8)
                // Stitch into the group's per-plane pixel buffers.
                let originX = bx * 8
                let originY = by * 8
                for ry in 0..<8 {
                    let dstRow = (originY + ry) * pixelW + originX
                    for rx in 0..<8 {
                        let dst = dstRow + rx
                        let src = ry * 8 + rx
                        yPx[dst] = ampsY[src]
                        xPx[dst] = ampsX[src]
                        bPx[dst] = ampsB[src]
                    }
                }
            }
            rowAboveY = rowCurrentY
            rowAboveX = rowCurrentX
            rowAboveB = rowCurrentB
            rowCurrentY = [Int32](repeating: 0, count: groupX)
            rowCurrentX = [Int32](repeating: 0, count: groupX)
            rowCurrentB = [Int32](repeating: 0, count: groupX)
        }
        return ACGroupRGBResult(xPlane: xPx, yPlane: yPx, bPlane: bPx)
    }

    /// Internal helper — decode one DCT8x8 block. Same shape as
    /// the per-cell body in `decodeChannel`, factored out so the
    /// 3-channel path can call it per-channel without duplicating.
    private static func decodeOneBlock(
        dcValue: Int32, channel: Int,
        rowAbove: [Int32]?, rowCurrent: [Int32], bx: Int,
        ctxMap: BlockCtxMap, ctxOffset: Int,
        order: [Int],
        stream: inout TokenStreamReader, from r: inout BitReader
    ) throws -> [Int32] {
        let blockCtx = ctxMap.context(
            dcIdx: 0, qf: 0, ord: 0, c: channel
        )
        let predicted = ACDecoder.predictNnz(
            rowAbove: rowAbove, rowCurrent: rowCurrent, bx: bx
        )
        var block = [Int32](repeating: 0, count: 64)
        block[0] = dcValue
        do {
            try ACDecoder.decodeBlock(
                block: &block, order: order,
                coveredBlocks: 1, log2CoveredBlocks: 0,
                blockCtx: blockCtx, predictedNnz: predicted,
                ctxOffset: ctxOffset, ctxMap: ctxMap,
                stream: &stream, from: &r
            )
        } catch let e as ACDecoderError {
            throw ACGroupDecoderError.acDecode(e)
        }
        return block
    }

    @inline(__always)
    private static func countNzeros(_ block: [Int32]) -> Int32 {
        var n: Int32 = 0
        for k in 1..<64 where block[k] != 0 { n += 1 }
        return n
    }
}

/// Encoder counterpart to `ACGroupDecoder.decodeChannel`. Used today
/// only by the round-trip tests; will become the per-channel sub-
/// loop of the production lossy encoder once the AC global section
/// + bitstream layer is ready.
package enum ACGroupEncoder {

    /// Tokenise one channel's worth of an AC group: forward DCT each
    /// 8×8 cell, quantise, write tokens via `ACEncoder.encodeBlock`.
    /// Returns the per-cell DC plane (so the caller can write it
    /// separately, mirroring how libjxl's DC group section ships
    /// the DC values out-of-band from the AC stream).
    package static func encodeChannel(
        pixels: [Float],
        groupX: Int, groupY: Int,
        weights: [Float], scale: Float,
        channel: Int, ctxMap: BlockCtxMap, ctxOffset: Int,
        writer: TokenStreamWriter,
        to w: inout BitWriter
    ) throws -> [Int32] {
        let pixelW = groupX * 8
        let pixelH = groupY * 8
        precondition(pixels.count == pixelW * pixelH)
        precondition(weights.count == 64)
        var dcPlane = [Int32](repeating: 0, count: groupX * groupY)
        var rowAbove: [Int32]? = nil
        var rowCurrent = [Int32](repeating: 0, count: groupX)
        let order = kDCT8x8NaturalOrder

        for by in 0..<groupY {
            for bx in 0..<groupX {
                // Slice 8×8 pixel block out of the group buffer.
                let originX = bx * 8
                let originY = by * 8
                var pixelBlock = [Float](repeating: 0, count: 64)
                for ry in 0..<8 {
                    let srcRow = (originY + ry) * pixelW + originX
                    for rx in 0..<8 {
                        pixelBlock[ry * 8 + rx] = pixels[srcRow + rx]
                    }
                }
                // Forward DCT + quantise.
                DCT2D.forward(&pixelBlock, size: 8)
                let coeffs = Dequantize.quantize(
                    amplitudes: pixelBlock, weights: weights, scale: scale
                )
                dcPlane[by * groupX + bx] = coeffs[0]

                let blockCtx = ctxMap.context(
                    dcIdx: 0, qf: 0, ord: 0, c: channel
                )
                let predicted = ACDecoder.predictNnz(
                    rowAbove: rowAbove, rowCurrent: rowCurrent, bx: bx
                )
                // Encode AC positions only — the decoder pre-loads
                // block[0] from the DC plane separately.
                var encBlock = coeffs
                encBlock[0] = 0   // AC encoder must not see the DC.
                try ACEncoder.encodeBlock(
                    block: encBlock, order: order,
                    coveredBlocks: 1, log2CoveredBlocks: 0,
                    blockCtx: blockCtx, predictedNnz: predicted,
                    ctxOffset: ctxOffset, ctxMap: ctxMap,
                    writer: writer, to: &w
                )
                // Track nzeros for next row's nnz prediction.
                var nzeros: Int32 = 0
                for k in 1..<64 where encBlock[k] != 0 { nzeros += 1 }
                rowCurrent[bx] = nzeros
            }
            rowAbove = rowCurrent
            rowCurrent = [Int32](repeating: 0, count: groupX)
        }
        return dcPlane
    }

    /// Three-channel encode counterpart of `ACGroupDecoder.decodeRGB`.
    /// Forward DCTs each cell of each plane, applies inverse-CfL
    /// (subtract `Y · slope` from X and B), quantises, and emits
    /// (Y, X, B) interleaved per cell. Returns the three DC planes
    /// (which the caller writes separately, mirroring how the libjxl
    /// DC group section ships DC out-of-band from the AC stream).
    package static func encodeRGB(
        xPx: [Float], yPx: [Float], bPx: [Float],
        groupX: Int, groupY: Int,
        weightsX: [Float], weightsY: [Float], weightsB: [Float],
        scale: Float,
        ctxMap: BlockCtxMap, ctxOffset: Int,
        cfl: ColorCorrelationMap? = nil,
        writer: TokenStreamWriter,
        to w: inout BitWriter
    ) throws -> (dcX: [Int32], dcY: [Int32], dcB: [Int32]) {
        let pixelW = groupX * 8
        let pixelH = groupY * 8
        precondition(xPx.count == pixelW * pixelH)
        precondition(yPx.count == pixelW * pixelH)
        precondition(bPx.count == pixelW * pixelH)
        var dcX = [Int32](repeating: 0, count: groupX * groupY)
        var dcY = [Int32](repeating: 0, count: groupX * groupY)
        var dcB = [Int32](repeating: 0, count: groupX * groupY)
        var rowAboveY: [Int32]? = nil
        var rowAboveX: [Int32]? = nil
        var rowAboveB: [Int32]? = nil
        var rowCurrentY = [Int32](repeating: 0, count: groupX)
        var rowCurrentX = [Int32](repeating: 0, count: groupX)
        var rowCurrentB = [Int32](repeating: 0, count: groupX)
        let order = kDCT8x8NaturalOrder

        for by in 0..<groupY {
            for bx in 0..<groupX {
                let originX = bx * 8
                let originY = by * 8
                // Slice each plane's 8×8 cell.
                func slice(_ src: [Float]) -> [Float] {
                    var out = [Float](repeating: 0, count: 64)
                    for ry in 0..<8 {
                        let srcRow = (originY + ry) * pixelW + originX
                        for rx in 0..<8 {
                            out[ry * 8 + rx] = src[srcRow + rx]
                        }
                    }
                    return out
                }
                var pixelY = slice(yPx)
                var pixelX = slice(xPx)
                var pixelB = slice(bPx)
                // Forward DCT each plane.
                DCT2D.forward(&pixelY, size: 8)
                DCT2D.forward(&pixelX, size: 8)
                DCT2D.forward(&pixelB, size: 8)
                // Inverse CfL: subtract `Y · slope` from X and B
                // before quantisation (mirrors the decoder's
                // `+= Y · slope` post-dequant).
                if let cmap = cfl {
                    let yToX = cmap.base.ytoXRatio(
                        slope: cmap.ytoxAt(originX, originY)
                    )
                    let yToB = cmap.base.ytoBRatio(
                        slope: cmap.ytobAt(originX, originY)
                    )
                    for k in 0..<64 {
                        pixelX[k] -= pixelY[k] * yToX
                        pixelB[k] -= pixelY[k] * yToB
                    }
                }
                let coeffsY = Dequantize.quantize(
                    amplitudes: pixelY, weights: weightsY, scale: scale
                )
                let coeffsX = Dequantize.quantize(
                    amplitudes: pixelX, weights: weightsX, scale: scale
                )
                let coeffsB = Dequantize.quantize(
                    amplitudes: pixelB, weights: weightsB, scale: scale
                )
                let cellIdx = by * groupX + bx
                dcY[cellIdx] = coeffsY[0]
                dcX[cellIdx] = coeffsX[0]
                dcB[cellIdx] = coeffsB[0]

                // Encode (Y, X, B) order.
                try emitBlock(
                    coeffs: coeffsY, channel: 1,
                    rowAbove: rowAboveY, rowCurrent: rowCurrentY, bx: bx,
                    ctxMap: ctxMap, ctxOffset: ctxOffset, order: order,
                    writer: writer, to: &w
                )
                rowCurrentY[bx] = nzerosOf(coeffsY)
                try emitBlock(
                    coeffs: coeffsX, channel: 0,
                    rowAbove: rowAboveX, rowCurrent: rowCurrentX, bx: bx,
                    ctxMap: ctxMap, ctxOffset: ctxOffset, order: order,
                    writer: writer, to: &w
                )
                rowCurrentX[bx] = nzerosOf(coeffsX)
                try emitBlock(
                    coeffs: coeffsB, channel: 2,
                    rowAbove: rowAboveB, rowCurrent: rowCurrentB, bx: bx,
                    ctxMap: ctxMap, ctxOffset: ctxOffset, order: order,
                    writer: writer, to: &w
                )
                rowCurrentB[bx] = nzerosOf(coeffsB)
            }
            rowAboveY = rowCurrentY
            rowAboveX = rowCurrentX
            rowAboveB = rowCurrentB
            rowCurrentY = [Int32](repeating: 0, count: groupX)
            rowCurrentX = [Int32](repeating: 0, count: groupX)
            rowCurrentB = [Int32](repeating: 0, count: groupX)
        }
        return (dcX: dcX, dcY: dcY, dcB: dcB)
    }

    private static func emitBlock(
        coeffs: [Int32], channel: Int,
        rowAbove: [Int32]?, rowCurrent: [Int32], bx: Int,
        ctxMap: BlockCtxMap, ctxOffset: Int,
        order: [Int],
        writer: TokenStreamWriter,
        to w: inout BitWriter
    ) throws {
        let blockCtx = ctxMap.context(
            dcIdx: 0, qf: 0, ord: 0, c: channel
        )
        let predicted = ACDecoder.predictNnz(
            rowAbove: rowAbove, rowCurrent: rowCurrent, bx: bx
        )
        var encBlock = coeffs
        encBlock[0] = 0
        try ACEncoder.encodeBlock(
            block: encBlock, order: order,
            coveredBlocks: 1, log2CoveredBlocks: 0,
            blockCtx: blockCtx, predictedNnz: predicted,
            ctxOffset: ctxOffset, ctxMap: ctxMap,
            writer: writer, to: &w
        )
    }

    @inline(__always)
    private static func nzerosOf(_ block: [Int32]) -> Int32 {
        var n: Int32 = 0
        for k in 1..<64 where block[k] != 0 { n += 1 }
        return n
    }
}
