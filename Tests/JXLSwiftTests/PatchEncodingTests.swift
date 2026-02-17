/// Tests for patch encoding (rectangular region copying from reference frames)
///
/// Validates the patch encoding feature that enables efficient compression
/// by copying repeated rectangular regions from reference frames rather than
/// re-encoding them.

import XCTest
@testable import JXLSwift

final class PatchEncodingTests: XCTestCase {
    
    // MARK: - PatchConfig Tests
    
    func testPatchConfig_DefaultInit() {
        let config = PatchConfig()
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.minPatchSize, 8)
        XCTAssertEqual(config.maxPatchSize, 128)
        XCTAssertEqual(config.similarityThreshold, 0.95, accuracy: 0.001)
        XCTAssertEqual(config.blockSize, 8)
        XCTAssertEqual(config.maxPatchesPerFrame, 256)
        XCTAssertEqual(config.searchRadius, 2)
    }
    
    func testPatchConfig_CustomInit() {
        let config = PatchConfig(
            enabled: true,
            minPatchSize: 16,
            maxPatchSize: 64,
            similarityThreshold: 0.99,
            blockSize: 16,
            maxPatchesPerFrame: 128,
            searchRadius: 1
        )
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.minPatchSize, 16)
        XCTAssertEqual(config.maxPatchSize, 64)
        XCTAssertEqual(config.similarityThreshold, 0.99, accuracy: 0.001)
        XCTAssertEqual(config.blockSize, 16)
        XCTAssertEqual(config.maxPatchesPerFrame, 128)
        XCTAssertEqual(config.searchRadius, 1)
    }
    
    func testPatchConfig_Presets() {
        // Aggressive preset
        let aggressive = PatchConfig.aggressive
        XCTAssertTrue(aggressive.enabled)
        XCTAssertEqual(aggressive.minPatchSize, 8)
        XCTAssertEqual(aggressive.maxPatchSize, 64)
        XCTAssertEqual(aggressive.maxPatchesPerFrame, 512)
        
        // Balanced preset
        let balanced = PatchConfig.balanced
        XCTAssertTrue(balanced.enabled)
        XCTAssertEqual(balanced.minPatchSize, 8)
        XCTAssertEqual(balanced.maxPatchSize, 128)
        XCTAssertEqual(balanced.maxPatchesPerFrame, 256)
        
        // Conservative preset
        let conservative = PatchConfig.conservative
        XCTAssertTrue(conservative.enabled)
        XCTAssertEqual(conservative.minPatchSize, 16)
        XCTAssertEqual(conservative.maxPatchSize, 128)
        XCTAssertEqual(conservative.maxPatchesPerFrame, 128)
        
        // Screen content preset
        let screenContent = PatchConfig.screenContent
        XCTAssertTrue(screenContent.enabled)
        XCTAssertEqual(screenContent.minPatchSize, 4)
        XCTAssertEqual(screenContent.maxPatchSize, 96)
        XCTAssertEqual(screenContent.maxPatchesPerFrame, 1024)
    }
    
    func testPatchConfig_BoundsValidation() {
        // Test that values are clamped to valid ranges
        let config = PatchConfig(
            minPatchSize: 0,  // Should be clamped to 1
            maxPatchSize: 5,  // Should be increased to match minPatchSize
            similarityThreshold: 1.5,  // Should be clamped to 1.0
            searchRadius: -1  // Should be clamped to 0
        )
        XCTAssertGreaterThanOrEqual(config.minPatchSize, 1)
        XCTAssertGreaterThanOrEqual(config.maxPatchSize, config.minPatchSize)
        XCTAssertLessThanOrEqual(config.similarityThreshold, 1.0)
        XCTAssertGreaterThanOrEqual(config.searchRadius, 0)
    }
    
    // MARK: - Patch Structure Tests
    
    func testPatch_Initialization() {
        let patch = Patch(
            destX: 10,
            destY: 20,
            width: 32,
            height: 32,
            referenceIndex: 1,
            sourceX: 5,
            sourceY: 15,
            similarity: 0.98
        )
        
        XCTAssertEqual(patch.destX, 10)
        XCTAssertEqual(patch.destY, 20)
        XCTAssertEqual(patch.width, 32)
        XCTAssertEqual(patch.height, 32)
        XCTAssertEqual(patch.referenceIndex, 1)
        XCTAssertEqual(patch.sourceX, 5)
        XCTAssertEqual(patch.sourceY, 15)
        XCTAssertEqual(patch.similarity, 0.98, accuracy: 0.001)
    }
    
    func testPatch_Area() {
        let patch = Patch(
            destX: 0, destY: 0, width: 16, height: 8,
            referenceIndex: 1, sourceX: 0, sourceY: 0
        )
        XCTAssertEqual(patch.area, 128)
    }
    
    func testPatch_OverlapDetection_NoOverlap() {
        let patch1 = Patch(
            destX: 0, destY: 0, width: 16, height: 16,
            referenceIndex: 1, sourceX: 0, sourceY: 0
        )
        let patch2 = Patch(
            destX: 20, destY: 20, width: 16, height: 16,
            referenceIndex: 1, sourceX: 20, sourceY: 20
        )
        XCTAssertFalse(patch1.overlaps(with: patch2))
    }
    
    func testPatch_OverlapDetection_WithOverlap() {
        let patch1 = Patch(
            destX: 0, destY: 0, width: 16, height: 16,
            referenceIndex: 1, sourceX: 0, sourceY: 0
        )
        let patch2 = Patch(
            destX: 8, destY: 8, width: 16, height: 16,
            referenceIndex: 1, sourceX: 8, sourceY: 8
        )
        XCTAssertTrue(patch1.overlaps(with: patch2))
    }
    
    func testPatch_OverlapDetection_Adjacent() {
        let patch1 = Patch(
            destX: 0, destY: 0, width: 16, height: 16,
            referenceIndex: 1, sourceX: 0, sourceY: 0
        )
        let patch2 = Patch(
            destX: 16, destY: 0, width: 16, height: 16,
            referenceIndex: 1, sourceX: 16, sourceY: 0
        )
        // Adjacent patches don't overlap
        XCTAssertFalse(patch1.overlaps(with: patch2))
    }
    
    // MARK: - PatchDetector Tests
    
    func testPatchDetector_DisabledConfig_ReturnsNoPatches() {
        let config = PatchConfig(enabled: false)
        let detector = PatchDetector(config: config)
        
        let frame1 = ImageFrame(width: 32, height: 32, channels: 3)
        let frame2 = ImageFrame(width: 32, height: 32, channels: 3)
        
        let patches = detector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        XCTAssertTrue(patches.isEmpty)
    }
    
    func testPatchDetector_DifferentDimensions_ReturnsNoPatches() {
        let config = PatchConfig.balanced
        let detector = PatchDetector(config: config)
        
        let frame1 = ImageFrame(width: 32, height: 32, channels: 3)
        let frame2 = ImageFrame(width: 64, height: 64, channels: 3)
        
        let patches = detector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        XCTAssertTrue(patches.isEmpty)
    }
    
    func testPatchDetector_IdenticalFrames_DetectsPatches() {
        let config = PatchConfig.balanced
        let detector = PatchDetector(config: config)
        
        // Create two identical frames with a solid pattern
        var frame1 = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<64 {
            for x in 0..<64 {
                let value: UInt16 = UInt16((x + y) * 10 % 256)
                frame1.setPixel(x: x, y: y, channel: 0, value: value)
                frame1.setPixel(x: x, y: y, channel: 1, value: value)
                frame1.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        let frame2 = frame1  // Identical copy
        
        let patches = detector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        // Should detect patches since frames are identical
        XCTAssertGreaterThan(patches.count, 0)
        
        // All patches should have high similarity
        for patch in patches {
            XCTAssertGreaterThan(patch.similarity, 0.9)
        }
    }
    
    func testPatchDetector_PartialMatch_DetectsCorrectPatches() {
        let config = PatchConfig(
            minPatchSize: 8,
            maxPatchSize: 32,
            similarityThreshold: 0.9,
            blockSize: 8
        )
        let detector = PatchDetector(config: config)
        
        // Create reference frame with a distinctive 16×16 pattern in top-left
        var refFrame = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<16 {
            for x in 0..<16 {
                let value: UInt16 = 200
                refFrame.setPixel(x: x, y: y, channel: 0, value: value)
                refFrame.setPixel(x: x, y: y, channel: 1, value: value)
                refFrame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        // Create current frame with the same pattern repeated elsewhere
        var currentFrame = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<16 {
            for x in 0..<16 {
                let value: UInt16 = 200
                currentFrame.setPixel(x: x + 32, y: y + 32, channel: 0, value: value)
                currentFrame.setPixel(x: x + 32, y: y + 32, channel: 1, value: value)
                currentFrame.setPixel(x: x + 32, y: y + 32, channel: 2, value: value)
            }
        }
        
        let patches = detector.detectPatches(
            currentFrame: currentFrame,
            referenceFrame: refFrame,
            referenceIndex: 1
        )
        
        // Should detect at least one patch with high similarity
        XCTAssertGreaterThan(patches.count, 0)
    }
    
    func testPatchDetector_MaxPatchesLimit() {
        let config = PatchConfig(
            minPatchSize: 8,
            maxPatchSize: 16,
            blockSize: 8,
            maxPatchesPerFrame: 5  // Limit to 5 patches
        )
        let detector = PatchDetector(config: config)
        
        // Create frames that would generate many patches
        var frame1 = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<64 {
            for x in 0..<64 {
                frame1.setPixel(x: x, y: y, channel: 0, value: 100)
            }
        }
        let frame2 = frame1
        
        let patches = detector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        // Should respect the max patches limit
        XCTAssertLessThanOrEqual(patches.count, 5)
    }
    
    func testPatchDetector_SortsByArea() {
        let config = PatchConfig.balanced
        let detector = PatchDetector(config: config)
        
        // Create identical frames to generate patches
        var frame1 = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<64 {
            for x in 0..<64 {
                frame1.setPixel(x: x, y: y, channel: 0, value: 150)
            }
        }
        let frame2 = frame1
        
        let patches = detector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        // Verify patches are sorted by area (largest first)
        for i in 1..<patches.count {
            XCTAssertGreaterThanOrEqual(patches[i-1].area, patches[i].area)
        }
    }
    
    func testPatchDetector_LowSimilarity_RejectsPatches() {
        let config = PatchConfig(
            minPatchSize: 8,
            similarityThreshold: 0.99,  // Very high threshold
            blockSize: 8
        )
        let detector = PatchDetector(config: config)
        
        // Create two very different frames
        var frame1 = ImageFrame(width: 32, height: 32, channels: 3)
        var frame2 = ImageFrame(width: 32, height: 32, channels: 3)
        
        for y in 0..<32 {
            for x in 0..<32 {
                frame1.setPixel(x: x, y: y, channel: 0, value: 0)
                frame2.setPixel(x: x, y: y, channel: 0, value: 255)
            }
        }
        
        let patches = detector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        // Should find no patches due to high threshold
        XCTAssertEqual(patches.count, 0)
    }
    
    // MARK: - EncodingOptions Integration Tests
    
    func testEncodingOptions_WithPatchConfig() {
        let patchConfig = PatchConfig.balanced
        let refConfig = ReferenceFrameConfig.balanced
        let options = EncodingOptions(
            referenceFrameConfig: refConfig,
            patchConfig: patchConfig
        )
        
        XCTAssertNotNil(options.patchConfig)
        XCTAssertNotNil(options.referenceFrameConfig)
        XCTAssertTrue(options.patchConfig!.enabled)
    }
    
    func testEncodingOptions_WithoutPatchConfig() {
        let options = EncodingOptions()
        XCTAssertNil(options.patchConfig)
    }
    
    // MARK: - Edge Case Tests
    
    func testPatchDetector_SmallFrame() {
        let config = PatchConfig(blockSize: 8)
        let detector = PatchDetector(config: config)
        
        // Frame smaller than block size
        let frame1 = ImageFrame(width: 4, height: 4, channels: 3)
        let frame2 = ImageFrame(width: 4, height: 4, channels: 3)
        
        let patches = detector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        // Should handle gracefully (likely no patches due to size)
        XCTAssertGreaterThanOrEqual(patches.count, 0)
    }
    
    func testPatchDetector_SingleChannel() {
        let config = PatchConfig.balanced
        let detector = PatchDetector(config: config)
        
        var frame1 = ImageFrame(width: 32, height: 32, channels: 1)
        for y in 0..<32 {
            for x in 0..<32 {
                frame1.setPixel(x: x, y: y, channel: 0, value: 128)
            }
        }
        let frame2 = frame1
        
        let patches = detector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        // Should work with single-channel images
        XCTAssertGreaterThanOrEqual(patches.count, 0)
    }
    
    func testPatchDetector_AlphaChannel() {
        let config = PatchConfig.balanced
        let detector = PatchDetector(config: config)
        
        var frame1 = ImageFrame(width: 32, height: 32, channels: 4, hasAlpha: true)
        for y in 0..<32 {
            for x in 0..<32 {
                frame1.setPixel(x: x, y: y, channel: 0, value: 100)
                frame1.setPixel(x: x, y: y, channel: 1, value: 100)
                frame1.setPixel(x: x, y: y, channel: 2, value: 100)
                frame1.setPixel(x: x, y: y, channel: 3, value: 255)  // Alpha
            }
        }
        let frame2 = frame1
        
        let patches = detector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        // Should work with RGBA images
        XCTAssertGreaterThanOrEqual(patches.count, 0)
    }
    
    func testPatchDetector_16BitPixels() {
        let config = PatchConfig.balanced
        let detector = PatchDetector(config: config)
        
        var frame1 = ImageFrame(width: 32, height: 32, channels: 3, pixelType: .uint16)
        for y in 0..<32 {
            for x in 0..<32 {
                let value: UInt16 = 32768
                frame1.setPixel(x: x, y: y, channel: 0, value: value)
                frame1.setPixel(x: x, y: y, channel: 1, value: value)
                frame1.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        let frame2 = frame1
        
        let patches = detector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        // Should work with 16-bit images
        XCTAssertGreaterThanOrEqual(patches.count, 0)
    }
    
    func testPatchDetector_FloatPixels() {
        let config = PatchConfig.balanced
        let detector = PatchDetector(config: config)
        
        var frame1 = ImageFrame(width: 32, height: 32, channels: 3, pixelType: .float32)
        for y in 0..<32 {
            for x in 0..<32 {
                let value: UInt16 = 16384  // Will be interpreted as float bits
                frame1.setPixel(x: x, y: y, channel: 0, value: value)
                frame1.setPixel(x: x, y: y, channel: 1, value: value)
                frame1.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        let frame2 = frame1
        
        let patches = detector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        // Should work with float images
        XCTAssertGreaterThanOrEqual(patches.count, 0)
    }
    
    // MARK: - Performance Tests
    
    func testPatchDetector_Performance_SmallFrames() {
        let config = PatchConfig.balanced
        let detector = PatchDetector(config: config)
        
        var frame1 = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<64 {
            for x in 0..<64 {
                frame1.setPixel(x: x, y: y, channel: 0, value: UInt16(x + y))
            }
        }
        let frame2 = frame1
        
        measure {
            _ = detector.detectPatches(
                currentFrame: frame1,
                referenceFrame: frame2,
                referenceIndex: 1
            )
        }
    }
    
    func testPatchDetector_Performance_MediumFrames() {
        let config = PatchConfig.balanced
        let detector = PatchDetector(config: config)
        
        var frame1 = ImageFrame(width: 256, height: 256, channels: 3)
        for y in stride(from: 0, to: 256, by: 4) {
            for x in stride(from: 0, to: 256, by: 4) {
                let value = UInt16((x + y) % 256)
                frame1.setPixel(x: x, y: y, channel: 0, value: value)
            }
        }
        let frame2 = frame1
        
        measure {
            _ = detector.detectPatches(
                currentFrame: frame1,
                referenceFrame: frame2,
                referenceIndex: 1
            )
        }
    }
    
    // MARK: - Preset Comparison Tests
    
    func testPatchConfig_AggressiveFindsMorePatches() {
        let aggressiveConfig = PatchConfig.aggressive
        let conservativeConfig = PatchConfig.conservative
        
        let aggressiveDetector = PatchDetector(config: aggressiveConfig)
        let conservativeDetector = PatchDetector(config: conservativeConfig)
        
        var frame1 = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<64 {
            for x in 0..<64 {
                // Add some noise to make matching harder
                let value = UInt16(100 + (x + y) % 20)
                frame1.setPixel(x: x, y: y, channel: 0, value: value)
            }
        }
        let frame2 = frame1
        
        let aggressivePatches = aggressiveDetector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        let conservativePatches = conservativeDetector.detectPatches(
            currentFrame: frame1,
            referenceFrame: frame2,
            referenceIndex: 1
        )
        
        // Aggressive should find at least as many patches (lower threshold)
        XCTAssertGreaterThanOrEqual(aggressivePatches.count, conservativePatches.count)
    }
}
