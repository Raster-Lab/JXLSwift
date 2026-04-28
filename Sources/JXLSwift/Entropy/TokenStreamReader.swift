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
// LZ77 back-references are NOT yet decoded — when the surrounding
// `EntropySectionHeader.lz77.enabled` is true and a token ≥
// `lz77.minSymbol` appears, the reader currently throws
// `.lz77NotImplemented`.

import Foundation

public enum TokenStreamReaderError: Error, Sendable {
    case bitstream(BitstreamError)
    case hybridUint(HybridUintConfigError)
    case ans(ANSError)
    case lz77NotImplemented
    case contextOutOfRange(Int, max: Int)
    case clusterOutOfRange(Int, max: Int)
}

/// Reads HybridUint-decoded integer tokens from an entropy section,
/// routing each request through the section's context map and the
/// per-cluster codebook. Mutating across calls — the rANS state lives
/// inside the reader for the ANS path. Prefix-code path is stateless
/// across token reads.
public struct TokenStreamReader: Sendable {
    public let header: EntropySectionHeader
    public let codebook: MultiClusterCodebook
    /// Lazily-built rANS decoder for the ANS path. nil for prefix-code
    /// sections.
    private var ansDecoder: ANSStreamDecoder?

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
    /// same BitReader).
    public mutating func readToken(
        context ctx: Int, from r: inout BitReader
    ) throws -> UInt32 {
        guard ctx >= 0 && ctx < header.contextMap.numContexts else {
            throw TokenStreamReaderError.contextOutOfRange(
                ctx, max: header.contextMap.numContexts - 1
            )
        }
        let cluster = Int(header.contextMap.map[ctx])
        guard cluster < header.numHistograms else {
            throw TokenStreamReaderError.clusterOutOfRange(
                cluster, max: header.numHistograms - 1
            )
        }
        if header.usePrefixCode {
            return try readPrefixToken(cluster: cluster, from: &r)
        }
        return try readANSToken(cluster: cluster, from: &r)
    }

    /// Prefix-code token read: decode Huffman symbol via
    /// `huffmanTables[cluster]`, then expand via this cluster's
    /// HybridUintConfig.
    private func readPrefixToken(
        cluster: Int, from r: inout BitReader
    ) throws -> UInt32 {
        let table = codebook.huffmanTables[cluster]
        let symbol: Int
        do { symbol = try table.decode(from: &r) }
        catch let e as BitstreamError {
            throw TokenStreamReaderError.bitstream(e)
        }
        return try expandToken(symbol: UInt32(symbol), cluster: cluster, from: &r)
    }

    /// rANS token read: pull the next symbol from the streaming ANS
    /// decoder (which reads its own state init / renorm bits from the
    /// same BitReader), then expand via the cluster's HybridUintConfig.
    private mutating func readANSToken(
        cluster: Int, from r: inout BitReader
    ) throws -> UInt32 {
        guard ansDecoder != nil else {
            throw TokenStreamReaderError.ans(.emptyDistribution)
        }
        let symbol: UInt32
        do { symbol = try ansDecoder!.readSymbol(cluster: cluster, from: &r) }
        catch let e as ANSError {
            throw TokenStreamReaderError.ans(e)
        } catch let e as BitstreamError {
            throw TokenStreamReaderError.bitstream(e)
        }
        return try expandToken(symbol: symbol, cluster: cluster, from: &r)
    }

    /// Common HybridUint expansion + LZ77 length-token check.
    private func expandToken(
        symbol: UInt32, cluster: Int, from r: inout BitReader
    ) throws -> UInt32 {
        if header.lz77.enabled, symbol >= header.lz77.minSymbol {
            throw TokenStreamReaderError.lz77NotImplemented
        }
        let cfg = header.uintConfigs[cluster]
        do { return try cfg.decode(token: symbol, from: &r) }
        catch let e as HybridUintConfigError {
            throw TokenStreamReaderError.hybridUint(e)
        } catch let e as BitstreamError {
            // HybridUint extra-bits read can throw BitstreamError
            // directly — wrap so callers get the structured form.
            throw TokenStreamReaderError.bitstream(e)
        }
    }
}
