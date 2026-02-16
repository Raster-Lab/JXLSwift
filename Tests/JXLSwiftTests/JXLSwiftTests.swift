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
