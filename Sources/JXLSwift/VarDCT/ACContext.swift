// ACContext — VarDCT block-context model + per-coefficient context
// derivation.
//
// VarDCT entropy-codes AC coefficients in two phases per 8×8
// block:
//   1. **Number-of-nonzeros (nnz)**, decoded once per block under
//      a context that mixes (block class, predicted-nnz bucket).
//   2. **Per-coefficient symbol**, decoded `nnz` times under a
//      context that mixes (block class, nonzeros-left, scan-position
//      bucket, prev-token sign).
//
// `BlockCtxMap` clusters the (channel, AC-strategy order, qf
// bucket, dc bucket) tuple into a small "block class" so the
// histogram count stays manageable. The default ctx map (libjxl
// `kDefaultCtxMap` in `ac_context.h`) groups the 27 AC strategies
// into 13 size-class orderings; the channel mapping reorders Y
// before X (so Y's larger histograms get the lower indices).
//
// **Status**: model-only. The bitstream layout that overrides the
// default ctx map (per-frame `BlockCtxMap` syntax) lives with the
// AC global section parser, which lands later. The default-config
// path covers the common cjxl output.
//
// Spec: ISO/IEC 18181-1 §K.8 (entropy coding of AC coefficients).
// libjxl: `lib/jxl/ac_context.h`.

import Foundation

/// AC strategy → ordering bucket. 27 strategies are clustered into
/// 13 ordering classes (one per "size class"), shared across
/// XxY / YxX pairs. Direct port of libjxl
/// `coeff_order.h::kStrategyOrder`.
public let kStrategyOrder: [UInt8] = [
    0, 1, 1, 1, 2, 3, 4, 4, 5,  5,  6,  6,  1,  1,
    1, 1, 1, 1, 7, 8, 8, 9, 10, 10, 11, 12, 12,
]

/// `kNumOrders` from libjxl — the number of distinct AC ordering
/// buckets.
public let kNumOrders: Int = 13

/// Maps a zigzag-scan position (0..63) into a compact frequency
/// bucket used by `ZeroDensityContext`. Position 0 (DC) is unused
/// (`0xBAD` in libjxl); positions 1..63 cluster into 31 buckets.
/// Direct port of `ac_context.h::kCoeffFreqContext`.
public let kCoeffFreqContext: [UInt16] = [
    0xBAD, 0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14,
    15,    15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
    23,    23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26,
    27,    27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30,
]

/// Maps a "remaining nonzeros" count (0..63) into a compact context
/// offset. Direct port of `ac_context.h::kCoeffNumNonzeroContext`.
public let kCoeffNumNonzeroContext: [UInt16] = [
    0xBAD, 0,   31,  62,  62,  93,  93,  93,  93,  123, 123, 123, 123,
    152,   152, 152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180,
    180,   180, 180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206,
    206,   206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
    206,   206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
]

/// 37 buckets for "predicted number of nonzeros" — context for the
/// per-block nnz read.
public let kNonZeroBuckets: Int = 37

/// Supremum of `ZeroDensityContext(...) + 1` when `x + y < 64`.
public let kZeroDensityContextCount: Int = 458

/// Absolute supremum of `ZeroDensityContext`.
public let kZeroDensityContextLimit: Int = 474

/// libjxl's spec-default block context map clustering 3 channels ×
/// 13 strategy orderings into 15 distinct block classes.
///
/// Layout: `kDefaultCtxMap[mappedChannel * kNumOrders + ord]`
/// where the channel mapping is **Y first** (libjxl reorders X↔Y
/// so the highest-frequency Y-luma context lands at index 0).
public let kDefaultBlockCtxMap: [UInt8] = [
    0, 1, 2, 2, 3,  3,  4,  5,  6,  6,  6,  6,  6,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
]

/// VarDCT block-context lookup table. Default-constructible to
/// libjxl's spec-default config (no DC thresholds, no QF
/// thresholds, 1 DC context, 15 block classes).
public struct BlockCtxMap: Sendable {
    /// Per-channel DC bucket cutoffs (libjxl `dc_thresholds[3]`).
    /// Empty by default — every block falls into `dc_idx = 0`.
    public var dcThresholds: [[Int32]]
    /// QF bucket cutoffs (libjxl `qf_thresholds`). Empty by default.
    public var qfThresholds: [UInt32]
    /// Compact block-class assignment. Indexed by
    /// `((mappedChannel * kNumOrders + ord) * (qfThresholds.count + 1)
    ///   + qfIdx) * numDcCtxs + dcIdx`.
    public var ctxMap: [UInt8]
    /// Number of distinct block classes (= max(ctxMap) + 1).
    public let numCtxs: Int
    /// Number of DC contexts. With no `dcThresholds[c]` the value
    /// is 1; otherwise it's `(thresh.count + 1)^numChannels`.
    public let numDcCtxs: Int

    public init(
        dcThresholds: [[Int32]] = [[], [], []],
        qfThresholds: [UInt32] = [],
        ctxMap: [UInt8] = kDefaultBlockCtxMap,
        numDcCtxs: Int = 1
    ) {
        precondition(dcThresholds.count == 3,
                     "dcThresholds must have 3 channel arrays")
        self.dcThresholds = dcThresholds
        self.qfThresholds = qfThresholds
        self.ctxMap = ctxMap
        self.numCtxs = (ctxMap.max().map { Int($0) } ?? -1) + 1
        self.numDcCtxs = numDcCtxs
    }

    /// Total number of AC histogram contexts across the whole
    /// frame. Layout: `numCtxs × kNonZeroBuckets` for the per-block
    /// nnz contexts, then `numCtxs × kZeroDensityContextCount` for
    /// the per-coefficient symbol contexts.
    public var numACContexts: Int {
        return numCtxs * (kNonZeroBuckets + kZeroDensityContextCount)
    }

    /// Look up a block class. `dcIdx` is in `[0, numDcCtxs)`; `qf`
    /// is the per-block quantiser-field value; `ord` ∈ `[0, kNumOrders)`
    /// (from `kStrategyOrder[acStrategyRaw]`); `c` is the libjxl
    /// **STORAGE** channel index (0=Y, 1=X, 2=B — libjxl swaps X/Y
    /// at storage so Y lives at slot 0 and X at slot 1). The internal
    /// `c^1 if c<2` mapping converts storage→ctx_map row, putting X
    /// at row 0 (its own clusters 0–6) and Y+B at rows 1–2 (shared
    /// clusters 7–14). Callers that have an XYB index need to convert:
    /// `storageC = (xybC == 0 || xybC == 1) ? (1 - xybC) : 2`.
    public func context(
        dcIdx: Int, qf: UInt32, ord: Int, c: Int
    ) -> Int {
        precondition(c >= 0 && c <= 2)
        // QF bucket: how many thresholds does qf exceed?
        var qfIdx = 0
        for t in qfThresholds where qf > t { qfIdx += 1 }
        // libjxl storage→ctx_map row mapping: storage 0 (Y) → row 1,
        // storage 1 (X) → row 0, storage 2 (B) → row 2.
        let mappedC = (c < 2) ? (c ^ 1) : 2
        var idx = mappedC * kNumOrders + ord
        idx = idx * (qfThresholds.count + 1) + qfIdx
        idx = idx * numDcCtxs + dcIdx
        return Int(ctxMap[idx])
    }

    /// Per-block DC context index (libjxl `compressed_dc.cc::DequantDC`,
    /// the `num_dc_ctxs > 1` branch). Combines the three channels'
    /// **quantised integer** DC values into a single `dc_idx` in
    /// `[0, numDcCtxs)` by counting how many per-channel thresholds
    /// each value exceeds, then mixing the three buckets:
    ///
    /// ```
    /// bucket = bucket_x
    /// bucket = bucket * (dcThresholds[2].count + 1) + bucket_b
    /// bucket = bucket * (dcThresholds[1].count + 1) + bucket_y
    /// ```
    ///
    /// `dcX` / `dcY` / `dcB` are the integer DC values for the block
    /// in XYB channel order (X = libjxl storage channel 1, Y =
    /// storage 0, B = storage 2 — the caller supplies them already
    /// de-mapped to X/Y/B). When `numDcCtxs <= 1` this always
    /// returns 0 (the spec-default single-DC-context case).
    public func dcContextIndex(dcX: Int32, dcY: Int32, dcB: Int32) -> Int {
        if numDcCtxs <= 1 { return 0 }
        var bucketX = 0
        for t in dcThresholds[0] where dcX > t { bucketX += 1 }
        var bucketY = 0
        for t in dcThresholds[1] where dcY > t { bucketY += 1 }
        var bucketB = 0
        for t in dcThresholds[2] where dcB > t { bucketB += 1 }
        var bucket = bucketX
        bucket = bucket * (dcThresholds[2].count + 1) + bucketB
        bucket = bucket * (dcThresholds[1].count + 1) + bucketY
        return bucket
    }

    /// Per-block nnz context: maps (predicted-nnz bucket, block class)
    /// to a compact context index in `[0, numCtxs * kNonZeroBuckets)`.
    public func nonZeroContext(
        nonZeros: UInt32, blockCtx: Int
    ) -> Int {
        let nnz = min(nonZeros, 64)
        let bucket: UInt32 = (nnz < 8) ? nnz : (4 + nnz / 2)
        return Int(bucket) * numCtxs + blockCtx
    }

    /// Read the all_default flag of the BlockCtxMap from the
    /// bitstream. If set (1), returns the libjxl-spec default
    /// `BlockCtxMap()`. Otherwise throws `notDefault` — callers
    /// who want the full reader use `read(from:)` below.
    public static func readDefaultOrThrow(
        from r: inout BitReader
    ) throws -> BlockCtxMap {
        let allDefault: Bool
        do { allDefault = try r.readBit() }
        catch let e as BitstreamError {
            throw BlockCtxMapError.bitstream(e)
        }
        if allDefault { return BlockCtxMap() }
        throw BlockCtxMapError.notDefault
    }

    /// Full `DecodeBlockCtxMap` reader. Mirrors libjxl
    /// `entropy_coder.cc::DecodeBlockCtxMap`:
    ///
    ///     all_default: u(1)
    ///     if all_default: return BlockCtxMap()
    ///     for c in 0..<3:
    ///         num_dc_t[c] = u(4)
    ///         dc_thresholds[c][i] = UnpackSigned(U32(kDCThresholdDist))
    ///     num_qf = u(4)
    ///     qf_thresholds[i] = U32(kQFThresholdDist) + 1
    ///     ctx_map = DecodeContextMap(size = 3 * kNumOrders *
    ///                                num_dc_ctxs * (qf+1))
    ///     enforce num_ctxs <= 16, num_dc_ctxs * (qf+1) <= 64
    public static func read(
        from r: inout BitReader
    ) throws -> BlockCtxMap {
        let trace = ProcessInfo.processInfo.environment["JXL_TRACE"] != nil
        let allDefault: Bool
        do { allDefault = try r.readBit() }
        catch let e as BitstreamError {
            throw BlockCtxMapError.bitstream(e)
        }
        if trace {
            FileHandle.standardError.write(Data(
                "TRACE BlockCtxMap allDefault=\(allDefault) at pos=\(r.position - 1)\n".utf8
            ))
        }
        if allDefault { return BlockCtxMap() }
        do {
            // 3 channels × DC thresholds.
            var dcThresh: [[Int32]] = [[], [], []]
            var numDcCtxs = 1
            for c in 0..<3 {
                let pBefore = r.position
                let n = Int(try r.read(bits: 4))
                if trace {
                    let m = "TRACE BlockCtxMap dc[\(c)] count=\(n) at pos=\(pBefore)\n"
                    FileHandle.standardError.write(Data(m.utf8))
                }
                var arr = [Int32](repeating: 0, count: n)
                for i in 0..<n {
                    let raw = try r.readU32((
                        .bits(4),
                        .offset(constant: 16, extraBits: 8),
                        .offset(constant: 272, extraBits: 16),
                        .offset(constant: 65808, extraBits: 32)
                    ))
                    arr[i] = unpackSigned(raw)
                }
                dcThresh[c] = arr
                numDcCtxs *= (n + 1)
            }
            // QF thresholds.
            let qfPosBefore = r.position
            let numQF = Int(try r.read(bits: 4))
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE BlockCtxMap qf count=\(numQF) at pos=\(qfPosBefore) numDcCtxs=\(numDcCtxs)\n".utf8
                ))
            }
            var qf = [UInt32](repeating: 0, count: numQF)
            for i in 0..<numQF {
                let raw = try r.readU32((
                    .bits(2),
                    .offset(constant: 4, extraBits: 3),
                    .offset(constant: 12, extraBits: 5),
                    .offset(constant: 44, extraBits: 8)
                ))
                qf[i] = raw + 1
            }
            // libjxl: invalid if num_dc_ctxs * (qf+1) > 64.
            if numDcCtxs * (numQF + 1) > 64 {
                throw BlockCtxMapError.invalidLayout(
                    "num_dc_ctxs (\(numDcCtxs)) * (qf+1) "
                    + "(\(numQF + 1)) > 64"
                )
            }
            // Entropy-coded ctx_map.
            let mapSize = 3 * kNumOrders * numDcCtxs * (numQF + 1)
            let cmPosBefore = r.position
            let cm: ContextMap
            do {
                cm = try ContextMap.read(numContexts: mapSize, from: &r)
            } catch let e as ContextMapError {
                throw BlockCtxMapError.contextMap(e)
            }
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE BlockCtxMap ctxMap mapSize=\(mapSize) bits=\(r.position - cmPosBefore) numClusters=\(cm.numClusters)\n".utf8
                ))
                // For the cjxl-d=1 8×8 fixture, the decoded ctxMap
                // values match `kDefaultBlockCtxMap` byte-exact —
                // confirming the inner ContextMap.read produces the
                // right *symbols*. Cursor desync (next session's
                // debug bite) must therefore be in the *bit count*
                // consumed by the same reads, not the symbol values.
                let mapStr = cm.map.map { String($0) }.joined(separator: ",")
                FileHandle.standardError.write(Data(
                    "TRACE BlockCtxMap ctxMap values: [\(mapStr)]\n".utf8
                ))
            }
            // libjxl enforces num_ctxs <= 16 (fits in a 4-bit
            // bucket-counter for the per-block contexts).
            if cm.numClusters > 16 {
                throw BlockCtxMapError.invalidLayout(
                    "num_ctxs (\(cm.numClusters)) > 16"
                )
            }
            return BlockCtxMap(
                dcThresholds: dcThresh,
                qfThresholds: qf,
                ctxMap: cm.map,
                numDcCtxs: numDcCtxs
            )
        } catch let e as BitstreamError {
            throw BlockCtxMapError.bitstream(e)
        }
    }

    /// Offset to the per-coefficient context block for `blockCtx`.
    /// The total AC context space is laid out as:
    ///   [0, numCtxs × kNonZeroBuckets)               nnz contexts
    ///   [numCtxs × kNonZeroBuckets, numACContexts)   coefficient
    /// contexts. `ZeroDensityContextsOffset(block_ctx)` jumps to the
    /// start of `block_ctx`'s slot in the second region.
    public func zeroDensityContextsOffset(blockCtx: Int) -> Int {
        return numCtxs * kNonZeroBuckets +
               kZeroDensityContextCount * blockCtx
    }
}

public enum BlockCtxMapError: Error, Sendable {
    case bitstream(BitstreamError)
    case notDefault
    case contextMap(ContextMapError)
    case invalidLayout(String)
}

/// libjxl `UnpackSigned`: zig-zag inverse mapping. Equivalent to
/// `ZigZag.unpack` for `UInt32`.
@inline(__always)
private func unpackSigned(_ u: UInt32) -> Int32 {
    return ZigZag.unpack(u)
}

/// Per-coefficient context derivation. Mirrors libjxl
/// `ac_context.h::ZeroDensityContext`. Inputs:
///   - `nonzerosLeft` — remaining unread nonzeros in this block
///   - `k` — current scan-order index (1..63 for DCT8x8)
///   - `coveredBlocks` — number of 8×8 cells the parent strategy
///     covers (= 1 for DCT8x8, 4 for DCT16x16, …)
///   - `log2CoveredBlocks` — log₂ of the above
///   - `prev` — 0 for first symbol after nnz; thereafter 1 if the
///     previous symbol was zero, 0 if non-zero (libjxl uses this as
///     a coarse "did the last AC die" sign-bit context)
///
/// The two cluster tables (`kCoeffNumNonzeroContext`,
/// `kCoeffFreqContext`) compress the joint (`nonzerosLeft`, `k`)
/// space into a 458-entry alphabet shared across all blocks.
@inline(__always)
public func zeroDensityContext(
    nonzerosLeft: Int, k: Int,
    coveredBlocks: Int, log2CoveredBlocks: Int,
    prev: Int
) -> Int {
    precondition(coveredBlocks == (1 << log2CoveredBlocks))
    let nzScaled = (nonzerosLeft + coveredBlocks - 1) >> log2CoveredBlocks
    let kScaled = k >> log2CoveredBlocks
    precondition(kScaled > 0 && kScaled < 64)
    precondition(nzScaled > 0 && nzScaled < 64)
    return (Int(kCoeffNumNonzeroContext[nzScaled]) +
            Int(kCoeffFreqContext[kScaled])) * 2 + prev
}
