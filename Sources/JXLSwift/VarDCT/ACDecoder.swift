// ACDecoder — per-block VarDCT AC coefficient stream decode.
//
// Converts the entropy-coded token stream that fills an AC group
// into per-block integer DCT coefficients. The output integers
// still need dequantisation (`Dequantize.dequantize`) and IDCT
// (`DCT2D.inverse`) before they're pixels.
//
// The decode loop per block:
//   1. Read an `nnz` token under context
//      `BlockCtxMap.NonZeroContext(predictedNnz, blockCtx) + ctxOffset`.
//   2. For each scan-order position `k` in `[coveredBlocks, size)`
//      while there are nonzeros remaining:
//        a. Compute coefficient context via `zeroDensityContext`.
//        b. Read a coefficient token; unpack via `ZigZag.unpack`
//           (libjxl's "neg_sign" form is bit-equal to our zig-zag
//           signed unpacker).
//        c. Place coefficient at `order[k]` in the natural-order
//           block buffer.
//        d. Track `prev` (was the last symbol zero?) and
//           decrement `nnz`.
//
// Spec: ISO/IEC 18181-1 §K.8. libjxl: `lib/jxl/dec_group.cc::
// DecodeACVarBlock`.
//
// **Status**: single-block decoder for `coveredBlocks = 1`
// (DCT8x8). The covered-blocks > 1 path (DCT16x16, DCT32x32 etc.)
// reuses the same loop with a different scan order and coverage
// mask — the `decode(...)` entry point already takes
// `coveredBlocks` so larger strategies just need a caller that
// sizes the block buffer to `coveredBlocks * 64` and supplies
// the right `order[]`.

import Foundation

public enum ACDecoderError: Error, Sendable {
    case nzerosOutOfRange(Int, max: Int)
    case nzerosNonZeroAtEnd(Int)
    case tokenStream(TokenStreamReaderError)
    case bitstream(BitstreamError)
}

/// Natural coefficient order for an 8×8 DCT block — the JPEG-style
/// zig-zag (or "snake") order libjxl computes via
/// `AcStrategy::ComputeNaturalCoeffOrder` for `cx=cy=1` with the
/// alternating-direction diagonal scan in
/// `lib/jxl/ac_strategy.cc::CoeffOrderAndLut`.
///
/// `naturalCoeffOrderDCT8[k]` is the natural-order position
/// (`y * 8 + x`) for the `k`-th scan-order index. `block[order[k]]`
/// places the k-th decoded scan-order coefficient at its 8×8 grid
/// position before IDCT.
public let naturalCoeffOrderDCT8: [Int] = [
    0,  1,  8, 16,  9,  2,  3, 10, 17, 24, 32, 25, 18, 11,  4,  5,
   12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13,  6,  7, 14, 21, 28,
   35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
   58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
]

public enum ACDecoder {

    /// Decode one VarDCT AC block from `stream`. Coefficients
    /// accumulate into `block` via `+=` (libjxl's convention so
    /// LLF coefficients pre-loaded into the block survive). The
    /// output buffer must be `coveredBlocks * 64` large and pre-
    /// populated with zeros for AC positions; LLF positions
    /// (the first `coveredBlocks` entries of the natural-order
    /// layout) are left untouched.
    ///
    /// - Parameters:
    ///   - block: in/out coefficient buffer, natural order, length
    ///     `coveredBlocks * 64`. AC positions accumulate `+=`.
    ///   - order: scan-order map, length `coveredBlocks * 64`.
    ///     `order[k]` is the natural-order position of the
    ///     `k`-th scan-order coefficient.
    ///   - coveredBlocks: 1 for DCT8x8, 4 for DCT16x16, etc.
    ///   - log2CoveredBlocks: log2 of the above.
    ///   - blockCtx: from `BlockCtxMap.context(...)` for this block.
    ///   - predictedNnz: predicted nnz from neighbours (caller
    ///     tracks this; the predictor is a small libjxl helper).
    ///   - ctxOffset: per-pass ANS context offset (0 for pass 0
    ///     of single-pass frames).
    ///   - ctxMap: the frame's `BlockCtxMap`.
    ///   - shift: pass-shift in libjxl's progressive pipeline; 0
    ///     for non-progressive single-pass frames.
    ///   - stream / r: caller-supplied TokenStreamReader + BitReader
    ///     positioned at the start of this block's tokens.
    public static func decodeBlock(
        block: inout [Int32],
        order: [Int],
        coveredBlocks: Int, log2CoveredBlocks: Int,
        blockCtx: Int, predictedNnz: UInt32,
        ctxOffset: Int, ctxMap: BlockCtxMap,
        shift: Int = 0,
        stream: inout TokenStreamReader,
        from r: inout BitReader
    ) throws {
        precondition(coveredBlocks == (1 << log2CoveredBlocks))
        let size = coveredBlocks * 64
        precondition(block.count == size,
                     "block must be coveredBlocks * 64")
        precondition(order.count == size, "order must match block size")

        let nzeroCtx =
            ctxMap.nonZeroContext(nonZeros: predictedNnz, blockCtx: blockCtx)
            + ctxOffset
        let nnzU32: UInt32
        do {
            nnzU32 = try stream.readToken(context: nzeroCtx, from: &r)
        } catch let e as TokenStreamReaderError {
            throw ACDecoderError.tokenStream(e)
        } catch let e as BitstreamError {
            throw ACDecoderError.bitstream(e)
        }
        let nnzMax = size - coveredBlocks
        guard nnzU32 <= UInt32(nnzMax) else {
            throw ACDecoderError.nzerosOutOfRange(Int(nnzU32), max: nnzMax)
        }

        var nzeros = Int(nnzU32)
        let histoOffset =
            ctxOffset + ctxMap.zeroDensityContextsOffset(blockCtx: blockCtx)

        // libjxl's heuristic: bias `prev` to 1 when nnz is small —
        // a sparse block tends to start with zeros under the per-
        // coefficient context.
        var prev = (nzeros > size / 16) ? 0 : 1

        var k = coveredBlocks
        while k < size && nzeros != 0 {
            let ctx =
                histoOffset
                + zeroDensityContext(
                    nonzerosLeft: nzeros, k: k,
                    coveredBlocks: coveredBlocks,
                    log2CoveredBlocks: log2CoveredBlocks,
                    prev: prev
                )
            let u: UInt32
            do {
                u = try stream.readToken(context: ctx, from: &r)
            } catch let e as TokenStreamReaderError {
                throw ACDecoderError.tokenStream(e)
            } catch let e as BitstreamError {
                throw ACDecoderError.bitstream(e)
            }
            // Sign decode: u=0→0, u=1→-1, u=2→+1, u=3→-2, …
            // Bit-identical to ZigZag.unpack — same formula libjxl
            // hand-rolls in `dec_group.cc::DecodeACVarBlock`.
            let coeff = ZigZag.unpack(u)
            let scaled = Int32(truncatingIfNeeded:
                Int64(coeff) << Int64(shift))
            block[order[k]] &+= scaled
            // libjxl: `prev = (u != 0); nzeros -= prev;`
            // `prev` flags whether the LAST coefficient was non-zero
            // — the next coefficient's context flips on this bit.
            // (Earlier this was inverted as `(u == 0)`, which masked
            //  itself for single-cluster fixtures because all routes
            //  share an ANS distribution but breaks textured/multi-
            //  cluster fixtures via wrong-context divergence.)
            prev = (u != 0) ? 1 : 0
            if u != 0 { nzeros -= 1 }
            k += 1
        }
        if nzeros != 0 {
            throw ACDecoderError.nzerosNonZeroAtEnd(nzeros)
        }
    }

    /// Predict the nnz of the block at column `bx` from
    /// neighbours. Mirrors libjxl `PredictFromTopAndLeft`:
    ///   • top-left corner (no row above, `bx == 0`): predictedMax
    ///   • left edge (no row above, `bx > 0`): rowCurrent[bx-1]
    ///   • top edge (`bx == 0`, row above present): rowAbove[bx]
    ///   • interior: `(rowAbove[bx] + rowCurrent[bx-1] + 1) >> 1`
    @inline(__always)
    public static func predictNnz(
        rowAbove: [Int32]?, rowCurrent: [Int32], bx: Int,
        predictedMax: Int32 = 32
    ) -> UInt32 {
        guard let top = rowAbove else {
            return UInt32(bx == 0 ? predictedMax : rowCurrent[bx - 1])
        }
        if bx == 0 {
            return UInt32(top[bx])
        }
        let avg = (top[bx] + rowCurrent[bx - 1] + 1) >> 1
        return UInt32(avg)
    }
}

/// AC encoder — counterpart to `ACDecoder.decodeBlock`. Mirrors
/// libjxl's `enc_group.cc::TokenizeCoefficients` for a single
/// VarDCT block. Used today only by tests; the production lossy
/// encoder is still pending.
public enum ACEncoder {

    /// Tokenise one block's AC coefficients into `writer`'s token
    /// buffer. Caller is responsible for ensuring the context map
    /// + codebook the writer was built with covers the contexts
    /// emitted here.
    ///
    /// - Parameters:
    ///   - block: natural-order coefficient buffer, length
    ///     `coveredBlocks * 64`. AC positions are read from
    ///     `[coveredBlocks, size)`.
    ///   - order: scan-order map, same size as `block`.
    ///     `order[k]` is the natural-order index of the `k`-th
    ///     scan-order coefficient.
    ///   - others: same semantics as `ACDecoder.decodeBlock`.
    public static func encodeBlock(
        block: [Int32],
        order: [Int],
        coveredBlocks: Int, log2CoveredBlocks: Int,
        blockCtx: Int, predictedNnz: UInt32,
        ctxOffset: Int, ctxMap: BlockCtxMap,
        shift: Int = 0,
        writer: TokenStreamWriter,
        to w: inout BitWriter
    ) throws {
        precondition(coveredBlocks == (1 << log2CoveredBlocks))
        let size = coveredBlocks * 64
        precondition(block.count == size && order.count == size)

        // Count nonzeros across AC positions.
        var nzeros = 0
        for k in coveredBlocks..<size where block[order[k]] != 0 {
            nzeros += 1
        }
        let nzeroCtx =
            ctxMap.nonZeroContext(nonZeros: predictedNnz, blockCtx: blockCtx)
            + ctxOffset
        try writer.writeToken(
            context: nzeroCtx, value: UInt32(nzeros), to: &w
        )
        if nzeros == 0 { return }

        let histoOffset =
            ctxOffset + ctxMap.zeroDensityContextsOffset(blockCtx: blockCtx)
        var remaining = nzeros
        var prev = (remaining > size / 16) ? 0 : 1
        var k = coveredBlocks
        while k < size && remaining != 0 {
            let ctx =
                histoOffset
                + zeroDensityContext(
                    nonzerosLeft: remaining, k: k,
                    coveredBlocks: coveredBlocks,
                    log2CoveredBlocks: log2CoveredBlocks,
                    prev: prev
                )
            // Apply the inverse `shift` the decoder applies, then
            // ZigZag-pack the signed residual to the unsigned token.
            let raw = block[order[k]] >> Int32(shift)
            let u = ZigZag.pack(raw)
            try writer.writeToken(context: ctx, value: u, to: &w)
            // libjxl convention (mirrors decoder): prev = u != 0.
            prev = (u != 0) ? 1 : 0
            if u != 0 { remaining -= 1 }
            k += 1
        }
    }
}

/// libjxl's "natural" scan order for an 8×8 DCT block (zigzag,
/// from low frequencies to high). `order[k]` is the natural-order
/// (row-major) position of the `k`-th scan-order coefficient.
/// Direct port of libjxl's spec-default DCT8x8 order — reused
/// across all blocks unless an override token in the AC global
/// section says otherwise.
public let kDCT8x8NaturalOrder: [Int] = [
     0,  1,  8,  16,  9,  2,  3, 10,
    17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
]
