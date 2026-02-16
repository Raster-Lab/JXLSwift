import XCTest
@testable import JXLSwift

final class FormatTests: XCTestCase {

    // MARK: - SizeHeader Tests

    func testSizeHeader_SmallDimensions_UseCompactEncoding() throws {
        let header = try SizeHeader(width: 64, height: 64)
        XCTAssertEqual(header.width, 64)
        XCTAssertEqual(header.height, 64)

        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()

        // small=true (1 bit) + height 8 bits + width 8 bits = 17 bits → 3 bytes
        XCTAssertEqual(writer.data.count, 3)
    }

    func testSizeHeader_256x256_StillSmall() throws {
        let header = try SizeHeader(width: 256, height: 256)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertEqual(writer.data.count, 3) // 17 bits → 3 bytes
    }

    func testSizeHeader_257x257_NotSmall() throws {
        let header = try SizeHeader(width: 257, height: 257)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        // small=false (1 bit) + 2 × (2-bit selector + 9-bit value) = 23 bits → 3 bytes
        XCTAssertEqual(writer.data.count, 3)
    }

    func testSizeHeader_LargeDimensions() throws {
        let header = try SizeHeader(width: 1920, height: 1080)
        XCTAssertEqual(header.width, 1920)
        XCTAssertEqual(header.height, 1080)

        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 0)
    }

    func testSizeHeader_MaximumDimension() throws {
        let maxDim = SizeHeader.maximumDimension
        let header = try SizeHeader(width: maxDim, height: 1)
        XCTAssertEqual(header.width, maxDim)
    }

    func testSizeHeader_ZeroWidth_ThrowsError() {
        XCTAssertThrowsError(try SizeHeader(width: 0, height: 64)) { error in
            guard let csError = error as? CodestreamError else {
                XCTFail("Expected CodestreamError"); return
            }
            if case .invalidDimensions(let w, let h) = csError {
                XCTAssertEqual(w, 0)
                XCTAssertEqual(h, 64)
            } else {
                XCTFail("Expected invalidDimensions error")
            }
        }
    }

    func testSizeHeader_ZeroHeight_ThrowsError() {
        XCTAssertThrowsError(try SizeHeader(width: 64, height: 0)) { error in
            guard let csError = error as? CodestreamError else {
                XCTFail("Expected CodestreamError"); return
            }
            if case .invalidDimensions = csError { /* pass */ }
            else { XCTFail("Expected invalidDimensions error") }
        }
    }

    func testSizeHeader_ExceedsMaximum_ThrowsError() {
        let tooLarge = SizeHeader.maximumDimension + 1
        XCTAssertThrowsError(try SizeHeader(width: tooLarge, height: 64))
    }

    func testSizeHeader_1x1_MinimumValid() throws {
        let header = try SizeHeader(width: 1, height: 1)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 0)
    }

    func testSizeHeader_Equatable() throws {
        let a = try SizeHeader(width: 100, height: 200)
        let b = try SizeHeader(width: 100, height: 200)
        let c = try SizeHeader(width: 200, height: 100)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Dimension Selector Tests

    func testSizeHeader_9BitDimension() throws {
        // 512 → v-1 = 511 < 512 = 2^9, selector 00
        let header = try SizeHeader(width: 512, height: 512)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 0)
    }

    func testSizeHeader_13BitDimension() throws {
        // 4096 → v-1 = 4095 < 8192 = 2^13, selector 01
        let header = try SizeHeader(width: 4096, height: 4096)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 0)
    }

    func testSizeHeader_18BitDimension() throws {
        // 65536 → v-1 = 65535 < 262144 = 2^18, selector 10
        let header = try SizeHeader(width: 65536, height: 1)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 0)
    }

    func testSizeHeader_30BitDimension() throws {
        // 262145 → v-1 = 262144 ≥ 2^18, selector 11
        let header = try SizeHeader(width: 262145, height: 1)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 0)
    }

    // MARK: - ColourEncoding Tests

    func testColourEncoding_sRGB_IsAllDefault() {
        let encoding = ColourEncoding.sRGB
        var writer = BitstreamWriter()
        encoding.serialise(to: &writer)
        writer.flushByte()

        // all_default = true → single bit → 1 byte
        XCTAssertEqual(writer.data.count, 1)
    }

    func testColourEncoding_LinearSRGB_NotDefault() {
        let encoding = ColourEncoding.linearSRGB
        var writer = BitstreamWriter()
        encoding.serialise(to: &writer)
        writer.flushByte()

        // Not all_default → more bits
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testColourEncoding_Greyscale() {
        let encoding = ColourEncoding.greyscale
        XCTAssertEqual(encoding.colourSpace, .grey)
        XCTAssertEqual(encoding.transferFunction, .sRGB)

        var writer = BitstreamWriter()
        encoding.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 0)
    }

    func testColourEncoding_ICCProfile() {
        let encoding = ColourEncoding(useICCProfile: true)
        var writer = BitstreamWriter()
        encoding.serialise(to: &writer)
        writer.flushByte()
        // all_default=false(1) + useICC=true(1) = 2 bits → 1 byte
        XCTAssertGreaterThan(writer.data.count, 0)
    }

    func testColourEncoding_CustomWhitePoint() {
        let encoding = ColourEncoding(
            colourSpace: .rgb,
            whitePoint: .custom,
            primaries: .sRGB,
            transferFunction: .sRGB
        )
        var writer = BitstreamWriter()
        encoding.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testColourEncoding_CustomPrimaries() {
        let encoding = ColourEncoding(
            colourSpace: .rgb,
            whitePoint: .d65,
            primaries: .custom,
            transferFunction: .sRGB
        )
        var writer = BitstreamWriter()
        encoding.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testColourEncoding_GammaTransferFunction() {
        let encoding = ColourEncoding(
            colourSpace: .rgb,
            whitePoint: .d65,
            primaries: .sRGB,
            transferFunction: .gamma
        )
        var writer = BitstreamWriter()
        encoding.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testColourEncoding_BT2100_PQ() {
        let encoding = ColourEncoding(
            colourSpace: .rgb,
            whitePoint: .d65,
            primaries: .bt2100,
            transferFunction: .pq,
            renderingIntent: .perceptual
        )
        XCTAssertEqual(encoding.primaries, .bt2100)
        XCTAssertEqual(encoding.transferFunction, .pq)
    }

    func testColourEncoding_Equatable() {
        XCTAssertEqual(ColourEncoding.sRGB, ColourEncoding.sRGB)
        XCTAssertNotEqual(ColourEncoding.sRGB, ColourEncoding.linearSRGB)
        XCTAssertNotEqual(ColourEncoding.sRGB, ColourEncoding.greyscale)
    }

    // MARK: - ColourSpace Enum Tests

    func testColourSpace_AllCases() {
        XCTAssertEqual(ColourSpace.rgb.rawValue, 0)
        XCTAssertEqual(ColourSpace.grey.rawValue, 1)
        XCTAssertEqual(ColourSpace.xyb.rawValue, 2)
        XCTAssertEqual(ColourSpace.unknown.rawValue, 3)
    }

    // MARK: - WhitePoint Enum Tests

    func testWhitePoint_AllCases() {
        XCTAssertEqual(WhitePoint.d65.rawValue, 0)
        XCTAssertEqual(WhitePoint.custom.rawValue, 1)
        XCTAssertEqual(WhitePoint.e.rawValue, 2)
        XCTAssertEqual(WhitePoint.dci.rawValue, 3)
    }

    // MARK: - Primaries Enum Tests

    func testPrimaries_AllCases() {
        XCTAssertEqual(Primaries.sRGB.rawValue, 0)
        XCTAssertEqual(Primaries.custom.rawValue, 1)
        XCTAssertEqual(Primaries.bt2100.rawValue, 2)
        XCTAssertEqual(Primaries.p3.rawValue, 3)
    }

    // MARK: - TransferFunction Enum Tests

    func testTransferFunction_AllCases() {
        XCTAssertEqual(ColourTransferFunction.bt709.rawValue, 0)
        XCTAssertEqual(ColourTransferFunction.linear.rawValue, 2)
        XCTAssertEqual(ColourTransferFunction.sRGB.rawValue, 3)
        XCTAssertEqual(ColourTransferFunction.pq.rawValue, 4)
        XCTAssertEqual(ColourTransferFunction.hlg.rawValue, 6)
        XCTAssertEqual(ColourTransferFunction.gamma.rawValue, 7)
    }

    // MARK: - RenderingIntent Enum Tests

    func testRenderingIntent_AllCases() {
        XCTAssertEqual(RenderingIntent.perceptual.rawValue, 0)
        XCTAssertEqual(RenderingIntent.relative.rawValue, 1)
        XCTAssertEqual(RenderingIntent.saturation.rawValue, 2)
        XCTAssertEqual(RenderingIntent.absolute.rawValue, 3)
    }

    // MARK: - ImageMetadata Tests

    func testImageMetadata_DefaultsAreAllDefault() {
        let metadata = ImageMetadata()
        var writer = BitstreamWriter()
        metadata.serialise(to: &writer)
        writer.flushByte()

        // all_default = true → single bit → 1 byte
        XCTAssertEqual(writer.data.count, 1)
    }

    func testImageMetadata_16BitDepth() {
        let metadata = ImageMetadata(bitsPerSample: 16)
        var writer = BitstreamWriter()
        metadata.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testImageMetadata_WithAlpha() {
        let metadata = ImageMetadata(hasAlpha: true, extraChannelCount: 1)
        var writer = BitstreamWriter()
        metadata.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testImageMetadata_XYBEncoded() {
        let metadata = ImageMetadata(xybEncoded: true)
        XCTAssertTrue(metadata.xybEncoded)

        var writer = BitstreamWriter()
        metadata.serialise(to: &writer)
        writer.flushByte()
        // Not all_default but compact; at least 1 byte
        XCTAssertGreaterThanOrEqual(writer.data.count, 1)
    }

    func testImageMetadata_NonDefaultOrientation() {
        let metadata = ImageMetadata(orientation: 6) // 90° rotation
        var writer = BitstreamWriter()
        metadata.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testImageMetadata_Animation() {
        let metadata = ImageMetadata(
            haveAnimation: true,
            animationTpsNumerator: 24,
            animationTpsDenominator: 1,
            animationLoopCount: 0
        )
        XCTAssertTrue(metadata.haveAnimation)
        XCTAssertEqual(metadata.animationTpsNumerator, 24)

        var writer = BitstreamWriter()
        metadata.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testImageMetadata_Equatable() {
        let a = ImageMetadata()
        let b = ImageMetadata()
        let c = ImageMetadata(bitsPerSample: 16)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testImageMetadata_32BitDepth() {
        let metadata = ImageMetadata(bitsPerSample: 32)
        var writer = BitstreamWriter()
        metadata.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testImageMetadata_4BitDepth() {
        let metadata = ImageMetadata(bitsPerSample: 4)
        var writer = BitstreamWriter()
        metadata.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    // MARK: - CodestreamHeader Tests

    func testCodestreamHeader_FromFrame() throws {
        let frame = ImageFrame(width: 64, height: 64, channels: 3)
        let header = try CodestreamHeader(frame: frame)

        XCTAssertEqual(header.size.width, 64)
        XCTAssertEqual(header.size.height, 64)
        XCTAssertEqual(header.metadata.bitsPerSample, 8)
        XCTAssertFalse(header.metadata.hasAlpha)
    }

    func testCodestreamHeader_Serialise_StartsWithSignature() throws {
        let frame = ImageFrame(width: 64, height: 64, channels: 3)
        let header = try CodestreamHeader(frame: frame)
        let data = header.serialise()

        // JPEG XL signature: 0xFF 0x0A
        XCTAssertGreaterThanOrEqual(data.count, 2)
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0x0A)
    }

    func testCodestreamHeader_WithAlpha() throws {
        let frame = ImageFrame(
            width: 128, height: 128, channels: 4,
            hasAlpha: true
        )
        let header = try CodestreamHeader(frame: frame)
        XCTAssertTrue(header.metadata.hasAlpha)
        XCTAssertEqual(header.metadata.extraChannelCount, 1)

        let data = header.serialise()
        XCTAssertGreaterThan(data.count, 2)
    }

    func testCodestreamHeader_16Bit() throws {
        let frame = ImageFrame(
            width: 64, height: 64, channels: 3,
            pixelType: .uint16,
            bitsPerSample: 16
        )
        let header = try CodestreamHeader(frame: frame)
        XCTAssertEqual(header.metadata.bitsPerSample, 16)
    }

    func testCodestreamHeader_Equatable() throws {
        let frame = ImageFrame(width: 64, height: 64, channels: 3)
        let a = try CodestreamHeader(frame: frame)
        let b = try CodestreamHeader(frame: frame)
        XCTAssertEqual(a, b)
    }

    func testCodestreamHeader_ExplicitInit() throws {
        let size = try SizeHeader(width: 100, height: 200)
        let metadata = ImageMetadata(bitsPerSample: 16)
        let header = CodestreamHeader(size: size, metadata: metadata)

        XCTAssertEqual(header.size.width, 100)
        XCTAssertEqual(header.metadata.bitsPerSample, 16)
    }

    // MARK: - ColourEncoding from ColorSpace

    func testColourEncoding_FromSRGB() {
        let encoding = ColourEncoding.from(colorSpace: .sRGB)
        XCTAssertEqual(encoding, .sRGB)
    }

    func testColourEncoding_FromLinearRGB() {
        let encoding = ColourEncoding.from(colorSpace: .linearRGB)
        XCTAssertEqual(encoding, .linearSRGB)
    }

    func testColourEncoding_FromGreyscale() {
        let encoding = ColourEncoding.from(colorSpace: .grayscale)
        XCTAssertEqual(encoding, .greyscale)
    }

    func testColourEncoding_FromCMYK_FallsBackToSRGB() {
        let encoding = ColourEncoding.from(colorSpace: .cmyk)
        XCTAssertEqual(encoding, .sRGB)
    }

    func testColourEncoding_FromCustom_UsesICCProfile() {
        let encoding = ColourEncoding.from(
            colorSpace: .custom(primaries: .sRGB, transferFunction: .sRGB)
        )
        XCTAssertTrue(encoding.useICCProfile)
    }

    // MARK: - CodestreamError Tests

    func testCodestreamError_InvalidDimensions_Description() {
        let error = CodestreamError.invalidDimensions(width: 0, height: 100)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("0"))
        XCTAssertTrue(error.errorDescription!.contains("100"))
    }

    func testCodestreamError_InvalidBitDepth_Description() {
        let error = CodestreamError.invalidBitDepth(0)
        XCTAssertNotNil(error.errorDescription)
    }

    func testCodestreamError_InvalidOrientation_Description() {
        let error = CodestreamError.invalidOrientation(9)
        XCTAssertNotNil(error.errorDescription)
    }

    func testCodestreamError_InvalidFrameHeader_Description() {
        let error = CodestreamError.invalidFrameHeader("bad data")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("bad data"))
    }

    func testCodestreamError_Equatable() {
        XCTAssertEqual(
            CodestreamError.invalidDimensions(width: 0, height: 0),
            CodestreamError.invalidDimensions(width: 0, height: 0)
        )
        XCTAssertNotEqual(
            CodestreamError.invalidDimensions(width: 0, height: 0),
            CodestreamError.invalidBitDepth(0)
        )
    }

    // MARK: - FrameType Tests

    func testFrameType_AllCases() {
        XCTAssertEqual(FrameType.regularFrame.rawValue, 0)
        XCTAssertEqual(FrameType.lfFrame.rawValue, 1)
        XCTAssertEqual(FrameType.referenceOnly.rawValue, 2)
        XCTAssertEqual(FrameType.skipProgressive.rawValue, 3)
    }

    // MARK: - BlendMode Tests

    func testBlendMode_AllCases() {
        XCTAssertEqual(BlendMode.replace.rawValue, 0)
        XCTAssertEqual(BlendMode.blend.rawValue, 1)
        XCTAssertEqual(BlendMode.add.rawValue, 2)
        XCTAssertEqual(BlendMode.multiply.rawValue, 3)
    }

    // MARK: - FrameEncoding Tests

    func testFrameEncoding_AllCases() {
        XCTAssertEqual(FrameEncoding.varDCT.rawValue, 0)
        XCTAssertEqual(FrameEncoding.modular.rawValue, 1)
    }

    // MARK: - FrameHeader Tests

    func testFrameHeader_Default_IsAllDefault() {
        let header = FrameHeader()
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()

        // all_default = true → single bit → 1 byte
        XCTAssertEqual(writer.data.count, 1)
    }

    func testFrameHeader_Lossless() {
        let header = FrameHeader.lossless()
        XCTAssertEqual(header.encoding, .modular)
        XCTAssertTrue(header.isLast)
        XCTAssertEqual(header.blendMode, .replace)
    }

    func testFrameHeader_Lossy() {
        let header = FrameHeader.lossy()
        XCTAssertEqual(header.encoding, .varDCT)
        XCTAssertTrue(header.isLast)
    }

    func testFrameHeader_Animation() {
        let header = FrameHeader.animation(duration: 100, isLast: false)
        XCTAssertEqual(header.duration, 100)
        XCTAssertFalse(header.isLast)
        XCTAssertEqual(header.blendMode, .blend)
    }

    func testFrameHeader_NotLast_NotAllDefault() {
        let header = FrameHeader(isLast: false)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testFrameHeader_WithBlendMode() {
        let header = FrameHeader(blendMode: .blend)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testFrameHeader_WithDuration() {
        let header = FrameHeader(duration: 42)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testFrameHeader_WithName() {
        let header = FrameHeader(name: "frame0")
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testFrameHeader_WithCrop() {
        let header = FrameHeader(
            cropX0: 10, cropY0: 20,
            frameWidth: 100, frameHeight: 200
        )
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testFrameHeader_MultiplePasses() {
        let header = FrameHeader(numPasses: 3)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testFrameHeader_SaveAsReference() {
        let header = FrameHeader(saveAsReference: 1)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    func testFrameHeader_Equatable() {
        let a = FrameHeader()
        let b = FrameHeader()
        let c = FrameHeader(blendMode: .blend)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testFrameHeader_ModularEncoding() {
        let header = FrameHeader(encoding: .modular)
        var writer = BitstreamWriter()
        header.serialise(to: &writer)
        writer.flushByte()
        XCTAssertGreaterThan(writer.data.count, 1)
    }

    // MARK: - SectionHeader Tests

    func testSectionHeader_Serialise() {
        let section = SectionHeader(length: 1024)
        var writer = BitstreamWriter()
        section.serialise(to: &writer)

        // 4 bytes little-endian length
        XCTAssertEqual(writer.data.count, 4)
        XCTAssertEqual(writer.data[0], 0x00) // 1024 & 0xFF = 0
        XCTAssertEqual(writer.data[1], 0x04) // (1024 >> 8) & 0xFF = 4
        XCTAssertEqual(writer.data[2], 0x00)
        XCTAssertEqual(writer.data[3], 0x00)
    }

    func testSectionHeader_ZeroLength() {
        let section = SectionHeader(length: 0)
        var writer = BitstreamWriter()
        section.serialise(to: &writer)
        XCTAssertEqual(writer.data.count, 4)
        XCTAssertEqual(writer.data[0], 0)
        XCTAssertEqual(writer.data[1], 0)
        XCTAssertEqual(writer.data[2], 0)
        XCTAssertEqual(writer.data[3], 0)
    }

    func testSectionHeader_LargeLength() {
        let length: UInt32 = 0xDEADBEEF
        let section = SectionHeader(length: length)
        var writer = BitstreamWriter()
        section.serialise(to: &writer)
        XCTAssertEqual(writer.data[0], 0xEF)
        XCTAssertEqual(writer.data[1], 0xBE)
        XCTAssertEqual(writer.data[2], 0xAD)
        XCTAssertEqual(writer.data[3], 0xDE)
    }

    func testSectionHeader_Equatable() {
        XCTAssertEqual(SectionHeader(length: 100), SectionHeader(length: 100))
        XCTAssertNotEqual(SectionHeader(length: 100), SectionHeader(length: 200))
    }

    // MARK: - GroupHeader Tests

    func testGroupHeader_Serialise() {
        let group = GroupHeader(groupIndex: 5, isGlobal: false)
        var writer = BitstreamWriter()
        group.serialise(to: &writer)
        XCTAssertGreaterThan(writer.data.count, 0)
    }

    func testGroupHeader_Global() {
        let group = GroupHeader(groupIndex: 0, isGlobal: true)
        XCTAssertTrue(group.isGlobal)
    }

    func testGroupHeader_Equatable() {
        XCTAssertEqual(
            GroupHeader(groupIndex: 1, isGlobal: false),
            GroupHeader(groupIndex: 1, isGlobal: false)
        )
        XCTAssertNotEqual(
            GroupHeader(groupIndex: 1, isGlobal: false),
            GroupHeader(groupIndex: 2, isGlobal: false)
        )
    }

    // MARK: - FrameData Tests

    func testFrameData_Serialise_ProducesNonEmptyOutput() {
        let header = FrameHeader()
        let sectionData = Data([0x01, 0x02, 0x03, 0x04])
        let frameData = FrameData(header: header, sections: [sectionData])

        let result = frameData.serialise()
        XCTAssertGreaterThan(result.count, 0)
    }

    func testFrameData_MultipleSections() {
        let header = FrameHeader(numGroups: 2)
        let section1 = Data([0xAA, 0xBB])
        let section2 = Data([0xCC, 0xDD, 0xEE])
        let frameData = FrameData(header: header, sections: [section1, section2])

        let result = frameData.serialise()
        XCTAssertGreaterThan(result.count, 0)
        // The serialised data should contain both section payloads
        XCTAssertTrue(result.contains(0xAA))
        XCTAssertTrue(result.contains(0xCC))
    }

    func testFrameData_EmptySections() {
        let header = FrameHeader()
        let frameData = FrameData(header: header, sections: [])
        let result = frameData.serialise()
        XCTAssertGreaterThan(result.count, 0) // At least the header
    }

    // MARK: - BoxType Tests

    func testBoxType_AllCases_HaveCorrectStrings() {
        XCTAssertEqual(BoxType.jxlSignature.rawValue, "JXL ")
        XCTAssertEqual(BoxType.fileType.rawValue, "ftyp")
        XCTAssertEqual(BoxType.jxlLevel.rawValue, "jxll")
        XCTAssertEqual(BoxType.jxlCodestream.rawValue, "jxlc")
        XCTAssertEqual(BoxType.jxlPartialCodestream.rawValue, "jxlp")
        XCTAssertEqual(BoxType.exif.rawValue, "Exif")
        XCTAssertEqual(BoxType.xml.rawValue, "xml ")
        XCTAssertEqual(BoxType.jumb.rawValue, "jumb")
        XCTAssertEqual(BoxType.colourProfile.rawValue, "colr")
        XCTAssertEqual(BoxType.frameIndex.rawValue, "jxli")
        XCTAssertEqual(BoxType.brotliCompressed.rawValue, "brob")
    }

    func testBoxType_Bytes_Are4Bytes() {
        for boxType in BoxType.allCases {
            XCTAssertEqual(boxType.bytes.count, 4, "\(boxType) should have 4 bytes")
        }
    }

    // MARK: - Box Tests

    func testBox_Serialise_HasCorrectStructure() {
        let payload = Data([0x01, 0x02, 0x03])
        let box = Box(type: .jxlCodestream, payload: payload)
        let data = box.serialise()

        // 4 bytes size + 4 bytes type + 3 bytes payload = 11
        XCTAssertEqual(data.count, 11)

        // Size is big-endian 11
        XCTAssertEqual(data[0], 0)
        XCTAssertEqual(data[1], 0)
        XCTAssertEqual(data[2], 0)
        XCTAssertEqual(data[3], 11)

        // Type is "jxlc"
        XCTAssertEqual(data[4], UInt8(ascii: "j"))
        XCTAssertEqual(data[5], UInt8(ascii: "x"))
        XCTAssertEqual(data[6], UInt8(ascii: "l"))
        XCTAssertEqual(data[7], UInt8(ascii: "c"))

        // Payload
        XCTAssertEqual(data[8], 0x01)
        XCTAssertEqual(data[9], 0x02)
        XCTAssertEqual(data[10], 0x03)
    }

    func testBox_EmptyPayload() {
        let box = Box(type: .jxlLevel, payload: Data())
        let data = box.serialise()
        // 4 bytes size + 4 bytes type = 8
        XCTAssertEqual(data.count, 8)
        // Size = 8
        XCTAssertEqual(data[3], 8)
    }

    func testBox_Equatable() {
        let a = Box(type: .exif, payload: Data([0x01]))
        let b = Box(type: .exif, payload: Data([0x01]))
        let c = Box(type: .xml, payload: Data([0x01]))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - EXIFMetadata Tests

    func testEXIFMetadata_BoxPayload_HasOffset() {
        let exif = EXIFMetadata(data: Data([0x49, 0x49, 0x2A, 0x00]))
        let payload = exif.boxPayload()

        // 4-byte offset (zeros) + 4 bytes data = 8
        XCTAssertEqual(payload.count, 8)
        // First 4 bytes are zero offset
        XCTAssertEqual(payload[0], 0)
        XCTAssertEqual(payload[1], 0)
        XCTAssertEqual(payload[2], 0)
        XCTAssertEqual(payload[3], 0)
        // Then the actual EXIF data
        XCTAssertEqual(payload[4], 0x49)
    }

    func testEXIFMetadata_Equatable() {
        let a = EXIFMetadata(data: Data([0x01]))
        let b = EXIFMetadata(data: Data([0x01]))
        let c = EXIFMetadata(data: Data([0x02]))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - XMPMetadata Tests

    func testXMPMetadata_FromString() {
        let xmp = XMPMetadata(xmlString: "<x:xmpmeta/>")
        XCTAssertEqual(xmp.data, Data("<x:xmpmeta/>".utf8))
    }

    func testXMPMetadata_FromData() {
        let raw = Data([0x3C, 0x78]) // "<x"
        let xmp = XMPMetadata(data: raw)
        XCTAssertEqual(xmp.data, raw)
    }

    func testXMPMetadata_Equatable() {
        let a = XMPMetadata(xmlString: "abc")
        let b = XMPMetadata(xmlString: "abc")
        let c = XMPMetadata(xmlString: "def")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - ICCProfile Tests

    func testICCProfile_BoxPayload_HasColourType() {
        let icc = ICCProfile(data: Data([0xAA, 0xBB, 0xCC]))
        let payload = icc.boxPayload()

        // "prof" (4 bytes) + 3 bytes data = 7
        XCTAssertEqual(payload.count, 7)
        // First 4 bytes are "prof"
        XCTAssertEqual(payload[0], UInt8(ascii: "p"))
        XCTAssertEqual(payload[1], UInt8(ascii: "r"))
        XCTAssertEqual(payload[2], UInt8(ascii: "o"))
        XCTAssertEqual(payload[3], UInt8(ascii: "f"))
    }

    func testICCProfile_Equatable() {
        let a = ICCProfile(data: Data([0x01]))
        let b = ICCProfile(data: Data([0x01]))
        let c = ICCProfile(data: Data([0x02]))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Thumbnail Tests

    func testThumbnail_Properties() {
        let thumb = Thumbnail(codestreamData: Data([0xFF, 0x0A]), width: 64, height: 48)
        XCTAssertEqual(thumb.width, 64)
        XCTAssertEqual(thumb.height, 48)
        XCTAssertEqual(thumb.codestreamData.count, 2)
    }

    func testThumbnail_Equatable() {
        let a = Thumbnail(codestreamData: Data([0x01]), width: 10, height: 10)
        let b = Thumbnail(codestreamData: Data([0x01]), width: 10, height: 10)
        let c = Thumbnail(codestreamData: Data([0x02]), width: 10, height: 10)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - FrameIndex Tests

    func testFrameIndex_BoxPayload_HasEntryCount() {
        let entries = [
            FrameIndexEntry(frameNumber: 0, byteOffset: 100, duration: 42),
            FrameIndexEntry(frameNumber: 1, byteOffset: 500, duration: 42),
        ]
        let index = FrameIndex(entries: entries)
        let payload = index.boxPayload()

        // 4 bytes count + 2 × (4 + 8 + 4) = 4 + 32 = 36
        XCTAssertEqual(payload.count, 36)
        // Entry count = 2 (big-endian)
        XCTAssertEqual(payload[0], 0)
        XCTAssertEqual(payload[1], 0)
        XCTAssertEqual(payload[2], 0)
        XCTAssertEqual(payload[3], 2)
    }

    func testFrameIndex_EmptyEntries() {
        let index = FrameIndex(entries: [])
        let payload = index.boxPayload()
        // 4 bytes count (= 0)
        XCTAssertEqual(payload.count, 4)
        XCTAssertEqual(payload[3], 0)
    }

    func testFrameIndex_Equatable() {
        let a = FrameIndex(entries: [FrameIndexEntry(frameNumber: 0, byteOffset: 0, duration: 1)])
        let b = FrameIndex(entries: [FrameIndexEntry(frameNumber: 0, byteOffset: 0, duration: 1)])
        XCTAssertEqual(a, b)
    }

    func testFrameIndexEntry_Equatable() {
        let a = FrameIndexEntry(frameNumber: 0, byteOffset: 100, duration: 42)
        let b = FrameIndexEntry(frameNumber: 0, byteOffset: 100, duration: 42)
        let c = FrameIndexEntry(frameNumber: 1, byteOffset: 100, duration: 42)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - JXLContainer Tests

    func testJXLContainer_BasicInit() {
        let container = JXLContainer(codestream: Data([0xFF, 0x0A]))
        XCTAssertEqual(container.codestream.count, 2)
        XCTAssertEqual(container.level, 5)
        XCTAssertFalse(container.hasMetadata)
    }

    func testJXLContainer_FromEncodedImage() {
        let stats = CompressionStats(originalSize: 100, compressedSize: 50, encodingTime: 0.1, peakMemory: 0)
        let encoded = EncodedImage(data: Data([0xFF, 0x0A, 0x01]), stats: stats)
        let container = JXLContainer(encodedImage: encoded)
        XCTAssertEqual(container.codestream.count, 3)
    }

    func testJXLContainer_HasMetadata_WithEXIF() {
        var container = JXLContainer(codestream: Data())
        XCTAssertFalse(container.hasMetadata)
        container.exif = EXIFMetadata(data: Data([0x01]))
        XCTAssertTrue(container.hasMetadata)
    }

    func testJXLContainer_HasMetadata_WithXMP() {
        var container = JXLContainer(codestream: Data())
        container.xmp = XMPMetadata(xmlString: "<xmp/>")
        XCTAssertTrue(container.hasMetadata)
    }

    func testJXLContainer_HasMetadata_WithICC() {
        var container = JXLContainer(codestream: Data())
        container.iccProfile = ICCProfile(data: Data([0x01]))
        XCTAssertTrue(container.hasMetadata)
    }

    func testJXLContainer_HasMetadata_WithThumbnail() {
        var container = JXLContainer(codestream: Data())
        container.thumbnail = Thumbnail(codestreamData: Data(), width: 1, height: 1)
        XCTAssertTrue(container.hasMetadata)
    }

    func testJXLContainer_HasMetadata_WithFrameIndex() {
        var container = JXLContainer(codestream: Data())
        container.frameIndex = FrameIndex(entries: [])
        XCTAssertTrue(container.hasMetadata)
    }

    func testJXLContainer_Serialise_StartsWithSignatureBox() {
        let container = JXLContainer(codestream: Data([0xFF, 0x0A]))
        let data = container.serialise()

        // First box should be JXL signature
        XCTAssertGreaterThanOrEqual(data.count, 12)

        // Box size (signature box: 8 header + 4 payload = 12)
        XCTAssertEqual(data[0], 0)
        XCTAssertEqual(data[1], 0)
        XCTAssertEqual(data[2], 0)
        XCTAssertEqual(data[3], 12)

        // Box type: "JXL "
        XCTAssertEqual(data[4], UInt8(ascii: "J"))
        XCTAssertEqual(data[5], UInt8(ascii: "X"))
        XCTAssertEqual(data[6], UInt8(ascii: "L"))
        XCTAssertEqual(data[7], UInt8(ascii: " "))

        // Payload: container signature
        XCTAssertEqual(data[8], 0x0D)
        XCTAssertEqual(data[9], 0x0A)
        XCTAssertEqual(data[10], 0x87)
        XCTAssertEqual(data[11], 0x0A)
    }

    func testJXLContainer_Serialise_HasFileTypeBox() {
        let container = JXLContainer(codestream: Data())
        let data = container.serialise()

        // After the 12-byte signature box, there should be a ftyp box
        XCTAssertGreaterThanOrEqual(data.count, 32)

        // ftyp box starts at offset 12
        // Box type at bytes 16-19
        XCTAssertEqual(data[16], UInt8(ascii: "f"))
        XCTAssertEqual(data[17], UInt8(ascii: "t"))
        XCTAssertEqual(data[18], UInt8(ascii: "y"))
        XCTAssertEqual(data[19], UInt8(ascii: "p"))
    }

    func testJXLContainer_Serialise_ContainsCodestream() {
        let codestream = Data([0xFF, 0x0A, 0xDE, 0xAD])
        let container = JXLContainer(codestream: codestream)
        let data = container.serialise()

        // The codestream box should contain our data
        // Find "jxlc" in the output
        var foundCodestream = false
        for i in 0..<(data.count - 4) {
            if data[i] == UInt8(ascii: "j") &&
               data[i+1] == UInt8(ascii: "x") &&
               data[i+2] == UInt8(ascii: "l") &&
               data[i+3] == UInt8(ascii: "c") {
                foundCodestream = true
                // The payload should follow the type
                if i + 4 + codestream.count <= data.count {
                    let payloadStart = i + 4
                    XCTAssertEqual(data[payloadStart], 0xFF)
                    XCTAssertEqual(data[payloadStart + 1], 0x0A)
                    XCTAssertEqual(data[payloadStart + 2], 0xDE)
                    XCTAssertEqual(data[payloadStart + 3], 0xAD)
                }
                break
            }
        }
        XCTAssertTrue(foundCodestream, "Output should contain jxlc box")
    }

    func testJXLContainer_Serialise_WithEXIF() {
        var container = JXLContainer(codestream: Data())
        container.exif = EXIFMetadata(data: Data([0x49, 0x49]))
        let data = container.serialise()

        // Should contain "Exif" box type
        let exifTag = Array("Exif".utf8)
        var found = false
        for i in 0..<(data.count - 3) {
            if data[i] == exifTag[0] && data[i+1] == exifTag[1] &&
               data[i+2] == exifTag[2] && data[i+3] == exifTag[3] {
                found = true
                break
            }
        }
        XCTAssertTrue(found, "Container should contain EXIF box")
    }

    func testJXLContainer_Serialise_WithXMP() {
        var container = JXLContainer(codestream: Data())
        container.xmp = XMPMetadata(xmlString: "<xmp/>")
        let data = container.serialise()

        let xmlTag = Array("xml ".utf8)
        var found = false
        for i in 0..<(data.count - 3) {
            if data[i] == xmlTag[0] && data[i+1] == xmlTag[1] &&
               data[i+2] == xmlTag[2] && data[i+3] == xmlTag[3] {
                found = true
                break
            }
        }
        XCTAssertTrue(found, "Container should contain xml box")
    }

    func testJXLContainer_Serialise_WithICC() {
        var container = JXLContainer(codestream: Data())
        container.iccProfile = ICCProfile(data: Data([0x01, 0x02]))
        let data = container.serialise()

        let colrTag = Array("colr".utf8)
        var found = false
        for i in 0..<(data.count - 3) {
            if data[i] == colrTag[0] && data[i+1] == colrTag[1] &&
               data[i+2] == colrTag[2] && data[i+3] == colrTag[3] {
                found = true
                break
            }
        }
        XCTAssertTrue(found, "Container should contain colr box")
    }

    func testJXLContainer_Serialise_WithFrameIndex() {
        var container = JXLContainer(codestream: Data())
        container.frameIndex = FrameIndex(entries: [
            FrameIndexEntry(frameNumber: 0, byteOffset: 0, duration: 1)
        ])
        let data = container.serialise()

        let jxliTag = Array("jxli".utf8)
        var found = false
        for i in 0..<(data.count - 3) {
            if data[i] == jxliTag[0] && data[i+1] == jxliTag[1] &&
               data[i+2] == jxliTag[2] && data[i+3] == jxliTag[3] {
                found = true
                break
            }
        }
        XCTAssertTrue(found, "Container should contain jxli box")
    }

    func testJXLContainer_Serialise_NonDefaultLevel() {
        var container = JXLContainer(codestream: Data())
        container.level = 10
        let data = container.serialise()

        let jxllTag = Array("jxll".utf8)
        var found = false
        for i in 0..<(data.count - 3) {
            if data[i] == jxllTag[0] && data[i+1] == jxllTag[1] &&
               data[i+2] == jxllTag[2] && data[i+3] == jxllTag[3] {
                found = true
                break
            }
        }
        XCTAssertTrue(found, "Container should contain jxll box for non-default level")
    }

    func testJXLContainer_Serialise_DefaultLevel_NoLevelBox() {
        let container = JXLContainer(codestream: Data())
        let data = container.serialise()

        let jxllTag = Array("jxll".utf8)
        var found = false
        for i in 0..<(data.count - 3) {
            if data[i] == jxllTag[0] && data[i+1] == jxllTag[1] &&
               data[i+2] == jxllTag[2] && data[i+3] == jxllTag[3] {
                found = true
                break
            }
        }
        XCTAssertFalse(found, "Container should NOT contain jxll box for default level 5")
    }

    func testJXLContainer_MIMEType() {
        XCTAssertEqual(JXLContainer.mimeType, "image/jxl")
    }

    func testJXLContainer_FileExtension() {
        XCTAssertEqual(JXLContainer.fileExtension, "jxl")
    }

    // MARK: - JXLContainerBuilder Tests

    func testContainerBuilder_Basic() {
        let container = JXLContainerBuilder(codestream: Data([0xFF, 0x0A]))
            .build()
        XCTAssertEqual(container.codestream.count, 2)
    }

    func testContainerBuilder_FromEncodedImage() {
        let stats = CompressionStats(originalSize: 100, compressedSize: 50, encodingTime: 0, peakMemory: 0)
        let encoded = EncodedImage(data: Data([0x01]), stats: stats)
        let container = JXLContainerBuilder(encodedImage: encoded)
            .build()
        XCTAssertEqual(container.codestream.count, 1)
    }

    func testContainerBuilder_WithEXIF() {
        let container = JXLContainerBuilder(codestream: Data())
            .withEXIF(Data([0x49, 0x49]))
            .build()
        XCTAssertNotNil(container.exif)
        XCTAssertEqual(container.exif?.data, Data([0x49, 0x49]))
    }

    func testContainerBuilder_WithXMP_String() {
        let container = JXLContainerBuilder(codestream: Data())
            .withXMP(xmlString: "<xmp/>")
            .build()
        XCTAssertNotNil(container.xmp)
    }

    func testContainerBuilder_WithXMP_Data() {
        let container = JXLContainerBuilder(codestream: Data())
            .withXMP(data: Data([0x3C]))
            .build()
        XCTAssertNotNil(container.xmp)
    }

    func testContainerBuilder_WithICCProfile() {
        let container = JXLContainerBuilder(codestream: Data())
            .withICCProfile(Data([0x01, 0x02]))
            .build()
        XCTAssertNotNil(container.iccProfile)
    }

    func testContainerBuilder_WithThumbnail() {
        let container = JXLContainerBuilder(codestream: Data())
            .withThumbnail(codestreamData: Data([0xFF, 0x0A]), width: 64, height: 48)
            .build()
        XCTAssertNotNil(container.thumbnail)
        XCTAssertEqual(container.thumbnail?.width, 64)
        XCTAssertEqual(container.thumbnail?.height, 48)
    }

    func testContainerBuilder_WithFrameIndex() {
        let entries = [
            FrameIndexEntry(frameNumber: 0, byteOffset: 0, duration: 42)
        ]
        let container = JXLContainerBuilder(codestream: Data())
            .withFrameIndex(entries)
            .build()
        XCTAssertNotNil(container.frameIndex)
        XCTAssertEqual(container.frameIndex?.entries.count, 1)
    }

    func testContainerBuilder_WithLevel() {
        let container = JXLContainerBuilder(codestream: Data())
            .withLevel(10)
            .build()
        XCTAssertEqual(container.level, 10)
    }

    func testContainerBuilder_Chaining() {
        let container = JXLContainerBuilder(codestream: Data([0xFF, 0x0A]))
            .withEXIF(Data([0x49]))
            .withXMP(xmlString: "<xmp/>")
            .withICCProfile(Data([0x01]))
            .withLevel(10)
            .build()

        XCTAssertNotNil(container.exif)
        XCTAssertNotNil(container.xmp)
        XCTAssertNotNil(container.iccProfile)
        XCTAssertEqual(container.level, 10)
        XCTAssertTrue(container.hasMetadata)
    }

    // MARK: - Integration Tests

    func testIntegration_CodestreamHeaderInContainer() throws {
        // Create a frame and generate a codestream header
        let frame = ImageFrame(width: 64, height: 64, channels: 3)
        let header = try CodestreamHeader(frame: frame)
        let headerData = header.serialise()

        // Wrap in container
        let container = JXLContainer(codestream: headerData)
        let containerData = container.serialise()

        // Container should be larger than raw codestream
        XCTAssertGreaterThan(containerData.count, headerData.count)

        // Container starts with JXL signature box
        XCTAssertEqual(containerData[4], UInt8(ascii: "J"))
        XCTAssertEqual(containerData[5], UInt8(ascii: "X"))
        XCTAssertEqual(containerData[6], UInt8(ascii: "L"))
    }

    func testIntegration_FullPipeline() throws {
        // Create a small image
        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 32))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }

        // Encode the image
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)

        // Wrap in container with metadata
        let container = JXLContainerBuilder(encodedImage: encoded)
            .withEXIF(Data([0x49, 0x49, 0x2A, 0x00]))
            .withXMP(xmlString: "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>")
            .build()

        let containerData = container.serialise()

        // Verify container structure
        XCTAssertGreaterThan(containerData.count, encoded.data.count)
        // Starts with JXL signature box
        XCTAssertEqual(containerData[4], UInt8(ascii: "J"))
    }

    func testIntegration_AnimationContainer() throws {
        // Create animation with multiple frames
        let frame1 = FrameHeader.animation(duration: 100, isLast: false)
        let frame2 = FrameHeader.animation(duration: 100, isLast: true)

        XCTAssertFalse(frame1.isLast)
        XCTAssertTrue(frame2.isLast)
        XCTAssertEqual(frame1.duration, 100)
        XCTAssertEqual(frame2.duration, 100)

        // Create animation metadata
        let metadata = ImageMetadata(
            haveAnimation: true,
            animationTpsNumerator: 10,
            animationTpsDenominator: 1,
            animationLoopCount: 0
        )

        XCTAssertTrue(metadata.haveAnimation)
        XCTAssertEqual(metadata.animationTpsNumerator, 10)

        // Create frame index
        let index = FrameIndex(entries: [
            FrameIndexEntry(frameNumber: 0, byteOffset: 0, duration: 100),
            FrameIndexEntry(frameNumber: 1, byteOffset: 500, duration: 100),
        ])

        // Create container with frame index
        let container = JXLContainerBuilder(codestream: Data([0xFF, 0x0A]))
            .withFrameIndex(index.entries)
            .build()

        let data = container.serialise()
        XCTAssertGreaterThan(data.count, 0)
    }
}
