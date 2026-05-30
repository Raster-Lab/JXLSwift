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

package enum MultiClusterCodebookError: Error, Sendable {
    case bitstream(BitstreamError)
    case prefix(PrefixCodeFormatError)
    case ans(SpecANSDistributionError)
}

/// Per-cluster decoded codebook — either a Huffman table or an
/// rANS distribution count array. Exactly one of `huffmanTables`
/// and `ansCounts` is populated, picked by the surrounding
/// `EntropySectionHeader.usePrefixCode`.
package struct MultiClusterCodebook: Sendable {
    /// One Huffman table per cluster; populated when the surrounding
    /// section uses prefix codes. Empty otherwise.
    package let huffmanTables: [PrefixCodeTable]
    /// One frequency array per cluster; populated when the surrounding
    /// section uses rANS. Empty otherwise.
    package let ansCounts: [[Int32]]
    /// Per-cluster alphabet sizes. For prefix-code clusters this is
    /// the value libjxl reads via `VarLenUint16 + 1`. For ANS this is
    /// the count array's length (right-truncated by libjxl's
    /// trailing-zero pop).
    package let alphabetSizes: [Int]

    package init(
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
    package static func read(
        from r: inout BitReader,
        header: EntropySectionHeader
    ) throws -> MultiClusterCodebook {
        let n = header.numHistograms
        let traceMC = ProcessInfo.processInfo.environment["JXL_TRACE"] != nil
        if traceMC {
            FileHandle.standardError.write(Data(
                "TRACE MultiClusterCodebook.read n=\(n) usePrefix=\(header.usePrefixCode) at pos=\(r.position)\n".utf8))
        }
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
            if traceMC {
                FileHandle.standardError.write(Data(
                    "TRACE MultiClusterCodebook alphabetSizes=\(alphabetSizes) at pos=\(r.position)\n".utf8))
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
        let trace = ProcessInfo.processInfo.environment["JXL_TRACE"] != nil
        for ci in 0..<n {
            let posBefore = r.position
            let cnt: [Int32]
            do {
                cnt = try SpecANSDistribution.readHistogram(
                    from: &r, precisionBits: 12
                )
            } catch let e as SpecANSDistributionError {
                throw MultiClusterCodebookError.ans(e)
            }
            if trace {
                let msg = "TRACE histo[\(ci)]: posBefore=\(posBefore) posAfter=\(r.position) (\(r.position - posBefore) bits) alphabet=\(cnt.count)\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
            counts.append(cnt)
            alphabetSizes.append(cnt.count)
        }
        return MultiClusterCodebook(
            huffmanTables: [], ansCounts: counts,
            alphabetSizes: alphabetSizes
        )
    }

    /// Write the codebook for the prefix-code path with **all
    /// single-symbol clusters** — the simplest case useful for
    /// stub encoders. Emits one `VarLenUint16(0)` per cluster
    /// (declares alphabet size 1), with no Huffman table bits per
    /// cluster (single-symbol alphabets carry zero header bits).
    /// Throws if any cluster's alphabet size is not 1; for the
    /// general case use `write(to:header:)`.
    package func writeSingleSymbolPrefix(
        to w: inout BitWriter, header: EntropySectionHeader
    ) throws {
        guard header.usePrefixCode else {
            throw MultiClusterCodebookError.bitstream(
                .malformedValue("writeSingleSymbolPrefix requires "
                              + "use_prefix_code=true")
            )
        }
        for size in alphabetSizes {
            guard size == 1 else {
                throw MultiClusterCodebookError.bitstream(
                    .malformedValue("writeSingleSymbolPrefix: cluster "
                                  + "alphabet size \(size) ≠ 1; "
                                  + "use write(to:header:) for the "
                                  + "general path")
                )
            }
            do { try w.writeVarLenUint16(0) }
            catch let e as BitstreamError {
                throw MultiClusterCodebookError.bitstream(e)
            }
        }
    }

    /// Write the per-cluster codebook tables that follow an
    /// `EntropySectionHeader`. Picks the prefix-code path or the
    /// rANS-distribution path based on `header.usePrefixCode`.
    ///
    /// **Prefix-code path** (per cluster, in order):
    ///   • `VarLenUint16(alphabet_size - 1)`
    ///   • If `alphabet_size > 1`: `PrefixCodeFormat.encode` over
    ///     the cluster's `lengths` array (recovered from the
    ///     `PrefixCodeTable` stored on this codebook).
    ///   • If `alphabet_size == 1`: zero bits — the surrounding
    ///     codebook header alone tells the decoder.
    ///
    /// **rANS-distribution path** (per cluster, in order):
    ///   • `SpecANSDistribution.writeHistogram(counts)` — the
    ///     simple-1, simple-2, and flat shortcuts plus the full
    ///     **complex** path (general per-symbol histograms) are all
    ///     supported, so any cluster histogram serialises.
    package func write(
        to w: inout BitWriter, header: EntropySectionHeader
    ) throws {
        let n = header.numHistograms
        if header.usePrefixCode {
            guard huffmanTables.count == n,
                  alphabetSizes.count == n else {
                throw MultiClusterCodebookError.bitstream(
                    .malformedValue("prefix codebook has wrong "
                                  + "cluster count (huffman \(huffmanTables.count) "
                                  + "alphabetSizes \(alphabetSizes.count) "
                                  + "expected \(n))")
                )
            }
            // The layout is **all alphabet sizes first, then all
            // Huffman tables** — matching `read` and libjxl
            // `DecodeHistograms` (NOT interleaved size/code pairs;
            // for a single cluster the two layouts coincide, which
            // is why the interleaved bug went unnoticed until the
            // first multi-cluster encoder).
            for c in 0..<n {
                let size = alphabetSizes[c]
                guard size >= 1 && size <= (1 << 16) else {
                    throw MultiClusterCodebookError.bitstream(
                        .malformedValue("alphabet size out of range: \(size)")
                    )
                }
                do { try w.writeVarLenUint16(UInt32(size - 1)) }
                catch let e as BitstreamError {
                    throw MultiClusterCodebookError.bitstream(e)
                }
            }
            for c in 0..<n {
                let size = alphabetSizes[c]
                // size == 1 → no Huffman bits (the size alone is
                // enough); otherwise emit the prefix-code table.
                if size > 1 {
                    let lengths = huffmanTables[c].lengths
                    do {
                        try PrefixCodeFormat.encode(
                            to: &w, lengths: lengths, alphabetSize: size
                        )
                    } catch let e as PrefixCodeFormatError {
                        throw MultiClusterCodebookError.prefix(e)
                    }
                }
            }
            return
        }
        // ANS distribution path.
        guard ansCounts.count == n else {
            throw MultiClusterCodebookError.bitstream(
                .malformedValue("ANS codebook has wrong cluster count "
                              + "(\(ansCounts.count) expected \(n))")
            )
        }
        for c in 0..<n {
            do {
                try SpecANSDistribution.writeHistogram(ansCounts[c], to: &w)
            } catch let e as SpecANSDistributionError {
                throw MultiClusterCodebookError.ans(e)
            }
        }
    }
}
