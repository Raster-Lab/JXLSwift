// ANSTokenStreamWriter — the encoder counterpart to the ANS path of
// `TokenStreamReader` (+ `ANSStreamDecoder`). Produces the exact
// interleaved LSB-first bitstream the streaming rANS decoder consumes.
//
// ISO/IEC 18181-1 §C.6.3 / libjxl `enc_ans.cc`. A JXL ANS token
// section is a SINGLE bitstream that interleaves three things, all
// read forward by the decoder:
//
//   init(32) , [renorm_0(16)?] , extra_0 , [renorm_1(16)?] , extra_1 , …
//
// where `renorm_i` is the 16-bit refill the decoder reads after
// decoding symbol i (only when its rANS state drops below 2^16), and
// `extra_i` are the HybridUint extra bits for token i. rANS encodes in
// REVERSE, so the refill words are produced last-symbol-first; reversed,
// they line up with the decoder's forward reads. The extra bits are
// plain forward bits, emitted in token order right after each token's
// refill — matching the reader's `readANSSymbol` → `expand` sequence.
//
// **Alias layout = libjxl-compatible.** The encode step is the exact
// inverse of `ANSStreamDecoder.readSymbol`'s decode step, including the
// `AliasTable` slot assignment. Because our `AliasTable` is a faithful
// port of libjxl `InitAliasTable` (verified byte-exact against
// cjxl-emitted streams), a stream this writer produces is decodable by
// libjxl/djxl, not just by our own reader. The encoder inverts the
// alias lookup by scanning all `tabSize` slots once per cluster to build
// a `(symbol, residue) → slot` map.
//
// Scope: `lz77.enabled == false` (the bridge + most sections). The
// frequency tables MUST be the on-wire (quantised) distributions the
// decoder reconstructs — see `SpecANSDistribution.writeComplex` — or the
// encode and decode alias tables disagree.

import Foundation

package enum ANSTokenStreamWriterError: Error, Sendable {
    case notANSSection
    case lz77NotSupported
    case contextOutOfRange(Int, max: Int)
    case clusterOutOfRange(Int, max: Int)
    case symbolHasZeroFrequency(cluster: Int, symbol: Int)
    case alias(AliasTableError)
}

/// Buffers context-routed integer tokens and emits them as one
/// interleaved rANS bitstream (init + refill words + HybridUint extra
/// bits) matching `TokenStreamReader`'s ANS path.
package struct ANSTokenStreamWriter {
    package let header: EntropySectionHeader
    package let codebook: MultiClusterCodebook

    /// Per-cluster encode state derived from the on-wire frequencies.
    private struct ClusterEnc {
        let freq: [UInt32]                 // per symbol (the wire counts)
        let slotForResidue: [[UInt32]]     // [symbol][residue] → rANS slot
    }
    private let clusters: [ClusterEnc]

    /// Buffered tokens in forward order: the cluster + the HybridUint
    /// expansion (token symbol + raw extra bits).
    private var pending: [(cluster: Int, symbol: UInt32,
                           extraBits: UInt32, extraNBits: Int)] = []

    package init(
        header: EntropySectionHeader,
        codebook: MultiClusterCodebook
    ) throws {
        guard !header.usePrefixCode else {
            throw ANSTokenStreamWriterError.notANSSection
        }
        guard !header.lz77.enabled else {
            throw ANSTokenStreamWriterError.lz77NotSupported
        }
        self.header = header
        self.codebook = codebook
        let logAlpha = header.logAlphaSize
        let range = Int(ANSConstants.tabSize)
        var built: [ClusterEnc] = []
        built.reserveCapacity(codebook.ansCounts.count)
        for counts in codebook.ansCounts {
            // Frequencies indexed by symbol (the wire counts).
            let freq = counts.map { UInt32(bitPattern: $0) }
            // Invert the alias lookup: scan every slot once, recording
            // the slot for each (symbol, residue=offset) pair.
            let alias: AliasTable
            do {
                alias = try AliasTable(
                    distribution: counts,
                    logRange: ANSConstants.logTabSize,
                    logAlphaSize: logAlpha)
            } catch let e as AliasTableError {
                throw ANSTokenStreamWriterError.alias(e)
            }
            var slotForResidue = [[UInt32]](
                repeating: [], count: freq.count)
            for s in 0..<freq.count where freq[s] > 0 {
                slotForResidue[s] = [UInt32](
                    repeating: 0, count: Int(freq[s]))
            }
            for slot in 0..<range {
                let lr = alias.lookup(slot: UInt32(slot))
                let sym = lr.value
                let off = Int(lr.offset)
                if sym >= 0 && sym < slotForResidue.count
                    && off < slotForResidue[sym].count {
                    slotForResidue[sym][off] = UInt32(slot)
                }
            }
            built.append(ClusterEnc(
                freq: freq, slotForResidue: slotForResidue))
        }
        self.clusters = built
    }

    /// Buffer one token at context `ctx`. Order matters — tokens are
    /// emitted (and the decoder reads them) in this call order.
    package mutating func writeToken(
        context ctx: Int, value: UInt32
    ) throws {
        guard ctx >= 0 && ctx < header.contextMap.numContexts else {
            throw ANSTokenStreamWriterError.contextOutOfRange(
                ctx, max: header.contextMap.numContexts - 1)
        }
        let cluster = Int(header.contextMap.map[ctx])
        guard cluster < header.numHistograms else {
            throw ANSTokenStreamWriterError.clusterOutOfRange(
                cluster, max: header.numHistograms - 1)
        }
        let exp = header.uintConfigs[cluster].encode(value)
        pending.append((cluster, exp.token, exp.extraBits, exp.extraNBits))
    }

    /// Emit the buffered tokens as the interleaved rANS bitstream into
    /// `w` (continuing the same bit position — the decoder reads the
    /// 32-bit state init immediately after the per-cluster codebook).
    package mutating func finish(to w: inout BitWriter) throws {
        let range = UInt32(ANSConstants.tabSize)
        // Per-token forward segment: an optional 16-bit refill word
        // followed by the token's extra bits.
        struct Seg { var hasRefill: Bool; var refill: UInt32
                     var extraBits: UInt32; var extraNBits: Int }
        var segs = [Seg](
            repeating: Seg(hasRefill: false, refill: 0,
                           extraBits: 0, extraNBits: 0),
            count: pending.count)
        // Reverse-order rANS encode, starting from libjxl's initial
        // state (`ANS_SIGNATURE << 16`). The decoder's forward pass ends
        // at this exact value, which libjxl/djxl verifies — using the
        // bare lower bound decodes with our reader but fails djxl.
        var state: UInt32 = ANSConstants.initialState
        var i = pending.count - 1
        while i >= 0 {
            let t = pending[i]
            let enc = clusters[t.cluster]
            let f = enc.freq[Int(t.symbol)]
            guard f > 0 else {
                throw ANSTokenStreamWriterError.symbolHasZeroFrequency(
                    cluster: t.cluster, symbol: Int(t.symbol))
            }
            var hasRefill = false
            var refill: UInt32 = 0
            // Renorm: emit a 16-bit word while the state would push the
            // post-encode value past 2^32. `bound = freq << (32 - logTab)`.
            let bound = UInt64(f) << UInt64(32 - ANSConstants.logTabSize)
            if UInt64(state) >= bound {
                refill = state & 0xFFFF
                state >>= 16
                hasRefill = true
            }
            // Encode step (inverse of the alias decode step).
            let offset = state % f
            let q = state / f
            let slot = enc.slotForResidue[Int(t.symbol)][Int(offset)]
            state = q &* range &+ slot
            segs[i] = Seg(hasRefill: hasRefill, refill: refill,
                          extraBits: t.extraBits, extraNBits: t.extraNBits)
            i -= 1
        }
        // Forward layout: 32-bit init (the final encoder state) then,
        // per token, [refill?][extra bits].
        w.write(bits: 32, value: state)
        for seg in segs {
            if seg.hasRefill { w.write(bits: 16, value: seg.refill) }
            if seg.extraNBits > 0 {
                w.write(bits: seg.extraNBits, value: seg.extraBits)
            }
        }
    }

    /// Number of buffered tokens.
    package var tokenCount: Int { pending.count }
}
