import XCTest
@testable import JXLSwift

/// Tests for the JXLDecoder, codestream header parsing, frame header
/// parsing, and container extraction.
final class DecoderTests: XCTestCase {

    // MARK: - Helpers

    /// Create a simple image frame filled with a gradient.
    private func makeGradientFrame(
        width: Int, height: Int, channels: Int
    ) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: channels
        )
        for c in 0..<channels {
            for y in 0..<height {
                for x in 0..<width {
                    let value = UInt16((x + y * width + c * 7) % 256)
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }
        return frame
    }

    /// Assert two frames are pixel-identical.
    private func assertPixelPerfect(
        _ a: ImageFrame, _ b: ImageFrame,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.width, b.width, "width", file: file, line: line)
        XCTAssertEqual(a.height, b.height, "height", file: file, line: line)
        XCTAssertEqual(a.channels, b.channels, "channels", file: file, line: line)
        for c in 0..<a.channels {
            for y in 0..<a.height {
                for x in 0..<a.width {
                    let av = a.getPixel(x: x, y: y, channel: c)
                    let bv = b.getPixel(x: x, y: y, channel: c)
                    if av != bv {
                        XCTFail("pixel (\(x),\(y)) ch\(c): \(av)≠\(bv)",
                                file: file, line: line)
                        return
                    }
                }
            }
        }
    }

    /// Encode a frame with JXLEncoder (lossless).
    private func encodeLossless(_ frame: ImageFrame) throws -> Data {
        let encoder = JXLEncoder(options: .lossless)
        return try encoder.encode(frame).data
    }

    // MARK: - Signature Parsing

    func testParseSignature_Valid() throws {
        let decoder = JXLDecoder()
        let data = Data([0xFF, 0x0A, 0x00])
        XCTAssertNoThrow(try decoder.parseSignature(data))
    }

    func testParseSignature_TooShort() {
        let decoder = JXLDecoder()
        XCTAssertThrowsError(try decoder.parseSignature(Data([0xFF]))) { error in
            XCTAssertEqual(error as? DecoderError, DecoderError.truncatedData)
        }
    }

    func testParseSignature_Empty() {
        let decoder = JXLDecoder()
        XCTAssertThrowsError(try decoder.parseSignature(Data())) { error in
            XCTAssertEqual(error as? DecoderError, DecoderError.truncatedData)
        }
    }

    func testParseSignature_WrongFirstByte() {
        let decoder = JXLDecoder()
        XCTAssertThrowsError(try decoder.parseSignature(Data([0x00, 0x0A]))) { error in
            XCTAssertEqual(error as? DecoderError, DecoderError.invalidSignature)
        }
    }

    func testParseSignature_WrongSecondByte() {
        let decoder = JXLDecoder()
        XCTAssertThrowsError(try decoder.parseSignature(Data([0xFF, 0x00]))) { error in
            XCTAssertEqual(error as? DecoderError, DecoderError.invalidSignature)
        }
    }

    // MARK: - Image Header Parsing

    func testParseImageHeader_ValidMinimal() throws {
        // Build a minimal valid codestream: signature + image header
        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        for c in 0..<3 {
            for y in 0..<8 {
                for x in 0..<8 {
                    frame.setPixel(x: x, y: y, channel: c, value: UInt16(x + y))
                }
            }
        }
        let data = try encodeLossless(frame)

        let decoder = JXLDecoder()
        let header = try decoder.parseImageHeader(data)

        XCTAssertEqual(header.width, 8)
        XCTAssertEqual(header.height, 8)
        XCTAssertEqual(header.bitsPerSample, 8)
        XCTAssertEqual(header.channels, 3)
        XCTAssertEqual(header.headerSize, 14)
    }

    func testParseImageHeader_SingleChannel() throws {
        let frame = ImageFrame(width: 4, height: 4, channels: 1)
        let data = try encodeLossless(frame)

        let decoder = JXLDecoder()
        let header = try decoder.parseImageHeader(data)

        XCTAssertEqual(header.width, 4)
        XCTAssertEqual(header.height, 4)
        XCTAssertEqual(header.channels, 1)
    }

    func testParseImageHeader_TruncatedData() {
        let decoder = JXLDecoder()
        // Only 13 bytes — needs 14
        let data = Data([0xFF, 0x0A, 0, 0, 0, 8, 0, 0, 0, 8, 8, 3, 0])
        XCTAssertThrowsError(try decoder.parseImageHeader(data)) { error in
            XCTAssertEqual(error as? DecoderError, DecoderError.truncatedData)
        }
    }

    func testParseImageHeader_PreservesAlphaFlag() throws {
        // Encode a frame with alpha
        let frame = ImageFrame(
            width: 4, height: 4, channels: 4, hasAlpha: true
        )
        let data = try encodeLossless(frame)

        let decoder = JXLDecoder()
        let header = try decoder.parseImageHeader(data)

        XCTAssertTrue(header.hasAlpha)
        XCTAssertEqual(header.channels, 4)
    }

    func testParseImageHeader_NoAlpha() throws {
        let frame = ImageFrame(width: 4, height: 4, channels: 3)
        let data = try encodeLossless(frame)

        let decoder = JXLDecoder()
        let header = try decoder.parseImageHeader(data)

        XCTAssertFalse(header.hasAlpha)
    }

    func testParseImageHeader_LargeDimensions() throws {
        let frame = ImageFrame(width: 256, height: 256, channels: 1)
        let data = try encodeLossless(frame)

        let decoder = JXLDecoder()
        let header = try decoder.parseImageHeader(data)

        XCTAssertEqual(header.width, 256)
        XCTAssertEqual(header.height, 256)
    }

    // MARK: - Frame Header Parsing

    func testParseFrameHeader_AllDefault() throws {
        // Serialise an all-default frame header
        let fh = FrameHeader() // defaults: varDCT, replace, isLast, 1 group, 1 pass
        var writer = BitstreamWriter()
        fh.serialise(to: &writer)
        writer.flushByte()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseFrameHeader(writer.data)

        XCTAssertTrue(parsed.isAllDefault)
        XCTAssertEqual(parsed.frameType, .regularFrame)
        XCTAssertEqual(parsed.encoding, .varDCT)
        XCTAssertEqual(parsed.blendMode, .replace)
        XCTAssertEqual(parsed.duration, 0)
        XCTAssertTrue(parsed.isLast)
        XCTAssertEqual(parsed.saveAsReference, 0)
        XCTAssertEqual(parsed.name, "")
        XCTAssertEqual(parsed.numGroups, 1)
        XCTAssertEqual(parsed.numPasses, 1)
    }

    func testParseFrameHeader_Modular() throws {
        let fh = FrameHeader.lossless()
        var writer = BitstreamWriter()
        fh.serialise(to: &writer)
        writer.flushByte()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseFrameHeader(writer.data)

        XCTAssertFalse(parsed.isAllDefault)
        XCTAssertEqual(parsed.encoding, .modular)
        XCTAssertEqual(parsed.frameType, .regularFrame)
        XCTAssertTrue(parsed.isLast)
    }

    func testParseFrameHeader_AnimationWithDuration() throws {
        let fh = FrameHeader.animation(duration: 100, isLast: false)
        var writer = BitstreamWriter()
        fh.serialise(to: &writer)
        writer.flushByte()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseFrameHeader(writer.data)

        XCTAssertEqual(parsed.duration, 100)
        XCTAssertFalse(parsed.isLast)
        XCTAssertEqual(parsed.blendMode, .blend)
    }

    func testParseFrameHeader_WithReference() throws {
        let fh = FrameHeader(
            frameType: .regularFrame,
            encoding: .modular,
            blendMode: .replace,
            isLast: false,
            saveAsReference: 2
        )
        var writer = BitstreamWriter()
        fh.serialise(to: &writer)
        writer.flushByte()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseFrameHeader(writer.data)

        XCTAssertEqual(parsed.saveAsReference, 2)
        XCTAssertFalse(parsed.isLast)
    }

    func testParseFrameHeader_MultiplePasses() throws {
        let fh = FrameHeader(
            frameType: .regularFrame,
            encoding: .varDCT,
            blendMode: .replace,
            isLast: true,
            numPasses: 3
        )
        var writer = BitstreamWriter()
        fh.serialise(to: &writer)
        writer.flushByte()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseFrameHeader(writer.data)

        XCTAssertEqual(parsed.numPasses, 3)
    }

    func testParseFrameHeader_TruncatedData() {
        let decoder = JXLDecoder()
        XCTAssertThrowsError(try decoder.parseFrameHeader(Data()))
    }

    // MARK: - Full Decode Round-Trip

    func testDecode_1x1_SingleChannel() throws {
        var frame = ImageFrame(width: 1, height: 1, channels: 1)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 128)

        let encoded = try encodeLossless(frame)
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)

        assertPixelPerfect(frame, decoded)
    }

    func testDecode_1x1_RGB() throws {
        var frame = ImageFrame(width: 1, height: 1, channels: 3)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 255)
        frame.setPixel(x: 0, y: 0, channel: 1, value: 128)
        frame.setPixel(x: 0, y: 0, channel: 2, value: 64)

        let encoded = try encodeLossless(frame)
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)

        assertPixelPerfect(frame, decoded)
    }

    func testDecode_8x8_Gradient() throws {
        let frame = makeGradientFrame(width: 8, height: 8, channels: 3)
        let encoded = try encodeLossless(frame)
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        assertPixelPerfect(frame, decoded)
    }

    func testDecode_16x16_Gradient() throws {
        let frame = makeGradientFrame(width: 16, height: 16, channels: 3)
        let encoded = try encodeLossless(frame)
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        assertPixelPerfect(frame, decoded)
    }

    func testDecode_OddDimensions_5x7() throws {
        let frame = makeGradientFrame(width: 5, height: 7, channels: 3)
        let encoded = try encodeLossless(frame)
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        assertPixelPerfect(frame, decoded)
    }

    func testDecode_4x4_SingleChannel_Flat() throws {
        let frame = ImageFrame(width: 4, height: 4, channels: 1)
        // All zeros by default
        let encoded = try encodeLossless(frame)
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        assertPixelPerfect(frame, decoded)
    }

    func testDecode_4x4_AllMax() throws {
        var frame = ImageFrame(width: 4, height: 4, channels: 1)
        for y in 0..<4 {
            for x in 0..<4 {
                frame.setPixel(x: x, y: y, channel: 0, value: 255)
            }
        }
        let encoded = try encodeLossless(frame)
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        assertPixelPerfect(frame, decoded)
    }

    func testDecode_4Channel_RGBA() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 4)
        let encoded = try encodeLossless(frame)
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        assertPixelPerfect(frame, decoded)
    }

    func testDecode_32x32_Random() throws {
        var frame = ImageFrame(width: 32, height: 32, channels: 3)
        var state: UInt64 = 42
        for c in 0..<3 {
            for y in 0..<32 {
                for x in 0..<32 {
                    state ^= state >> 12
                    state ^= state << 25
                    state ^= state >> 27
                    let value = UInt16((state &* 0x2545F4914F6CDD1D) >> 56)
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }
        let encoded = try encodeLossless(frame)
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        assertPixelPerfect(frame, decoded)
    }

    // MARK: - Error Handling

    func testDecode_InvalidSignature_ThrowsError() {
        let decoder = JXLDecoder()
        let data = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                         0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try decoder.decode(data)) { error in
            XCTAssertEqual(error as? DecoderError, DecoderError.invalidSignature)
        }
    }

    func testDecode_TruncatedData_ThrowsError() {
        let decoder = JXLDecoder()
        // Valid signature but nothing else
        let data = Data([0xFF, 0x0A])
        XCTAssertThrowsError(try decoder.decode(data)) { error in
            XCTAssertEqual(error as? DecoderError, DecoderError.truncatedData)
        }
    }

    func testDecode_EmptyData_ThrowsError() {
        let decoder = JXLDecoder()
        XCTAssertThrowsError(try decoder.decode(Data())) { error in
            XCTAssertEqual(error as? DecoderError, DecoderError.truncatedData)
        }
    }

    // MARK: - Container Extraction

    func testExtractCodestream_BareCodestream() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let data = try encodeLossless(frame)

        let decoder = JXLDecoder()
        let extracted = try decoder.extractCodestream(data)

        XCTAssertEqual(extracted, data)
    }

    func testExtractCodestream_Container() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        // Wrap in a container
        let container = JXLContainer(codestream: codestream)
        let containerData = container.serialise()

        let decoder = JXLDecoder()
        let extracted = try decoder.extractCodestream(containerData)

        // The extracted codestream should match the original
        XCTAssertEqual(extracted, codestream)
    }

    func testExtractCodestream_EmptyData_ThrowsError() {
        let decoder = JXLDecoder()
        XCTAssertThrowsError(try decoder.extractCodestream(Data())) { error in
            XCTAssertEqual(error as? DecoderError, DecoderError.truncatedData)
        }
    }

    func testExtractCodestream_InvalidContainer_ThrowsError() {
        let decoder = JXLDecoder()
        // Not a bare codestream and not a valid container
        let data = Data([0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try decoder.extractCodestream(data)) { error in
            guard let decoderError = error as? DecoderError,
                  case .invalidContainer = decoderError else {
                XCTFail("Expected invalidContainer error, got \(error)")
                return
            }
        }
    }

    // MARK: - DecoderError Properties

    func testDecoderError_Descriptions() {
        let errors: [(DecoderError, String)] = [
            (.invalidSignature, "Invalid JPEG XL codestream signature"),
            (.truncatedData, "Data is too short for a valid JPEG XL codestream"),
            (.invalidImageHeader("test"), "Invalid image header: test"),
            (.invalidFrameHeader("test"), "Invalid frame header: test"),
            (.unsupportedEncoding("test"), "Unsupported encoding mode: test"),
            (.invalidDimensions(width: 0, height: 0), "Invalid image dimensions: 0×0"),
            (.decodingFailed("test"), "Decoding failed: test"),
            (.invalidContainer("test"), "Invalid container format: test"),
        ]
        for (error, expected) in errors {
            XCTAssertEqual(error.errorDescription, expected)
        }
    }

    func testDecoderError_Equatable() {
        XCTAssertEqual(DecoderError.invalidSignature, DecoderError.invalidSignature)
        XCTAssertNotEqual(DecoderError.invalidSignature, DecoderError.truncatedData)
        XCTAssertEqual(
            DecoderError.invalidDimensions(width: 1, height: 2),
            DecoderError.invalidDimensions(width: 1, height: 2)
        )
        XCTAssertNotEqual(
            DecoderError.invalidDimensions(width: 1, height: 2),
            DecoderError.invalidDimensions(width: 3, height: 4)
        )
    }

    // MARK: - DecodedImageHeader Properties

    func testDecodedImageHeader_Equatable() {
        let h1 = DecodedImageHeader(
            width: 8, height: 8, bitsPerSample: 8, channels: 3,
            colorSpaceIndicator: 0, hasAlpha: false, headerSize: 14
        )
        let h2 = DecodedImageHeader(
            width: 8, height: 8, bitsPerSample: 8, channels: 3,
            colorSpaceIndicator: 0, hasAlpha: false, headerSize: 14
        )
        XCTAssertEqual(h1, h2)
    }

    // MARK: - DecodedFrameHeader Properties

    func testDecodedFrameHeader_Equatable() {
        let f1 = DecodedFrameHeader(
            frameType: .regularFrame, encoding: .modular,
            blendMode: .replace, duration: 0, isLast: true,
            saveAsReference: 0, name: "", numGroups: 1,
            numPasses: 1, isAllDefault: false, headerSize: 5
        )
        let f2 = DecodedFrameHeader(
            frameType: .regularFrame, encoding: .modular,
            blendMode: .replace, duration: 0, isLast: true,
            saveAsReference: 0, name: "", numGroups: 1,
            numPasses: 1, isAllDefault: false, headerSize: 5
        )
        XCTAssertEqual(f1, f2)
    }

    // MARK: - Performance

    func testDecodePerformance_16x16() throws {
        let frame = makeGradientFrame(width: 16, height: 16, channels: 3)
        let encoded = try encodeLossless(frame)
        let decoder = JXLDecoder()

        measure {
            _ = try? decoder.decode(encoded)
        }
    }
}
