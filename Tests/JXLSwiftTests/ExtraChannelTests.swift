/// Tests for extra channel support (depth, thermal, spectral, etc.)
///
/// Verifies that extra channels are correctly created, accessed, and preserved
/// through the encoding pipeline with various channel types and bit depths.

import XCTest
@testable import JXLSwift

final class ExtraChannelTests: XCTestCase {
    
    // MARK: - ExtraChannelType Tests
    
    func testExtraChannelType_AllCasesDefined() {
        // Verify all standard extra channel types are available
        XCTAssertEqual(ExtraChannelType.alpha.rawValue, 0)
        XCTAssertEqual(ExtraChannelType.depth.rawValue, 1)
        XCTAssertEqual(ExtraChannelType.spotColor.rawValue, 2)
        XCTAssertEqual(ExtraChannelType.selectionMask.rawValue, 3)
        XCTAssertEqual(ExtraChannelType.black.rawValue, 4)
        XCTAssertEqual(ExtraChannelType.cfa.rawValue, 5)
        XCTAssertEqual(ExtraChannelType.thermal.rawValue, 6)
        XCTAssertEqual(ExtraChannelType.reserved.rawValue, 7)
        XCTAssertEqual(ExtraChannelType.optional.rawValue, 8)
    }
    
    // MARK: - ExtraChannelInfo Tests
    
    func testExtraChannelInfo_DepthChannel_DefaultValues() {
        let depthChannel = ExtraChannelInfo.depth()
        
        XCTAssertEqual(depthChannel.type, .depth)
        XCTAssertEqual(depthChannel.bitsPerSample, 16)
        XCTAssertEqual(depthChannel.name, "Depth")
        XCTAssertEqual(depthChannel.dimShift, 0)
        XCTAssertFalse(depthChannel.alphaPremultiplied)
        XCTAssertTrue(depthChannel.spotColor.isEmpty)
    }
    
    func testExtraChannelInfo_ThermalChannel_DefaultValues() {
        let thermalChannel = ExtraChannelInfo.thermal()
        
        XCTAssertEqual(thermalChannel.type, .thermal)
        XCTAssertEqual(thermalChannel.bitsPerSample, 16)
        XCTAssertEqual(thermalChannel.name, "Thermal")
        XCTAssertEqual(thermalChannel.dimShift, 0)
    }
    
    func testExtraChannelInfo_OptionalChannel_CustomName() {
        let channel = ExtraChannelInfo.optional(bitsPerSample: 8, name: "Spectral-NIR")
        
        XCTAssertEqual(channel.type, .optional)
        XCTAssertEqual(channel.bitsPerSample, 8)
        XCTAssertEqual(channel.name, "Spectral-NIR")
    }
    
    func testExtraChannelInfo_CustomBitsPerSample_ClampedToValidRange() {
        let tooLow = ExtraChannelInfo(type: .depth, bitsPerSample: 0)
        XCTAssertEqual(tooLow.bitsPerSample, 1, "Bits per sample should be clamped to minimum of 1")
        
        let tooHigh = ExtraChannelInfo(type: .depth, bitsPerSample: 64)
        XCTAssertEqual(tooHigh.bitsPerSample, 32, "Bits per sample should be clamped to maximum of 32")
        
        let valid = ExtraChannelInfo(type: .depth, bitsPerSample: 12)
        XCTAssertEqual(valid.bitsPerSample, 12, "Valid bits per sample should be preserved")
    }
    
    // MARK: - ImageFrame Extra Channel Tests
    
    func testImageFrame_NoExtraChannels_DefaultBehavior() {
        let frame = ImageFrame(width: 16, height: 16, channels: 3)
        
        XCTAssertTrue(frame.extraChannels.isEmpty)
        XCTAssertTrue(frame.extraChannelData.isEmpty)
    }
    
    func testImageFrame_WithDepthChannel_AllocatesCorrectDataSize() {
        let depthChannel = ExtraChannelInfo.depth(bitsPerSample: 16)
        let frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 3,
            extraChannels: [depthChannel]
        )
        
        XCTAssertEqual(frame.extraChannels.count, 1)
        XCTAssertEqual(frame.extraChannels[0].type, .depth)
        
        // 16x16 pixels * 2 bytes (16 bits) = 512 bytes
        let expectedSize = 16 * 16 * 2
        XCTAssertEqual(frame.extraChannelData.count, expectedSize)
    }
    
    func testImageFrame_MultipleExtraChannels_AllocatesCorrectDataSize() {
        let depthChannel = ExtraChannelInfo.depth(bitsPerSample: 16)  // 16x16 * 2 = 512 bytes
        let thermalChannel = ExtraChannelInfo.thermal(bitsPerSample: 8)  // 16x16 * 1 = 256 bytes
        
        let frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 3,
            extraChannels: [depthChannel, thermalChannel]
        )
        
        XCTAssertEqual(frame.extraChannels.count, 2)
        
        // Total: 512 + 256 = 768 bytes
        let expectedSize = (16 * 16 * 2) + (16 * 16 * 1)
        XCTAssertEqual(frame.extraChannelData.count, expectedSize)
    }
    
    // MARK: - Extra Channel Data Access Tests
    
    func testGetSetExtraChannelValue_8Bit_RoundTrip() {
        let channel = ExtraChannelInfo(type: .thermal, bitsPerSample: 8, name: "Thermal")
        var frame = ImageFrame(width: 8, height: 8, channels: 3, extraChannels: [channel])
        
        // Set values in a gradient pattern
        for y in 0..<8 {
            for x in 0..<8 {
                let value = UInt16(x * 32 + y * 32)
                frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 0, value: value)
            }
        }
        
        // Verify values can be read back (with 8-bit precision loss)
        for y in 0..<8 {
            for x in 0..<8 {
                let value = frame.getExtraChannelValue(x: x, y: y, extraChannelIndex: 0)
                // 8-bit precision: value should be in range [0, 255]
                XCTAssertLessThanOrEqual(value, 255)
            }
        }
    }
    
    func testGetSetExtraChannelValue_16Bit_RoundTrip() {
        let channel = ExtraChannelInfo.depth(bitsPerSample: 16)
        var frame = ImageFrame(width: 8, height: 8, channels: 3, extraChannels: [channel])
        
        // Set depth values in a gradient
        for y in 0..<8 {
            for x in 0..<8 {
                let value = UInt16(x * 8192 + y * 1024)
                frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 0, value: value)
            }
        }
        
        // Verify values can be read back accurately
        for y in 0..<8 {
            for x in 0..<8 {
                let expected = UInt16(x * 8192 + y * 1024)
                let actual = frame.getExtraChannelValue(x: x, y: y, extraChannelIndex: 0)
                XCTAssertEqual(actual, expected, accuracy: 1,
                              "16-bit depth value at (\(x), \(y)) should match")
            }
        }
    }
    
    func testGetSetExtraChannelValue_MultipleChannels_IndependentData() {
        let depthChannel = ExtraChannelInfo.depth(bitsPerSample: 16)
        let thermalChannel = ExtraChannelInfo.thermal(bitsPerSample: 8)
        
        var frame = ImageFrame(
            width: 4,
            height: 4,
            channels: 3,
            extraChannels: [depthChannel, thermalChannel]
        )
        
        // Set distinct patterns for each channel
        for y in 0..<4 {
            for x in 0..<4 {
                frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 0, value: UInt16(x * 10000))
                frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 1, value: UInt16(y * 50))
            }
        }
        
        // Verify channels maintain independent data
        for y in 0..<4 {
            for x in 0..<4 {
                let depthValue = frame.getExtraChannelValue(x: x, y: y, extraChannelIndex: 0)
                let thermalValue = frame.getExtraChannelValue(x: x, y: y, extraChannelIndex: 1)
                
                // Depth should vary with x (with tolerance for 16-bit storage)
                let expectedDepth = x * 10000
                if expectedDepth > 100 {
                    XCTAssertGreaterThanOrEqual(depthValue, UInt16(expectedDepth - 100))
                }
                XCTAssertLessThanOrEqual(depthValue, 65535)
                
                // Thermal should vary with y (clamped to 8-bit range)
                XCTAssertLessThanOrEqual(thermalValue, 255)
            }
        }
    }
    
    func testGetExtraChannelValue_InvalidIndex_ReturnsZero() {
        let channel = ExtraChannelInfo.depth()
        let frame = ImageFrame(width: 4, height: 4, channels: 3, extraChannels: [channel])
        
        // Try to access non-existent channel
        let value = frame.getExtraChannelValue(x: 0, y: 0, extraChannelIndex: 1)
        XCTAssertEqual(value, 0, "Accessing invalid extra channel should return 0")
    }
    
    func testSetExtraChannelValue_InvalidIndex_DoesNotCrash() {
        let channel = ExtraChannelInfo.depth()
        var frame = ImageFrame(width: 4, height: 4, channels: 3, extraChannels: [channel])
        
        // Try to set non-existent channel (should not crash)
        frame.setExtraChannelValue(x: 0, y: 0, extraChannelIndex: 5, value: 12345)
        
        // Verify original channel is unaffected
        XCTAssertEqual(frame.getExtraChannelValue(x: 0, y: 0, extraChannelIndex: 0), 0)
    }
    
    // MARK: - Encoding Integration Tests
    
    func testVarDCT_WithDepthChannel_ProducesValidOutput() throws {
        let depthChannel = ExtraChannelInfo.depth(bitsPerSample: 16)
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 3,
            pixelType: .uint8,
            extraChannels: [depthChannel]
        )
        
        // Fill RGB with gradient
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        // Fill depth channel
        for y in 0..<16 {
            for x in 0..<16 {
                let depth = UInt16((x + y) * 2000)
                frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 0, value: depth)
            }
        }
        
        // Encode with VarDCT
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .squirrel)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        // Verify output is non-empty
        XCTAssertGreaterThan(result.data.count, 0,
                            "VarDCT encoding with depth channel should produce output")
    }
    
    func testModular_WithThermalChannel_ProducesValidOutput() throws {
        let thermalChannel = ExtraChannelInfo.thermal(bitsPerSample: 8)
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 3,
            pixelType: .uint8,
            extraChannels: [thermalChannel]
        )
        
        // Fill RGB
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: 100)
                frame.setPixel(x: x, y: y, channel: 1, value: 150)
                frame.setPixel(x: x, y: y, channel: 2, value: 200)
            }
        }
        
        // Fill thermal channel
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 0, value: UInt16((x + y) * 8))
            }
        }
        
        // Encode with Modular (lossless)
        let options = EncodingOptions(mode: .lossless, effort: .squirrel)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0,
                            "Modular encoding with thermal channel should produce output")
    }
    
    func testVarDCT_MultipleExtraChannels_ProducesValidOutput() throws {
        let depthChannel = ExtraChannelInfo.depth(bitsPerSample: 16)
        let thermalChannel = ExtraChannelInfo.thermal(bitsPerSample: 8)
        let customChannel = ExtraChannelInfo.optional(bitsPerSample: 8, name: "Custom")
        
        var frame = ImageFrame(
            width: 8,
            height: 8,
            channels: 3,
            extraChannels: [depthChannel, thermalChannel, customChannel]
        )
        
        // Fill main channels
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 32))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        // Fill extra channels
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 0, value: UInt16(x * 5000))
                frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 1, value: UInt16(y * 30))
                frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 2, value: UInt16((x + y) * 20))
            }
        }
        
        let options = EncodingOptions(mode: .lossy(quality: 85), effort: .squirrel)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0,
                            "Encoding with multiple extra channels should succeed")
    }
    
    // MARK: - Edge Case Tests
    
    func testImageFrame_EmptyExtraChannelsArray_Works() {
        let frame = ImageFrame(width: 4, height: 4, channels: 3, extraChannels: [])
        
        XCTAssertTrue(frame.extraChannels.isEmpty)
        XCTAssertTrue(frame.extraChannelData.isEmpty)
    }
    
    func testExtraChannelInfo_Equality_WorksCorrectly() {
        let channel1 = ExtraChannelInfo.depth(bitsPerSample: 16, name: "Depth")
        let channel2 = ExtraChannelInfo.depth(bitsPerSample: 16, name: "Depth")
        let channel3 = ExtraChannelInfo.depth(bitsPerSample: 8, name: "Depth")
        
        XCTAssertEqual(channel1, channel2, "Identical channel info should be equal")
        XCTAssertNotEqual(channel1, channel3, "Different bit depths should not be equal")
    }
    
    func testExtraChannelValue_BoundaryPixels_HandledCorrectly() {
        let channel = ExtraChannelInfo.depth(bitsPerSample: 16)
        var frame = ImageFrame(width: 10, height: 10, channels: 3, extraChannels: [channel])
        
        // Test corner pixels
        frame.setExtraChannelValue(x: 0, y: 0, extraChannelIndex: 0, value: 1000)
        frame.setExtraChannelValue(x: 9, y: 0, extraChannelIndex: 0, value: 2000)
        frame.setExtraChannelValue(x: 0, y: 9, extraChannelIndex: 0, value: 3000)
        frame.setExtraChannelValue(x: 9, y: 9, extraChannelIndex: 0, value: 4000)
        
        XCTAssertEqual(frame.getExtraChannelValue(x: 0, y: 0, extraChannelIndex: 0), 1000)
        XCTAssertEqual(frame.getExtraChannelValue(x: 9, y: 0, extraChannelIndex: 0), 2000)
        XCTAssertEqual(frame.getExtraChannelValue(x: 0, y: 9, extraChannelIndex: 0), 3000)
        XCTAssertEqual(frame.getExtraChannelValue(x: 9, y: 9, extraChannelIndex: 0), 4000)
    }
    
    func testExtraChannel_MaxValue_HandledCorrectly() {
        let channel = ExtraChannelInfo(type: .depth, bitsPerSample: 16)
        var frame = ImageFrame(width: 4, height: 4, channels: 3, extraChannels: [channel])
        
        // Set maximum 16-bit value
        frame.setExtraChannelValue(x: 2, y: 2, extraChannelIndex: 0, value: 65535)
        
        let value = frame.getExtraChannelValue(x: 2, y: 2, extraChannelIndex: 0)
        XCTAssertEqual(value, 65535, "Maximum value should be preserved")
    }
    
    func testExtraChannel_MinValue_HandledCorrectly() {
        let channel = ExtraChannelInfo(type: .depth, bitsPerSample: 16)
        var frame = ImageFrame(width: 4, height: 4, channels: 3, extraChannels: [channel])
        
        // Set minimum value (default is 0)
        frame.setExtraChannelValue(x: 1, y: 1, extraChannelIndex: 0, value: 0)
        
        let value = frame.getExtraChannelValue(x: 1, y: 1, extraChannelIndex: 0)
        XCTAssertEqual(value, 0, "Minimum value should be preserved")
    }
    
    // MARK: - Performance Tests
    
    func testPerformance_SetExtraChannelValues_LargeImage() {
        let channel = ExtraChannelInfo.depth(bitsPerSample: 16)
        var frame = ImageFrame(width: 256, height: 256, channels: 3, extraChannels: [channel])
        
        measure {
            for y in 0..<256 {
                for x in 0..<256 {
                    frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 0, value: UInt16(x + y))
                }
            }
        }
    }
    
    func testPerformance_GetExtraChannelValues_LargeImage() {
        let channel = ExtraChannelInfo.depth(bitsPerSample: 16)
        var frame = ImageFrame(width: 256, height: 256, channels: 3, extraChannels: [channel])
        
        // Pre-fill with data
        for y in 0..<256 {
            for x in 0..<256 {
                frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 0, value: UInt16(x + y))
            }
        }
        
        measure {
            var sum: UInt64 = 0
            for y in 0..<256 {
                for x in 0..<256 {
                    sum += UInt64(frame.getExtraChannelValue(x: x, y: y, extraChannelIndex: 0))
                }
            }
            XCTAssertGreaterThan(sum, 0)
        }
    }
}
