/// Tests for reference frame encoding (animation delta encoding)
///
/// Validates the reference frame encoding feature that enables efficient
/// compression of animations by encoding frames as deltas from previous
/// reference frames.

import XCTest
@testable import JXLSwift

final class ReferenceFrameEncodingTests: XCTestCase {
    
    // MARK: - ReferenceFrameConfig Tests
    
    func testReferenceFrameConfig_DefaultInit() {
        let config = ReferenceFrameConfig()
        XCTAssertEqual(config.keyframeInterval, 30)
        XCTAssertEqual(config.maxDeltaFrames, 120)
        XCTAssertEqual(config.similarityThreshold, 0.7, accuracy: 0.001)
        XCTAssertEqual(config.maxReferenceFrames, 4)
    }
    
    func testReferenceFrameConfig_CustomInit() {
        let config = ReferenceFrameConfig(
            keyframeInterval: 15,
            maxDeltaFrames: 60,
            similarityThreshold: 0.8,
            maxReferenceFrames: 2
        )
        XCTAssertEqual(config.keyframeInterval, 15)
        XCTAssertEqual(config.maxDeltaFrames, 60)
        XCTAssertEqual(config.similarityThreshold, 0.8, accuracy: 0.001)
        XCTAssertEqual(config.maxReferenceFrames, 2)
    }
    
    func testReferenceFrameConfig_Presets() {
        // Aggressive preset
        let aggressive = ReferenceFrameConfig.aggressive
        XCTAssertEqual(aggressive.keyframeInterval, 60)
        XCTAssertEqual(aggressive.maxDeltaFrames, 240)
        
        // Balanced preset
        let balanced = ReferenceFrameConfig.balanced
        XCTAssertEqual(balanced.keyframeInterval, 30)
        XCTAssertEqual(balanced.maxDeltaFrames, 120)
        
        // Conservative preset
        let conservative = ReferenceFrameConfig.conservative
        XCTAssertEqual(conservative.keyframeInterval, 15)
        XCTAssertEqual(conservative.maxDeltaFrames, 60)
    }
    
    // MARK: - Basic Encoding Tests
    
    func testEncode_WithReferenceFrameConfig_ProducesValidOutput() throws {
        let frame1 = ImageFrame(width: 32, height: 32, channels: 3)
        let frame2 = ImageFrame(width: 32, height: 32, channels: 3)
        
        let animConfig = AnimationConfig.fps30
        let refConfig = ReferenceFrameConfig.balanced
        let options = EncodingOptions(
            animationConfig: animConfig,
            referenceFrameConfig: refConfig
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode([frame1, frame2])
        
        XCTAssertGreaterThan(result.data.count, 0)
        
        // Check JPEG XL signature
        XCTAssertGreaterThanOrEqual(result.data.count, 2)
        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0x0A)
    }
    
    func testEncode_TenFrames_WithBalancedReferenceFrames() throws {
        var frames: [ImageFrame] = []
        
        // Create 10 frames
        for i in 0..<10 {
            var frame = ImageFrame(width: 32, height: 32, channels: 3)
            let value = UInt16((i * 10) % 256)
            for y in 0..<32 {
                for x in 0..<32 {
                    frame.setPixel(x: x, y: y, channel: 0, value: value)
                    frame.setPixel(x: x, y: y, channel: 1, value: value)
                    frame.setPixel(x: x, y: y, channel: 2, value: value)
                }
            }
            frames.append(frame)
        }
        
        let animConfig = AnimationConfig.fps30
        let refConfig = ReferenceFrameConfig.balanced
        let options = EncodingOptions(
            animationConfig: animConfig,
            referenceFrameConfig: refConfig
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frames)
        
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.stats.compressionRatio, 0)
    }
}
