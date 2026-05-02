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
//   • Decodes the distance via that cluster's `HybridUintConfig` (+1).
//   • Replays `length` previously-emitted values starting `distance`
//     positions back in the running history buffer.
// Subsequent `readToken` calls drain that copy queue before reading
// any new ANS symbols. The "special distance" remap (libjxl
// `SpecialDistance`) is only applied when a non-zero distance
// multiplier is in effect — we don't take that branch yet, but
// distances in TOC-permutation / context-map streams use the simple
// `decoded + 1` form.

import Foundation

public enum TokenStreamReaderError: Error, Sendable {
    case bitstream(BitstreamError)
    case hybridUint(HybridUintConfigError)
    case ans(ANSError)
    case lz77NotImplemented
    case lz77InvalidDistance(distance: UInt32, historySize: Int)
    case lz77InvalidLength
    case contextOutOfRange(Int, max: Int)
    case clusterOutOfRange(Int, max: Int)
}

/// Reads HybridUint-decoded integer tokens from an entropy section,
/// routing each request through the section's context map and the
/// per-cluster codebook. Mutating across calls — the rANS state lives
/// inside the reader for the ANS path; the LZ77 history & copy queue
/// also live here.
public struct TokenStreamReader: Sendable {
    public let header: EntropySectionHeader
    public let codebook: MultiClusterCodebook
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

    public init(
        header: EntropySectionHeader,
        codebook: MultiClusterCodebook,
        useAliasTables: Bool = true
    ) {
        self.header = header
        self.codebook = codebook
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
    public mutating func readToken(
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
        let distance = try expand(
            symbol: distSymbol, cluster: distCluster, from: &r
        ) &+ 1
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
