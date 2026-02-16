import XCTest
@testable import JXLSwift

/// Integration tests for CLI-related functionality covering:
/// - Argument parsing validation (encoding options construction)
/// - Info subcommand metadata display (codestream header parsing)
/// - Benchmark subcommand completion (all effort levels)
/// - Invalid argument error messages
final class CLIIntegrationTests: XCTestCase {

    // MARK: - CLI Argument Parsing Tests

    func testArgumentParsing_DefaultOptions_MatchExpectedDefaults() {
        let options = EncodingOptions()
        switch options.mode {
        case .lossy(let quality):
            XCTAssertEqual(quality, 90, accuracy: 0.001)
        default:
            XCTFail("Default mode should be lossy with quality 90")
        }
        XCTAssertEqual(options.effort, .squirrel)
        XCTAssertFalse(options.progressive)
        XCTAssertTrue(options.useHardwareAcceleration)
        XCTAssertTrue(options.useAccelerate)
        XCTAssertTrue(options.useMetal)
        XCTAssertEqual(options.numThreads, 0)
    }

    func testArgumentParsing_LosslessMode_SetsCorrectOptions() {
        let options = EncodingOptions.lossless
        switch options.mode {
        case .lossless:
            break // Expected
        default:
            XCTFail("Lossless preset should use .lossless mode")
        }
        XCTAssertTrue(options.modularMode)
    }

    func testArgumentParsing_FastPreset_SetsCorrectOptions() {
        let options = EncodingOptions.fast
        switch options.mode {
        case .lossy(let quality):
            XCTAssertEqual(quality, 85, accuracy: 0.001)
        default:
            XCTFail("Fast preset should use lossy mode")
        }
        XCTAssertEqual(options.effort, .falcon)
    }

    func testArgumentParsing_HighQualityPreset_SetsCorrectOptions() {
        let options = EncodingOptions.highQuality
        switch options.mode {
        case .lossy(let quality):
            XCTAssertEqual(quality, 95, accuracy: 0.001)
        default:
            XCTFail("High quality preset should use lossy mode")
        }
        XCTAssertEqual(options.effort, .kitten)
    }

    func testArgumentParsing_DistanceMode_SetsCorrectly() {
        let options = EncodingOptions(mode: .distance(1.5), effort: .falcon)
        switch options.mode {
        case .distance(let d):
            XCTAssertEqual(d, 1.5, accuracy: 0.001)
        default:
            XCTFail("Should be distance mode")
        }
    }

    func testArgumentParsing_EffortLevels_AllRawValuesValid() {
        // Verify all effort levels 1-9 parse correctly (mirrors CLI --effort 1-9)
        for rawValue in 1...9 {
            let effort = EncodingEffort(rawValue: rawValue)
            XCTAssertNotNil(effort, "Effort level \(rawValue) should be valid")
        }
    }

    func testArgumentParsing_InvalidEffort_ReturnsNil() {
        // Mirrors CLI validation: effort 0, 10, -1 should be rejected
        XCTAssertNil(EncodingEffort(rawValue: 0))
        XCTAssertNil(EncodingEffort(rawValue: 10))
        XCTAssertNil(EncodingEffort(rawValue: -1))
    }

    func testArgumentParsing_DisableAccelerate_SetsFlag() {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            effort: .squirrel,
            useHardwareAcceleration: false,
            useAccelerate: false
        )
        XCTAssertFalse(options.useHardwareAcceleration)
        XCTAssertFalse(options.useAccelerate)
    }

    func testArgumentParsing_DisableMetal_SetsFlag() {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            effort: .squirrel,
            useMetal: false
        )
        XCTAssertFalse(options.useMetal)
    }

    func testArgumentParsing_CustomThreadCount_SetsCorrectly() {
        let options = EncodingOptions(numThreads: 4)
        XCTAssertEqual(options.numThreads, 4)
    }

    func testArgumentParsing_QualityBoundaries_AcceptedCorrectly() {
        // Quality 0 and 100 should both be accepted as valid options
        let lowQ = EncodingOptions(mode: .lossy(quality: 0))
        let highQ = EncodingOptions(mode: .lossy(quality: 100))
        switch lowQ.mode {
        case .lossy(let q):
            XCTAssertEqual(q, 0, accuracy: 0.001)
        default:
            XCTFail("Should be lossy mode")
        }
        switch highQ.mode {
        case .lossy(let q):
            XCTAssertEqual(q, 100, accuracy: 0.001)
        default:
            XCTFail("Should be lossy mode")
        }
    }

    // MARK: - Info Subcommand Metadata Display Tests

    func testInfo_EncodedFile_HasValidSignature() throws {
        let result = try encodeTestFrame(width: 32, height: 32)
        let data = result.data

        // Verify the signature bytes that the info subcommand checks
        XCTAssertGreaterThanOrEqual(data.count, 2)
        XCTAssertEqual(data[0], 0xFF, "JPEG XL signature byte 0")
        XCTAssertEqual(data[1], 0x0A, "JPEG XL signature byte 1")
    }

    func testInfo_EncodedFile_HasSufficientHeaderData() throws {
        let result = try encodeTestFrame(width: 64, height: 64)
        // The info subcommand requires at least 12 bytes to read dimensions
        XCTAssertGreaterThanOrEqual(result.data.count, 12,
            "Encoded output should have enough bytes for header parsing")
    }

    func testInfo_CompressionStats_ReportsValidMetrics() throws {
        let result = try encodeTestFrame(width: 32, height: 32)

        XCTAssertGreaterThan(result.stats.originalSize, 0, "Original size should be positive")
        XCTAssertGreaterThan(result.stats.compressedSize, 0, "Compressed size should be positive")
        XCTAssertGreaterThan(result.stats.compressionRatio, 0, "Compression ratio should be positive")
        XCTAssertGreaterThanOrEqual(result.stats.encodingTime, 0, "Encoding time should be non-negative")
    }

    func testInfo_LosslessOutput_HasValidSignatureAndStats() throws {
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        fillGradient(frame: &frame)

        let result = try encoder.encode(frame)

        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0x0A)
        XCTAssertGreaterThan(result.stats.compressionRatio, 0)
    }

    func testInfo_SmallImage_ProducesValidHeader() throws {
        // 1x1 image — edge case for the info subcommand
        let result = try encodeTestFrame(width: 1, height: 1)

        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0x0A)
        XCTAssertGreaterThan(result.data.count, 2)
    }

    func testInfo_LargeImage_ProducesValidHeader() throws {
        // Non-power-of-2 image dimensions
        let result = try encodeTestFrame(width: 100, height: 75)

        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0x0A)
        XCTAssertGreaterThanOrEqual(result.data.count, 12)
    }

    func testInfo_CodestreamHeader_SerializesCorrectly() throws {
        let header = try CodestreamHeader(
            frame: ImageFrame(width: 128, height: 64, channels: 3)
        )
        let data = header.serialise()

        // Signature
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0x0A)

        // Data should contain the serialised size header and metadata
        XCTAssertGreaterThan(data.count, 2)
    }

    func testInfo_SizeHeader_SmallDimensions() throws {
        // Both ≤ 256 should use the small encoding path
        let header = try SizeHeader(width: 128, height: 64)
        XCTAssertEqual(header.width, 128)
        XCTAssertEqual(header.height, 64)
    }

    func testInfo_SizeHeader_LargeDimensions() throws {
        // > 256 should use the variable-length encoding path
        let header = try SizeHeader(width: 1920, height: 1080)
        XCTAssertEqual(header.width, 1920)
        XCTAssertEqual(header.height, 1080)
    }

    func testInfo_SizeHeader_InvalidDimensions_ThrowsError() {
        XCTAssertThrowsError(try SizeHeader(width: 0, height: 100)) { error in
            XCTAssertTrue(error is CodestreamError)
        }
        XCTAssertThrowsError(try SizeHeader(width: 100, height: 0)) { error in
            XCTAssertTrue(error is CodestreamError)
        }
    }

    func testInfo_ImageMetadata_DefaultValues() {
        let metadata = ImageMetadata()
        XCTAssertEqual(metadata.bitsPerSample, 8)
        XCTAssertFalse(metadata.hasAlpha)
        XCTAssertEqual(metadata.extraChannelCount, 0)
        XCTAssertFalse(metadata.xybEncoded)
        XCTAssertEqual(metadata.colourEncoding, ColourEncoding.sRGB)
        XCTAssertEqual(metadata.orientation, 1)
        XCTAssertFalse(metadata.haveAnimation)
    }

    func testInfo_ColourEncoding_SRGBDefault() {
        let encoding = ColourEncoding.sRGB
        XCTAssertFalse(encoding.useICCProfile)
        XCTAssertEqual(encoding.colourSpace, .rgb)
        XCTAssertEqual(encoding.whitePoint, .d65)
        XCTAssertEqual(encoding.primaries, .sRGB)
        XCTAssertEqual(encoding.transferFunction, .sRGB)
        XCTAssertEqual(encoding.renderingIntent, .relative)
    }

    func testInfo_ColourEncoding_GreyscaleConversion() {
        let encoding = ColourEncoding.from(colorSpace: .grayscale)
        XCTAssertEqual(encoding.colourSpace, .grey)
    }

    func testInfo_ColourEncoding_LinearRGBConversion() {
        let encoding = ColourEncoding.from(colorSpace: .linearRGB)
        XCTAssertEqual(encoding.transferFunction, .linear)
    }

    // MARK: - Benchmark Subcommand Completion Tests

    func testBenchmark_AllEffortLevels_CompleteWithoutErrors() throws {
        let efforts: [EncodingEffort] = [
            .lightning, .thunder, .falcon, .cheetah, .hare,
            .wombat, .squirrel, .kitten, .tortoise
        ]

        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        fillGradient(frame: &frame)

        for effort in efforts {
            let options = EncodingOptions(
                mode: .lossy(quality: 90),
                effort: effort
            )
            let encoder = JXLEncoder(options: options)
            XCTAssertNoThrow(try encoder.encode(frame),
                "Encoding should succeed at effort level \(effort)")
        }
    }

    func testBenchmark_LosslessMode_CompletesWithoutErrors() throws {
        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        fillGradient(frame: &frame)

        let encoder = JXLEncoder(options: .lossless)
        let result = try encoder.encode(frame)

        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.stats.compressionRatio, 0)
    }

    func testBenchmark_MultipleIterations_ProduceConsistentResults() throws {
        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        fillGradient(frame: &frame)

        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            effort: .falcon
        )
        let encoder = JXLEncoder(options: options)

        var sizes: [Int] = []
        for _ in 0..<3 {
            let result = try encoder.encode(frame)
            sizes.append(result.data.count)
        }

        // All iterations should produce identical output
        XCTAssertEqual(sizes[0], sizes[1], "Iterations should produce consistent sizes")
        XCTAssertEqual(sizes[1], sizes[2], "Iterations should produce consistent sizes")
    }

    func testBenchmark_DifferentImageSizes_AllComplete() throws {
        let sizes: [(Int, Int)] = [(8, 8), (16, 16), (32, 32), (64, 64)]

        for (w, h) in sizes {
            var frame = ImageFrame(width: w, height: h, channels: 3)
            fillGradient(frame: &frame)

            let encoder = JXLEncoder(options: .fast)
            let result = try encoder.encode(frame)

            XCTAssertGreaterThan(result.data.count, 0,
                "Encoding \(w)×\(h) should produce output")
            XCTAssertEqual(result.data[0], 0xFF,
                "Encoding \(w)×\(h) should have valid signature")
            XCTAssertEqual(result.data[1], 0x0A,
                "Encoding \(w)×\(h) should have valid signature")
        }
    }

    func testBenchmark_StatsReportCorrectValues() throws {
        var frame = ImageFrame(width: 32, height: 32, channels: 3)
        fillGradient(frame: &frame)

        let encoder = JXLEncoder(options: .fast)
        let result = try encoder.encode(frame)

        // Original size should match the frame data size
        XCTAssertEqual(result.stats.originalSize, frame.data.count)
        // Compressed size should match encoded data size
        XCTAssertEqual(result.stats.compressedSize, result.data.count)
        // Ratio should be original / compressed
        let expectedRatio = Double(result.stats.originalSize) / Double(result.stats.compressedSize)
        XCTAssertEqual(result.stats.compressionRatio, expectedRatio, accuracy: 0.001)
    }

    // MARK: - Invalid Argument Error Message Tests

    func testInvalidArguments_ZeroDimensions_ThrowsInvalidImageDimensions() {
        let encoder = JXLEncoder()
        let frame = ImageFrame(width: 0, height: 0, channels: 3)
        XCTAssertThrowsError(try encoder.encode(frame)) { error in
            guard let encoderError = error as? EncoderError else {
                XCTFail("Expected EncoderError, got \(type(of: error))")
                return
            }
            switch encoderError {
            case .invalidImageDimensions:
                // Verify the error description is meaningful
                XCTAssertNotNil(encoderError.errorDescription)
                XCTAssertFalse(encoderError.errorDescription!.isEmpty,
                    "Error description should be non-empty")
            default:
                XCTFail("Expected invalidImageDimensions, got \(encoderError)")
            }
        }
    }

    func testInvalidArguments_ZeroChannels_ThrowsError() {
        let encoder = JXLEncoder()
        let frame = ImageFrame(width: 8, height: 8, channels: 0)
        XCTAssertThrowsError(try encoder.encode(frame)) { error in
            XCTAssertTrue(error is EncoderError)
            let encoderError = error as! EncoderError
            XCTAssertNotNil(encoderError.errorDescription)
            XCTAssertFalse(encoderError.errorDescription!.isEmpty)
        }
    }

    func testInvalidArguments_TooManyChannels_ThrowsError() {
        let encoder = JXLEncoder()
        let frame = ImageFrame(width: 8, height: 8, channels: 5)
        XCTAssertThrowsError(try encoder.encode(frame)) { error in
            XCTAssertTrue(error is EncoderError)
            let encoderError = error as! EncoderError
            XCTAssertNotNil(encoderError.errorDescription)
            XCTAssertFalse(encoderError.errorDescription!.isEmpty)
        }
    }

    func testInvalidArguments_AllEncoderErrors_HaveDescriptions() {
        let errors: [EncoderError] = [
            .invalidImageDimensions,
            .invalidConfiguration,
            .unsupportedPixelFormat,
            .encodingFailed("test reason"),
            .insufficientMemory,
            .hardwareAccelerationUnavailable,
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription,
                "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty,
                "Error \(error) description should be non-empty")
        }
    }

    func testInvalidArguments_EncodingFailedError_ContainsReason() {
        let error = EncoderError.encodingFailed("out of memory")
        XCTAssertTrue(error.errorDescription!.contains("out of memory"),
            "encodingFailed error description should contain the reason string")
    }

    func testInvalidArguments_CodestreamError_InvalidDimensions_HasDescription() {
        let error = CodestreamError.invalidDimensions(width: 0, height: 0)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("0"),
            "Error should mention the invalid dimension values")
    }

    func testInvalidArguments_CodestreamError_InvalidBitDepth_HasDescription() {
        let error = CodestreamError.invalidBitDepth(0)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testInvalidArguments_CodestreamError_InvalidOrientation_HasDescription() {
        let error = CodestreamError.invalidOrientation(10)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("10"))
    }

    func testInvalidArguments_CodestreamError_InvalidFrameHeader_HasDescription() {
        let error = CodestreamError.invalidFrameHeader("missing field")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("missing field"))
    }

    func testInvalidArguments_PixelBufferError_DataSizeMismatch_HasDescription() {
        let error = PixelBufferError.dataSizeMismatch(expected: 100, actual: 50)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("100"))
        XCTAssertTrue(error.errorDescription!.contains("50"))
    }

    func testInvalidArguments_PixelBuffer_WrongDataSize_ThrowsError() {
        let badData = [UInt8](repeating: 0, count: 10)
        XCTAssertThrowsError(
            try PixelBuffer(data: badData, width: 8, height: 8, channels: 3)
        ) { error in
            XCTAssertTrue(error is PixelBufferError)
        }
    }

    // MARK: - Encode Output File Validation Tests

    func testEncode_WriteToFile_ProducesValidJXL() throws {
        let encoder = JXLEncoder(options: .fast)
        var frame = ImageFrame(width: 32, height: 32, channels: 3)
        fillGradient(frame: &frame)

        let result = try encoder.encode(frame)

        // Write to temp file (mirrors what the encode subcommand does)
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("cli_test_\(UUID().uuidString).jxl")
        try result.data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Read back and verify
        let readData = try Data(contentsOf: tempFile)
        XCTAssertEqual(readData.count, result.data.count)
        XCTAssertEqual(readData[0], 0xFF)
        XCTAssertEqual(readData[1], 0x0A)

        // Verify file extension is correct
        XCTAssertEqual(tempFile.pathExtension, "jxl")
    }

    // MARK: - Hardware Subcommand Tests

    func testHardware_DispatchBackend_CurrentIsValid() {
        let current = DispatchBackend.current
        XCTAssertTrue(current.isAvailable)
        XCTAssertFalse(current.displayName.isEmpty)
    }

    func testHardware_DispatchBackend_AvailableIncludesScalar() {
        let available = DispatchBackend.available
        XCTAssertTrue(available.contains(.scalar),
            "Scalar backend should always be available")
    }

    func testHardware_DispatchBackend_AllCasesHaveDisplayNames() {
        for backend in DispatchBackend.allCases {
            XCTAssertFalse(backend.displayName.isEmpty,
                "Backend \(backend) should have a display name")
        }
    }

    func testHardware_DispatchBackend_OnlyMetalRequiresGPU() {
        for backend in DispatchBackend.allCases {
            if backend == .metal {
                XCTAssertTrue(backend.requiresGPU)
            } else {
                XCTAssertFalse(backend.requiresGPU)
            }
        }
    }

    // MARK: - Helpers

    /// Create and encode a test frame with gradient data.
    private func encodeTestFrame(width: Int, height: Int) throws -> EncodedImage {
        let encoder = JXLEncoder(options: .fast)
        var frame = ImageFrame(width: width, height: height, channels: 3)
        fillGradient(frame: &frame)
        return try encoder.encode(frame)
    }

    /// Fill an image frame with a gradient pattern for testing.
    private func fillGradient(frame: inout ImageFrame) {
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let r = UInt16((x * 255) / max(frame.width - 1, 1))
                let g = UInt16((y * 255) / max(frame.height - 1, 1))
                let b = UInt16(128)
                frame.setPixel(x: x, y: y, channel: 0, value: r)
                frame.setPixel(x: x, y: y, channel: 1, value: g)
                frame.setPixel(x: x, y: y, channel: 2, value: b)
            }
        }
    }
}
