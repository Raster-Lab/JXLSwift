import XCTest
@testable import JXLSwift

final class JXLSwiftTests: XCTestCase {
    
    // MARK: - Architecture Tests
    
    func testArchitectureDetection() {
        let arch = CPUArchitecture.current
        XCTAssertNotEqual(arch, .unknown)
    }
    
    func testHardwareCapabilities() {
        let caps = HardwareCapabilities.detect()
        XCTAssertGreaterThan(caps.coreCount, 0)
    }
    
    // MARK: - Image Frame Tests
    
    func testImageFrameCreation() {
        let frame = ImageFrame(
            width: 64,
            height: 64,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB
        )
        
        XCTAssertEqual(frame.width, 64)
        XCTAssertEqual(frame.height, 64)
        XCTAssertEqual(frame.channels, 3)
    }
    
    func testImageFramePixelAccess() {
        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        
        // Set a pixel
        frame.setPixel(x: 4, y: 4, channel: 0, value: 255)
        
        // Get the pixel
        let value = frame.getPixel(x: 4, y: 4, channel: 0)
        XCTAssertEqual(value, 255)
    }
    
    // MARK: - Bitstream Tests
    
    func testBitstreamWriter() {
        var writer = BitstreamWriter()
        
        // Write signature
        try? writer.writeSignature()
        
        // Should have written 2 bytes
        XCTAssertEqual(writer.data.count, 2)
        XCTAssertEqual(writer.data[0], 0xFF)
        XCTAssertEqual(writer.data[1], 0x0A)
    }
    
    func testBitstreamBitWriting() {
        var writer = BitstreamWriter()
        
        // Write individual bits
        writer.writeBit(true)   // 1
        writer.writeBit(false)  // 0
        writer.writeBit(true)   // 1
        writer.writeBit(false)  // 0
        writer.writeBit(true)   // 1
        writer.writeBit(false)  // 0
        writer.writeBit(true)   // 1
        writer.writeBit(false)  // 0
        
        // Should form 0xAA (10101010)
        XCTAssertEqual(writer.data.count, 1)
        XCTAssertEqual(writer.data[0], 0xAA)
    }
    
    func testBitstreamVarint() {
        var writer = BitstreamWriter()
        
        // Write small value
        writer.writeVarint(42)
        XCTAssertEqual(writer.data.count, 1)
        XCTAssertEqual(writer.data[0], 42)
        
        // Write larger value
        writer = BitstreamWriter()
        writer.writeVarint(300)
        XCTAssertGreaterThan(writer.data.count, 1)
    }
    
    // MARK: - Encoding Configuration Tests
    
    func testEncodingOptions() {
        let options = EncodingOptions()
        XCTAssertEqual(options.effort, .squirrel)
        XCTAssertTrue(options.useHardwareAcceleration)
    }
    
    func testEncodingOptionsPresets() {
        let highQuality = EncodingOptions.highQuality
        let fast = EncodingOptions.fast
        let lossless = EncodingOptions.lossless
        
        XCTAssertEqual(highQuality.effort, .kitten)
        XCTAssertEqual(fast.effort, .falcon)
        
        if case .lossless = lossless.mode {
            // Success
        } else {
            XCTFail("Lossless preset should use lossless mode")
        }
    }
    
    // MARK: - Encoder Tests
    
    func testEncoderCreation() {
        let encoder = JXLEncoder()
        XCTAssertNotNil(encoder)
    }
    
    func testEncoderValidation() {
        let encoder = JXLEncoder()
        
        // Invalid dimensions
        let invalidFrame = ImageFrame(width: 0, height: 0, channels: 3)
        XCTAssertThrowsError(try encoder.encode(invalidFrame)) { error in
            XCTAssertTrue(error is EncoderError)
        }
    }
    
    func testLosslessEncoding() throws {
        let encoder = JXLEncoder(options: .lossless)
        
        // Create a small test image (8x8 RGB)
        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        
        // Fill with a gradient pattern
        for y in 0..<8 {
            for x in 0..<8 {
                let value = UInt16((x + y) * 4095)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        // Encode
        let result = try encoder.encode(frame)
        
        // Verify result
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.stats.originalSize, 0)
        XCTAssertGreaterThan(result.stats.compressedSize, 0)
        
        // Lossless should have reasonable compression
        print("Compression ratio: \(result.stats.compressionRatio)")
    }
    
    func testLossyEncoding() throws {
        let encoder = JXLEncoder(options: .fast)
        
        // Create a small test image (16x16 RGB)
        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        
        // Fill with a pattern
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 4095))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 4095))
                frame.setPixel(x: x, y: y, channel: 2, value: 32767)
            }
        }
        
        // Encode
        let result = try encoder.encode(frame)
        
        // Verify result
        XCTAssertGreaterThan(result.data.count, 0)
        print("Lossy compression ratio: \(result.stats.compressionRatio)")
        print("Encoding time: \(result.stats.encodingTime)s")
    }
    
    // MARK: - Color Space Tests
    
    func testColorSpaces() {
        let srgb = ColorSpace.sRGB
        let grayscale = ColorSpace.grayscale
        
        // Just verify they exist
        XCTAssertNotNil(srgb)
        XCTAssertNotNil(grayscale)
    }
    
    func testColorPrimaries() {
        let primaries = ColorPrimaries.sRGB
        
        XCTAssertEqual(primaries.redX, 0.64, accuracy: 0.001)
        XCTAssertEqual(primaries.redY, 0.33, accuracy: 0.001)
    }
    
    // MARK: - Wide Gamut Color Primaries Tests
    
    func testColorPrimaries_DisplayP3_HasCorrectValues() {
        let primaries = ColorPrimaries.displayP3
        
        // Display P3 (DCI-P3 D65) chromaticity coordinates
        XCTAssertEqual(primaries.redX, 0.680, accuracy: 0.001)
        XCTAssertEqual(primaries.redY, 0.320, accuracy: 0.001)
        XCTAssertEqual(primaries.greenX, 0.265, accuracy: 0.001)
        XCTAssertEqual(primaries.greenY, 0.690, accuracy: 0.001)
        XCTAssertEqual(primaries.blueX, 0.150, accuracy: 0.001)
        XCTAssertEqual(primaries.blueY, 0.060, accuracy: 0.001)
        XCTAssertEqual(primaries.whiteX, 0.3127, accuracy: 0.0001)  // D65 white point
        XCTAssertEqual(primaries.whiteY, 0.3290, accuracy: 0.0001)
    }
    
    func testColorPrimaries_Rec2020_HasCorrectValues() {
        let primaries = ColorPrimaries.rec2020
        
        // Rec. 2020 (BT.2020) chromaticity coordinates
        XCTAssertEqual(primaries.redX, 0.708, accuracy: 0.001)
        XCTAssertEqual(primaries.redY, 0.292, accuracy: 0.001)
        XCTAssertEqual(primaries.greenX, 0.170, accuracy: 0.001)
        XCTAssertEqual(primaries.greenY, 0.797, accuracy: 0.001)
        XCTAssertEqual(primaries.blueX, 0.131, accuracy: 0.001)
        XCTAssertEqual(primaries.blueY, 0.046, accuracy: 0.001)
        XCTAssertEqual(primaries.whiteX, 0.3127, accuracy: 0.0001)  // D65 white point
        XCTAssertEqual(primaries.whiteY, 0.3290, accuracy: 0.0001)
    }
    
    func testColorPrimaries_Rec2020_WiderThanDisplayP3() {
        // Rec. 2020 should have a wider color gamut than Display P3
        // This is verified by checking that Rec. 2020 red is more saturated (higher redX)
        XCTAssertGreaterThan(ColorPrimaries.rec2020.redX, ColorPrimaries.displayP3.redX)
        // And green is more saturated (higher greenY)
        XCTAssertGreaterThan(ColorPrimaries.rec2020.greenY, ColorPrimaries.displayP3.greenY)
    }
    
    func testColorPrimaries_DisplayP3_WiderThanSRGB() {
        // Display P3 should have a wider color gamut than sRGB
        // This is verified by checking that Display P3 red is more saturated
        XCTAssertGreaterThan(ColorPrimaries.displayP3.redX, ColorPrimaries.sRGB.redX)
    }
    
    // MARK: - HDR Color Space Tests
    
    func testColorSpace_DisplayP3_HasCorrectPrimaries() {
        guard case let .custom(primaries, transferFunction) = ColorSpace.displayP3 else {
            XCTFail("displayP3 should return custom color space")
            return
        }
        
        XCTAssertEqual(primaries.redX, ColorPrimaries.displayP3.redX, accuracy: 0.001)
        if case .sRGB = transferFunction {
            // Expected sRGB transfer function
        } else {
            XCTFail("displayP3 should use sRGB transfer function")
        }
    }
    
    func testColorSpace_DisplayP3Linear_HasLinearTransferFunction() {
        guard case let .custom(primaries, transferFunction) = ColorSpace.displayP3Linear else {
            XCTFail("displayP3Linear should return custom color space")
            return
        }
        
        XCTAssertEqual(primaries.redX, ColorPrimaries.displayP3.redX, accuracy: 0.001)
        if case .linear = transferFunction {
            // Expected linear transfer function
        } else {
            XCTFail("displayP3Linear should use linear transfer function")
        }
    }
    
    func testColorSpace_Rec2020PQ_HasPQTransferFunction() {
        guard case let .custom(primaries, transferFunction) = ColorSpace.rec2020PQ else {
            XCTFail("rec2020PQ should return custom color space")
            return
        }
        
        XCTAssertEqual(primaries.redX, ColorPrimaries.rec2020.redX, accuracy: 0.001)
        if case .pq = transferFunction {
            // Expected PQ transfer function (HDR10)
        } else {
            XCTFail("rec2020PQ should use PQ transfer function")
        }
    }
    
    func testColorSpace_Rec2020HLG_HasHLGTransferFunction() {
        guard case let .custom(primaries, transferFunction) = ColorSpace.rec2020HLG else {
            XCTFail("rec2020HLG should return custom color space")
            return
        }
        
        XCTAssertEqual(primaries.redX, ColorPrimaries.rec2020.redX, accuracy: 0.001)
        if case .hlg = transferFunction {
            // Expected HLG transfer function
        } else {
            XCTFail("rec2020HLG should use HLG transfer function")
        }
    }
    
    func testColorSpace_Rec2020Linear_HasLinearTransferFunction() {
        guard case let .custom(primaries, transferFunction) = ColorSpace.rec2020Linear else {
            XCTFail("rec2020Linear should return custom color space")
            return
        }
        
        XCTAssertEqual(primaries.redX, ColorPrimaries.rec2020.redX, accuracy: 0.001)
        if case .linear = transferFunction {
            // Expected linear transfer function
        } else {
            XCTFail("rec2020Linear should use linear transfer function")
        }
    }
    
    // MARK: - ImageFrame with HDR Color Spaces
    
    func testImageFrame_DisplayP3_CreatesSuccessfully() {
        let frame = ImageFrame(
            width: 64,
            height: 64,
            channels: 3,
            pixelType: .uint16,
            colorSpace: .displayP3
        )
        
        XCTAssertEqual(frame.width, 64)
        XCTAssertEqual(frame.height, 64)
        if case .custom = frame.colorSpace {
            // Expected custom color space
        } else {
            XCTFail("displayP3 should create custom color space")
        }
    }
    
    func testImageFrame_Rec2020PQ_CreatesSuccessfully() {
        let frame = ImageFrame(
            width: 64,
            height: 64,
            channels: 3,
            pixelType: .float32,  // HDR typically uses float
            colorSpace: .rec2020PQ,
            bitsPerSample: 16
        )
        
        XCTAssertEqual(frame.width, 64)
        XCTAssertEqual(frame.height, 64)
        XCTAssertEqual(frame.pixelType, .float32)
        if case .custom = frame.colorSpace {
            // Expected custom color space
        } else {
            XCTFail("rec2020PQ should create custom color space")
        }
    }
    
    func testImageFrame_Rec2020HLG_CreatesSuccessfully() {
        let frame = ImageFrame(
            width: 64,
            height: 64,
            channels: 3,
            pixelType: .uint16,  // HLG can use integer types
            colorSpace: .rec2020HLG,
            bitsPerSample: 10
        )
        
        XCTAssertEqual(frame.width, 64)
        XCTAssertEqual(frame.height, 64)
        XCTAssertEqual(frame.bitsPerSample, 10)
        if case .custom = frame.colorSpace {
            // Expected custom color space
        } else {
            XCTFail("rec2020HLG should create custom color space")
        }
    }
    
    // MARK: - Alpha Channel Tests
    
    func testAlphaMode_None_IsDefaultWhenNoAlpha() {
        let frame = ImageFrame(
            width: 64,
            height: 64,
            channels: 3,
            hasAlpha: false
        )
        
        XCTAssertFalse(frame.hasAlpha)
        if case .none = frame.alphaMode {
            // Expected .none when hasAlpha is false
        } else {
            XCTFail("alphaMode should be .none when hasAlpha is false")
        }
    }
    
    func testAlphaMode_Straight_WhenHasAlpha() {
        let frame = ImageFrame(
            width: 64,
            height: 64,
            channels: 4,
            hasAlpha: true,
            alphaMode: .straight
        )
        
        XCTAssertTrue(frame.hasAlpha)
        if case .straight = frame.alphaMode {
            // Expected .straight alpha mode
        } else {
            XCTFail("alphaMode should be .straight when specified")
        }
    }
    
    func testAlphaMode_Premultiplied_WhenHasAlpha() {
        let frame = ImageFrame(
            width: 64,
            height: 64,
            channels: 4,
            hasAlpha: true,
            alphaMode: .premultiplied
        )
        
        XCTAssertTrue(frame.hasAlpha)
        if case .premultiplied = frame.alphaMode {
            // Expected .premultiplied alpha mode
        } else {
            XCTFail("alphaMode should be .premultiplied when specified")
        }
    }
    
    func testImageFrame_WithAlpha_AllocatesCorrectDataSize() {
        let frame = ImageFrame(
            width: 64,
            height: 64,
            channels: 4,  // RGBA
            pixelType: .uint8,
            hasAlpha: true
        )
        
        let expectedBytes = 64 * 64 * 4 * 1  // width * height * channels * bytes_per_sample
        XCTAssertEqual(frame.data.count, expectedBytes)
    }
    
    func testImageFrame_WithAlpha_CanSetAndGetAlphaChannel() {
        var frame = ImageFrame(
            width: 8,
            height: 8,
            channels: 4,  // RGBA
            pixelType: .uint8,
            hasAlpha: true
        )
        
        // Set alpha value for a pixel
        frame.setPixel(x: 4, y: 4, channel: 3, value: 128)  // 50% transparent
        
        // Verify alpha value can be read back
        let alphaValue = frame.getPixel(x: 4, y: 4, channel: 3)
        XCTAssertEqual(alphaValue, 128)
    }
    
    func testImageFrame_WithAlpha_uint16_CanSetAndGetAlphaChannel() {
        var frame = ImageFrame(
            width: 8,
            height: 8,
            channels: 4,  // RGBA
            pixelType: .uint16,
            hasAlpha: true,
            bitsPerSample: 16
        )
        
        // Set alpha value for a pixel (16-bit)
        frame.setPixel(x: 4, y: 4, channel: 3, value: 32768)  // 50% transparent
        
        // Verify alpha value can be read back
        let alphaValue = frame.getPixel(x: 4, y: 4, channel: 3)
        XCTAssertEqual(alphaValue, 32768)
    }
    
    func testImageFrame_WithAlphaFloat32_CanSetAndGetAlphaChannel() {
        var frame = ImageFrame(
            width: 8,
            height: 8,
            channels: 4,  // RGBA
            pixelType: .float32,
            hasAlpha: true,
            bitsPerSample: 32
        )
        
        // Set alpha value for a pixel (float, scaled to 16-bit range)
        frame.setPixel(x: 4, y: 4, channel: 3, value: 32768)  // 50% transparent
        
        // Verify alpha value can be read back (may have slight precision loss)
        let alphaValue = frame.getPixel(x: 4, y: 4, channel: 3)
        XCTAssertEqual(alphaValue, 32768, accuracy: 100)  // Allow small tolerance for float conversion
    }
    
    // MARK: - Performance Tests
    
    func testEncodingPerformance() throws {
        let encoder = JXLEncoder(options: .fast)
        
        // Create a larger image for performance testing
        var frame = ImageFrame(width: 256, height: 256, channels: 3)
        
        // Fill with random-ish pattern
        for y in 0..<256 {
            for x in 0..<256 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x * y) % 65536))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16((x + y) % 65536))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x ^ y) % 65536))
            }
        }
        
        measure {
            _ = try? encoder.encode(frame)
        }
    }
}
