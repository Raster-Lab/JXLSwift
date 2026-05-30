// ANSStreamDecoder — rANS decoder reading state and renormalisation
// words inline from a `BitReader` (rather than from a separate `Data`
// buffer like `ANSDecoder`).
//
// ISO/IEC 18181-1 §C.6.3 / libjxl `ANSSymbolReader`. The JXL spec
// interleaves rANS-coded tokens with raw extra bits in a single LSB-
// first bitstream: the entropy-section codestream carries the rANS
// state init (32 bits) and renormalisation words (16 bits each) on the
// same `BitReader` that supplies the HybridUint extra bits and any
// other inline reads. This decoder maintains the rANS state and reads
// 32-bit init / 16-bit renorm fixed-width values from the BitReader on
// demand.
//
// Lazy state init: `state == 0` is used as the "not initialised" sentinel
// (which matches libjxl). Post-renorm `state >= stateLowerBound`, so
// `state == 0` cannot occur mid-stream.
//
// Per-stream layout (matches libjxl):
//   on first read: state = ReadFixedBits<32>()
//   loop:
//     slot = state & (tabSize - 1)
//     symbol = slotLUT[cluster][slot]
//     state = freq[symbol] * (state >> logTabSize) + (slot - cum[symbol])
//     if state < stateLowerBound:
//         state = (state << 16) | ReadFixedBits<16>()

import Foundation

/// rANS decoder with per-cluster distributions, reading from a
/// `BitReader`. Mutating across calls — the rANS state lives inside the
/// decoder and persists for the whole entropy section.
///
/// **Lookup mode:** for byte-equality with libjxl-emitted streams,
/// the decoder uses an `AliasTable` (Vose's alias method) that
/// matches libjxl's `InitAliasTable`. For round-trip with our own
/// `ANSStreamEncoder` (which uses our cumulative-frequency layout),
/// the decoder falls back to a slot LUT built from `ANSDistribution`.
/// `useAliasTables` selects between the two.
package struct ANSStreamDecoder: Sendable {
    /// One distribution per cluster (cumulative-frequency layout).
    package let distributions: [ANSDistribution]
    /// One alias table per cluster (libjxl-compatible layout).
    package let aliasTables: [AliasTable]?
    /// Which lookup the decoder uses.
    package let useAliasTables: Bool
    private var state: UInt32 = 0
    private var initialised: Bool = false

    package init(distributions: [ANSDistribution]) {
        self.distributions = distributions
        self.aliasTables = nil
        self.useAliasTables = false
    }

    /// Build a libjxl-compatible alias-table-backed decoder from the
    /// per-cluster `[Int32]` count arrays produced by
    /// `SpecANSDistribution.readHistogram`. The `logAlphaSize` is the
    /// post-tree codebook's `log_alpha_size` (5..8 for rANS).
    package init(counts: [[Int32]], logAlphaSize: Int) throws {
        var aliases: [AliasTable] = []
        aliases.reserveCapacity(counts.count)
        for c in counts {
            // libjxl trims trailing zeros for the alias-table input;
            // the alias table itself does the trim too, but we keep
            // the original counts in `distributions` for diagnostics.
            aliases.append(try AliasTable(
                distribution: c,
                logRange: ANSConstants.logTabSize,
                logAlphaSize: logAlphaSize
            ))
        }
        // Also build a simple distribution view (for `currentState`
        // diagnostics — not used in lookup).
        var dists: [ANSDistribution] = []
        dists.reserveCapacity(counts.count)
        for c in counts {
            let raw = c.map { UInt32(bitPattern: $0) }
            dists.append(try ANSDistribution(rawFrequencies: raw))
        }
        self.distributions = dists
        self.aliasTables = aliases
        self.useAliasTables = true
    }

    /// Convenience constructor from the per-cluster count arrays
    /// produced by `SpecANSDistribution.readHistogram`. Uses the
    /// cumulative-frequency layout — only useful for round-tripping
    /// against `ANSStreamEncoder`. For libjxl byte-equality use
    /// `init(counts:logAlphaSize:)`.
    package static func from(counts: [[Int32]]) throws -> ANSStreamDecoder {
        var dists: [ANSDistribution] = []
        dists.reserveCapacity(counts.count)
        for c in counts {
            let raw = c.map { UInt32(bitPattern: $0) }
            dists.append(try ANSDistribution(rawFrequencies: raw))
        }
        return ANSStreamDecoder(distributions: dists)
    }

    /// Cached `JXL_TRACE` env-var check. Looking it up via
    /// `ProcessInfo.processInfo.environment` for every symbol read is
    /// a measurable hot spot (`[String:String]` hash lookup × 16M+
    /// reads dominated 4096² decode runtime). Resolved once at
    /// process start.
    @usableFromInline static let traceEnabled: Bool =
        ProcessInfo.processInfo.environment["JXL_TRACE"] != nil

    /// Read one symbol from cluster `cluster`. The first call also
    /// consumes the 32-bit rANS state init from the bitstream.
    package mutating func readSymbol(
        cluster: Int, from r: inout BitReader
    ) throws -> UInt32 {
        if !initialised {
            let posBefore = r.position
            state = try r.read(bits: 32)
            initialised = true
            if Self.traceEnabled {
                let slot = state & (ANSConstants.tabSize - 1)
                FileHandle.standardError.write(Data(
                    "TRACE ANS init: posBefore=\(posBefore) state=0x\(String(state, radix: 16)) slot=\(slot)\n".utf8
                ))
            }
        }
        guard cluster >= 0,
              cluster < (aliasTables?.count ?? distributions.count) else {
            throw ANSError.symbolHasZeroFrequency(symbol: -1)
        }
        let logTab = UInt32(ANSConstants.logTabSize)
        let mask: UInt32 = ANSConstants.tabSize - 1
        let slot = state & mask

        let symbol: UInt32
        let offset: UInt32
        let freq: UInt32
        if useAliasTables, let tables = aliasTables {
            let lr = tables[cluster].lookup(slot: slot)
            symbol = UInt32(lr.value)
            offset = lr.offset
            freq = lr.freq
        } else {
            let dist = distributions[cluster]
            symbol = dist.symbol(forSlot: slot)
            freq = dist.frequencies[Int(symbol)]
            offset = slot &- dist.cumulative[Int(symbol)]
        }
        if Self.traceEnabled {
            let msg = "TRACE swift-ANS: cluster=\(cluster) state=0x\(String(state, radix: 16)) slot=\(slot) symbol=\(symbol) offset=\(offset) freq=\(freq)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
        // rANS decode step.
        state = freq &* (state >> logTab) &+ offset
        // Renormalise: if state < 2^16, shift up and read 16 bits.
        if state < ANSConstants.stateLowerBound {
            let w = try r.read(bits: 16)
            state = (state << 16) | w
        }
        return symbol
    }

    /// Whether the rANS state init has been consumed yet.
    package var hasInitialised: Bool { initialised }

    /// Current state — primarily for diagnostics / testing.
    package var currentState: UInt32 { state }
}

/// Streaming-format rANS encoder. Companion to `ANSStreamDecoder`:
/// produces the exact bit layout the streaming decoder consumes —
/// 32-bit state init at the front of the bitstream, followed by 16-bit
/// renormalisation words in *decoder consumption order* (i.e., reversed
/// from the encoder's chronological push order).
///
/// Used in tests to round-trip through `ANSStreamDecoder`. The
/// production codec layer wires its rANS encoder differently (it emits
/// via the same `BitWriter` that carries the rest of the section) and
/// will be built later.
package struct ANSStreamEncoder {
    package let distributions: [ANSDistribution]
    /// Symbols + their target cluster, in forward order.
    private var pending: [(symbol: UInt32, cluster: Int)] = []

    package init(distributions: [ANSDistribution]) {
        self.distributions = distributions
    }

    package mutating func write(symbol: Int, cluster: Int) throws {
        guard cluster >= 0 && cluster < distributions.count else {
            throw ANSError.symbolHasZeroFrequency(symbol: symbol)
        }
        guard symbol >= 0 && symbol < distributions[cluster].alphabetSize else {
            throw ANSError.symbolHasZeroFrequency(symbol: symbol)
        }
        guard distributions[cluster].frequencies[symbol] > 0 else {
            throw ANSError.symbolHasZeroFrequency(symbol: symbol)
        }
        pending.append((UInt32(symbol), cluster))
    }

    /// Encode and return the streaming-format bitstream as `Data`. The
    /// data starts with a 32-bit rANS state (LSB-first) and is followed
    /// by 16-bit renorm words (LSB-first) in decoder consumption order.
    /// All bits are byte-aligned because `BitWriter` is byte-aligned at
    /// every 32-/16-bit boundary.
    package mutating func finish() -> Data {
        let tab = ANSConstants.tabSize
        var state: UInt32 = ANSConstants.stateLowerBound
        var renormChrono: [UInt16] = []
        // Encode in REVERSE.
        for (sym, cluster) in pending.reversed() {
            let dist = distributions[cluster]
            let freq = dist.frequencies[Int(sym)]
            let cum = dist.cumulative[Int(sym)]
            // Renorm bound: (state_lower_bound << 16) / tab * freq == 2^20 * freq
            let bound: UInt64 = (UInt64(1) << 20) &* UInt64(freq)
            while UInt64(state) >= bound {
                renormChrono.append(UInt16(state & 0xFFFF))
                state >>= 16
            }
            state = (state / freq) &* tab &+ cum &+ (state % freq)
        }
        // Write state init first (32 bits LSB-first), then renorm words
        // in REVERSE chronological order (i.e., decoder read order).
        var w = BitWriter()
        w.write(bits: 32, value: state)
        for word in renormChrono.reversed() {
            w.write(bits: 16, value: UInt32(word))
        }
        return w.finishToData()
    }
}
