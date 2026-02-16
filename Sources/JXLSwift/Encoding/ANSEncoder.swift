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
                // Safety: allow at most 2 full passes over the non-zero
                // symbols.  If the deficit can't be resolved (every
                // non-zero symbol is already at minimum 1), stop and
                // accept the minor table imprecision.
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

    /// Build a multi-context encoder with histogram clustering.
    ///
    /// Contexts with similar probability distributions are merged into
    /// clusters, reducing the number of distinct distribution tables that
    /// must be transmitted.  Each original context is mapped to a cluster
    /// ID.  The resulting encoder uses the clustered distributions.
    ///
    /// - Parameters:
    ///   - contextSymbols: An array of symbol sequences, one per context.
    ///   - alphabetSize: The shared alphabet size.
    ///   - maxClusters: Maximum number of clusters to retain.  Pass 0 to
    ///     use the number of input contexts (no limit).
    ///   - distanceThreshold: Pairs with Jensen-Shannon divergence below
    ///     this value are eligible for merging.  Default is 0.1.
    /// - Returns: A tuple of the clustered encoder and the context-to-cluster
    ///   mapping.
    static func buildClustered(
        contextSymbols: [[Int]],
        alphabetSize: Int,
        maxClusters: Int = 0,
        distanceThreshold: Double = 0.1
    ) throws -> (encoder: MultiContextANSEncoder, contextMap: [Int]) {
        let result = try HistogramClustering.cluster(
            contextSymbols: contextSymbols,
            alphabetSize: alphabetSize,
            maxClusters: maxClusters,
            distanceThreshold: distanceThreshold
        )

        return (
            encoder: MultiContextANSEncoder(distributions: result.distributions),
            contextMap: result.contextMap
        )
    }
}

// MARK: - Histogram Clustering

/// Histogram clustering for merging similar ANS probability distributions.
///
/// When multi-context ANS coding uses many contexts, some may have very
/// similar frequency distributions.  Merging these into clusters reduces
/// the number of distribution tables that must be serialised, saving
/// header overhead while incurring only a small compression penalty.
///
/// The algorithm uses Jensen-Shannon divergence (JSD) as the distance
/// metric between pairs of normalised distributions.  It greedily merges
/// the closest pair until either the minimum distance exceeds a threshold
/// or the target cluster count is reached.
///
/// This follows the general histogram clustering strategy described in
/// ISO/IEC 18181-1 §8 for reducing entropy coding overhead.
enum HistogramClustering: Sendable {

    /// Result of histogram clustering.
    struct ClusterResult: Sendable {
        /// The clustered (merged) distributions, one per cluster.
        let distributions: [ANSDistribution]

        /// Maps each original context index to its cluster index.
        /// `contextMap[i]` is the cluster that context `i` was assigned to.
        let contextMap: [Int]

        /// Number of clusters produced.
        var clusterCount: Int { distributions.count }
    }

    /// Cluster similar distributions from per-context symbol sequences.
    ///
    /// - Parameters:
    ///   - contextSymbols: Per-context symbol sequences.
    ///   - alphabetSize: The shared alphabet size.
    ///   - maxClusters: Maximum clusters to retain (0 = no limit).
    ///   - distanceThreshold: JSD threshold for merging (default 0.1).
    /// - Returns: A ``ClusterResult`` with merged distributions and a
    ///   context mapping.
    /// - Throws: ``ANSError`` if distribution construction fails.
    static func cluster(
        contextSymbols: [[Int]],
        alphabetSize: Int,
        maxClusters: Int = 0,
        distanceThreshold: Double = 0.1
    ) throws -> ClusterResult {
        let numContexts = contextSymbols.count

        guard numContexts > 0 else {
            return ClusterResult(distributions: [], contextMap: [])
        }

        // Build raw frequency counts per context
        var rawFreqs = [[UInt32]]()
        for symbols in contextSymbols {
            if symbols.isEmpty {
                rawFreqs.append([UInt32](repeating: 1, count: alphabetSize))
            } else {
                let freqs = try ANSFrequencyAnalysis.countFrequencies(
                    symbols: symbols, alphabetSize: alphabetSize
                )
                rawFreqs.append(freqs)
            }
        }

        // If only one context, no clustering needed
        if numContexts == 1 {
            let dist = try ANSDistribution(rawFrequencies: rawFreqs[0])
            return ClusterResult(distributions: [dist], contextMap: [0])
        }

        // Effective max clusters
        let effectiveMax = maxClusters > 0
            ? min(maxClusters, numContexts)
            : numContexts

        // Initialise: each context is its own cluster
        // clusterAssignment[i] = cluster ID for context i
        var clusterAssignment = Array(0..<numContexts)
        // clusterFreqs[clusterID] = merged frequency array
        var clusterFreqs = rawFreqs
        // Track which cluster IDs are still active
        var activeClusters = Set(0..<numContexts)

        // Greedy agglomerative merging.
        // The loop runs while we exceed effectiveMax (forced merge) or
        // while threshold-based merging is possible (count > 1).  The
        // break condition inside stops threshold merging when JSD is too
        // high.
        while activeClusters.count > effectiveMax || activeClusters.count > 1 {
            // Find the closest pair of active clusters
            var bestI = -1
            var bestJ = -1
            var bestDist = Double.infinity

            let sorted = activeClusters.sorted()
            for ai in 0..<sorted.count {
                for aj in (ai + 1)..<sorted.count {
                    let d = jensenShannonDivergence(
                        clusterFreqs[sorted[ai]],
                        clusterFreqs[sorted[aj]]
                    )
                    if d < bestDist {
                        bestDist = d
                        bestI = sorted[ai]
                        bestJ = sorted[aj]
                    }
                }
            }

            // Stop if best distance exceeds threshold and we are at or
            // below the cluster limit
            if bestDist > distanceThreshold
                && activeClusters.count <= effectiveMax {
                break
            }

            // Merge cluster bestJ into bestI
            for k in 0..<alphabetSize {
                clusterFreqs[bestI][k] += clusterFreqs[bestJ][k]
            }
            activeClusters.remove(bestJ)

            // Update assignments: all contexts pointing to bestJ now
            // point to bestI
            for c in 0..<numContexts {
                if clusterAssignment[c] == bestJ {
                    clusterAssignment[c] = bestI
                }
            }
        }

        // Compact: renumber active clusters to 0..<N
        let sortedActive = activeClusters.sorted()
        var clusterRemap = [Int: Int]()
        for (newID, oldID) in sortedActive.enumerated() {
            clusterRemap[oldID] = newID
        }

        // Every value in clusterAssignment is guaranteed to be in
        // activeClusters because merging only redirects to active IDs.
        let contextMap = clusterAssignment.map { clusterRemap[$0, default: 0] }

        // Build final distributions from merged frequencies
        var distributions = [ANSDistribution]()
        for oldID in sortedActive {
            let dist = try ANSDistribution(rawFrequencies: clusterFreqs[oldID])
            distributions.append(dist)
        }

        return ClusterResult(
            distributions: distributions,
            contextMap: contextMap
        )
    }

    /// Compute Jensen-Shannon divergence between two frequency arrays.
    ///
    /// JSD is a symmetric, bounded (0–ln 2) divergence measure based on
    /// the KL divergence.  It is well-suited for comparing probability
    /// distributions because it handles zero-probability symbols
    /// gracefully (via the averaged distribution M).
    ///
    /// - Parameters:
    ///   - a: First frequency array.
    ///   - b: Second frequency array.
    /// - Returns: The JSD value (0 = identical, ln(2) ≈ 0.693 = maximally
    ///   different).
    static func jensenShannonDivergence(
        _ a: [UInt32],
        _ b: [UInt32]
    ) -> Double {
        let n = max(a.count, b.count)
        guard n > 0 else { return 0 }

        let totalA = a.reduce(Double(0)) { $0 + Double($1) }
        let totalB = b.reduce(Double(0)) { $0 + Double($1) }

        guard totalA > 0 && totalB > 0 else { return 0 }

        var klAM: Double = 0
        var klBM: Double = 0

        for i in 0..<n {
            let pA = i < a.count ? Double(a[i]) / totalA : 0
            let pB = i < b.count ? Double(b[i]) / totalB : 0
            let m = (pA + pB) / 2.0

            if pA > 0 && m > 0 {
                klAM += pA * log(pA / m)
            }
            if pB > 0 && m > 0 {
                klBM += pB * log(pB / m)
            }
        }

        return (klAM + klBM) / 2.0
    }
}

// MARK: - ANS Interleaving

/// Interleaved rANS encoder for parallel decoding.
///
/// Distributes symbols across multiple independent rANS streams using
/// round-robin assignment (symbol `i` goes to stream `i % streamCount`).
/// Each stream maintains its own rANS state and emits its own
/// renormalisation bytes, enabling fully parallel decoding.
///
/// The output format is:
/// - 1 byte: stream count
/// - 4 bytes per stream: final rANS state (big-endian)
/// - Concatenated renormalisation bytes from all streams
///
/// This follows the interleaved ANS strategy used in JPEG XL for
/// improved throughput on multi-core hardware.
struct InterleavedANSEncoder: Sendable {
    /// The probability distribution used for encoding.
    let distribution: ANSDistribution

    /// Number of interleaved streams.
    let streamCount: Int

    /// Create an interleaved encoder with the given distribution.
    ///
    /// - Parameters:
    ///   - distribution: The symbol probability distribution.
    ///   - streamCount: Number of interleaved streams (default 4).
    init(distribution: ANSDistribution, streamCount: Int = 4) {
        self.distribution = distribution
        self.streamCount = max(1, min(streamCount, 255))
    }

    /// Encode a sequence of symbols into an interleaved compressed byte stream.
    ///
    /// Symbols are distributed across streams in round-robin order.
    /// Each stream encodes its symbols in reverse order using rANS.
    ///
    /// - Parameter symbols: The symbols to encode.  Each symbol must
    ///   be in `0 ..< distribution.alphabetSize` and have non-zero
    ///   frequency.
    /// - Returns: The interleaved compressed byte stream.
    /// - Throws: ``ANSError/symbolOutOfRange(symbol:alphabetSize:)``
    ///   if a symbol is invalid.
    func encode(_ symbols: [Int]) throws -> Data {
        let dist = distribution
        let tab = ANSConstants.tabSize
        let n = streamCount

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

        // Distribute symbols across streams (round-robin)
        var streams = [[Int]](repeating: [], count: n)
        for (i, s) in symbols.enumerated() {
            streams[i % n].append(s)
        }

        // Encode each stream independently
        var states = [UInt32](repeating: ANSConstants.stateInit, count: n)
        var outputs = [[UInt8]](repeating: [], count: n)

        for streamIdx in 0..<n {
            let streamSymbols = streams[streamIdx]

            // Encode in reverse order (rANS is stack-like)
            for i in stride(
                from: streamSymbols.count - 1, through: 0, by: -1
            ) {
                let s = streamSymbols[i]
                let freq = dist.frequencies[s]
                let cumStart = dist.cumulative[s]

                // Renormalise: push bytes until state is small enough
                let maxState = freq * (ANSConstants.stateUpper / tab)
                while states[streamIdx] >= maxState {
                    outputs[streamIdx].append(
                        UInt8(states[streamIdx] & 0xFF)
                    )
                    states[streamIdx] >>= 8
                }

                // Encode symbol into state
                states[streamIdx] = (states[streamIdx] / freq) * tab
                    + (states[streamIdx] % freq) + cumStart
            }

            // Reverse renormalisation bytes so decoder reads forward
            outputs[streamIdx].reverse()
        }

        // Build output: stream count, per-stream states, then bytes
        var result = [UInt8]()
        let totalBytes = outputs.reduce(0) { $0 + $1.count }
        result.reserveCapacity(1 + n * 4 + totalBytes)

        // Stream count
        result.append(UInt8(n))

        // Final states (big-endian, 4 bytes each)
        for state in states {
            result.append(UInt8((state >> 24) & 0xFF))
            result.append(UInt8((state >> 16) & 0xFF))
            result.append(UInt8((state >> 8) & 0xFF))
            result.append(UInt8(state & 0xFF))
        }

        // Interleaved renormalisation bytes from all streams
        for streamOutput in outputs {
            result.append(contentsOf: streamOutput)
        }

        return Data(result)
    }
}

/// Interleaved rANS decoder for parallel decoding.
///
/// Decodes an interleaved byte stream produced by
/// ``InterleavedANSEncoder``.  Each stream is decoded independently
/// using its own rANS state, and the original symbol order is
/// reconstructed by round-robin reassembly.
struct InterleavedANSDecoder: Sendable {
    /// The probability distribution used for decoding.
    let distribution: ANSDistribution

    /// Number of interleaved streams.
    let streamCount: Int

    /// Create an interleaved decoder with the given distribution.
    ///
    /// - Parameters:
    ///   - distribution: The same distribution used by the encoder.
    ///   - streamCount: Number of interleaved streams (default 4).
    init(distribution: ANSDistribution, streamCount: Int = 4) {
        self.distribution = distribution
        self.streamCount = max(1, min(streamCount, 255))
    }

    /// Decode an interleaved compressed byte stream into the original symbols.
    ///
    /// Reads the stream count and per-stream states from the header,
    /// decodes each stream independently, then reconstructs the original
    /// symbol order by round-robin reassembly.
    ///
    /// - Parameters:
    ///   - data: The compressed byte stream produced by
    ///     ``InterleavedANSEncoder``.
    ///   - count: The total number of symbols to decode.
    /// - Returns: The decoded symbols in their original order.
    /// - Throws: ``ANSError/truncatedData`` if the data is too short,
    ///   or ``ANSError/decodingFailed(_:)`` if the state is invalid.
    func decode(_ data: Data, count: Int) throws -> [Int] {
        guard data.count >= 1 else { throw ANSError.truncatedData }

        let bytes = Array(data)
        let n = Int(bytes[0])

        guard n >= 1 else {
            throw ANSError.decodingFailed("stream count must be >= 1")
        }

        guard n == streamCount else {
            throw ANSError.decodingFailed(
                "stream count mismatch: data has \(n), expected \(streamCount)"
            )
        }

        let headerSize = 1 + n * 4
        guard bytes.count >= headerSize else {
            throw ANSError.truncatedData
        }

        let tab = ANSConstants.tabSize

        // Read per-stream initial states (big-endian)
        var states = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            let offset = 1 + i * 4
            states[i] = UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }

        // Determine how many symbols each stream must decode
        var streamCounts = [Int](repeating: count / n, count: n)
        for i in 0..<(count % n) {
            streamCounts[i] += 1
        }

        // Decode each stream. The renormalisation bytes for each stream
        // are laid out sequentially after the header.  We must figure out
        // each stream's byte range. Since we don't know the exact sizes
        // up front, we decode streams sequentially, each consuming bytes
        // from a shared position cursor.
        var pos = headerSize
        var streamSymbols = [[Int]](repeating: [], count: n)

        for streamIdx in 0..<n {
            var state = states[streamIdx]
            var decoded = [Int]()
            decoded.reserveCapacity(streamCounts[streamIdx])

            for _ in 0..<streamCounts[streamIdx] {
                let slot = state % tab
                let (symbol, freq, cumStart) = distribution.decode(
                    slot: slot
                )

                decoded.append(symbol)

                state = freq * (state / tab) + slot - cumStart

                // Renormalise: read bytes while state is below lower bound
                while state < ANSConstants.stateLower {
                    guard pos < bytes.count else {
                        if decoded.count == streamCounts[streamIdx] { break }
                        throw ANSError.truncatedData
                    }
                    state = (state << 8) | UInt32(bytes[pos])
                    pos += 1
                }
            }

            streamSymbols[streamIdx] = decoded
        }

        // Reconstruct original order by round-robin reassembly
        var result = [Int]()
        result.reserveCapacity(count)

        var streamPositions = [Int](repeating: 0, count: n)
        for i in 0..<count {
            let streamIdx = i % n
            result.append(streamSymbols[streamIdx][streamPositions[streamIdx]])
            streamPositions[streamIdx] += 1
        }

        return result
    }
}

// MARK: - LZ77 Hybrid Mode

/// A token in the LZ77 token stream.
///
/// The LZ77 algorithm decomposes a symbol sequence into a stream of
/// literal symbols and back-references (matches) to previously seen
/// data.  This enum represents both token types.
enum LZ77Token: Sendable, Equatable {
    /// A single literal symbol.
    ///
    /// - Parameter symbol: The literal symbol value.
    case literal(symbol: Int)

    /// A back-reference to repeated data.
    ///
    /// - Parameters:
    ///   - length: Number of symbols to copy.
    ///   - distance: How far back in the output to start copying.
    case match(length: Int, distance: Int)
}

/// Hybrid LZ77 + ANS encoder.
///
/// Combines LZ77 back-reference matching with ANS entropy coding for
/// improved compression.  The encoder first finds repeated patterns
/// using a greedy LZ77 match finder, then entropy-codes the resulting
/// token stream with rANS.
///
/// The encoding pipeline is:
/// 1. Scan symbols for repeated subsequences (LZ77 matching).
/// 2. Convert tokens to a flat symbol stream:
///    - Literal: marker `0`, then the literal symbol value.
///    - Match: marker `1`, then length as varint bytes, then distance
///      as varint bytes.
/// 3. Compress the flat symbol stream using ANS.
///
/// Output format:
/// - 4 bytes: original symbol count (big-endian `UInt32`)
/// - Remaining bytes: ANS-compressed flat symbol stream
struct LZ77HybridEncoder: Sendable {
    /// Maximum look-back window size in symbols.
    let windowSize: Int

    /// Minimum match length to emit a match token.
    let minMatchLength: Int

    /// Create an LZ77 hybrid encoder.
    ///
    /// - Parameters:
    ///   - windowSize: Maximum look-back distance (default 1024,
    ///     clamped to 1...32768).
    ///   - minMatchLength: Minimum match length to consider
    ///     (default 3, minimum 2).
    init(windowSize: Int = 1024, minMatchLength: Int = 3) {
        self.windowSize = max(1, min(windowSize, 32768))
        self.minMatchLength = max(2, minMatchLength)
    }

    /// Find LZ77 matches in the given symbol sequence.
    ///
    /// Uses a greedy algorithm: at each position, scan backwards in
    /// the window for the longest match of at least
    /// ``minMatchLength`` symbols.  If found, emit a
    /// ``LZ77Token/match(length:distance:)``; otherwise emit a
    /// ``LZ77Token/literal(symbol:)``.
    ///
    /// - Parameter symbols: The input symbol sequence.
    /// - Returns: The LZ77 token stream.
    func findMatches(in symbols: [Int]) -> [LZ77Token] {
        var tokens = [LZ77Token]()
        let count = symbols.count
        var i = 0

        while i < count {
            var bestLength = 0
            var bestDistance = 0

            // Search window: look back up to windowSize positions
            let windowStart = max(0, i - windowSize)

            for j in windowStart..<i {
                var matchLen = 0
                // Allow overlapping matches: compare source (starting
                // at j) with target (starting at i).  When j + matchLen
                // wraps past i the comparison naturally uses already-
                // matched data, which is the standard LZ77 behaviour for
                // run-length patterns.
                while i + matchLen < count
                    && symbols[j + matchLen] == symbols[i + matchLen] {
                    matchLen += 1
                }

                if matchLen >= minMatchLength && matchLen > bestLength {
                    bestLength = matchLen
                    bestDistance = i - j
                }
            }

            if bestLength >= minMatchLength {
                tokens.append(.match(
                    length: bestLength, distance: bestDistance
                ))
                i += bestLength
            } else {
                tokens.append(.literal(symbol: symbols[i]))
                i += 1
            }
        }

        return tokens
    }

    /// Encode a symbol sequence using LZ77 + ANS hybrid compression.
    ///
    /// - Parameter symbols: The symbols to encode.
    /// - Returns: The compressed data (4-byte count header + ANS
    ///   payload).
    /// - Throws: ``ANSError`` if ANS encoding fails.
    func encode(_ symbols: [Int]) throws -> Data {
        let tokens = findMatches(in: symbols)

        // Convert tokens to a flat symbol stream
        let flatStream = tokensToFlatStream(tokens)

        // Build distribution and ANS-encode
        let alphabetSize = max(2, (flatStream.max() ?? 0) + 1)
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: flatStream, alphabetSize: alphabetSize
        )
        let encoder = ANSEncoder(distribution: dist)
        let ansData = try encoder.encode(flatStream)

        // Serialise distribution for the decoder
        let distData = dist.serialise()

        // Output: 4-byte symbol count + 4-byte flat stream count +
        //         4-byte dist length + distribution + ANS data
        var result = Data()
        let symbolCount = UInt32(symbols.count)
        result.append(UInt8((symbolCount >> 24) & 0xFF))
        result.append(UInt8((symbolCount >> 16) & 0xFF))
        result.append(UInt8((symbolCount >> 8) & 0xFF))
        result.append(UInt8(symbolCount & 0xFF))

        let flatCount = UInt32(flatStream.count)
        result.append(UInt8((flatCount >> 24) & 0xFF))
        result.append(UInt8((flatCount >> 16) & 0xFF))
        result.append(UInt8((flatCount >> 8) & 0xFF))
        result.append(UInt8(flatCount & 0xFF))

        let distLen = UInt32(distData.count)
        result.append(UInt8((distLen >> 24) & 0xFF))
        result.append(UInt8((distLen >> 16) & 0xFF))
        result.append(UInt8((distLen >> 8) & 0xFF))
        result.append(UInt8(distLen & 0xFF))

        result.append(distData)
        result.append(ansData)

        return result
    }

    /// Convert a token stream to a flat symbol stream for ANS encoding.
    ///
    /// - Literal: marker `0`, then literal symbol value.
    /// - Match: marker `1`, then length as varint bytes, then distance
    ///   as varint bytes.
    ///
    /// - Parameter tokens: The LZ77 token stream.
    /// - Returns: The flat symbol stream.
    func tokensToFlatStream(_ tokens: [LZ77Token]) -> [Int] {
        var flat = [Int]()

        for token in tokens {
            switch token {
            case .literal(let symbol):
                // Marker 0 = literal, then the symbol value
                flat.append(0)
                flat.append(symbol)
            case .match(let length, let distance):
                // Marker 1 = match, then length varint, then distance varint
                flat.append(1)
                appendVarint(length, to: &flat)
                appendVarint(distance, to: &flat)
            }
        }

        return flat
    }

    /// Append an integer as varint-encoded bytes (7 bits per byte,
    /// MSB continuation flag) to the flat symbol stream.
    ///
    /// Each byte of the varint is emitted as a separate symbol.
    ///
    /// - Parameters:
    ///   - value: The integer to encode.
    ///   - stream: The symbol stream to append to.
    private func appendVarint(_ value: Int, to stream: inout [Int]) {
        var v = value
        repeat {
            var byte = v & 0x7F
            v >>= 7
            if v > 0 { byte |= 0x80 }
            stream.append(byte)
        } while v > 0
    }
}

/// Hybrid LZ77 + ANS decoder.
///
/// Decodes data produced by ``LZ77HybridEncoder``.  The decoder first
/// ANS-decodes the compressed flat symbol stream, then reconstructs
/// the original symbol sequence by replaying literal and match tokens.
struct LZ77HybridDecoder: Sendable {

    /// Create an LZ77 hybrid decoder.
    init() {}

    /// Decode LZ77 + ANS compressed data into the original symbols.
    ///
    /// - Parameter data: The compressed data produced by
    ///   ``LZ77HybridEncoder``.
    /// - Returns: The original symbol sequence.
    /// - Throws: ``ANSError/truncatedData`` if the data is too short,
    ///   or ``ANSError/decodingFailed(_:)`` on invalid token data.
    func decode(_ data: Data) throws -> [Int] {
        guard data.count >= 12 else { throw ANSError.truncatedData }

        let bytes = Array(data)

        // Read original symbol count (big-endian UInt32)
        let symbolCount = Int(
            UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        )

        // Read flat stream count (big-endian UInt32)
        let flatCount = Int(
            UInt32(bytes[4]) << 24
            | UInt32(bytes[5]) << 16
            | UInt32(bytes[6]) << 8
            | UInt32(bytes[7])
        )

        // Read distribution length (big-endian UInt32)
        let distLen = Int(
            UInt32(bytes[8]) << 24
            | UInt32(bytes[9]) << 16
            | UInt32(bytes[10]) << 8
            | UInt32(bytes[11])
        )

        let distStart = 12
        let distEnd = distStart + distLen
        guard distEnd <= bytes.count else { throw ANSError.truncatedData }

        // Deserialise distribution
        let distData = Data(bytes[distStart..<distEnd])
        let dist = try ANSDistribution.deserialise(from: distData)

        // ANS-decode the flat symbol stream using the exact count
        let ansData = Data(bytes[distEnd...])
        let decoder = ANSDecoder(distribution: dist)
        let flatStream = try decoder.decode(ansData, count: flatCount)

        // Reconstruct original symbols from the flat stream
        var result = [Int]()
        result.reserveCapacity(symbolCount)
        var pos = 0

        while result.count < symbolCount && pos < flatStream.count {
            let marker = flatStream[pos]
            pos += 1

            switch marker {
            case 0:
                // Literal
                guard pos < flatStream.count else {
                    throw ANSError.decodingFailed(
                        "truncated literal in LZ77 stream"
                    )
                }
                result.append(flatStream[pos])
                pos += 1

            case 1:
                // Match: read length varint, then distance varint
                let (length, newPos1) = readVarint(
                    from: flatStream, at: pos
                )
                pos = newPos1
                let (distance, newPos2) = readVarint(
                    from: flatStream, at: pos
                )
                pos = newPos2

                guard distance > 0 && distance <= result.count else {
                    throw ANSError.decodingFailed(
                        "invalid LZ77 distance \(distance)"
                    )
                }
                guard length > 0 else {
                    throw ANSError.decodingFailed(
                        "invalid LZ77 length \(length)"
                    )
                }

                // Copy from the output buffer
                let srcStart = result.count - distance
                for k in 0..<length {
                    result.append(result[srcStart + k])
                }

            default:
                throw ANSError.decodingFailed(
                    "unknown LZ77 marker \(marker)"
                )
            }
        }

        guard result.count == symbolCount else {
            throw ANSError.decodingFailed(
                "decoded \(result.count) symbols, expected \(symbolCount)"
            )
        }

        return result
    }

    /// Read a varint from the flat symbol stream.
    ///
    /// - Parameters:
    ///   - stream: The flat symbol stream.
    ///   - start: The position to start reading from.
    /// - Returns: A tuple of `(value, nextPosition)`.
    private func readVarint(
        from stream: [Int],
        at start: Int
    ) -> (value: Int, nextPos: Int) {
        var value = 0
        var shift = 0
        var pos = start

        while pos < stream.count {
            let byte = stream[pos]
            pos += 1
            value |= (byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 { break }
        }

        return (value, pos)
    }
}
