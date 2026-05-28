// rANS — range Asymmetric Numeral Systems entropy coder.
//
// ISO/IEC 18181-1 §C.6.3. JPEG XL uses 32-bit-state rANS with 16-bit
// renormalisation: the encoder accumulates a 32-bit state, emits a
// 16-bit word every time the state is about to overflow, and dumps the
// final 32-bit state as the codestream's final 4 bytes.
//
// The encoder runs symbols in REVERSE order (last symbol pushed first).
// The decoder reads the final state from the END of the stream and pops
// symbols in FORWARD order. This is intrinsic to rANS — see Yann Collet's
// FSE/rANS notes — and it's why we materialise the encoded bytes into a
// reverse-order buffer then flip them at finalisation.
//
// Distribution precision is `tabSize = 4096` (12 bits). Per-symbol
// frequencies sum to exactly `tabSize`.
//
// Renormalisation thresholds:
//     stateLowerBound = 1 << 16                        // 65 536
//     The encoder emits 16 bits and shifts state down whenever
//     state ≥ ((stateLowerBound << 16) / tabSize) * freq.
//     The decoder shifts state up and reads 16 bits whenever
//     state < stateLowerBound.

import Foundation

public enum ANSError: Error, Sendable, Equatable {
    case emptyDistribution
    case symbolHasZeroFrequency(symbol: Int)
    case invalidDistributionSum(expected: UInt32, got: UInt32)
    case truncatedBitstream
    case malformedFinalState
    case bitstream(BitstreamError)
}

public enum ANSConstants {
    public static let logTabSize: Int = 12
    public static let tabSize: UInt32 = 1 << UInt32(logTabSize)         // 4096
    public static let stateLowerBound: UInt32 = 1 << 16                  // 65 536
    /// libjxl `ANS_SIGNATURE` (`lib/jxl/ans_params.h`). The encoder's
    /// initial rANS state is `ANS_SIGNATURE << 16`; the decoder verifies
    /// its **final** state returns to that exact value, so a stream
    /// initialised with any other value (e.g. `stateLowerBound`) decodes
    /// with our lenient reader but is rejected by libjxl/djxl.
    public static let signature: UInt32 = 0x13
    /// Initial encoder state / expected decoder final state.
    public static let initialState: UInt32 = signature << 16            // 0x130000
}

/// A normalised probability distribution for an alphabet. Frequencies
/// sum to exactly `tabSize`. Provides O(1) symbol → (freq, cum) lookup
/// and O(1) slot → symbol lookup via an explicit LUT.
public struct ANSDistribution: Sendable {
    /// Number of symbols in the alphabet.
    public let alphabetSize: Int
    /// Per-symbol frequencies. Sum equals `ANSConstants.tabSize`.
    public let frequencies: [UInt32]
    /// Per-symbol cumulative-frequencies (exclusive prefix sum).
    public let cumulative: [UInt32]
    /// Slot → symbol LUT, sized `tabSize`. `slotLUT[s]` is the symbol
    /// whose `[cumulative[symbol], cumulative[symbol]+freq[symbol])`
    /// range contains slot `s`.
    fileprivate let slotLUT: [UInt32]

    /// Build a distribution from raw symbol counts, normalising to
    /// `tabSize`. Symbols with non-zero raw count get at least frequency
    /// 1; the largest-count symbol absorbs any rounding adjustment.
    public init(rawFrequencies: [UInt32]) throws {
        guard !rawFrequencies.isEmpty else { throw ANSError.emptyDistribution }
        let total = rawFrequencies.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { throw ANSError.emptyDistribution }

        let alphabet = rawFrequencies.count
        let tab = UInt64(ANSConstants.tabSize)

        // First pass: proportional scaling, with a minimum of 1 for any
        // symbol that had a non-zero raw count.
        var normed = [UInt32](repeating: 0, count: alphabet)
        for i in 0..<alphabet {
            if rawFrequencies[i] == 0 {
                normed[i] = 0
            } else {
                let scaled = UInt64(rawFrequencies[i]) * tab / total
                normed[i] = UInt32(max(1, scaled))
            }
        }

        // Second pass: ensure the sum equals `tabSize` exactly. Add or
        // subtract the difference from the symbol with the largest
        // current frequency. This avoids dropping any non-zero symbol
        // to 0 (which would make it un-encodable).
        var sum: Int64 = normed.reduce(Int64(0)) { $0 + Int64($1) }
        let target = Int64(tab)
        while sum != target {
            // Find the largest non-zero frequency.
            var bestIdx = -1
            var bestFreq: UInt32 = 0
            for i in 0..<alphabet where normed[i] > bestFreq {
                bestFreq = normed[i]; bestIdx = i
            }
            guard bestIdx >= 0 else { break }   // unreachable when total > 0
            if sum < target {
                normed[bestIdx] &+= 1; sum &+= 1
            } else {
                if normed[bestIdx] <= 1 { break }   // can't shrink further
                normed[bestIdx] &-= 1; sum &-= 1
            }
        }
        guard UInt64(sum) == tab else {
            throw ANSError.invalidDistributionSum(expected: ANSConstants.tabSize,
                                                   got: UInt32(truncatingIfNeeded: sum))
        }
        self.frequencies = normed
        self.alphabetSize = alphabet

        // Cumulative frequencies (exclusive prefix sum).
        var cum = [UInt32](repeating: 0, count: alphabet)
        var running: UInt32 = 0
        for i in 0..<alphabet {
            cum[i] = running
            running &+= normed[i]
        }
        self.cumulative = cum

        // Slot LUT.
        var slot = [UInt32](repeating: 0, count: Int(ANSConstants.tabSize))
        for s in 0..<alphabet where normed[s] > 0 {
            let lo = Int(cum[s])
            let hi = lo + Int(normed[s])
            for i in lo..<hi { slot[i] = UInt32(s) }
        }
        self.slotLUT = slot
    }

    @inline(__always)
    public func symbol(forSlot slot: UInt32) -> UInt32 {
        slotLUT[Int(slot)]
    }
}

/// rANS encoder. Push symbols one at a time; the encoder runs symbols
/// in **reverse** order internally (the spec mandates this), so the
/// caller emits symbols in forward order and the encoder buffers them.
/// Call `finish()` once to retrieve the final byte stream.
public struct ANSEncoder {
    private let distribution: ANSDistribution
    private var symbols: [UInt32] = []

    public init(distribution: ANSDistribution) {
        self.distribution = distribution
    }

    public mutating func write(_ symbol: Int) throws {
        guard symbol >= 0 && symbol < distribution.alphabetSize else {
            throw ANSError.symbolHasZeroFrequency(symbol: symbol)
        }
        guard distribution.frequencies[symbol] > 0 else {
            throw ANSError.symbolHasZeroFrequency(symbol: symbol)
        }
        symbols.append(UInt32(symbol))
    }

    /// Encode the buffered symbols and return the resulting byte
    /// stream. Layout: 16-bit renormalisation words emitted in encoder
    /// order, followed by the final 32-bit state. Decoder reads in the
    /// same order.
    public mutating func finish() -> Data {
        var output = [UInt16]()
        output.reserveCapacity(symbols.count / 2)

        var state: UInt32 = ANSConstants.stateLowerBound
        let tab = ANSConstants.tabSize

        // Encode in REVERSE order.
        // Renormalisation bound (UInt64 to avoid 1<<32 overflow on UInt32):
        //   state must stay < (stateLowerBound << 16) / tab * freq
        //                  == 2^20 * freq
        // before applying the encode step. Otherwise the new state would
        // exceed 2^32. While too large, emit the low 16 bits and shift.
        for sym in symbols.reversed() {
            let freq = distribution.frequencies[Int(sym)]
            let cum  = distribution.cumulative[Int(sym)]
            let bound: UInt64 = (UInt64(1) << 20) &* UInt64(freq)
            while UInt64(state) >= bound {
                output.append(UInt16(state & 0xFFFF))
                state >>= 16
            }
            // rANS encode: state = (state / freq) * tab + cum + (state % freq)
            state = (state / freq) &* tab &+ cum &+ (state % freq)
        }

        // Emit the renorm words in REVERSE (so the decoder reads them
        // forward in the order they were pushed during encode).
        var bytes = Data()
        for w in output.reversed() {
            bytes.append(UInt8(w & 0xFF))
            bytes.append(UInt8((w >> 8) & 0xFF))
        }
        // Final 32-bit state, little-endian.
        bytes.append(UInt8(state & 0xFF))
        bytes.append(UInt8((state >> 8) & 0xFF))
        bytes.append(UInt8((state >> 16) & 0xFF))
        bytes.append(UInt8((state >> 24) & 0xFF))
        return bytes
    }
}

/// rANS decoder. Construct from the encoded byte stream and a matching
/// distribution; pop symbols one at a time in forward order.
public struct ANSDecoder {
    private let distribution: ANSDistribution
    private var data: Data
    /// Byte offset into `data` of the next renorm word to consume.
    private var renormCursor: Int
    /// Byte offset of the final-state 4 bytes (initialised at the end
    /// of the input; renormCursor decreases past this point would mean
    /// the decoder has consumed all renorm words).
    private let finalStateOffset: Int
    private var state: UInt32 = 0

    public init(data: Data, distribution: ANSDistribution) throws {
        guard data.count >= 4 else { throw ANSError.malformedFinalState }
        self.distribution = distribution
        self.data = data
        self.finalStateOffset = data.count - 4
        self.renormCursor = 0

        // Read the final state from the last 4 bytes.
        let base = data.startIndex
        self.state =
              UInt32(data[base + finalStateOffset])
            | (UInt32(data[base + finalStateOffset + 1]) << 8)
            | (UInt32(data[base + finalStateOffset + 2]) << 16)
            | (UInt32(data[base + finalStateOffset + 3]) << 24)
    }

    public mutating func read() throws -> Int {
        let logTab = UInt32(ANSConstants.logTabSize)
        let mask: UInt32 = ANSConstants.tabSize - 1
        let slot = state & mask
        let symbol = distribution.symbol(forSlot: slot)
        let freq = distribution.frequencies[Int(symbol)]
        let cum  = distribution.cumulative[Int(symbol)]
        // rANS decode step: state = freq * (state >> logTab) + slot - cum
        state = freq &* (state >> logTab) &+ slot &- cum
        // Renormalise: while state too small, read 16 bits.
        while state < ANSConstants.stateLowerBound {
            guard renormCursor + 2 <= finalStateOffset else {
                throw ANSError.truncatedBitstream
            }
            let base = data.startIndex
            let w = UInt32(data[base + renormCursor])
                  | (UInt32(data[base + renormCursor + 1]) << 8)
            state = (state << 16) | w
            renormCursor += 2
        }
        return Int(symbol)
    }
}
