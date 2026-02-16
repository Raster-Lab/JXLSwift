/// Tests for ANS (Asymmetric Numeral Systems) Entropy Coding
///
/// Validates the rANS encoder, decoder, distribution tables, frequency
/// analysis, serialisation, and multi-context ANS.

import XCTest
@testable import JXLSwift

final class ANSEncoderTests: XCTestCase {

    // MARK: - ANS Constants

    func testConstants_TabSize_IsPowerOf2() {
        XCTAssertEqual(ANSConstants.tabSize, 1 << ANSConstants.logTabSize)
    }

    func testConstants_StateBounds_Ordered() {
        XCTAssertGreaterThan(
            ANSConstants.stateUpper, ANSConstants.stateLower
        )
        XCTAssertGreaterThanOrEqual(
            ANSConstants.stateInit, ANSConstants.stateLower
        )
    }

    func testConstants_MaxAlphabetSize_Positive() {
        XCTAssertGreaterThan(ANSConstants.maxAlphabetSize, 0)
    }

    // MARK: - ANS Error

    func testError_EmptyDistribution_HasDescription() {
        let error = ANSError.emptyDistribution
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("empty"))
    }

    func testError_SymbolOutOfRange_HasDescription() {
        let error = ANSError.symbolOutOfRange(symbol: 5, alphabetSize: 3)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("5"))
        XCTAssertTrue(error.errorDescription!.contains("3"))
    }

    func testError_InvalidDistributionSum_HasDescription() {
        let error = ANSError.invalidDistributionSum(expected: 4096, got: 100)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("4096"))
    }

    func testError_DecodingFailed_HasDescription() {
        let error = ANSError.decodingFailed("test message")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("test message"))
    }

    func testError_TruncatedData_HasDescription() {
        let error = ANSError.truncatedData
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("truncated"))
    }

    // MARK: - ANS Distribution

    func testDistribution_UniformFrequencies_SumsToTabSize() throws {
        let freqs: [UInt32] = [100, 100, 100, 100]
        let dist = try ANSDistribution(rawFrequencies: freqs)
        let sum = dist.frequencies.reduce(UInt32(0), +)
        XCTAssertEqual(sum, ANSConstants.tabSize)
    }

    func testDistribution_SkewedFrequencies_SumsToTabSize() throws {
        let freqs: [UInt32] = [1000, 10, 5, 1]
        let dist = try ANSDistribution(rawFrequencies: freqs)
        let sum = dist.frequencies.reduce(UInt32(0), +)
        XCTAssertEqual(sum, ANSConstants.tabSize)
    }

    func testDistribution_SingleSymbol_GetsFullTab() throws {
        let freqs: [UInt32] = [42]
        let dist = try ANSDistribution(rawFrequencies: freqs)
        XCTAssertEqual(dist.frequencies[0], ANSConstants.tabSize)
        XCTAssertEqual(dist.alphabetSize, 1)
    }

    func testDistribution_ZeroFrequencySymbol_RemainsZero() throws {
        let freqs: [UInt32] = [100, 0, 100]
        let dist = try ANSDistribution(rawFrequencies: freqs)
        XCTAssertEqual(dist.frequencies[1], 0)
        XCTAssertGreaterThan(dist.frequencies[0], 0)
        XCTAssertGreaterThan(dist.frequencies[2], 0)
    }

    func testDistribution_NonZeroInput_GetsAtLeastOne() throws {
        // Even a very rare symbol should get frequency ≥ 1
        var freqs = [UInt32](repeating: 0, count: 256)
        freqs[0] = 1_000_000
        freqs[255] = 1   // very rare
        let dist = try ANSDistribution(rawFrequencies: freqs)
        XCTAssertGreaterThanOrEqual(dist.frequencies[255], 1)
    }

    func testDistribution_EmptyFrequencies_Throws() {
        XCTAssertThrowsError(
            try ANSDistribution(rawFrequencies: [])
        ) { error in
            XCTAssertTrue(error is ANSError)
        }
    }

    func testDistribution_AllZeroFrequencies_Throws() {
        XCTAssertThrowsError(
            try ANSDistribution(rawFrequencies: [0, 0, 0])
        ) { error in
            XCTAssertTrue(error is ANSError)
        }
    }

    func testDistribution_CumulativeFrequencies_AreMonotonic() throws {
        let freqs: [UInt32] = [50, 30, 20, 10, 5]
        let dist = try ANSDistribution(rawFrequencies: freqs)
        for i in 1..<dist.alphabetSize {
            XCTAssertGreaterThanOrEqual(dist.cumulative[i], dist.cumulative[i - 1])
        }
    }

    func testDistribution_CumulativeStart_IsZeroForFirstSymbol() throws {
        let freqs: [UInt32] = [100, 200, 300]
        let dist = try ANSDistribution(rawFrequencies: freqs)
        XCTAssertEqual(dist.cumulative[0], 0)
    }

    func testDistribution_DecodeLUT_ReturnsValidSymbols() throws {
        let freqs: [UInt32] = [100, 200, 300]
        let dist = try ANSDistribution(rawFrequencies: freqs)
        for slot in 0..<Int(ANSConstants.tabSize) {
            let (symbol, freq, _) = dist.decode(slot: UInt32(slot))
            XCTAssertGreaterThanOrEqual(symbol, 0)
            XCTAssertLessThan(symbol, dist.alphabetSize)
            XCTAssertGreaterThan(freq, 0)
        }
    }

    // MARK: - ANS Encoder/Decoder Round-Trip

    func testRoundTrip_UniformDistribution() throws {
        let symbols = [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3]
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 4
        )

        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode(symbols)

        let decoder = ANSDecoder(distribution: dist)
        let decoded = try decoder.decode(encoded, count: symbols.count)

        XCTAssertEqual(decoded, symbols)
    }

    func testRoundTrip_SkewedDistribution() throws {
        // Very skewed: 0 appears much more than others
        var symbols = [Int](repeating: 0, count: 100)
        symbols.append(contentsOf: [1, 1, 1, 2, 3])
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 4
        )

        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode(symbols)

        let decoder = ANSDecoder(distribution: dist)
        let decoded = try decoder.decode(encoded, count: symbols.count)

        XCTAssertEqual(decoded, symbols)
    }

    func testRoundTrip_SparseData_MostlyZeros() throws {
        // Mostly zeros with occasional non-zero
        var symbols = [Int](repeating: 0, count: 200)
        symbols[50] = 1
        symbols[100] = 2
        symbols[150] = 1
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 3
        )

        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode(symbols)

        let decoder = ANSDecoder(distribution: dist)
        let decoded = try decoder.decode(encoded, count: symbols.count)

        XCTAssertEqual(decoded, symbols)
    }

    func testRoundTrip_SingleSymbolAlphabet() throws {
        let symbols = [0, 0, 0, 0, 0]
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 1
        )

        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode(symbols)

        let decoder = ANSDecoder(distribution: dist)
        let decoded = try decoder.decode(encoded, count: symbols.count)

        XCTAssertEqual(decoded, symbols)
    }

    func testRoundTrip_TwoSymbols() throws {
        let symbols = [0, 1, 0, 1, 1, 0, 0, 1]
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 2
        )

        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode(symbols)

        let decoder = ANSDecoder(distribution: dist)
        let decoded = try decoder.decode(encoded, count: symbols.count)

        XCTAssertEqual(decoded, symbols)
    }

    func testRoundTrip_LargeAlphabet() throws {
        // Use 64 distinct symbols
        var symbols = [Int]()
        for i in 0..<64 {
            symbols.append(contentsOf: [Int](repeating: i, count: i + 1))
        }
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 64
        )

        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode(symbols)

        let decoder = ANSDecoder(distribution: dist)
        let decoded = try decoder.decode(encoded, count: symbols.count)

        XCTAssertEqual(decoded, symbols)
    }

    func testRoundTrip_LongSequence() throws {
        // 10000 symbols
        var symbols = [Int]()
        for i in 0..<10000 {
            symbols.append(i % 8)
        }
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 8
        )

        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode(symbols)

        let decoder = ANSDecoder(distribution: dist)
        let decoded = try decoder.decode(encoded, count: symbols.count)

        XCTAssertEqual(decoded, symbols)
    }

    func testRoundTrip_SingleElement() throws {
        let symbols = [0]
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 1
        )

        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode(symbols)

        let decoder = ANSDecoder(distribution: dist)
        let decoded = try decoder.decode(encoded, count: 1)

        XCTAssertEqual(decoded, symbols)
    }

    // MARK: - ANS Encoder Errors

    func testEncoder_SymbolOutOfRange_Throws() throws {
        let dist = try ANSDistribution(rawFrequencies: [100, 100])
        let encoder = ANSEncoder(distribution: dist)

        XCTAssertThrowsError(try encoder.encode([2])) { error in
            guard let ansError = error as? ANSError,
                  case .symbolOutOfRange(let s, let n) = ansError else {
                XCTFail("Expected symbolOutOfRange error")
                return
            }
            XCTAssertEqual(s, 2)
            XCTAssertEqual(n, 2)
        }
    }

    func testEncoder_NegativeSymbol_Throws() throws {
        let dist = try ANSDistribution(rawFrequencies: [100, 100])
        let encoder = ANSEncoder(distribution: dist)

        XCTAssertThrowsError(try encoder.encode([-1])) { error in
            XCTAssertTrue(error is ANSError)
        }
    }

    func testEncoder_ZeroFrequencySymbol_Throws() throws {
        let dist = try ANSDistribution(rawFrequencies: [100, 0, 100])
        let encoder = ANSEncoder(distribution: dist)

        XCTAssertThrowsError(try encoder.encode([1])) { error in
            XCTAssertTrue(error is ANSError)
        }
    }

    func testEncoder_EmptySymbols_ProducesMinimalOutput() throws {
        let dist = try ANSDistribution(rawFrequencies: [100])
        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode([])
        // Should have exactly the 4-byte final state
        XCTAssertEqual(encoded.count, 4)
    }

    // MARK: - ANS Decoder Errors

    func testDecoder_TruncatedData_Throws() throws {
        let dist = try ANSDistribution(rawFrequencies: [100, 100])
        let decoder = ANSDecoder(distribution: dist)
        // Less than 4 bytes
        XCTAssertThrowsError(
            try decoder.decode(Data([0x00, 0x01]), count: 1)
        ) { error in
            XCTAssertTrue(error is ANSError)
        }
    }

    func testDecoder_EmptyData_Throws() throws {
        let dist = try ANSDistribution(rawFrequencies: [100])
        let decoder = ANSDecoder(distribution: dist)
        XCTAssertThrowsError(
            try decoder.decode(Data(), count: 1)
        )
    }

    func testDecoder_ZeroCount_ReturnsEmpty() throws {
        let dist = try ANSDistribution(rawFrequencies: [100])
        let decoder = ANSDecoder(distribution: dist)
        let decoded = try decoder.decode(Data([0, 1, 0, 0]), count: 0)
        XCTAssertEqual(decoded.count, 0)
    }

    // MARK: - Compression Efficiency

    func testCompression_SkewedData_SmallerThanUniform() throws {
        // Highly skewed data should compress well
        let skewed = [Int](repeating: 0, count: 1000)
            + [1, 2, 3, 4, 5]
        let distSkewed = try ANSFrequencyAnalysis.buildDistribution(
            symbols: skewed, alphabetSize: 6
        )
        let encoderSkewed = ANSEncoder(distribution: distSkewed)
        let encodedSkewed = try encoderSkewed.encode(skewed)

        // Uniform data should be larger
        var uniform = [Int]()
        for i in 0..<1005 {
            uniform.append(i % 6)
        }
        let distUniform = try ANSFrequencyAnalysis.buildDistribution(
            symbols: uniform, alphabetSize: 6
        )
        let encoderUniform = ANSEncoder(distribution: distUniform)
        let encodedUniform = try encoderUniform.encode(uniform)

        XCTAssertLessThan(
            encodedSkewed.count, encodedUniform.count,
            "Skewed data should compress better than uniform"
        )
    }

    func testCompression_SingleSymbol_HighRatio() throws {
        let symbols = [Int](repeating: 0, count: 1000)
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 1
        )
        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode(symbols)

        // Single-symbol stream should compress very well
        let ratio = Double(symbols.count) / Double(encoded.count)
        XCTAssertGreaterThan(ratio, 1.0, "Single-symbol should compress")
    }

    // MARK: - Frequency Analysis

    func testFrequencyAnalysis_CountFrequencies_Correct() throws {
        let symbols = [0, 1, 1, 2, 2, 2]
        let freqs = try ANSFrequencyAnalysis.countFrequencies(
            symbols: symbols, alphabetSize: 3
        )
        XCTAssertEqual(freqs, [1, 2, 3])
    }

    func testFrequencyAnalysis_CountFrequencies_AllZeros() throws {
        let symbols = [Int]()
        let freqs = try ANSFrequencyAnalysis.countFrequencies(
            symbols: symbols, alphabetSize: 4
        )
        XCTAssertEqual(freqs, [0, 0, 0, 0])
    }

    func testFrequencyAnalysis_OutOfRange_Throws() {
        XCTAssertThrowsError(
            try ANSFrequencyAnalysis.countFrequencies(
                symbols: [5], alphabetSize: 3
            )
        ) { error in
            XCTAssertTrue(error is ANSError)
        }
    }

    func testFrequencyAnalysis_NegativeSymbol_Throws() {
        XCTAssertThrowsError(
            try ANSFrequencyAnalysis.countFrequencies(
                symbols: [-1], alphabetSize: 3
            )
        ) { error in
            XCTAssertTrue(error is ANSError)
        }
    }

    func testFrequencyAnalysis_BuildDistribution_Works() throws {
        let symbols = [0, 0, 0, 1, 1, 2]
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 3
        )
        XCTAssertEqual(dist.alphabetSize, 3)
        let sum = dist.frequencies.reduce(UInt32(0), +)
        XCTAssertEqual(sum, ANSConstants.tabSize)
    }

    // MARK: - Distribution Serialisation

    func testSerialisation_Uncompressed_RoundTrip() throws {
        let freqs: [UInt32] = [100, 200, 50, 30]
        let dist = try ANSDistribution(rawFrequencies: freqs)
        let serialised = dist.serialise()
        let restored = try ANSDistribution.deserialise(from: serialised)

        XCTAssertEqual(restored.alphabetSize, dist.alphabetSize)
        // Frequencies may differ slightly due to double-normalisation
        // but should still sum to tabSize
        let sum = restored.frequencies.reduce(UInt32(0), +)
        XCTAssertEqual(sum, ANSConstants.tabSize)
    }

    func testSerialisation_Compressed_RoundTrip() throws {
        // Sparse distribution — mostly zeros
        var freqs = [UInt32](repeating: 0, count: 32)
        freqs[0] = 500
        freqs[10] = 100
        freqs[20] = 50
        let dist = try ANSDistribution(rawFrequencies: freqs)
        let serialised = dist.serialiseCompressed()
        let restored = try ANSDistribution.deserialise(from: serialised)

        XCTAssertEqual(restored.alphabetSize, dist.alphabetSize)
        let sum = restored.frequencies.reduce(UInt32(0), +)
        XCTAssertEqual(sum, ANSConstants.tabSize)
    }

    func testSerialisation_CompressedSmaller_ForSparse() throws {
        // Sparse distribution should compress better with RLE
        var freqs = [UInt32](repeating: 0, count: 128)
        freqs[0] = 500
        freqs[64] = 100
        let dist = try ANSDistribution(rawFrequencies: freqs)

        let uncompressed = dist.serialise()
        let compressed = dist.serialiseCompressed()

        XCTAssertLessThan(
            compressed.count, uncompressed.count,
            "RLE should be smaller for sparse distributions"
        )
    }

    func testSerialisation_Deserialise_TruncatedData_Throws() {
        XCTAssertThrowsError(
            try ANSDistribution.deserialise(from: Data([0x01]))
        )
    }

    func testSerialisation_Deserialise_ZeroAlphabet_Throws() {
        XCTAssertThrowsError(
            try ANSDistribution.deserialise(from: Data([0x00, 0x00]))
        )
    }

    func testSerialisation_Deserialise_UnknownMode_Throws() {
        XCTAssertThrowsError(
            try ANSDistribution.deserialise(
                from: Data([0x02, 0x05, 0x00, 0x00, 0x01, 0x00])
            )
        )
    }

    func testSerialisation_Uncompressed_Format() throws {
        let freqs: [UInt32] = [100, 200]
        let dist = try ANSDistribution(rawFrequencies: freqs)
        let serialised = dist.serialise()

        // Header: alphabet size, mode
        XCTAssertEqual(serialised[0], 2)  // alphabet size
        XCTAssertEqual(serialised[1], 0)  // uncompressed mode
        // Should have 2 + 2*2 = 6 bytes
        XCTAssertEqual(serialised.count, 6)
    }

    func testSerialisation_Compressed_ModeByteIsOne() throws {
        let freqs: [UInt32] = [100, 200]
        let dist = try ANSDistribution(rawFrequencies: freqs)
        let serialised = dist.serialiseCompressed()

        XCTAssertEqual(serialised[0], 2)  // alphabet size
        XCTAssertEqual(serialised[1], 1)  // compressed mode
    }

    // MARK: - Multi-Context ANS

    func testMultiContext_RoundTrip_TwoContexts() throws {
        // Context 0: mostly symbol 0
        let ctx0Symbols = [Int](repeating: 0, count: 50) + [1, 1]
        // Context 1: mostly symbol 1
        let ctx1Symbols = [1, 1, 1, 1] + [Int](repeating: 0, count: 2)

        let encoder = try MultiContextANSEncoder.build(
            contextSymbols: [ctx0Symbols, ctx1Symbols],
            alphabetSize: 2
        )

        // Encode interleaved symbols with contexts
        let pairs: [(symbol: Int, context: Int)] = [
            (0, 0), (1, 1), (0, 0), (1, 1),
            (0, 0), (0, 1), (1, 0), (1, 1),
        ]

        let encoded = try encoder.encode(pairs)
        let contexts = pairs.map { $0.context }
        let decoded = try encoder.decode(encoded, contexts: contexts)

        let expected = pairs.map { $0.symbol }
        XCTAssertEqual(decoded, expected)
    }

    func testMultiContext_EmptyContext_UsesUniform() throws {
        // Context 0 has data, context 1 is empty (gets uniform distribution)
        let encoder = try MultiContextANSEncoder.build(
            contextSymbols: [[0, 0, 1], []],
            alphabetSize: 2
        )
        XCTAssertEqual(encoder.contextCount, 2)
    }

    func testMultiContext_InvalidContext_Throws() throws {
        let encoder = try MultiContextANSEncoder.build(
            contextSymbols: [[0, 1]],
            alphabetSize: 2
        )

        XCTAssertThrowsError(
            try encoder.encode([(symbol: 0, context: 1)])
        )
    }

    func testMultiContext_DecodeInvalidContext_Throws() throws {
        let encoder = try MultiContextANSEncoder.build(
            contextSymbols: [[0, 1]],
            alphabetSize: 2
        )

        let encoded = try encoder.encode([(symbol: 0, context: 0)])
        XCTAssertThrowsError(
            try encoder.decode(encoded, contexts: [5])
        )
    }

    // MARK: - Edge Cases

    func testRoundTrip_RepeatedSameSymbol_Long() throws {
        let symbols = [Int](repeating: 3, count: 5000)
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 4
        )

        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode(symbols)

        let decoder = ANSDecoder(distribution: dist)
        let decoded = try decoder.decode(encoded, count: symbols.count)

        XCTAssertEqual(decoded, symbols)
    }

    func testRoundTrip_AlternatingSymbols() throws {
        var symbols = [Int]()
        for i in 0..<500 {
            symbols.append(i % 2)
        }
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 2
        )

        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode(symbols)

        let decoder = ANSDecoder(distribution: dist)
        let decoded = try decoder.decode(encoded, count: symbols.count)

        XCTAssertEqual(decoded, symbols)
    }

    func testRoundTrip_MaxAlphabet_256Symbols() throws {
        // Use all 256 symbols
        var symbols = [Int]()
        for i in 0..<256 {
            // Weight symbol i proportional to i + 1
            symbols.append(contentsOf: [Int](repeating: i, count: i + 1))
        }
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 256
        )

        let encoder = ANSEncoder(distribution: dist)
        let encoded = try encoder.encode(symbols)

        let decoder = ANSDecoder(distribution: dist)
        let decoded = try decoder.decode(encoded, count: symbols.count)

        XCTAssertEqual(decoded, symbols)
    }

    // MARK: - Distribution Properties

    func testDistribution_Frequencies_PreserveRelativeOrder() throws {
        let freqs: [UInt32] = [1000, 100, 10, 1]
        let dist = try ANSDistribution(rawFrequencies: freqs)

        // Most frequent symbol should still have highest normalised frequency
        XCTAssertGreaterThan(dist.frequencies[0], dist.frequencies[1])
        XCTAssertGreaterThan(dist.frequencies[1], dist.frequencies[2])
        XCTAssertGreaterThanOrEqual(dist.frequencies[2], dist.frequencies[3])
    }

    func testDistribution_TwoEqualFreqs_AreEqual() throws {
        let freqs: [UInt32] = [500, 500]
        let dist = try ANSDistribution(rawFrequencies: freqs)
        XCTAssertEqual(dist.frequencies[0], dist.frequencies[1])
        XCTAssertEqual(dist.frequencies[0], ANSConstants.tabSize / 2)
    }

    // MARK: - Performance

    func testPerformance_EncodeDecodeRoundTrip() throws {
        // Build a realistic symbol sequence
        var symbols = [Int]()
        for i in 0..<50000 {
            // Geometric-like distribution
            let s = min(i % 16, 7)
            symbols.append(s)
        }
        let dist = try ANSFrequencyAnalysis.buildDistribution(
            symbols: symbols, alphabetSize: 8
        )
        let encoder = ANSEncoder(distribution: dist)
        let decoder = ANSDecoder(distribution: dist)

        measure {
            let encoded = try! encoder.encode(symbols)
            let _ = try! decoder.decode(encoded, count: symbols.count)
        }
    }
}
