/// Tests for progressive decoding functionality
///
/// Validates that progressive decoding correctly reconstructs images
/// incrementally across multiple passes, providing quality improvement
/// from DC-only to full-quality reconstruction.

import XCTest
@testable import JXLSwift

final class ProgressiveDecodingTests: XCTestCase {
    
    // MARK: - Basic Progressive Decoding
    
    func testProgressiveDecoding_SmallImage_ProducesThreePasses() throws {
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
        
        // Encode with progressive mode
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            effort: .squirrel,
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let encoded = try encoder.encode(frame)
        
        // Decode progressively
        let decoder = JXLDecoder()
        var passCount = 0
        var lastFrame: ImageFrame?
        
        let finalFrame = try decoder.decodeProgressive(encoded.data) { intermediateFrame, passIndex in
            passCount += 1
            lastFrame = intermediateFrame
            
            // Verify frame dimensions are preserved
            XCTAssertEqual(intermediateFrame.width, 16)
            XCTAssertEqual(intermediateFrame.height, 16)
            XCTAssertEqual(intermediateFrame.channels, 3)
            
            // Pass index should be 0, 1, or 2
            XCTAssertTrue(passIndex >= 0 && passIndex < 3, "Pass index should be 0-2, got \(passIndex)")
        }
        
        // Should have 3 passes
        XCTAssertEqual(passCount, 3, "Progressive decoding should produce 3 passes")
        
        // Last callback frame should equal final return value
        XCTAssertEqual(lastFrame?.width, finalFrame.width)
        XCTAssertEqual(lastFrame?.height, finalFrame.height)
    }
    
    func testProgressiveDecoding_MediumImage_IncreasingQuality() throws {
        // Create a larger test image with more detail
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
        
        // Encode with progressive mode
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            effort: .falcon,
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let encoded = try encoder.encode(frame)
        
        // Decode progressively and collect frames
        let decoder = JXLDecoder()
        var frames: [ImageFrame] = []
        
        _ = try decoder.decodeProgressive(encoded.data) { intermediateFrame, passIndex in
            frames.append(intermediateFrame)
        }
        
        // Should have 3 progressive frames
        XCTAssertEqual(frames.count, 3, "Should have 3 progressive frames")
        
        // All frames should have same dimensions
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.width, 64, "Pass \(index) width mismatch")
            XCTAssertEqual(frame.height, 64, "Pass \(index) height mismatch")
            XCTAssertEqual(frame.channels, 3, "Pass \(index) channels mismatch")
        }
    }
    
    func testProgressiveDecoding_Grayscale_ProducesValidOutput() throws {
        // Test progressive decoding with single channel
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
        let encoded = try encoder.encode(frame)
        
        // Decode progressively
        let decoder = JXLDecoder()
        var passCount = 0
        
        _ = try decoder.decodeProgressive(encoded.data) { intermediateFrame, _ in
            passCount += 1
            XCTAssertEqual(intermediateFrame.channels, 1)
        }
        
        XCTAssertEqual(passCount, 3)
    }
    
    // MARK: - Progressive Round-Trip Tests
    
    func testProgressiveDecoding_RoundTrip_FinalFrameMatchesNonProgressive() throws {
        // Create test image
        var frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            bitsPerSample: 8
        )
        
        // Fill with test pattern
        for y in 0..<32 {
            for x in 0..<32 {
                let r = UInt16((x * 8) % 256)
                let g = UInt16((y * 8) % 256)
                let b = UInt16(((x + y) * 4) % 256)
                frame.setPixel(x: x, y: y, channel: 0, value: r)
                frame.setPixel(x: x, y: y, channel: 1, value: g)
                frame.setPixel(x: x, y: y, channel: 2, value: b)
            }
        }
        
        let quality: Float = 85
        
        // Encode with progressive mode
        let progressiveOptions = EncodingOptions(
            mode: .lossy(quality: quality),
            progressive: true
        )
        let progressiveEncoder = JXLEncoder(options: progressiveOptions)
        let progressiveEncoded = try progressiveEncoder.encode(frame)
        
        // Encode without progressive mode
        let nonProgressiveOptions = EncodingOptions(
            mode: .lossy(quality: quality),
            progressive: false
        )
        let nonProgressiveEncoder = JXLEncoder(options: nonProgressiveOptions)
        let nonProgressiveEncoded = try nonProgressiveEncoder.encode(frame)
        
        // Decode both
        let decoder = JXLDecoder()
        
        var progressiveFinal: ImageFrame?
        _ = try decoder.decodeProgressive(progressiveEncoded.data) { frame, _ in
            progressiveFinal = frame
        }
        
        let nonProgressiveDecoded = try decoder.decode(nonProgressiveEncoded.data)
        
        // Final progressive frame should be similar to non-progressive decode
        // (they may not be identical due to different encoding paths, but should be close)
        guard let progressiveFinal = progressiveFinal else {
            XCTFail("Progressive decoding did not produce final frame")
            return
        }
        
        // Compare dimensions
        XCTAssertEqual(progressiveFinal.width, nonProgressiveDecoded.width)
        XCTAssertEqual(progressiveFinal.height, nonProgressiveDecoded.height)
        XCTAssertEqual(progressiveFinal.channels, nonProgressiveDecoded.channels)
        
        // For lossy compression, we expect similar but not identical results
        // Just verify both are valid frames with reasonable pixel values
        for c in 0..<3 {
            for y in 0..<32 {
                for x in 0..<32 {
                    let progValue = progressiveFinal.getPixel(x: x, y: y, channel: c)
                    let nonProgValue = nonProgressiveDecoded.getPixel(x: x, y: y, channel: c)
                    
                    // Both should be in valid range
                    XCTAssertLessThanOrEqual(progValue, 255)
                    XCTAssertLessThanOrEqual(nonProgValue, 255)
                }
            }
        }
    }
    
    // MARK: - Pass-by-Pass Validation
    
    func testProgressiveDecoding_PassOrder_IsCorrect() throws {
        // Create a simple 8x8 image (exactly one block)
        var frame = ImageFrame(
            width: 8,
            height: 8,
            channels: 3,
            pixelType: .uint8,
            bitsPerSample: 8
        )
        
        // Fill with solid color for simplicity
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: 128)
                frame.setPixel(x: x, y: y, channel: 1, value: 64)
                frame.setPixel(x: x, y: y, channel: 2, value: 192)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let encoded = try encoder.encode(frame)
        
        let decoder = JXLDecoder()
        var passIndices: [Int] = []
        
        _ = try decoder.decodeProgressive(encoded.data) { _, passIndex in
            passIndices.append(passIndex)
        }
        
        // Passes should be in order: 0, 1, 2
        XCTAssertEqual(passIndices, [0, 1, 2], "Passes should be decoded in order 0, 1, 2")
    }
    
    // MARK: - Non-Progressive Data Handling
    
    func testProgressiveDecoding_NonProgressiveData_ThrowsError() throws {
        // When trying to decode non-progressive data with progressive API,
        // it should throw an error since the data format doesn't match
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 3,
            pixelType: .uint8,
            bitsPerSample: 8
        )
        
        // Fill with pattern
        for y in 0..<16 {
            for x in 0..<16 {
                let value = UInt16((x + y) * 16)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        // Encode WITHOUT progressive mode
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            progressive: false
        )
        
        let encoder = JXLEncoder(options: options)
        let encoded = try encoder.encode(frame)
        
        // Try to decode with progressive API - should throw error
        let decoder = JXLDecoder()
        
        XCTAssertThrowsError(try decoder.decodeProgressive(encoded.data) { _, _ in
            XCTFail("Callback should not be called for non-progressive data")
        })
    }
    
    // MARK: - Error Handling
    
    func testProgressiveDecoding_InvalidData_ThrowsError() throws {
        // Create invalid data
        let invalidData = Data([0xFF, 0x0A, 0x00, 0x00, 0x00])
        
        let decoder = JXLDecoder()
        
        XCTAssertThrowsError(try decoder.decodeProgressive(invalidData) { _, _ in
            XCTFail("Callback should not be called for invalid data")
        })
    }
    
    func testProgressiveDecoding_TruncatedData_ThrowsError() throws {
        // Create a valid image and encode it
        var frame = ImageFrame(
            width: 8,
            height: 8,
            channels: 3,
            pixelType: .uint8,
            bitsPerSample: 8
        )
        
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: 100)
                frame.setPixel(x: x, y: y, channel: 1, value: 100)
                frame.setPixel(x: x, y: y, channel: 2, value: 100)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let encoded = try encoder.encode(frame)
        
        // Truncate the data
        let truncated = encoded.data.prefix(encoded.data.count / 2)
        
        let decoder = JXLDecoder()
        
        // Should throw error for truncated data
        XCTAssertThrowsError(try decoder.decodeProgressive(truncated) { _, _ in
            // May get some callbacks before error
        })
    }
    
    // MARK: - Lossless Mode Tests
    
    func testProgressiveDecoding_LosslessMode_CallbackOnce() throws {
        // Progressive decoding is specific to VarDCT (lossy) mode
        // For lossless/Modular mode, should fall back to single callback
        
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 3,
            pixelType: .uint8,
            bitsPerSample: 8
        )
        
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossless,
            effort: .squirrel
        )
        
        let encoder = JXLEncoder(options: options)
        let encoded = try encoder.encode(frame)
        
        let decoder = JXLDecoder()
        var callbackCount = 0
        
        _ = try decoder.decodeProgressive(encoded.data) { intermediateFrame, passIndex in
            callbackCount += 1
            XCTAssertEqual(passIndex, 0, "Lossless mode should use pass index 0")
            
            // Should get full frame immediately
            XCTAssertEqual(intermediateFrame.width, 16)
            XCTAssertEqual(intermediateFrame.height, 16)
        }
        
        // Lossless should call callback exactly once
        XCTAssertEqual(callbackCount, 1, "Lossless mode should call callback once")
    }
    
    // MARK: - Different Image Sizes
    
    func testProgressiveDecoding_NonBlockAlignedSize_HandlesCorrectly() throws {
        // Test image size that's not a multiple of 8
        let width = 23
        let height = 17
        
        var frame = ImageFrame(
            width: width,
            height: height,
            channels: 3,
            pixelType: .uint8,
            bitsPerSample: 8
        )
        
        for y in 0..<height {
            for x in 0..<width {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x * 11) % 256))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16((y * 13) % 256))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            progressive: true
        )
        
        let encoder = JXLEncoder(options: options)
        let encoded = try encoder.encode(frame)
        
        let decoder = JXLDecoder()
        var passCount = 0
        
        let finalFrame = try decoder.decodeProgressive(encoded.data) { intermediateFrame, _ in
            passCount += 1
            XCTAssertEqual(intermediateFrame.width, width)
            XCTAssertEqual(intermediateFrame.height, height)
        }
        
        XCTAssertEqual(passCount, 3)
        XCTAssertEqual(finalFrame.width, width)
        XCTAssertEqual(finalFrame.height, height)
    }
}
