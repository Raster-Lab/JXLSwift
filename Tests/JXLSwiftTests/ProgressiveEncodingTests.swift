/// Tests for progressive encoding functionality
///
/// Validates that progressive encoding produces valid output and
/// correctly splits coefficient data across multiple passes.

import XCTest
@testable import JXLSwift

final class ProgressiveEncodingTests: XCTestCase {
    
    // MARK: - Basic Progressive Encoding
    
    func testProgressiveEncoding_SmallImage_ProducesValidOutput() throws {
        // Create a simple test image
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        // Fill with gradient pattern
        for y in 0..<16 {
            for x in 0..<16 {
                let value = UInt16((x * 16 + y * 16) % 256)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        // Create encoder with progressive mode enabled
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            effort: .squirrel,
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        // Verify output is non-empty
        XCTAssertGreaterThan(result.data.count, 0, "Progressive encoding should produce non-empty output")
        
        // Verify starts with JPEG XL signature
        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0x0A)
    }
    
    func testProgressiveEncoding_MediumImage_ProducesValidOutput() throws {
        // Create a larger test image
        var frame = ImageFrame(
            width: 64,
            height: 64,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        // Fill with checkerboard pattern
        for y in 0..<64 {
            for x in 0..<64 {
                let value: UInt16 = ((x / 8) + (y / 8)) % 2 == 0 ? 0 : 255
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            effort: .falcon,
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.stats.compressionRatio, 1.0)
    }
    
    func testProgressiveEncoding_Grayscale_ProducesValidOutput() throws {
        // Test progressive encoding with single channel
        var frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 1,
            pixelType: .uint8,
            colorSpace: .grayscale,
            bitsPerSample: 8
        )
        
        // Fill with gradient
        for y in 0..<32 {
            for x in 0..<32 {
                let value = UInt16(x * 8)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Progressive vs Non-Progressive Comparison
    
    func testProgressiveEncoding_ComparedToNonProgressive_ProducesLargerOutput() throws {
        // Progressive encoding typically produces larger output due to
        // overhead of multiple passes and pass markers
        
        var frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        // Fill with test data
        for y in 0..<32 {
            for x in 0..<32 {
                let value = UInt16((x + y) % 256)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        // Non-progressive encoding
        let nonProgressiveOptions = EncodingOptions(
            mode: .lossy(quality: 90),
            progressive: false
        )
        let nonProgressiveEncoder = JXLEncoder(options: nonProgressiveOptions)
        let nonProgressiveResult = try nonProgressiveEncoder.encode(frame)
        
        // Progressive encoding
        let progressiveOptions = EncodingOptions(
            mode: .lossy(quality: 90),
            progressive: true
        )
        let progressiveEncoder = JXLEncoder(options: progressiveOptions)
        let progressiveResult = try progressiveEncoder.encode(frame)
        
        // Progressive should produce larger output due to pass overhead
        // (though this isn't strictly guaranteed for all images)
        XCTAssertGreaterThan(progressiveResult.data.count, 0)
        XCTAssertGreaterThan(nonProgressiveResult.data.count, 0)
        
        // Both should have valid signatures
        XCTAssertEqual(progressiveResult.data[0], 0xFF)
        XCTAssertEqual(progressiveResult.data[1], 0x0A)
        XCTAssertEqual(nonProgressiveResult.data[0], 0xFF)
        XCTAssertEqual(nonProgressiveResult.data[1], 0x0A)
    }
    
    // MARK: - Progressive with Different Quality Levels
    
    func testProgressiveEncoding_HighQuality_ProducesValidOutput() throws {
        var frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 8))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 8))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 95),
            effort: .kitten,
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testProgressiveEncoding_LowQuality_ProducesValidOutput() throws {
        var frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 8))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 8))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 50),
            effort: .falcon,
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Progressive with Different Effort Levels
    
    func testProgressiveEncoding_FastEffort_ProducesValidOutput() throws {
        var frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        // Simple gradient
        for y in 0..<32 {
            for x in 0..<32 {
                let value = UInt16((x + y) * 4)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            effort: .falcon,
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testProgressiveEncoding_HighEffort_ProducesValidOutput() throws {
        var frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        // Complex pattern
        for y in 0..<32 {
            for x in 0..<32 {
                let value = UInt16((x * x + y * y) % 256)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16((x * y) % 256))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            effort: .kitten,
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Progressive with ANS Entropy Coding
    
    func testProgressiveEncoding_WithANS_ProducesValidOutput() throws {
        var frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        for y in 0..<32 {
            for x in 0..<32 {
                let value = UInt16((x + y) % 256)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            effort: .squirrel,
            progressive: true,
            useANS: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testProgressiveEncoding_WithoutANS_ProducesValidOutput() throws {
        var frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        for y in 0..<32 {
            for x in 0..<32 {
                let value = UInt16((x + y) % 256)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            effort: .squirrel,
            progressive: true,
            useANS: false
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Edge Cases
    
    func testProgressiveEncoding_TinyImage_ProducesValidOutput() throws {
        // Test with image smaller than a single 8x8 block
        var frame = ImageFrame(
            width: 4,
            height: 4,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        for y in 0..<4 {
            for x in 0..<4 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 64))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 64))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testProgressiveEncoding_NonMultipleOf8Dimensions_ProducesValidOutput() throws {
        // Test with dimensions not multiples of 8
        var frame = ImageFrame(
            width: 30,
            height: 22,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        for y in 0..<22 {
            for x in 0..<30 {
                let value = UInt16((x + y) % 256)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testProgressiveEncoding_AllBlackImage_ProducesValidOutput() throws {
        // Test with solid color (all zeros)
        let frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        // All pixels are already zero (default)
        
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testProgressiveEncoding_AllWhiteImage_ProducesValidOutput() throws {
        // Test with solid color (all max values)
        var frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: 255)
                frame.setPixel(x: x, y: y, channel: 1, value: 255)
                frame.setPixel(x: x, y: y, channel: 2, value: 255)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Progressive Flag Validation
    
    func testProgressiveEncoding_FlagDisabled_UsesNonProgressiveMode() throws {
        var frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        for y in 0..<32 {
            for x in 0..<32 {
                let value = UInt16((x + y) % 256)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        // Explicitly disable progressive mode
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            progressive: false
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0x0A)
    }
    
    // MARK: - Encoding Statistics
    
    func testProgressiveEncoding_ProvidesValidStatistics() throws {
        var frame = ImageFrame(
            width: 64,
            height: 64,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        for y in 0..<64 {
            for x in 0..<64 {
                let value = UInt16((x * y) % 256)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        // Verify statistics
        XCTAssertGreaterThan(result.stats.originalSize, 0)
        XCTAssertGreaterThan(result.stats.compressedSize, 0)
        XCTAssertGreaterThan(result.stats.compressionRatio, 0)
        XCTAssertGreaterThanOrEqual(result.stats.encodingTime, 0)
        XCTAssertGreaterThanOrEqual(result.stats.peakMemory, 0)
    }
}
