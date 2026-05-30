// TokenStreamReader — reads context-routed integer tokens from the
// body that follows an entropy section's per-cluster codebook.
//
// ISO/IEC 18181-1 §C.6 (libjxl `ANSSymbolReader::ReadHybridUint*`).
// Once the entropy section's `EntropySectionHeader` and
// `MultiClusterCodebook` have been parsed, the actual stream of
// values is read one token at a time:
//
//   1. Look up `cluster = contextMap[ctx]` for the requested context.
//   2. For prefix-code mode: decode the next Huffman symbol from
//      `huffmanTables[cluster]`. For ANS mode: read the next ANS
//      symbol via the streaming `ANSStreamDecoder` (rANS state init +
//      renorm words come from the same `BitReader`).
//   3. Apply `uintConfigs[cluster].decode(token, br)` to the symbol
//      to recover the unsigned integer value (HybridUint expansion
//      reads any extra raw bits the token encoded).
//
// **LZ77 back-references**: when a symbol decoded at step 2 is `≥
// lz77.minSymbol`, libjxl interprets it as a "length token". The
// reader then:
//   • Decodes the run length via `lz77.lengthUintConfig`.
//   • Reads a "distance token" at an extra cluster (the one beyond
//     the user contexts — `contextMap.map[numUserContexts]`).
//   • Decodes the distance via that cluster's `HybridUintConfig`.
//   • Applies the libjxl `SpecialDistance` remap when a non-zero
//     `distanceMultiplier` is in effect (modular sub-image case):
//     decoded values `< 120` index a 2D pattern LUT scaled by the
//     channel width, and decoded values `≥ 120` map to
//     `decoded + 1 − 120`. When `distanceMultiplier == 0` (the
//     TOC-permutation / context-map case) the distance is simply
//     `decoded + 1`.
//   • Replays `length` previously-emitted values starting `distance`
//     positions back in the running history buffer.
// Subsequent `readToken` calls drain that copy queue before reading
// any new ANS symbols.
//
// libjxl reference: `lib/jxl/dec_ans.h::SpecialDistance`,
// `ReadHybridUintClusteredInlined`. The LUT below is the WebP-lossless
// 2D distance table (`kSpecialDistances`, 120 entries) shifted by the
// channel width — the only way modular streams encode short-range
// "this row" / "row above" copies efficiently.

import Foundation

package enum TokenStreamReaderError: Error, Sendable {
    case bitstream(BitstreamError)
    case hybridUint(HybridUintConfigError)
    case ans(ANSError)
    case lz77NotImplemented
    case lz77InvalidDistance(distance: UInt32, historySize: Int)
    case lz77InvalidLength
    case contextOutOfRange(Int, max: Int)
    case clusterOutOfRange(Int, max: Int)
}

/// libjxl `kNumSpecialDistances` — the size of the 2D distance LUT
/// applied to modular sub-image LZ77 references when a non-zero
/// `distanceMultiplier` is in effect.
package let kNumSpecialDistances: Int = 120

/// libjxl `kSpecialDistances` (WebP-lossless inheritance) — 120 entries
/// of `(rowOffset, colOffset)` pairs. The effective distance is
/// `max(1, rowOffset + multiplier × colOffset)` where the multiplier is
/// the widest channel in the sub-image. This lets short-range
/// "previous row" / "row above" copies fit in a single token.
///
/// Spec / libjxl: `lib/jxl/dec_ans.h::kSpecialDistances`.
package let kSpecialDistancesLUT: [(Int8, Int8)] = [
    (0, 1),  (1, 0),  (1, 1),  (-1, 1), (0, 2),  (2, 0),  (1, 2),  (-1, 2),
    (2, 1),  (-2, 1), (2, 2),  (-2, 2), (0, 3),  (3, 0),  (1, 3),  (-1, 3),
    (3, 1),  (-3, 1), (2, 3),  (-2, 3), (3, 2),  (-3, 2), (0, 4),  (4, 0),
    (1, 4),  (-1, 4), (4, 1),  (-4, 1), (3, 3),  (-3, 3), (2, 4),  (-2, 4),
    (4, 2),  (-4, 2), (0, 5),  (3, 4),  (-3, 4), (4, 3),  (-4, 3), (5, 0),
    (1, 5),  (-1, 5), (5, 1),  (-5, 1), (2, 5),  (-2, 5), (5, 2),  (-5, 2),
    (4, 4),  (-4, 4), (3, 5),  (-3, 5), (5, 3),  (-5, 3), (0, 6),  (6, 0),
    (1, 6),  (-1, 6), (6, 1),  (-6, 1), (2, 6),  (-2, 6), (6, 2),  (-6, 2),
    (4, 5),  (-4, 5), (5, 4),  (-5, 4), (3, 6),  (-3, 6), (6, 3),  (-6, 3),
    (0, 7),  (7, 0),  (1, 7),  (-1, 7), (5, 5),  (-5, 5), (7, 1),  (-7, 1),
    (4, 6),  (-4, 6), (6, 4),  (-6, 4), (2, 7),  (-2, 7), (7, 2),  (-7, 2),
    (3, 7),  (-3, 7), (7, 3),  (-7, 3), (5, 6),  (-5, 6), (6, 5),  (-6, 5),
    (8, 0),  (4, 7),  (-4, 7), (7, 4),  (-7, 4), (8, 1),  (8, 2),  (6, 6),
    (-6, 6), (8, 3),  (5, 7),  (-5, 7), (7, 5),  (-7, 5), (8, 4),  (6, 7),
    (-6, 7), (7, 6),  (-7, 6), (8, 5),  (7, 7),  (-7, 7), (8, 6),  (8, 7),
]

/// Reads HybridUint-decoded integer tokens from an entropy section,
/// routing each request through the section's context map and the
/// per-cluster codebook. Mutating across calls — the rANS state lives
/// inside the reader for the ANS path; the LZ77 history & copy queue
/// also live here.
package struct TokenStreamReader: Sendable {
    package let header: EntropySectionHeader
    package let codebook: MultiClusterCodebook
    /// libjxl's "distance multiplier" — the widest channel width in
    /// the modular sub-image whose LZ77 references this reader
    /// services. `0` disables the `SpecialDistance` remap (correct
    /// for TOC permutation / context-map / tree streams). Modular
    /// sub-image readers must pass the channel-width max so distances
    /// `< 120` get the 2D-pattern LUT treatment that libjxl uses to
    /// encode "previous row" / "row above" patterns.
    package let distanceMultiplier: Int
    /// Lazily-built rANS decoder for the ANS path. nil for prefix-code
    /// sections.
    private var ansDecoder: ANSStreamDecoder?
    /// Running history of emitted **decoded values** (post-HybridUint).
    /// Sized to bound LZ77 distances; libjxl's typical bound is
    /// `1 << 20` but we just grow naturally.
    private var history: [UInt32] = []
    /// Number of values still owed by a running LZ77 copy.
    private var copyRemaining: UInt32 = 0
    /// Index in `history` of the next value to emit during a running
    /// LZ77 copy.
    private var copyReadPos: Int = 0

    package init(
        header: EntropySectionHeader,
        codebook: MultiClusterCodebook,
        distanceMultiplier: Int = 0,
        useAliasTables: Bool = true
    ) {
        self.header = header
        self.codebook = codebook
        self.distanceMultiplier = distanceMultiplier
        if !header.usePrefixCode {
            if useAliasTables,
               let aliasDecoder = try? ANSStreamDecoder(
                   counts: codebook.ansCounts,
                   logAlphaSize: header.logAlphaSize
               ) {
                self.ansDecoder = aliasDecoder
            } else {
                self.ansDecoder = try? ANSStreamDecoder.from(
                    counts: codebook.ansCounts
                )
            }
        } else {
            self.ansDecoder = nil
        }
    }

    /// Read one token at context index `ctx`. The caller threads the
    /// `BitReader` through; consumes a Huffman codeword + optional
    /// extra bits (prefix mode), or an rANS symbol + optional extra
    /// bits (ANS mode, with state init / renorm reads coming from the
    /// same BitReader). Drains any pending LZ77 copy before reading
    /// new ANS symbols.
    package mutating func readToken(
        context ctx: Int, from r: inout BitReader
    ) throws -> UInt32 {
        // 0. Drain any in-flight LZ77 copy first. The "context" the
        // caller supplied is irrelevant here — replay just walks
        // history at the previously-decoded distance.
        if copyRemaining > 0 {
            let v = history[copyReadPos]
            copyReadPos &+= 1
            copyRemaining &-= 1
            history.append(v)
            return v
        }
        // libjxl `ContextMap` for an LZ77-enabled section has
        // `numUserContexts + 1` entries — the extra slot is the LZ77
        // distance context. User reads must stay below that bound;
        // we accept either layout so old call sites that pass the
        // pre-LZ77 user index still validate.
        let totalCtx = header.contextMap.numContexts
        let userCtxBound = header.lz77.enabled
            ? max(0, totalCtx - 1) : totalCtx
        guard ctx >= 0 && ctx < userCtxBound else {
            throw TokenStreamReaderError.contextOutOfRange(
                ctx, max: userCtxBound - 1
            )
        }
        let cluster = Int(header.contextMap.map[ctx])
        guard cluster < header.numHistograms else {
            throw TokenStreamReaderError.clusterOutOfRange(
                cluster, max: header.numHistograms - 1
            )
        }
        let symbol: UInt32
        if header.usePrefixCode {
            symbol = try readPrefixSymbol(cluster: cluster, from: &r)
        } else {
            symbol = try readANSSymbol(cluster: cluster, from: &r)
        }
        // LZ77 length-token branch.
        if header.lz77.enabled, symbol >= header.lz77.minSymbol {
            return try beginLZ77Copy(
                lengthSymbol: symbol, from: &r
            )
        }
        // Normal HybridUint expansion at this cluster's config.
        let value = try expand(symbol: symbol, cluster: cluster, from: &r)
        // History is only needed when LZ77 might trigger; skip the
        // append + amortised reallocation cost on plain streams (the
        // common case for pixel data).
        if header.lz77.enabled {
            history.append(value)
        }
        return value
    }

    /// Prefix-code symbol read (the raw HybridUint token, before
    /// extra-bits expansion).
    private func readPrefixSymbol(
        cluster: Int, from r: inout BitReader
    ) throws -> UInt32 {
        let table = codebook.huffmanTables[cluster]
        let symbol: Int
        do { symbol = try table.decode(from: &r) }
        catch let e as BitstreamError {
            throw TokenStreamReaderError.bitstream(e)
        }
        return UInt32(symbol)
    }

    /// rANS symbol read (the raw HybridUint token).
    private mutating func readANSSymbol(
        cluster: Int, from r: inout BitReader
    ) throws -> UInt32 {
        guard ansDecoder != nil else {
            throw TokenStreamReaderError.ans(.emptyDistribution)
        }
        do {
            return try ansDecoder!.readSymbol(cluster: cluster, from: &r)
        } catch let e as ANSError {
            throw TokenStreamReaderError.ans(e)
        } catch let e as BitstreamError {
            throw TokenStreamReaderError.bitstream(e)
        }
    }

    /// HybridUint extra-bits expansion at this cluster's config.
    private func expand(
        symbol: UInt32, cluster: Int, from r: inout BitReader
    ) throws -> UInt32 {
        let cfg = header.uintConfigs[cluster]
        do { return try cfg.decode(token: symbol, from: &r) }
        catch let e as HybridUintConfigError {
            throw TokenStreamReaderError.hybridUint(e)
        } catch let e as BitstreamError {
            throw TokenStreamReaderError.bitstream(e)
        }
    }

    /// Handle a length-token that triggered LZ77. Decodes the run
    /// length via `lz77.lengthUintConfig`, reads a distance token at
    /// the LZ77 distance cluster, and seeds the copy queue.
    /// Returns the **first** copied value (subsequent calls drain
    /// the queue via the `copyRemaining` branch in `readToken`).
    private mutating func beginLZ77Copy(
        lengthSymbol: UInt32, from r: inout BitReader
    ) throws -> UInt32 {
        // 1. Decode length from `lengthSymbol - minSymbol` via the
        // section's LZ77 length config.
        let lenSym = lengthSymbol &- header.lz77.minSymbol
        let length: UInt32
        do {
            length = try header.lz77.lengthUintConfig.decode(
                token: lenSym, from: &r
            ) &+ header.lz77.minLength
        } catch let e as HybridUintConfigError {
            throw TokenStreamReaderError.hybridUint(e)
        } catch let e as BitstreamError {
            throw TokenStreamReaderError.bitstream(e)
        }
        guard length > 0 else {
            throw TokenStreamReaderError.lz77InvalidLength
        }
        // 2. Distance comes from the extra LZ77 cluster — the last
        // entry in the context map (libjxl `numUserContexts`-th).
        let distCtx = header.contextMap.numContexts - 1
        guard distCtx >= 0 else {
            throw TokenStreamReaderError.contextOutOfRange(distCtx, max: -1)
        }
        let distCluster = Int(header.contextMap.map[distCtx])
        guard distCluster < header.numHistograms else {
            throw TokenStreamReaderError.clusterOutOfRange(
                distCluster, max: header.numHistograms - 1
            )
        }
        let distSymbol: UInt32
        if header.usePrefixCode {
            distSymbol = try readPrefixSymbol(cluster: distCluster, from: &r)
        } else {
            distSymbol = try readANSSymbol(cluster: distCluster, from: &r)
        }
        let rawDist = try expand(
            symbol: distSymbol, cluster: distCluster, from: &r
        )
        // libjxl `ReadHybridUintClusteredInlined`: when the section's
        // `distanceMultiplier > 0` (modular sub-image case), the
        // first `kNumSpecialDistances` (120) wire values index a 2D
        // pattern LUT scaled by the multiplier; the remainder shifts
        // down by 120. With `distanceMultiplier == 0` (TOC permutation
        // / context-map streams) the wire value is just `decoded + 1`.
        let distance: UInt32
        if distanceMultiplier > 0
            && rawDist < UInt32(kNumSpecialDistances) {
            let pair = kSpecialDistancesLUT[Int(rawDist)]
            let s = Int(pair.0) &+ distanceMultiplier &* Int(pair.1)
            distance = UInt32(max(1, s))
        } else {
            let numSpecial: UInt32 =
                distanceMultiplier > 0
                ? UInt32(kNumSpecialDistances) : 0
            distance = rawDist &+ 1 &- numSpecial
        }
        // 3. Validate against history.
        if Int(distance) > history.count {
            throw TokenStreamReaderError.lz77InvalidDistance(
                distance: distance, historySize: history.count
            )
        }
        copyRemaining = length
        copyReadPos = history.count &- Int(distance)
        // 4. Emit the first value and recurse into the drain branch.
        let v = history[copyReadPos]
        copyReadPos &+= 1
        copyRemaining &-= 1
        history.append(v)
        return v
    }
}
