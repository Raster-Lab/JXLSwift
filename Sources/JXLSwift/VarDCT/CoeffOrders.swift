// CoeffOrders — VarDCT AC coefficient-order permutations.
//
// ISO/IEC 18181-1 §C.8.5. libjxl: `lib/jxl/coeff_order.cc`.
// `ProcessACGlobal` reads a `used_orders` bitmask (`U32(0x5F, 0x13, 0,
// Bits(13))` per `frame_header.h:503`); for each bit set, the
// codestream encodes a coefficient-order PERMUTATION for each of the
// 3 channels, transmitted via Lehmer codes through an entropy section
// with `kPermutationContexts = 8` rANS contexts.
//
// The decoded permutation maps "scan-order index" → "natural-order
// position" for that AC strategy. For `used_orders` bits NOT set, the
// natural (zigzag-style) order is used — that's the case our existing
// 8×8/16×16/32×32 tests exercise (small fixtures emit `used_orders=0`).
//
// **What this file ships**: the bit-consumption layer for
// `DecodeCoeffOrders`. Larger / textured cjxl-d=1 fixtures emit
// non-zero `used_orders` (e.g., 384×384 → 74, 264×264 → 90); we read
// the corresponding permutations to advance the bitstream past them
// but currently discard the result. Once a real-fixture permutation is
// needed (e.g., AC strategies other than DCT8 in the per-block grid),
// the caller can pass a destination buffer.
//
// **Lehmer codes** (`lib/jxl/lehmer_code.h::DecodeLehmerCode`): a
// permutation of size `n` is encoded as `n` integers `code[i] ∈
// [0, n - i)`; the decoder uses an order-statistics tree (Fenwick-
// like) to extract the i-th unused element at each step. We
// implement this directly in Swift below.

import Foundation

package enum CoeffOrdersError: Error, Sendable {
    case bitstream(BitstreamError)
    case tokenStream(TokenStreamReaderError)
    case invalidPermutationSize(end: Int, size: Int)
    case invalidLehmerCode(i: Int, code: UInt32, n: Int)
}

package enum CoeffOrders {

    /// libjxl `coeff_order.h::kPermutationContexts`.
    package static let kPermutationContexts: Int = 8

    /// libjxl `coeff_order_fwd.h::kNumOrders`.
    package static let kNumOrders: Int = 13

    /// libjxl `coeff_order.cc::CoeffOrderContext`. Encodes `val` via
    /// `HybridUintConfig(0,0,0)` and returns the resulting token,
    /// clamped to `kPermutationContexts - 1`. For HybridUintConfig
    /// `(split_exp=0, msb=0, lsb=0)`:
    ///
    ///     val == 0           → token 0
    ///     val == 1           → token 1
    ///     val ∈ [2^k, 2^(k+1) - 1] for k ≥ 0  → token (k + 1)
    ///
    /// i.e., `token = 1 + floor(log2(val))` for `val >= 1`, then
    /// `min(token, 7)`.
    @inline(__always)
    package static func context(_ val: UInt32) -> Int {
        if val == 0 { return 0 }
        let n = 32 - Int(val.leadingZeroBitCount) - 1  // floor(log2(val))
        return min(1 + n, kPermutationContexts - 1)
    }

    /// Per-ord (LLF, total coefficient count). Indexed by libjxl's
    /// `kStrategyOrder[ord_index]` value (0..12). Derived from any
    /// AC strategy that maps to that ord — strategies sharing an
    /// ord have identical block-coverage shape.
    private static let kPerOrdLLF: [Int] = [
        1, 1, 4, 16, 2, 4, 8, 64, 32, 256, 128, 1024, 512
    ]
    private static let kPerOrdSize: [Int] = kPerOrdLLF.map { $0 * 64 }

    /// Natural (default) AC coefficient scan order for `strategy`.
    ///
    /// Direct port of libjxl `ac_strategy.cc::CoeffOrderAndLut<is_lut=false>`
    /// (called via `AcStrategy::ComputeNaturalCoeffOrder`). Returns
    /// `order` of length `coveredBlocks * 64` where `order[k]` is the
    /// natural-order (row-major within the cx*8 × cy*8 coefficient
    /// grid, after `CoefficientLayout` swap so cx ≥ cy) position of
    /// the `k`-th scan-order coefficient.
    ///
    /// LLF positions occupy scan indices `[0, cx*cy)` and map to the
    /// top-left `cx × cy` corner of the coefficient grid in row-major.
    /// AC positions follow in zig-zag/snake order. For asymmetric
    /// strategies (DCT16x8, DCT32x8, …), `CoefficientLayout` first
    /// swaps cx/cy so cx ≥ cy — so DCT16x8 and DCT8x16 share the
    /// same order (and the same `orderBucket`).
    package static func naturalCoeffOrder(for strategy: ACStrategy) -> [Int] {
        var cx = strategy.blockCells.cellsX
        var cy = strategy.blockCells.cellsY
        // CoefficientLayout(&cy, &cx): make first arg the smaller.
        // We pass (cy, cx) → after: cy = min, cx = max.
        if cy > cx { swap(&cx, &cy) }
        let kBlockDim = 8
        let size = cx * cy * 64
        var order = [Int](repeating: 0, count: size)

        // xs, xsm, xss: when cx == cy this is the trivial case
        // (xs=1, xsm=0, xss=0 — no rows skipped). For cx > cy we
        // generate a zigzag for a cx×cx square then drop rows whose
        // y is not a multiple of (cx/cy).
        let xs = cx / cy                      // ≥ 1
        let xsm = xs - 1
        let xss = xs <= 1 ? 0 : (Int.bitWidth - (xs - 1).leadingZeroBitCount)
        // CeilLog2NonZero(xs): xs=1→0, xs=2→1, xs=4→2, xs=8→3, …

        var cur = cx * cy  // first AC scan slot
        // First half — diagonals i = 0 ..< cx*8.
        for i in 0..<(cx * kBlockDim) {
            for j in 0...i {
                var x = j
                var y = i - j
                if i & 1 == 1 { swap(&x, &y) }
                if (y & xsm) != 0 { continue }
                y >>= xss
                let val: Int
                if x < cx && y < cy {
                    val = y * cx + x
                } else {
                    val = cur
                    cur += 1
                }
                order[val] = y * cx * kBlockDim + x
            }
        }
        // Second half — diagonals i = cx*8 - 2 ..> 0 (descending).
        var ip = cx * kBlockDim - 1
        while ip > 0 {
            let i = ip - 1
            for j in 0...i {
                var x = cx * kBlockDim - 1 - (i - j)
                var y = cx * kBlockDim - 1 - j
                if i & 1 == 1 { swap(&x, &y) }
                if (y & xsm) != 0 { continue }
                y >>= xss
                let val = cur
                cur += 1
                order[val] = y * cx * kBlockDim + x
            }
            ip -= 1
        }
        return order
    }

    /// Read all permutations encoded in `usedOrders`. The caller has
    /// already consumed the per-pass DecodeHistograms for the
    /// permutation-context histograms and provides the resulting
    /// `TokenStreamReader`. Result is currently DISCARDED — this
    /// pass exists to advance the bitstream past the per-pass
    /// permutation block so the AC group decode can begin at the
    /// correct position. **Deprecated** — `decodePermutations(...)`
    /// returns the decoded orders; use that from any path that
    /// actually decodes per-block AC for non-DCT8 strategies, or
    /// for DCT8 strategies when the bitstream sets `used_orders`
    /// bit 0 (cjxl emits this for textured ≥ d=0.5 fixtures).
    package static func skipUnusedPermutations(
        usedOrders: UInt16,
        from r: inout BitReader,
        stream: inout TokenStreamReader
    ) throws {
        _ = try decodePermutations(
            usedOrders: usedOrders, from: &r, stream: &stream
        )
    }

    /// Decode all permutations encoded in `usedOrders` and return
    /// `[ord: [channel: order]]`. Each `order` is a permutation of
    /// `[0, kPerOrdSize[ord])` already composed with the natural
    /// scan order — the result is the FINAL coefficient order the
    /// AC decoder should pass to `ACDecoder.decodeBlock`.
    ///
    /// libjxl `coeff_order.cc::DecodeCoeffOrders` + `DecodeCoeffOrder`:
    ///
    ///     for ord in unique(kStrategyOrder):
    ///         if (used_orders & (1 << ord)) == 0: continue
    ///         natural = ComputeNaturalCoeffOrder(strategy_for_ord)
    ///         for c in 0..<3:
    ///             lehmer = ReadPermutation(skip=llf, size=size, ...)
    ///             order  = DecodeLehmerCode(lehmer, size)
    ///             for k in 0..<size: order[k] = natural[order[k]]
    package static func decodePermutations(
        usedOrders: UInt16,
        from r: inout BitReader,
        stream: inout TokenStreamReader
    ) throws -> [Int: [[Int]]] {
        var orders: [Int: [[Int]]] = [:]
        guard usedOrders != 0 else { return orders }
        for ord in 0..<kNumOrders {
            if (usedOrders >> UInt16(ord)) & 1 == 0 { continue }
            let skip = kPerOrdLLF[ord]
            let size = kPerOrdSize[ord]
            let natural = naturalCoeffOrder(for: representativeStrategy(forOrd: ord))
            var perChannel: [[Int]] = []
            perChannel.reserveCapacity(3)
            for _ in 0..<3 {
                let order = try readPermutation(
                    skip: skip, size: size,
                    natural: natural, from: &r, stream: &stream
                )
                perChannel.append(order)
            }
            orders[ord] = perChannel
        }
        return orders
    }

    /// Read one permutation off the wire and return the final
    /// coefficient order (Lehmer-decoded, then composed with
    /// `natural`).
    private static func readPermutation(
        skip: Int, size: Int, natural: [Int],
        from r: inout BitReader,
        stream: inout TokenStreamReader
    ) throws -> [Int] {
        precondition(natural.count == size,
                     "natural order length must equal permutation size")
        let endRaw: UInt32
        do {
            endRaw = try stream.readToken(
                context: context(UInt32(size)), from: &r
            )
        } catch let e as TokenStreamReaderError {
            throw CoeffOrdersError.tokenStream(e)
        }
        let end = Int(endRaw) + skip
        guard end <= size else {
            throw CoeffOrdersError.invalidPermutationSize(end: end, size: size)
        }
        // libjxl initialises the Lehmer code to all zeros (so positions
        // < skip and ≥ end implicitly yield the i-th unused element).
        var lehmer = [UInt32](repeating: 0, count: size)
        var last: UInt32 = 0
        for i in skip..<end {
            let l: UInt32
            do {
                l = try stream.readToken(
                    context: context(last), from: &r
                )
            } catch let e as TokenStreamReaderError {
                throw CoeffOrdersError.tokenStream(e)
            }
            guard l < UInt32(size - i) else {
                throw CoeffOrdersError.invalidLehmerCode(
                    i: i, code: l, n: size
                )
            }
            lehmer[i] = l
            last = l
        }
        // Lehmer decode: turn the factorial-base code into a
        // permutation of [0, size) using a Fenwick-tree order-
        // statistics structure. Direct port of libjxl
        // `lehmer_code.h::DecodeLehmerCode`.
        let perm = decodeLehmerCode(lehmer, size: size)
        // Compose with natural order.
        var order = [Int](repeating: 0, count: size)
        for k in 0..<size {
            order[k] = natural[perm[k]]
        }
        return order
    }

    /// Pick any AC strategy whose `orderBucket == ord` so we can
    /// generate the natural order for that ord. For asymmetric
    /// strategy pairs (DCT16x8 / DCT8x16) the natural order is
    /// shared by `CoefficientLayout` so either works.
    private static func representativeStrategy(forOrd ord: Int) -> ACStrategy {
        for s in ACStrategy.allCases where s.orderBucket == ord {
            return s
        }
        preconditionFailure("no ACStrategy for ord \(ord)")
    }

    /// libjxl `lehmer_code.h::DecodeLehmerCode` — Fenwick-style
    /// order-statistics tree. `code[0..n)` is a Lehmer code where
    /// `code[i]` is the rank of the i-th selected element among
    /// the still-unused values in `[0, n)`. Returns the resulting
    /// permutation of `[0, n)`.
    package static func decodeLehmerCode(
        _ code: [UInt32], size n: Int
    ) -> [Int] {
        precondition(n > 0, "Lehmer size must be positive")
        // padded_n = next power of two ≥ n.
        var paddedN = 1
        while paddedN < n { paddedN <<= 1 }
        let log2N: Int = paddedN.trailingZeroBitCount
        // Initialise Fenwick: temp[i] = lowest_bit(i+1).
        var temp = [Int](repeating: 0, count: paddedN)
        for i in 0..<paddedN {
            let i1 = i + 1
            temp[i] = i1 & -i1   // ValueOfLowest1Bit
        }
        var perm = [Int](repeating: 0, count: n)
        for i in 0..<n {
            // rank of the i-th unused element (1-indexed).
            var rank = Int(code[i]) + 1
            // Walk Fenwick tree top-down to find the smallest index
            // whose prefix sum ≥ rank.
            var bit = paddedN
            var next = 0
            for _ in 0...log2N {
                let cand = next + bit
                bit >>= 1
                if temp[cand - 1] < rank {
                    next = cand
                    rank -= temp[cand - 1]
                }
            }
            perm[i] = next
            // Mark `next` as used: subtract 1 from all Fenwick
            // bins that count it.
            var cursor = next + 1
            while cursor <= paddedN {
                temp[cursor - 1] -= 1
                cursor += cursor & -cursor
            }
        }
        return perm
    }
}
