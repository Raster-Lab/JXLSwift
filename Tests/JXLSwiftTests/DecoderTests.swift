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

    /// Create a frame filled with pseudo-random data using xorshift64*.
    private func makeRandomFrame(
        width: Int, height: Int, channels: Int, seed: UInt64 = 42
    ) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: channels
        )
        var state = seed
        for c in 0..<channels {
            for y in 0..<height {
                for x in 0..<width {
                    state ^= state >> 12
                    state ^= state << 25
                    state ^= state >> 27
                    let value = UInt16((state &* 0x2545F4914F6CDD1D) >> 56)
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }
        return frame
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

    func testParseFrameHeader_WithName() throws {
        let fh = FrameHeader(
            frameType: .regularFrame,
            encoding: .modular,
            blendMode: .replace,
            isLast: true,
            name: "test"
        )
        var writer = BitstreamWriter()
        fh.serialise(to: &writer)
        writer.flushByte()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseFrameHeader(writer.data)

        XCTAssertEqual(parsed.name, "test")
        XCTAssertTrue(parsed.isLast)
        XCTAssertEqual(parsed.encoding, .modular)
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
        let frame = makeRandomFrame(width: 32, height: 32, channels: 3)
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

    // MARK: - Metadata Extraction — parseContainer

    func testParseContainer_BareCodestream_ReturnsContainerWithNoMetadata() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let decoder = JXLDecoder()
        let container = try decoder.parseContainer(codestream)

        XCTAssertEqual(container.codestream, codestream)
        XCTAssertNil(container.exif)
        XCTAssertNil(container.xmp)
        XCTAssertNil(container.iccProfile)
        XCTAssertNil(container.frameIndex)
    }

    func testParseContainer_ContainerWithCodestreamOnly() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let original = JXLContainer(codestream: codestream)
        let serialised = original.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertEqual(parsed.codestream, codestream)
        XCTAssertNil(parsed.exif)
        XCTAssertNil(parsed.xmp)
        XCTAssertNil(parsed.iccProfile)
    }

    func testParseContainer_WithEXIF() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let exifData = EXIFBuilder.createWithOrientation(6)
        let container = JXLContainerBuilder(codestream: codestream)
            .withEXIF(exifData)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertEqual(parsed.codestream, codestream)
        XCTAssertNotNil(parsed.exif)
        XCTAssertEqual(parsed.exif?.data, exifData)
    }

    func testParseContainer_WithXMP() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let xmpString = "<x:xmpmeta><rdf:RDF><rdf:Description/></rdf:RDF></x:xmpmeta>"
        let container = JXLContainerBuilder(codestream: codestream)
            .withXMP(xmlString: xmpString)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertEqual(parsed.codestream, codestream)
        XCTAssertNotNil(parsed.xmp)
        XCTAssertEqual(parsed.xmp?.data, Data(xmpString.utf8))
    }

    func testParseContainer_WithICCProfile() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let iccData = Data([0x00, 0x00, 0x01, 0x00, 0x41, 0x44, 0x42, 0x45])
        let container = JXLContainerBuilder(codestream: codestream)
            .withICCProfile(iccData)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertEqual(parsed.codestream, codestream)
        XCTAssertNotNil(parsed.iccProfile)
        XCTAssertEqual(parsed.iccProfile?.data, iccData)
    }

    func testParseContainer_WithAllMetadata() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let exifData = EXIFBuilder.createWithOrientation(3)
        let xmpString = "<x:xmpmeta/>"
        let iccData = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let container = JXLContainerBuilder(codestream: codestream)
            .withEXIF(exifData)
            .withXMP(xmlString: xmpString)
            .withICCProfile(iccData)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertEqual(parsed.codestream, codestream)
        XCTAssertEqual(parsed.exif?.data, exifData)
        XCTAssertEqual(parsed.xmp?.data, Data(xmpString.utf8))
        XCTAssertEqual(parsed.iccProfile?.data, iccData)
    }

    func testParseContainer_WithFrameIndex() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let entries = [
            FrameIndexEntry(frameNumber: 0, byteOffset: 0, duration: 100),
            FrameIndexEntry(frameNumber: 1, byteOffset: 256, duration: 200),
        ]
        let container = JXLContainerBuilder(codestream: codestream)
            .withFrameIndex(entries)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertNotNil(parsed.frameIndex)
        XCTAssertEqual(parsed.frameIndex?.entries.count, 2)
        XCTAssertEqual(parsed.frameIndex?.entries[0].frameNumber, 0)
        XCTAssertEqual(parsed.frameIndex?.entries[0].byteOffset, 0)
        XCTAssertEqual(parsed.frameIndex?.entries[0].duration, 100)
        XCTAssertEqual(parsed.frameIndex?.entries[1].frameNumber, 1)
        XCTAssertEqual(parsed.frameIndex?.entries[1].byteOffset, 256)
        XCTAssertEqual(parsed.frameIndex?.entries[1].duration, 200)
    }

    func testParseContainer_WithLevel10() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let container = JXLContainerBuilder(codestream: codestream)
            .withLevel(10)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertEqual(parsed.level, 10)
    }

    func testParseContainer_EmptyData_ThrowsError() {
        let decoder = JXLDecoder()
        XCTAssertThrowsError(try decoder.parseContainer(Data())) { error in
            XCTAssertEqual(error as? DecoderError, DecoderError.truncatedData)
        }
    }

    func testParseContainer_NoCodestreamBox_ThrowsError() {
        let decoder = JXLDecoder()
        // Build a container with only signature and ftyp, no jxlc
        let sigBox = Box(
            type: .jxlSignature,
            payload: Data(JXLContainer.signaturePayload)
        )
        let ftypBox = Box(
            type: .fileType,
            payload: JXLContainer.fileTypePayload(level: 5)
        )
        var data = Data()
        data.append(sigBox.serialise())
        data.append(ftypBox.serialise())

        XCTAssertThrowsError(try decoder.parseContainer(data)) { error in
            guard let decoderError = error as? DecoderError,
                  case .invalidContainer = decoderError else {
                XCTFail("Expected invalidContainer error, got \(error)")
                return
            }
        }
    }

    func testParseContainer_InvalidBoxSize_ThrowsError() {
        let decoder = JXLDecoder()
        // Box with size = 0 (invalid)
        let data = Data([0x00, 0x00, 0x00, 0x00, 0x4A, 0x58, 0x4C, 0x20])
        XCTAssertThrowsError(try decoder.parseContainer(data)) { error in
            guard let decoderError = error as? DecoderError,
                  case .invalidContainer = decoderError else {
                XCTFail("Expected invalidContainer error, got \(error)")
                return
            }
        }
    }

    // MARK: - Metadata Extraction — extractMetadata

    func testExtractMetadata_BareCodestream_AllNil() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let decoder = JXLDecoder()
        let (exif, xmp, icc) = try decoder.extractMetadata(codestream)

        XCTAssertNil(exif)
        XCTAssertNil(xmp)
        XCTAssertNil(icc)
    }

    func testExtractMetadata_WithEXIF() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let exifData = EXIFBuilder.createWithOrientation(8)
        let container = JXLContainerBuilder(codestream: codestream)
            .withEXIF(exifData)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let (exif, xmp, icc) = try decoder.extractMetadata(serialised)

        XCTAssertNotNil(exif)
        XCTAssertEqual(exif?.data, exifData)
        XCTAssertNil(xmp)
        XCTAssertNil(icc)
    }

    func testExtractMetadata_WithXMP() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let xmpString = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF/></x:xmpmeta>"
        let container = JXLContainerBuilder(codestream: codestream)
            .withXMP(xmlString: xmpString)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let (exif, xmp, icc) = try decoder.extractMetadata(serialised)

        XCTAssertNil(exif)
        XCTAssertNotNil(xmp)
        XCTAssertEqual(String(data: xmp!.data, encoding: .utf8), xmpString)
        XCTAssertNil(icc)
    }

    func testExtractMetadata_WithICCProfile() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let iccData = Data(repeating: 0xAB, count: 128)
        let container = JXLContainerBuilder(codestream: codestream)
            .withICCProfile(iccData)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let (exif, xmp, icc) = try decoder.extractMetadata(serialised)

        XCTAssertNil(exif)
        XCTAssertNil(xmp)
        XCTAssertNotNil(icc)
        XCTAssertEqual(icc?.data, iccData)
    }

    func testExtractMetadata_AllMetadata() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let exifData = EXIFBuilder.createWithOrientation(1)
        let xmpString = "<xmp/>"
        let iccData = Data([0x01, 0x02, 0x03])

        let container = JXLContainerBuilder(codestream: codestream)
            .withEXIF(exifData)
            .withXMP(xmlString: xmpString)
            .withICCProfile(iccData)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let (exif, xmp, icc) = try decoder.extractMetadata(serialised)

        XCTAssertNotNil(exif)
        XCTAssertNotNil(xmp)
        XCTAssertNotNil(icc)
        XCTAssertEqual(exif?.data, exifData)
        XCTAssertEqual(icc?.data, iccData)
    }

    // MARK: - Metadata Round-Trip

    func testMetadataRoundTrip_EXIF_OrientationPreserved() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        for orientation: UInt32 in 1...8 {
            let exifData = EXIFBuilder.createWithOrientation(orientation)
            let container = JXLContainerBuilder(codestream: codestream)
                .withEXIF(exifData)
                .build()
            let serialised = container.serialise()

            let decoder = JXLDecoder()
            let parsed = try decoder.parseContainer(serialised)

            XCTAssertNotNil(parsed.exif)
            let extracted = EXIFOrientation.extractOrientation(from: parsed.exif!.data)
            XCTAssertEqual(extracted, orientation,
                           "Orientation \(orientation) not preserved")
        }
    }

    func testMetadataRoundTrip_XMP_ContentPreserved() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let xmpContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              dc:title="Test Image"/>
          </rdf:RDF>
        </x:xmpmeta>
        """

        let container = JXLContainerBuilder(codestream: codestream)
            .withXMP(xmlString: xmpContent)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertNotNil(parsed.xmp)
        let extractedXMP = String(data: parsed.xmp!.data, encoding: .utf8)
        XCTAssertEqual(extractedXMP, xmpContent)
    }

    func testMetadataRoundTrip_ICC_DataPreserved() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        // Simulate a real ICC profile with varied bytes
        var iccData = Data()
        for i: UInt8 in 0..<255 {
            iccData.append(i)
        }

        let container = JXLContainerBuilder(codestream: codestream)
            .withICCProfile(iccData)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertNotNil(parsed.iccProfile)
        XCTAssertEqual(parsed.iccProfile?.data, iccData)
    }

    func testMetadataRoundTrip_FrameIndex_EntriesPreserved() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let entries = [
            FrameIndexEntry(frameNumber: 0, byteOffset: 0, duration: 50),
            FrameIndexEntry(frameNumber: 1, byteOffset: 1024, duration: 100),
            FrameIndexEntry(frameNumber: 2, byteOffset: 2048, duration: 150),
        ]

        let container = JXLContainerBuilder(codestream: codestream)
            .withFrameIndex(entries)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertNotNil(parsed.frameIndex)
        XCTAssertEqual(parsed.frameIndex?.entries.count, 3)
        for (i, entry) in entries.enumerated() {
            XCTAssertEqual(parsed.frameIndex?.entries[i].frameNumber, entry.frameNumber)
            XCTAssertEqual(parsed.frameIndex?.entries[i].byteOffset, entry.byteOffset)
            XCTAssertEqual(parsed.frameIndex?.entries[i].duration, entry.duration)
        }
    }

    func testMetadataRoundTrip_CodestreamDecodesCorrectly() throws {
        let original = makeGradientFrame(width: 8, height: 8, channels: 3)
        let codestream = try encodeLossless(original)

        let exifData = EXIFBuilder.createWithOrientation(5)
        let container = JXLContainerBuilder(codestream: codestream)
            .withEXIF(exifData)
            .withXMP(xmlString: "<xmp/>")
            .withICCProfile(Data([0x01]))
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)
        let decoded = try decoder.decode(parsed.codestream)

        assertPixelPerfect(original, decoded)
    }

    // MARK: - Edge Cases

    func testParseContainer_EmptyEXIF_StillParsed() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let container = JXLContainerBuilder(codestream: codestream)
            .withEXIF(Data())
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        // EXIF box payload = 4-byte offset + 0 bytes data
        // After stripping 4-byte offset, the exif data is empty
        XCTAssertNotNil(parsed.exif)
        XCTAssertEqual(parsed.exif?.data.count, 0)
    }

    func testParseContainer_EmptyXMP_StillParsed() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let container = JXLContainerBuilder(codestream: codestream)
            .withXMP(xmlString: "")
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertNotNil(parsed.xmp)
        XCTAssertEqual(parsed.xmp?.data.count, 0)
    }

    func testParseContainer_LargeXMP_Preserved() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        // Create a large XMP string (8 KB)
        let largeXMP = String(repeating: "x", count: 8192)
        let container = JXLContainerBuilder(codestream: codestream)
            .withXMP(xmlString: largeXMP)
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertEqual(parsed.xmp?.data.count, 8192)
        XCTAssertEqual(String(data: parsed.xmp!.data, encoding: .utf8), largeXMP)
    }

    func testParseContainer_EmptyFrameIndex() throws {
        let frame = makeGradientFrame(width: 4, height: 4, channels: 1)
        let codestream = try encodeLossless(frame)

        let container = JXLContainerBuilder(codestream: codestream)
            .withFrameIndex([])
            .build()
        let serialised = container.serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(serialised)

        XCTAssertNotNil(parsed.frameIndex)
        XCTAssertEqual(parsed.frameIndex?.entries.count, 0)
    }

    func testParseContainer_SingleByteData_ThrowsError() {
        let decoder = JXLDecoder()
        XCTAssertThrowsError(try decoder.parseContainer(Data([0x42]))) { error in
            XCTAssertEqual(error as? DecoderError, DecoderError.truncatedData)
        }
    }

    func testParseContainer_BoxExtendsPastEnd_ThrowsError() {
        let decoder = JXLDecoder()
        // Box claims size 100 but data is only 8 bytes
        var data = Data()
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x64] as [UInt8]) // size = 100
        data.append(contentsOf: Array("JXL ".utf8)) // type
        XCTAssertThrowsError(try decoder.parseContainer(data)) { error in
            guard let decoderError = error as? DecoderError,
                  case .invalidContainer = decoderError else {
                XCTFail("Expected invalidContainer error, got \(error)")
                return
            }
        }
    }
}
