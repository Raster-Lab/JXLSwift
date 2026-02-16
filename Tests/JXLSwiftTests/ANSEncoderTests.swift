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

    // MARK: - Encoder Integration (ANS Mode)

    func testModularEncoder_ANSMode_ProducesOutput() throws {
        var options = EncodingOptions.lossless
        options.useANS = true
        let encoder = JXLEncoder(options: options)

        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        for y in 0..<8 {
            for x in 0..<8 {
                for c in 0..<3 {
                    frame.setPixel(x: x, y: y, channel: c, value: UInt16(x * 32 + y * 16 + c * 64))
                }
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.stats.compressionRatio, 0)
    }

    func testVarDCTEncoder_ANSMode_ProducesOutput() throws {
        var options = EncodingOptions(mode: .lossy(quality: 90))
        options.useANS = true
        let encoder = JXLEncoder(options: options)

        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        for y in 0..<16 {
            for x in 0..<16 {
                for c in 0..<3 {
                    frame.setPixel(x: x, y: y, channel: c, value: UInt16(x * 16 + y * 8 + c * 32))
                }
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.stats.compressionRatio, 0)
    }

    func testModularEncoder_ANSMode_1x1Image() throws {
        var options = EncodingOptions.lossless
        options.useANS = true
        let encoder = JXLEncoder(options: options)

        var frame = ImageFrame(width: 1, height: 1, channels: 1)
        frame.setPixel(x: 0, y: 0, channel: 0, value: UInt16(128))

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }

    func testVarDCTEncoder_ANSMode_SingleChannel() throws {
        var options = EncodingOptions(mode: .lossy(quality: 85))
        options.useANS = true
        let encoder = JXLEncoder(options: options)

        var frame = ImageFrame(width: 8, height: 8, channels: 1)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }

    func testEncodingOptions_UseANS_DefaultIsFalse() {
        let options = EncodingOptions()
        XCTAssertFalse(options.useANS)
    }

    func testEncodingOptions_UseANS_CanBeEnabled() {
        let options = EncodingOptions(useANS: true)
        XCTAssertTrue(options.useANS)
    }

    // MARK: - Jensen-Shannon Divergence

    func testJSD_IdenticalDistributions_IsZero() {
        let a: [UInt32] = [100, 200, 300]
        let b: [UInt32] = [100, 200, 300]
        let jsd = HistogramClustering.jensenShannonDivergence(a, b)
        XCTAssertEqual(jsd, 0, accuracy: 1e-10)
    }

    func testJSD_ProportionalDistributions_IsZero() {
        let a: [UInt32] = [10, 20, 30]
        let b: [UInt32] = [100, 200, 300]
        let jsd = HistogramClustering.jensenShannonDivergence(a, b)
        XCTAssertEqual(jsd, 0, accuracy: 1e-10)
    }

    func testJSD_DifferentDistributions_IsPositive() {
        let a: [UInt32] = [1000, 1, 1]
        let b: [UInt32] = [1, 1, 1000]
        let jsd = HistogramClustering.jensenShannonDivergence(a, b)
        XCTAssertGreaterThan(jsd, 0)
    }

    func testJSD_IsSymmetric() {
        let a: [UInt32] = [500, 100, 50]
        let b: [UInt32] = [100, 400, 200]
        let jsdAB = HistogramClustering.jensenShannonDivergence(a, b)
        let jsdBA = HistogramClustering.jensenShannonDivergence(b, a)
        XCTAssertEqual(jsdAB, jsdBA, accuracy: 1e-10)
    }

    func testJSD_IsBounded() {
        // JSD is bounded by ln(2) ≈ 0.693
        let a: [UInt32] = [1000, 0, 0]
        let b: [UInt32] = [0, 0, 1000]
        let jsd = HistogramClustering.jensenShannonDivergence(a, b)
        XCTAssertLessThanOrEqual(jsd, log(2.0) + 1e-10)
        XCTAssertGreaterThanOrEqual(jsd, 0)
    }

    func testJSD_EmptyArrays_IsZero() {
        let a: [UInt32] = []
        let b: [UInt32] = []
        let jsd = HistogramClustering.jensenShannonDivergence(a, b)
        XCTAssertEqual(jsd, 0)
    }

    func testJSD_OneZeroTotal_IsZero() {
        let a: [UInt32] = [0, 0]
        let b: [UInt32] = [100, 200]
        let jsd = HistogramClustering.jensenShannonDivergence(a, b)
        XCTAssertEqual(jsd, 0)
    }

    func testJSD_DifferentLengths_HandlesGracefully() {
        let a: [UInt32] = [100, 200]
        let b: [UInt32] = [100, 200, 300]
        let jsd = HistogramClustering.jensenShannonDivergence(a, b)
        XCTAssertGreaterThan(jsd, 0)
    }

    // MARK: - Histogram Clustering

    func testClustering_EmptyInput_ReturnsEmpty() throws {
        let result = try HistogramClustering.cluster(
            contextSymbols: [],
            alphabetSize: 4
        )
        XCTAssertEqual(result.clusterCount, 0)
        XCTAssertEqual(result.contextMap.count, 0)
    }

    func testClustering_SingleContext_NoMerge() throws {
        let result = try HistogramClustering.cluster(
            contextSymbols: [[0, 1, 2, 0, 1]],
            alphabetSize: 3
        )
        XCTAssertEqual(result.clusterCount, 1)
        XCTAssertEqual(result.contextMap, [0])
    }

    func testClustering_IdenticalContexts_MergedToOne() throws {
        // Two contexts with identical symbol distributions should merge
        let symbols = [0, 0, 0, 1, 1, 2]
        let result = try HistogramClustering.cluster(
            contextSymbols: [symbols, symbols],
            alphabetSize: 3,
            distanceThreshold: 0.1
        )
        XCTAssertEqual(result.clusterCount, 1)
        XCTAssertEqual(result.contextMap[0], result.contextMap[1])
    }

    func testClustering_VeryDifferentContexts_NotMerged() throws {
        // Two very different distributions should not merge at low threshold
        let ctx0 = [Int](repeating: 0, count: 100)
        let ctx1 = [Int](repeating: 1, count: 100)
        let result = try HistogramClustering.cluster(
            contextSymbols: [ctx0, ctx1],
            alphabetSize: 2,
            distanceThreshold: 0.01
        )
        XCTAssertEqual(result.clusterCount, 2)
        XCTAssertNotEqual(result.contextMap[0], result.contextMap[1])
    }

    func testClustering_ThreeContexts_TwoSimilarMerge() throws {
        // ctx0 and ctx1 are very similar (heavily skewed to 0)
        let ctx0 = [Int](repeating: 0, count: 100) + [1]
        let ctx1 = [Int](repeating: 0, count: 95) + [1, 1, 1]
        // ctx2 is heavily skewed the other way
        let ctx2 = [0] + [Int](repeating: 1, count: 100)
        let result = try HistogramClustering.cluster(
            contextSymbols: [ctx0, ctx1, ctx2],
            alphabetSize: 2,
            distanceThreshold: 0.1
        )
        // ctx0 and ctx1 should be in the same cluster
        XCTAssertEqual(result.contextMap[0], result.contextMap[1])
        // ctx2 should be in a different cluster
        XCTAssertNotEqual(result.contextMap[0], result.contextMap[2])
        XCTAssertEqual(result.clusterCount, 2)
    }

    func testClustering_MaxClusters_Respected() throws {
        // 4 very different contexts, but limit to 2 clusters
        let result = try HistogramClustering.cluster(
            contextSymbols: [
                [Int](repeating: 0, count: 100),
                [Int](repeating: 1, count: 100),
                [Int](repeating: 2, count: 100),
                [Int](repeating: 3, count: 100),
            ],
            alphabetSize: 4,
            maxClusters: 2,
            distanceThreshold: 1.0
        )
        XCTAssertLessThanOrEqual(result.clusterCount, 2)
        XCTAssertEqual(result.contextMap.count, 4)
    }

    func testClustering_MaxClustersZero_NoLimit() throws {
        // 4 different contexts, maxClusters=0 means no forced merging
        let result = try HistogramClustering.cluster(
            contextSymbols: [
                [Int](repeating: 0, count: 100),
                [Int](repeating: 1, count: 100),
                [Int](repeating: 2, count: 100),
                [Int](repeating: 3, count: 100),
            ],
            alphabetSize: 4,
            maxClusters: 0,
            distanceThreshold: 0.001
        )
        // With very low threshold and no limit, all stay separate
        XCTAssertEqual(result.clusterCount, 4)
    }

    func testClustering_ContextMapValid_AllIndicesInRange() throws {
        let result = try HistogramClustering.cluster(
            contextSymbols: [
                [0, 1, 0], [1, 1, 0], [0, 0, 0],
                [1, 0, 1], [0, 1, 1],
            ],
            alphabetSize: 2,
            distanceThreshold: 0.5
        )
        for cluster in result.contextMap {
            XCTAssertGreaterThanOrEqual(cluster, 0)
            XCTAssertLessThan(cluster, result.clusterCount)
        }
    }

    func testClustering_DistributionsSumToTabSize() throws {
        let result = try HistogramClustering.cluster(
            contextSymbols: [
                [0, 0, 1], [0, 1, 1], [1, 1, 1],
            ],
            alphabetSize: 2,
            distanceThreshold: 0.5
        )
        for dist in result.distributions {
            let sum = dist.frequencies.reduce(UInt32(0), +)
            XCTAssertEqual(sum, ANSConstants.tabSize)
        }
    }

    func testClustering_EmptyContexts_HandledGracefully() throws {
        // Mix of empty and non-empty contexts
        let result = try HistogramClustering.cluster(
            contextSymbols: [
                [],        // empty → uniform
                [0, 0, 0], // skewed toward 0
                [],        // empty → uniform
            ],
            alphabetSize: 2,
            distanceThreshold: 0.5
        )
        // The two empty contexts should have identical (uniform) distributions
        // and merge together
        XCTAssertEqual(result.contextMap[0], result.contextMap[2])
        XCTAssertEqual(result.contextMap.count, 3)
    }

    func testClustering_HighThreshold_MergesAll() throws {
        // With a very high threshold, all contexts should merge
        let result = try HistogramClustering.cluster(
            contextSymbols: [
                [Int](repeating: 0, count: 100),
                [Int](repeating: 1, count: 100),
                [Int](repeating: 2, count: 100),
            ],
            alphabetSize: 3,
            distanceThreshold: 1.0
        )
        XCTAssertEqual(result.clusterCount, 1)
    }

    // MARK: - Clustered Multi-Context Encoder

    func testBuildClustered_RoundTrip_IdenticalContexts() throws {
        let symbols = [0, 0, 1, 0, 1]
        let (encoder, contextMap) = try MultiContextANSEncoder.buildClustered(
            contextSymbols: [symbols, symbols],
            alphabetSize: 2,
            distanceThreshold: 0.5
        )

        // Both contexts map to the same cluster
        XCTAssertEqual(contextMap[0], contextMap[1])

        // Encode using mapped contexts
        let pairs: [(symbol: Int, context: Int)] = [
            (0, contextMap[0]), (1, contextMap[1]),
            (0, contextMap[0]), (1, contextMap[0]),
        ]
        let encoded = try encoder.encode(pairs)
        let decoded = try encoder.decode(
            encoded, contexts: pairs.map { $0.context }
        )
        XCTAssertEqual(decoded, pairs.map { $0.symbol })
    }

    func testBuildClustered_RoundTrip_DifferentContexts() throws {
        let ctx0 = [Int](repeating: 0, count: 50) + [1]
        let ctx1 = [1, 1, 1, 1, 0]
        let (encoder, contextMap) = try MultiContextANSEncoder.buildClustered(
            contextSymbols: [ctx0, ctx1],
            alphabetSize: 2,
            distanceThreshold: 0.01
        )

        // These are very different so should stay separate
        XCTAssertNotEqual(contextMap[0], contextMap[1])

        // Encode using mapped contexts
        let pairs: [(symbol: Int, context: Int)] = [
            (0, contextMap[0]), (1, contextMap[1]),
            (0, contextMap[0]), (0, contextMap[1]),
        ]
        let encoded = try encoder.encode(pairs)
        let decoded = try encoder.decode(
            encoded, contexts: pairs.map { $0.context }
        )
        XCTAssertEqual(decoded, pairs.map { $0.symbol })
    }

    func testBuildClustered_DefaultThreshold_Works() throws {
        let (encoder, contextMap) = try MultiContextANSEncoder.buildClustered(
            contextSymbols: [[0, 1, 0], [0, 0, 1]],
            alphabetSize: 2
        )
        XCTAssertEqual(contextMap.count, 2)
        XCTAssertGreaterThan(encoder.contextCount, 0)
    }

    func testBuildClustered_ManyContexts_ReducesClusters() throws {
        // 8 contexts: 4 are similar (mostly 0), 4 are similar (mostly 1)
        var contextSymbols = [[Int]]()
        for _ in 0..<4 {
            contextSymbols.append([Int](repeating: 0, count: 50) + [1, 1])
        }
        for _ in 0..<4 {
            contextSymbols.append([Int](repeating: 1, count: 50) + [0, 0])
        }

        let (encoder, contextMap) = try MultiContextANSEncoder.buildClustered(
            contextSymbols: contextSymbols,
            alphabetSize: 2,
            distanceThreshold: 0.1
        )

        // Should reduce to approximately 2 clusters
        XCTAssertLessThanOrEqual(encoder.contextCount, 4)
        XCTAssertGreaterThanOrEqual(encoder.contextCount, 2)

        // First 4 contexts should map to the same cluster
        XCTAssertEqual(contextMap[0], contextMap[1])
        XCTAssertEqual(contextMap[1], contextMap[2])
        XCTAssertEqual(contextMap[2], contextMap[3])

        // Last 4 contexts should map to the same cluster
        XCTAssertEqual(contextMap[4], contextMap[5])
        XCTAssertEqual(contextMap[5], contextMap[6])
        XCTAssertEqual(contextMap[6], contextMap[7])

        // The two groups should be in different clusters
        XCTAssertNotEqual(contextMap[0], contextMap[4])
    }
}
