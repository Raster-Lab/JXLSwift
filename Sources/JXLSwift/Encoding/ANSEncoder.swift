/// ANS (Asymmetric Numeral Systems) Entropy Coding
///
/// Implements rANS (range ANS) entropy coding as specified in
/// ISO/IEC 18181-1 Annex A for JPEG XL.  rANS provides near-optimal
/// compression by encoding symbols according to their probability
/// distributions, approaching the Shannon entropy limit.
///
/// The encoder supports:
/// - Symbol frequency analysis and distribution table generation
/// - Multi-context ANS (context-dependent distributions)
/// - Distribution serialisation (compressed and uncompressed modes)
/// - Encode → decode round-trip for validation

import Foundation

// MARK: - ANS Constants

/// Constants for the rANS entropy codec.
///
/// These values follow the ranges specified in ISO/IEC 18181-1 Annex A.
enum ANSConstants: Sendable {
    /// Log2 of the distribution precision (number of probability bits).
    ///
    /// The probability table sums to `1 << logTabSize`.  JPEG XL uses 12
    /// as the default precision.
    static let logTabSize: Int = 12

    /// Distribution precision: probabilities must sum to this value.
    static let tabSize: UInt32 = 1 << logTabSize         // 4096

    /// Lower bound of the rANS state.  Renormalisation pushes output
    /// bytes whenever the state drops below this threshold.
    static let stateLower: UInt32 = 1 << 16              // 65536

    /// Upper bound of the rANS state.  The state is always in
    /// `[stateLower, stateUpper)` after renormalisation.
    static let stateUpper: UInt32 = 1 << 24              // 16777216

    /// Initial rANS state for both encoder and decoder.
    static let stateInit: UInt32 = stateLower

    /// Maximum number of symbols supported in a single distribution.
    static let maxAlphabetSize: Int = 256
}

// MARK: - ANS Error

/// Errors specific to ANS entropy coding.
enum ANSError: Error, LocalizedError, Sendable {
    /// The symbol frequency table is empty.
    case emptyDistribution
    /// A symbol outside the alphabet was encountered.
    case symbolOutOfRange(symbol: Int, alphabetSize: Int)
    /// The distribution table does not sum to the required precision.
    case invalidDistributionSum(expected: UInt32, got: UInt32)
    /// The decoder reached an invalid state.
    case decodingFailed(String)
    /// The encoded data is truncated or corrupted.
    case truncatedData

    var errorDescription: String? {
        switch self {
        case .emptyDistribution:
            return "ANS distribution table is empty"
        case .symbolOutOfRange(let s, let n):
            return "Symbol \(s) is outside alphabet size \(n)"
        case .invalidDistributionSum(let expected, let got):
            return "Distribution sums to \(got), expected \(expected)"
        case .decodingFailed(let msg):
            return "ANS decoding failed: \(msg)"
        case .truncatedData:
            return "ANS encoded data is truncated"
        }
    }
}

// MARK: - ANS Distribution

/// A probability distribution for a set of symbols.
///
/// Each symbol is assigned a frequency (count) such that all frequencies
/// sum to ``ANSConstants/tabSize``.  The distribution is used by both the
/// encoder and decoder to map between symbols and rANS states.
///
/// Symbols with zero frequency cannot be encoded.  The distribution also
/// pre-computes cumulative frequencies for O(1) encoding and builds a
/// lookup table for O(1) decoding.
struct ANSDistribution: Sendable {
    /// Number of distinct symbols in the alphabet.
    let alphabetSize: Int

    /// Per-symbol frequencies.  `frequencies[s]` is the probability
    /// weight of symbol `s`.  Sum must equal ``ANSConstants/tabSize``.
    let frequencies: [UInt32]

    /// Cumulative frequencies (exclusive prefix sum).
    /// `cumulative[s]` = sum of `frequencies[0..<s]`.
    let cumulative: [UInt32]

    /// Reverse lookup table for decoding.  Given a slot in
    /// `0 ..< tabSize`, returns `(symbol, frequency, cumulative)`.
    private let decodeLUT: [(symbol: Int, freq: UInt32, cumStart: UInt32)]

    /// Create a distribution from raw (unnormalised) symbol frequencies.
    ///
    /// The frequencies are normalised so that they sum to
    /// ``ANSConstants/tabSize``.  Symbols with non-zero input frequency
    /// are guaranteed to retain at least a frequency of 1 after
    /// normalisation.
    ///
    /// - Parameter rawFrequencies: Per-symbol counts (at least one must
    ///   be non-zero).
    /// - Throws: ``ANSError/emptyDistribution`` if all counts are zero.
    init(rawFrequencies: [UInt32]) throws {
        guard !rawFrequencies.isEmpty else { throw ANSError.emptyDistribution }

        let total = rawFrequencies.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { throw ANSError.emptyDistribution }

        self.alphabetSize = rawFrequencies.count

        // --- normalise to tabSize ---
        let tab = ANSConstants.tabSize
        var normed = [UInt32](repeating: 0, count: alphabetSize)

        // First pass: proportional scaling, ensuring non-zero inputs get ≥ 1
        var assigned: UInt32 = 0
        for i in 0..<alphabetSize {
            if rawFrequencies[i] == 0 {
                normed[i] = 0
            } else {
                let scaled = UInt64(rawFrequencies[i]) * UInt64(tab) / total
                normed[i] = max(1, UInt32(scaled))
                assigned += normed[i]
            }
        }

        // Second pass: distribute remainder to largest-frequency symbols
        var diff = Int64(tab) - Int64(assigned)
        if diff != 0 {
            // Sort indices by raw frequency descending to spread adjustment
            let sorted = (0..<alphabetSize)
                .filter { rawFrequencies[$0] > 0 }
                .sorted { rawFrequencies[$0] > rawFrequencies[$1] }

            var idx = 0
            while diff > 0 && !sorted.isEmpty {
                normed[sorted[idx % sorted.count]] += 1
                diff -= 1
                idx += 1
            }
            while diff < 0 && !sorted.isEmpty {
                let si = sorted[idx % sorted.count]
                if normed[si] > 1 {
                    normed[si] -= 1
                    diff += 1
                }
                idx += 1
                // Safety: avoid infinite loop if we can't shrink
                if idx > sorted.count * 2 { break }
            }
        }

        self.frequencies = normed

        // --- cumulative frequencies ---
        var cum = [UInt32](repeating: 0, count: alphabetSize + 1)
        for i in 0..<alphabetSize {
            cum[i + 1] = cum[i] + normed[i]
        }
        self.cumulative = Array(cum.prefix(alphabetSize))

        // --- decode LUT ---
        let tabInt = Int(tab)
        var lut = [(symbol: Int, freq: UInt32, cumStart: UInt32)](
            repeating: (0, 0, 0), count: tabInt
        )
        for s in 0..<alphabetSize where normed[s] > 0 {
            let start = Int(cum[s])
            let end = Int(cum[s + 1])
            for slot in start..<end {
                lut[slot] = (s, normed[s], cum[s])
            }
        }
        self.decodeLUT = lut
    }

    /// Look up decode information for a given slot value.
    ///
    /// - Parameter slot: A value in `0 ..< tabSize` derived from the
    ///   rANS state.
    /// - Returns: A tuple of `(symbol, frequency, cumulativeStart)`.
    func decode(slot: UInt32) -> (symbol: Int, freq: UInt32, cumStart: UInt32) {
        return decodeLUT[Int(slot)]
    }
}

// MARK: - ANS Encoder

/// rANS (range Asymmetric Numeral Systems) encoder.
///
/// Encodes a sequence of symbols into a compressed byte stream using
/// the provided probability distribution.  Symbols are processed in
/// reverse order (last symbol first) because rANS encoding is
/// stack-like: the decoder reads the same byte stream forward.
///
/// Usage:
/// ```swift
/// let dist = try ANSDistribution(rawFrequencies: freqs)
/// var encoder = try ANSEncoder(distribution: dist)
/// let data = try encoder.encode(symbols)
/// ```
struct ANSEncoder: Sendable {
    /// The probability distribution used for encoding.
    let distribution: ANSDistribution

    /// Create an encoder with the given distribution.
    ///
    /// - Parameter distribution: The symbol probability distribution.
    init(distribution: ANSDistribution) {
        self.distribution = distribution
    }

    /// Encode a sequence of symbols into a compressed byte stream.
    ///
    /// - Parameter symbols: The symbols to encode.  Each symbol must
    ///   be in `0 ..< distribution.alphabetSize` and have non-zero
    ///   frequency.
    /// - Returns: The compressed byte stream (including a 4-byte
    ///   final-state trailer).
    /// - Throws: ``ANSError/symbolOutOfRange(symbol:alphabetSize:)``
    ///   if a symbol is invalid.
    func encode(_ symbols: [Int]) throws -> Data {
        let dist = distribution
        let tab = ANSConstants.tabSize

        // Validate symbols
        for s in symbols {
            guard s >= 0 && s < dist.alphabetSize else {
                throw ANSError.symbolOutOfRange(
                    symbol: s, alphabetSize: dist.alphabetSize
                )
            }
            guard dist.frequencies[s] > 0 else {
                throw ANSError.symbolOutOfRange(
                    symbol: s, alphabetSize: dist.alphabetSize
                )
            }
        }

        // Encode in reverse order (rANS is stack-like)
        var state = ANSConstants.stateInit
        var output = [UInt8]()

        for i in stride(from: symbols.count - 1, through: 0, by: -1) {
            let s = symbols[i]
            let freq = dist.frequencies[s]
            let cumStart = dist.cumulative[s]

            // Renormalise: push bytes until state is small enough
            let maxState = freq * (ANSConstants.stateUpper / tab)
            while state >= maxState {
                output.append(UInt8(state & 0xFF))
                state >>= 8
            }

            // Encode symbol into state
            // state' = (state / freq) * tab + (state % freq) + cumStart
            state = (state / freq) * tab + (state % freq) + cumStart
        }

        // The renormalisation bytes are emitted in reverse order.
        // Reverse them so the decoder can read forward.
        output.reverse()

        // Prepend the final state as 4 bytes (big-endian).
        // The decoder reads these first to initialise its state.
        var result = [UInt8]()
        result.reserveCapacity(4 + output.count)
        result.append(UInt8((state >> 24) & 0xFF))
        result.append(UInt8((state >> 16) & 0xFF))
        result.append(UInt8((state >> 8) & 0xFF))
        result.append(UInt8(state & 0xFF))
        result.append(contentsOf: output)

        return Data(result)
    }
}

// MARK: - ANS Decoder

/// rANS (range Asymmetric Numeral Systems) decoder.
///
/// Decodes a compressed byte stream produced by ``ANSEncoder`` back
/// into the original sequence of symbols.  The decoder reads the
/// stream forward, extracting one symbol at a time.
struct ANSDecoder: Sendable {
    /// The probability distribution used for decoding.
    let distribution: ANSDistribution

    /// Create a decoder with the given distribution.
    ///
    /// - Parameter distribution: The same distribution used by the
    ///   encoder.
    init(distribution: ANSDistribution) {
        self.distribution = distribution
    }

    /// Decode a compressed byte stream into the original symbols.
    ///
    /// - Parameters:
    ///   - data: The compressed byte stream produced by ``ANSEncoder``.
    ///   - count: The number of symbols to decode.
    /// - Returns: The decoded symbols.
    /// - Throws: ``ANSError/truncatedData`` if the data is too short,
    ///   or ``ANSError/decodingFailed(_:)`` if the state is invalid.
    func decode(_ data: Data, count: Int) throws -> [Int] {
        guard data.count >= 4 else { throw ANSError.truncatedData }

        let tab = ANSConstants.tabSize
        let bytes = Array(data)

        // Read initial state from first 4 bytes (big-endian)
        var state: UInt32 = UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])

        var pos = 4
        var symbols = [Int]()
        symbols.reserveCapacity(count)

        for _ in 0..<count {
            // Extract slot from state
            let slot = state % tab

            // Look up symbol
            let (symbol, freq, cumStart) = distribution.decode(slot: slot)

            symbols.append(symbol)

            // Update state
            state = freq * (state / tab) + slot - cumStart

            // Renormalise: read bytes while state is below lower bound
            while state < ANSConstants.stateLower {
                guard pos < bytes.count else {
                    // Allow final state to be valid even without more bytes
                    if symbols.count == count { break }
                    throw ANSError.truncatedData
                }
                state = (state << 8) | UInt32(bytes[pos])
                pos += 1
            }
        }

        return symbols
    }
}

// MARK: - ANS Frequency Analysis

/// Utility functions for building ANS distributions from data.
enum ANSFrequencyAnalysis: Sendable {
    /// Count symbol frequencies in a sequence of symbols.
    ///
    /// - Parameters:
    ///   - symbols: The symbol sequence.
    ///   - alphabetSize: The maximum alphabet size.  Symbols must be
    ///     in `0 ..< alphabetSize`.
    /// - Returns: An array of length `alphabetSize` with per-symbol
    ///   counts.
    /// - Throws: ``ANSError/symbolOutOfRange(symbol:alphabetSize:)``
    ///   if any symbol is out of range.
    static func countFrequencies(
        symbols: [Int],
        alphabetSize: Int
    ) throws -> [UInt32] {
        var freqs = [UInt32](repeating: 0, count: alphabetSize)
        for s in symbols {
            guard s >= 0 && s < alphabetSize else {
                throw ANSError.symbolOutOfRange(
                    symbol: s, alphabetSize: alphabetSize
                )
            }
            freqs[s] += 1
        }
        return freqs
    }

    /// Build an ANS distribution by analysing the given symbol sequence.
    ///
    /// This is a convenience method that counts frequencies and creates
    /// a normalised ``ANSDistribution``.
    ///
    /// - Parameters:
    ///   - symbols: The symbol sequence.
    ///   - alphabetSize: The maximum alphabet size.
    /// - Returns: A normalised ``ANSDistribution``.
    static func buildDistribution(
        symbols: [Int],
        alphabetSize: Int
    ) throws -> ANSDistribution {
        let freqs = try countFrequencies(
            symbols: symbols, alphabetSize: alphabetSize
        )
        return try ANSDistribution(rawFrequencies: freqs)
    }
}

// MARK: - ANS Distribution Serialisation

/// Serialisation and deserialisation of ANS distributions.
///
/// Supports two modes following the JPEG XL specification:
/// - **Uncompressed**: Direct frequency table encoding.
/// - **Compressed**: Run-length encoded frequency tables for sparse
///   distributions.
extension ANSDistribution {
    // MARK: Serialisation

    /// Serialise the distribution table to bytes (uncompressed mode).
    ///
    /// Format:
    /// - 1 byte: alphabet size (capped at 255)
    /// - 1 byte: mode (0 = uncompressed, 1 = compressed/RLE)
    /// - For each symbol: 2 bytes (little-endian UInt16) frequency
    ///
    /// - Returns: The serialised distribution table.
    func serialise() -> Data {
        var data = Data()

        // Alphabet size (1 byte)
        data.append(UInt8(min(alphabetSize, 255)))

        // Mode: 0 = uncompressed
        data.append(0)

        // Frequencies as 16-bit LE values
        for f in frequencies {
            data.append(UInt8(f & 0xFF))
            data.append(UInt8((f >> 8) & 0xFF))
        }

        return data
    }

    /// Serialise using RLE compression for sparse distributions.
    ///
    /// Format:
    /// - 1 byte: alphabet size
    /// - 1 byte: mode (1 = compressed/RLE)
    /// - RLE-encoded frequencies: for each run, a (count, value) pair
    ///   where count is a varint and value is a 16-bit LE frequency.
    ///
    /// - Returns: The RLE-compressed distribution table.
    func serialiseCompressed() -> Data {
        var data = Data()

        // Alphabet size
        data.append(UInt8(min(alphabetSize, 255)))

        // Mode: 1 = compressed (RLE)
        data.append(1)

        // RLE-encode frequencies
        var i = 0
        while i < frequencies.count {
            let value = frequencies[i]
            var run = 1
            while i + run < frequencies.count && frequencies[i + run] == value {
                run += 1
            }

            // Write run length as varint
            var v = UInt64(run)
            while v >= 128 {
                data.append(UInt8((v & 0x7F) | 0x80))
                v >>= 7
            }
            data.append(UInt8(v & 0x7F))

            // Write frequency value (16-bit LE)
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))

            i += run
        }

        return data
    }

    // MARK: Deserialisation

    /// Deserialise a distribution table from bytes.
    ///
    /// Automatically detects uncompressed vs. compressed mode from
    /// the mode byte.
    ///
    /// - Parameter data: The serialised distribution table.
    /// - Returns: The deserialised distribution.
    /// - Throws: ``ANSError/truncatedData`` or
    ///   ``ANSError/decodingFailed(_:)`` on invalid data.
    static func deserialise(from data: Data) throws -> ANSDistribution {
        guard data.count >= 2 else { throw ANSError.truncatedData }

        let bytes = Array(data)
        let alphabetSize = Int(bytes[0])
        let mode = bytes[1]

        guard alphabetSize > 0 else {
            throw ANSError.decodingFailed("alphabet size is zero")
        }

        switch mode {
        case 0:
            // Uncompressed
            return try deserialiseUncompressed(
                bytes: bytes, alphabetSize: alphabetSize
            )
        case 1:
            // Compressed (RLE)
            return try deserialiseCompressed(
                bytes: bytes, alphabetSize: alphabetSize
            )
        default:
            throw ANSError.decodingFailed(
                "unknown distribution mode \(mode)"
            )
        }
    }

    /// Deserialise an uncompressed distribution table.
    private static func deserialiseUncompressed(
        bytes: [UInt8],
        alphabetSize: Int
    ) throws -> ANSDistribution {
        let headerLen = 2
        let needed = headerLen + alphabetSize * 2
        guard bytes.count >= needed else { throw ANSError.truncatedData }

        var freqs = [UInt32](repeating: 0, count: alphabetSize)
        for i in 0..<alphabetSize {
            let lo = UInt32(bytes[headerLen + i * 2])
            let hi = UInt32(bytes[headerLen + i * 2 + 1])
            freqs[i] = lo | (hi << 8)
        }

        return try ANSDistribution(rawFrequencies: freqs)
    }

    /// Deserialise an RLE-compressed distribution table.
    private static func deserialiseCompressed(
        bytes: [UInt8],
        alphabetSize: Int
    ) throws -> ANSDistribution {
        var pos = 2   // skip header
        var freqs = [UInt32]()

        while freqs.count < alphabetSize && pos < bytes.count {
            // Read varint run length
            var run: UInt64 = 0
            var shift: UInt64 = 0
            while pos < bytes.count {
                let b = UInt64(bytes[pos])
                pos += 1
                run |= (b & 0x7F) << shift
                shift += 7
                if b & 0x80 == 0 { break }
            }

            // Read 16-bit LE frequency
            guard pos + 1 < bytes.count else {
                throw ANSError.truncatedData
            }
            let lo = UInt32(bytes[pos])
            let hi = UInt32(bytes[pos + 1])
            let value = lo | (hi << 8)
            pos += 2

            for _ in 0..<Int(run) {
                if freqs.count < alphabetSize {
                    freqs.append(value)
                }
            }
        }

        // Pad remaining with zeros if needed
        while freqs.count < alphabetSize {
            freqs.append(0)
        }

        return try ANSDistribution(rawFrequencies: freqs)
    }
}

// MARK: - Multi-Context ANS

/// Multi-context ANS encoder for context-dependent entropy coding.
///
/// Each context maintains its own probability distribution, allowing
/// the encoder to adapt to varying statistical properties within the
/// data stream.  This matches the multi-context ANS approach described
/// in ISO/IEC 18181-1 §8.
struct MultiContextANSEncoder: Sendable {
    /// Per-context distributions.
    let distributions: [ANSDistribution]

    /// Number of contexts.
    var contextCount: Int { distributions.count }

    /// Create a multi-context encoder from per-context distributions.
    ///
    /// - Parameter distributions: One distribution per context.
    init(distributions: [ANSDistribution]) {
        self.distributions = distributions
    }

    /// Build a multi-context encoder from per-context symbol sequences.
    ///
    /// - Parameters:
    ///   - contextSymbols: An array of symbol sequences, one per
    ///     context.
    ///   - alphabetSize: The shared alphabet size.
    /// - Returns: A multi-context encoder.
    static func build(
        contextSymbols: [[Int]],
        alphabetSize: Int
    ) throws -> MultiContextANSEncoder {
        var dists = [ANSDistribution]()
        for symbols in contextSymbols {
            if symbols.isEmpty {
                // Uniform distribution for unused contexts
                let uniform = [UInt32](
                    repeating: 1, count: alphabetSize
                )
                let dist = try ANSDistribution(rawFrequencies: uniform)
                dists.append(dist)
            } else {
                let dist = try ANSFrequencyAnalysis.buildDistribution(
                    symbols: symbols, alphabetSize: alphabetSize
                )
                dists.append(dist)
            }
        }
        return MultiContextANSEncoder(distributions: dists)
    }

    /// Encode symbols with their associated contexts.
    ///
    /// - Parameter symbolsWithContexts: Pairs of `(symbol, contextIndex)`.
    /// - Returns: The compressed byte stream.
    /// - Throws: ``ANSError`` on invalid symbols or contexts.
    func encode(_ symbolsWithContexts: [(symbol: Int, context: Int)]) throws -> Data {
        // Group by context and encode each context's symbols separately,
        // then interleave the output.  For simplicity we use a single
        // rANS state and switch distributions per symbol.
        let tab = ANSConstants.tabSize

        // Validate
        for (s, ctx) in symbolsWithContexts {
            guard ctx >= 0 && ctx < contextCount else {
                throw ANSError.decodingFailed(
                    "context \(ctx) out of range [0, \(contextCount))"
                )
            }
            let dist = distributions[ctx]
            guard s >= 0 && s < dist.alphabetSize else {
                throw ANSError.symbolOutOfRange(
                    symbol: s, alphabetSize: dist.alphabetSize
                )
            }
            guard dist.frequencies[s] > 0 else {
                throw ANSError.symbolOutOfRange(
                    symbol: s, alphabetSize: dist.alphabetSize
                )
            }
        }

        // Encode in reverse order
        var state = ANSConstants.stateInit
        var output = [UInt8]()

        for i in stride(
            from: symbolsWithContexts.count - 1, through: 0, by: -1
        ) {
            let (s, ctx) = symbolsWithContexts[i]
            let dist = distributions[ctx]
            let freq = dist.frequencies[s]
            let cumStart = dist.cumulative[s]

            // Renormalise
            let maxState = freq * (ANSConstants.stateUpper / tab)
            while state >= maxState {
                output.append(UInt8(state & 0xFF))
                state >>= 8
            }

            // Encode
            state = (state / freq) * tab + (state % freq) + cumStart
        }

        // Reverse renormalisation bytes then prepend final state
        output.reverse()

        var result = [UInt8]()
        result.reserveCapacity(4 + output.count)
        result.append(UInt8((state >> 24) & 0xFF))
        result.append(UInt8((state >> 16) & 0xFF))
        result.append(UInt8((state >> 8) & 0xFF))
        result.append(UInt8(state & 0xFF))
        result.append(contentsOf: output)

        return Data(result)
    }

    /// Decode symbols with known context ordering.
    ///
    /// - Parameters:
    ///   - data: The compressed byte stream.
    ///   - contexts: The context index for each symbol, in order.
    /// - Returns: The decoded symbols.
    func decode(_ data: Data, contexts: [Int]) throws -> [Int] {
        guard data.count >= 4 else { throw ANSError.truncatedData }

        let tab = ANSConstants.tabSize
        let bytes = Array(data)

        var state: UInt32 = UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])

        var pos = 4
        var symbols = [Int]()
        symbols.reserveCapacity(contexts.count)

        for ctx in contexts {
            guard ctx >= 0 && ctx < contextCount else {
                throw ANSError.decodingFailed(
                    "context \(ctx) out of range"
                )
            }
            let dist = distributions[ctx]

            let slot = state % tab
            let (symbol, freq, cumStart) = dist.decode(slot: slot)

            symbols.append(symbol)

            state = freq * (state / tab) + slot - cumStart

            while state < ANSConstants.stateLower {
                guard pos < bytes.count else {
                    if symbols.count == contexts.count { break }
                    throw ANSError.truncatedData
                }
                state = (state << 8) | UInt32(bytes[pos])
                pos += 1
            }
        }

        return symbols
    }
}
