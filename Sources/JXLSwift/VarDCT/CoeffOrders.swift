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

public enum CoeffOrdersError: Error, Sendable {
    case bitstream(BitstreamError)
    case tokenStream(TokenStreamReaderError)
    case invalidPermutationSize(end: Int, size: Int)
    case invalidLehmerCode(i: Int, code: UInt32, n: Int)
}

public enum CoeffOrders {

    /// libjxl `coeff_order.h::kPermutationContexts`.
    public static let kPermutationContexts: Int = 8

    /// libjxl `coeff_order_fwd.h::kNumOrders`.
    public static let kNumOrders: Int = 13

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
    public static func context(_ val: UInt32) -> Int {
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

    /// Read all permutations encoded in `usedOrders`. The caller has
    /// already consumed the per-pass DecodeHistograms for the
    /// permutation-context histograms and provides the resulting
    /// `TokenStreamReader`. Result is currently DISCARDED — this
    /// pass exists to advance the bitstream past the per-pass
    /// permutation block so the AC group decode can begin at the
    /// correct position.
    ///
    /// libjxl-equivalent flow (`coeff_order.cc::DecodeCoeffOrders`):
    ///
    ///     for ord in unique(kStrategyOrder):
    ///         if (used_orders & (1 << ord)) == 0: continue
    ///         for c in 0..<3:
    ///             readPermutation(skip=llf, size=size,
    ///                             stream=permutationStream)
    public static func skipUnusedPermutations(
        usedOrders: UInt16,
        from r: inout BitReader,
        stream: inout TokenStreamReader
    ) throws {
        guard usedOrders != 0 else { return }
        for ord in 0..<kNumOrders {
            if (usedOrders >> UInt16(ord)) & 1 == 0 { continue }
            let llf = kPerOrdLLF[ord]
            let size = kPerOrdSize[ord]
            // 3 channels: X, Y, B.
            for _ in 0..<3 {
                try readAndDiscardPermutation(
                    skip: llf, size: size, from: &r, stream: &stream
                )
            }
        }
    }

    /// Read one permutation's tokens off the wire and discard. Mirrors
    /// libjxl `ReadPermutation`:
    ///
    ///     end = readToken(context(size)) + skip
    ///     if end > size: failure
    ///     last = 0
    ///     for i in skip..<end:
    ///         lehmer[i] = readToken(context(last))
    ///         last = lehmer[i]
    ///         if lehmer[i] >= size - i: failure
    ///
    /// The caller's `TokenStreamReader` advances state appropriately.
    private static func readAndDiscardPermutation(
        skip: Int, size: Int,
        from r: inout BitReader,
        stream: inout TokenStreamReader
    ) throws {
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
        var last: UInt32 = 0
        for i in skip..<end {
            let lehmer: UInt32
            do {
                lehmer = try stream.readToken(
                    context: context(last), from: &r
                )
            } catch let e as TokenStreamReaderError {
                throw CoeffOrdersError.tokenStream(e)
            }
            guard lehmer < UInt32(size - i) else {
                throw CoeffOrdersError.invalidLehmerCode(
                    i: i, code: lehmer, n: size
                )
            }
            last = lehmer
        }
        // We don't decode the Lehmer code into a real permutation here
        // because no current code path consumes it. Once an AC strategy
        // other than DCT8 lands per-block, the caller will provide a
        // destination buffer and we'll do the order-statistics-tree
        // decode (libjxl `lehmer_code.h::DecodeLehmerCode`).
    }
}
