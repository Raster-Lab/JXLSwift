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
//      symbol (NOT YET IMPLEMENTED — needs `ANSDecoder` integration).
//   3. Apply `uintConfigs[cluster].decode(token, br)` to the symbol
//      to recover the unsigned integer value (HybridUint expansion
//      reads any extra raw bits the token encoded).
//
// LZ77 back-references are NOT yet decoded — when the surrounding
// `EntropySectionHeader.lz77.enabled` is true and a token ≥
// `lz77.minSymbol` appears, the reader currently throws
// `.lz77NotImplemented`. For Modular tree decoding (the next chain
// milestone), LZ77 is typically disabled and this stays out of scope.

import Foundation

public enum TokenStreamReaderError: Error, Sendable {
    case bitstream(BitstreamError)
    case hybridUint(HybridUintConfigError)
    case ansNotImplemented
    case lz77NotImplemented
    case contextOutOfRange(Int, max: Int)
    case clusterOutOfRange(Int, max: Int)
}

/// Reads HybridUint-decoded integer tokens from an entropy section,
/// routing each request through the section's context map and the
/// per-cluster codebook. Stateless except for the underlying
/// `BitReader`.
public struct TokenStreamReader: Sendable {
    public let header: EntropySectionHeader
    public let codebook: MultiClusterCodebook

    public init(header: EntropySectionHeader, codebook: MultiClusterCodebook) {
        self.header = header
        self.codebook = codebook
    }

    /// Read one token at context index `ctx`. The caller threads the
    /// `BitReader` through; consumes a Huffman codeword + optional
    /// extra bits.
    public func readToken(context ctx: Int, from r: inout BitReader) throws -> UInt32 {
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
        // ANS mode requires maintaining rANS decoder state across
        // tokens — not yet implemented. The MultiClusterCodebook's
        // `ansCounts` field is populated; integrating `ANSDecoder`
        // here is the next chain milestone for the ANS path.
        throw TokenStreamReaderError.ansNotImplemented
    }

    /// Prefix-code token read: decode Huffman symbol via
    /// `huffmanTables[cluster]`, then expand via this cluster's
    /// HybridUintConfig.
    private func readPrefixToken(cluster: Int, from r: inout BitReader) throws -> UInt32 {
        let table = codebook.huffmanTables[cluster]
        let symbol: Int
        do { symbol = try table.decode(from: &r) }
        catch let e as BitstreamError {
            throw TokenStreamReaderError.bitstream(e)
        }
        // LZ77 length-token check.
        if header.lz77.enabled, UInt32(symbol) >= header.lz77.minSymbol {
            throw TokenStreamReaderError.lz77NotImplemented
        }
        let cfg = header.uintConfigs[cluster]
        do {
            return try cfg.decode(token: UInt32(symbol), from: &r)
        } catch let e as HybridUintConfigError {
            throw TokenStreamReaderError.hybridUint(e)
        }
    }
}
