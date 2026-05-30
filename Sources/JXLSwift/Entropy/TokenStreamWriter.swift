// TokenStreamWriter — encoder counterpart to `TokenStreamReader`.
//
// Caller supplies an `EntropySectionHeader` + `MultiClusterCodebook`
// matching what they wrote to the bit stream just before, and pushes
// (context, value) pairs in the order the decoder will read them.
//
// Two paths, mirroring the decoder:
//
//   • **Prefix-code path** (`header.usePrefixCode == true`):
//     - Look up `cluster = contextMap[ctx]`.
//     - HybridUintConfig.encode(value) → (token, extras).
//     - Emit `token` via `huffmanTables[cluster]` (Huffman codeword)
//       directly to the destination `BitWriter`.
//     - Emit `extraNBits` of `extraBits` to the same `BitWriter`.
//     - No state, no buffering — fully forward.
//
//   • **rANS path** (`header.usePrefixCode == false`):
//     - Push (token, cluster) pairs into a buffer; the encoder runs
//       in REVERSE at `finish()` time so tokens, renorm words, and
//       extras have to interleave manually. **NOT YET IMPLEMENTED**;
//       the prefix-code path is the focus of the first end-to-end
//       encoder iteration.
//
// LZ77 back-references are likewise out of scope here — the reader
// supports replay of length-tokens, but the encoder side needs a
// matching back-reference search and emit. Caller should ensure
// `header.lz77.enabled == false` for now.

import Foundation

package enum TokenStreamWriterError: Error, Sendable {
    case rANSPathNotImplemented
    case lz77NotImplemented
    case contextOutOfRange(Int, max: Int)
    case clusterOutOfRange(Int, max: Int)
    case prefix(PrefixCodeError)
    case bitstream(BitstreamError)
}

/// Encodes a sequence of (context, value) tokens into a destination
/// `BitWriter`, matching the format `TokenStreamReader` expects to
/// read back.
package struct TokenStreamWriter: Sendable {
    package let header: EntropySectionHeader
    package let codebook: MultiClusterCodebook

    package init(header: EntropySectionHeader, codebook: MultiClusterCodebook) {
        self.header = header
        self.codebook = codebook
    }

    /// Emit one (context, value) token.
    package func writeToken(
        context ctx: Int, value: UInt32, to w: inout BitWriter
    ) throws {
        if header.lz77.enabled {
            // The encoder side needs a back-reference search to
            // exploit LZ77; without one we'd fail to maintain the
            // invariant that emitted symbols < lz77.minSymbol.
            throw TokenStreamWriterError.lz77NotImplemented
        }
        guard ctx >= 0 && ctx < header.contextMap.numContexts else {
            throw TokenStreamWriterError.contextOutOfRange(
                ctx, max: header.contextMap.numContexts - 1
            )
        }
        let cluster = Int(header.contextMap.map[ctx])
        guard cluster < header.numHistograms else {
            throw TokenStreamWriterError.clusterOutOfRange(
                cluster, max: header.numHistograms - 1
            )
        }
        // HybridUint expansion to (token, extra_bits).
        let cfg = header.uintConfigs[cluster]
        let exp = cfg.encode(value)
        if header.usePrefixCode {
            // Look up Huffman table.
            guard cluster < codebook.huffmanTables.count else {
                throw TokenStreamWriterError.clusterOutOfRange(
                    cluster, max: codebook.huffmanTables.count - 1
                )
            }
            let table = codebook.huffmanTables[cluster]
            do {
                try table.encode(Int(exp.token), to: &w)
            } catch let e as PrefixCodeError {
                throw TokenStreamWriterError.prefix(e)
            }
            // Extra bits follow the codeword in forward order.
            if exp.extraNBits > 0 {
                w.write(bits: exp.extraNBits, value: exp.extraBits)
            }
            return
        }
        throw TokenStreamWriterError.rANSPathNotImplemented
    }
}
