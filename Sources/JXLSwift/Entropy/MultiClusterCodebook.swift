// MultiClusterCodebook — per-cluster ANS distributions OR per-cluster
// Huffman tables, decoded as a unit immediately after
// `EntropySectionHeader`.
//
// ISO/IEC 18181-1 §C.6 (libjxl `lib/jxl/dec_ans.cc::DecodeANSCodes`):
//
//   if use_prefix_code:
//     for c in 0..<num_histograms: alphabet_sizes[c] = VarLenUint16 + 1
//     for c in 0..<num_histograms:
//       if alphabet_sizes[c] > 1:
//         huffman_data[c] = PrefixCodeFormat.decode(alphabet_sizes[c])
//       else: degenerate single-symbol code
//   else:
//     for c in 0..<num_histograms:
//       counts[c] = SpecANSDistribution.readHistogram(precisionBits=12)
//
// `EntropySectionHeader.numHistograms` supplies the cluster count;
// `EntropySectionHeader.usePrefixCode` picks which branch to read.
//
// This is the missing layer between the entropy-section structural
// prefix (which sets up clustering and per-cluster HybridUintConfig)
// and the actual stream of tokens that follows. With it, a JXL
// decoder can parse all the per-cluster tables it needs to interpret
// the entropy-coded body.

import Foundation

public enum MultiClusterCodebookError: Error, Sendable {
    case bitstream(BitstreamError)
    case prefix(PrefixCodeFormatError)
    case ans(SpecANSDistributionError)
}

/// Per-cluster decoded codebook — either a Huffman table or an
/// rANS distribution count array. Exactly one of `huffmanTables`
/// and `ansCounts` is populated, picked by the surrounding
/// `EntropySectionHeader.usePrefixCode`.
public struct MultiClusterCodebook: Sendable {
    /// One Huffman table per cluster; populated when the surrounding
    /// section uses prefix codes. Empty otherwise.
    public let huffmanTables: [PrefixCodeTable]
    /// One frequency array per cluster; populated when the surrounding
    /// section uses rANS. Empty otherwise.
    public let ansCounts: [[Int32]]
    /// Per-cluster alphabet sizes. For prefix-code clusters this is
    /// the value libjxl reads via `VarLenUint16 + 1`. For ANS this is
    /// the count array's length (right-truncated by libjxl's
    /// trailing-zero pop).
    public let alphabetSizes: [Int]

    public init(
        huffmanTables: [PrefixCodeTable],
        ansCounts: [[Int32]],
        alphabetSizes: [Int]
    ) {
        self.huffmanTables = huffmanTables
        self.ansCounts = ansCounts
        self.alphabetSizes = alphabetSizes
    }

    /// Read all per-cluster tables that follow an
    /// `EntropySectionHeader`. The caller passes the parsed header so
    /// we know `numHistograms` and `usePrefixCode`.
    public static func read(
        from r: inout BitReader,
        header: EntropySectionHeader
    ) throws -> MultiClusterCodebook {
        let n = header.numHistograms
        if header.usePrefixCode {
            // 1. Per-cluster alphabet sizes.
            var alphabetSizes = [Int]()
            alphabetSizes.reserveCapacity(n)
            for _ in 0..<n {
                let raw: UInt32
                do { raw = try r.readVarLenUint16() }
                catch let e as BitstreamError {
                    throw MultiClusterCodebookError.bitstream(e)
                }
                alphabetSizes.append(Int(raw) + 1)
            }
            // 2. Per-cluster Huffman tables. Single-symbol alphabets
            // emit zero bits and decode to the trivial table.
            var huffman = [PrefixCodeTable]()
            huffman.reserveCapacity(n)
            for c in 0..<n {
                let alpha = alphabetSizes[c]
                let tbl: PrefixCodeTable
                do {
                    tbl = try PrefixCodeFormat.decode(
                        from: &r, alphabetSize: alpha
                    )
                } catch let e as PrefixCodeFormatError {
                    throw MultiClusterCodebookError.prefix(e)
                }
                huffman.append(tbl)
            }
            return MultiClusterCodebook(
                huffmanTables: huffman,
                ansCounts: [],
                alphabetSizes: alphabetSizes
            )
        }
        // ANS path.
        var counts = [[Int32]]()
        counts.reserveCapacity(n)
        var alphabetSizes = [Int]()
        alphabetSizes.reserveCapacity(n)
        for _ in 0..<n {
            let cnt: [Int32]
            do {
                cnt = try SpecANSDistribution.readHistogram(
                    from: &r, precisionBits: 12
                )
            } catch let e as SpecANSDistributionError {
                throw MultiClusterCodebookError.ans(e)
            }
            counts.append(cnt)
            alphabetSizes.append(cnt.count)
        }
        return MultiClusterCodebook(
            huffmanTables: [], ansCounts: counts,
            alphabetSizes: alphabetSizes
        )
    }
}
