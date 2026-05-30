// TOCPermutation — entropy-coded TOC group reordering.
//
// ISO/IEC 18181-1 §C.8.1.5 (libjxl `lib/jxl/coeff_order.cc::
// DecodePermutation` + `lib/jxl/lehmer_code.h::DecodeLehmerCode`).
// When the TOC's `has_permutation` flag is 1, an entropy-coded
// Lehmer-code sequence follows; it permutes the per-group byte sizes
// so an encoder can keep raster-order group IDs while emitting groups
// in any order (for random-access optimisation).
//
// **Bit layout:**
//
//     // (after `has_permutation = 1`, before alignToByte)
//     entropy_section_header   // numContexts = 8 (`kPermutationContexts`)
//     end_token                // ANS-coded HybridUint at context CoeffOrderContext(size)
//     for i in 0..<end:
//         lehmer[i]            // ANS-coded HybridUint at context CoeffOrderContext(prev)
//
// Then `DecodeLehmerCode(lehmer)` recovers `permutation[0..<size]`,
// which is the **logical→emission** mapping: section `i` in the
// caller's (logical) view is at emission position `permutation[i]`,
// so its byte offset is the prefix sum at index `permutation[i]` of
// the read-order sizes.

import Foundation

package enum TOCPermutationError: Error, Sendable, Equatable {
    case bitstream(BitstreamError)
    case header(String)
    case codebook(String)
    case ansToken(String)
    case invalidEnd(end: UInt32, size: Int)
    case invalidLehmer(value: UInt32, position: Int, size: Int)
}

/// libjxl `kPermutationContexts` — number of per-magnitude contexts
/// the permutation entropy stream uses.
package let kPermutationContexts: Int = 8

/// libjxl `CoeffOrderContext(val)` — bucket a value into one of 8
/// magnitude classes for context-routing the Lehmer code's tokens.
/// Uses `HybridUintConfig(0, 0, 0)` to extract the token, capped at
/// `kPermutationContexts - 1`.
package func coeffOrderContext(_ val: UInt32) -> Int {
    let cfg = HybridUintConfig(splitExponent: 0,
                               msbInToken: 0, lsbInToken: 0)
    let tok = cfg.encode(val).token
    return min(Int(tok), kPermutationContexts - 1)
}

/// Decode a TOC permutation. `size` is `numTocEntries`. Returns the
/// `[size]` permutation array. The reader is positioned right after
/// the `has_permutation=1` bit; this function consumes the entropy
/// section's bits but **does not** byte-align — the caller does that
/// (matching libjxl `ReadToc`).
package func decodeTOCPermutation(
    from r: inout BitReader, size: Int, skip: Int = 0
) throws -> [Int] {
    // 1. Inner entropy section: 8 contexts.
    let hdr: EntropySectionHeader
    do {
        hdr = try EntropySectionHeader.read(
            from: &r, numContexts: kPermutationContexts
        )
    } catch let e as EntropySectionHeaderError {
        throw TOCPermutationError.header(String(describing: e))
    }
    let cb: MultiClusterCodebook
    do {
        cb = try MultiClusterCodebook.read(from: &r, header: hdr)
    } catch let e as MultiClusterCodebookError {
        throw TOCPermutationError.codebook(String(describing: e))
    }
    var stream = TokenStreamReader(header: hdr, codebook: cb)

    // 2. Read `end` token at context CoeffOrderContext(size).
    let endToken: UInt32
    do {
        endToken = try stream.readToken(
            context: coeffOrderContext(UInt32(size)), from: &r
        )
    } catch let e as TokenStreamReaderError {
        throw TOCPermutationError.ansToken(String(describing: e))
    }
    let end = Int(endToken) &+ skip
    if end > size {
        throw TOCPermutationError.invalidEnd(end: UInt32(end), size: size)
    }

    // 3. Read `lehmer[skip..end]`. Indices outside [skip, end) stay 0.
    var lehmer = [UInt32](repeating: 0, count: size)
    var last: UInt32 = 0
    for i in skip..<end {
        let v: UInt32
        do {
            v = try stream.readToken(
                context: coeffOrderContext(last), from: &r
            )
        } catch let e as TokenStreamReaderError {
            throw TOCPermutationError.ansToken(String(describing: e))
        }
        if v >= UInt32(size - i) {
            throw TOCPermutationError.invalidLehmer(
                value: v, position: i, size: size
            )
        }
        lehmer[i] = v
        last = v
    }

    // 4. Lehmer code → permutation. We use the simple O(n²) algorithm
    // since `size` is tied to `numTocEntries` (≤ 65536 in spec, small
    // for typical files: ≤ a few hundred).
    return lehmerCodeToPermutation(lehmer)
}

/// Convert a Lehmer code to a permutation. `code[i]` is the rank
/// (0-indexed) of `permutation[i]` among the values *not yet placed*
/// at indices 0..<i.
///
/// O(n²) implementation — sufficient for TOC permutation sizes.
/// libjxl uses a Fenwick-tree variant for O(n log n); we can swap
/// later if profiling shows this matters.
package func lehmerCodeToPermutation(_ code: [UInt32]) -> [Int] {
    let n = code.count
    var available = Array(0..<n)
    var perm = [Int](repeating: 0, count: n)
    for i in 0..<n {
        let rank = Int(code[i])
        // `rank` is index into the remaining-available list.
        precondition(rank < available.count, "Lehmer rank out of range")
        perm[i] = available[rank]
        available.remove(at: rank)
    }
    return perm
}
