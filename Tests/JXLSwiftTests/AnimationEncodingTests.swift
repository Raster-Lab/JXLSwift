/// Tests for multi-frame animation encoding
///
/// Validates JPEG XL animation encoding with multiple frames, frame timing,
/// loop counts, and various frame rates.

import XCTest
@testable import JXLSwift

final class AnimationEncodingTests: XCTestCase {
    
    // MARK: - AnimationConfig Tests
    
    func testAnimationConfig_DefaultInit() {
        let config = AnimationConfig()
        XCTAssertEqual(config.fps, 30)
        XCTAssertEqual(config.tpsDenominator, 1)
        XCTAssertEqual(config.loopCount, 0)
        XCTAssertTrue(config.frameDurations.isEmpty)
    }
    
    func testAnimationConfig_CustomInit() {
        let config = AnimationConfig(
            fps: 24,
            tpsDenominator: 1,
            loopCount: 5,
            frameDurations: [100, 200, 150]
        )
        XCTAssertEqual(config.fps, 24)
        XCTAssertEqual(config.tpsDenominator, 1)
        XCTAssertEqual(config.loopCount, 5)
        XCTAssertEqual(config.frameDurations.count, 3)
    }
    
    func testAnimationConfig_DurationForFrame_Uniform() {
        let config = AnimationConfig(fps: 30)
        // Default: 1000ms / 30fps = 33 ticks (integer division)
        XCTAssertEqual(config.duration(for: 0), 33)
        XCTAssertEqual(config.duration(for: 5), 33)
        XCTAssertEqual(config.duration(for: 100), 33)
    }
    
    func testAnimationConfig_DurationForFrame_ZeroFPS_ReturnsDefault() {
        let config = AnimationConfig(fps: 0)
        // Should return 1000 ticks to avoid division by zero
        XCTAssertEqual(config.duration(for: 0), 1000)
    }
    
    func testAnimationConfig_DurationForFrame_Custom() {
        let config = AnimationConfig(
            fps: 30,
            frameDurations: [50, 100, 75, 200]
        )
        XCTAssertEqual(config.duration(for: 0), 50)
        XCTAssertEqual(config.duration(for: 1), 100)
        XCTAssertEqual(config.duration(for: 2), 75)
        XCTAssertEqual(config.duration(for: 3), 200)
        // Out of range falls back to uniform
        XCTAssertEqual(config.duration(for: 4), 33)
    }
    
    func testAnimationConfig_Presets() {
        XCTAssertEqual(AnimationConfig.fps30.fps, 30)
        XCTAssertEqual(AnimationConfig.fps24.fps, 24)
        XCTAssertEqual(AnimationConfig.fps60.fps, 60)
        XCTAssertEqual(AnimationConfig.fps30.loopCount, 0) // infinite
    }
    
    // MARK: - Single Frame Tests
    
    func testEncode_SingleFrame_UsesStandardEncoder() throws {
        let frame = ImageFrame(width: 64, height: 64, channels: 3)
        let encoder = JXLEncoder(options: EncodingOptions())
        
        let result = try encoder.encode([frame])
        
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.stats.originalSize, 0)
        XCTAssertGreaterThan(result.stats.compressedSize, 0)
    }
    
    // MARK: - Multi-Frame Encoding Tests
    
    func testEncode_TwoFrames_ProducesValidOutput() throws {
        let frame1 = ImageFrame(width: 32, height: 32, channels: 3)
        let frame2 = ImageFrame(width: 32, height: 32, channels: 3)
        
        let animConfig = AnimationConfig.fps30
        let options = EncodingOptions(animationConfig: animConfig)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode([frame1, frame2])
        
        XCTAssertGreaterThan(result.data.count, 0)
        
        // Check JPEG XL signature
        XCTAssertGreaterThanOrEqual(result.data.count, 2)
        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0x0A)
        
        // Stats should reflect both frames
        XCTAssertEqual(result.stats.originalSize, frame1.data.count + frame2.data.count)
    }
    
    func testEncode_TenFrames_SuccessfullyEncodes() throws {
        var frames: [ImageFrame] = []
        for i in 0..<10 {
            var frame = ImageFrame(width: 16, height: 16, channels: 3)
            // Add some variation to each frame
            for y in 0..<16 {
                for x in 0..<16 {
                    frame.setPixel(x: x, y: y, channel: 0, value: UInt16(i * 25))
                }
            }
            frames.append(frame)
        }
        
        let animConfig = AnimationConfig.fps24
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            animationConfig: animConfig
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frames)
        
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0x0A)
        
        // Compression should work across frames
        XCTAssertGreaterThan(result.stats.compressionRatio, 1.0)
    }
    
    func testEncode_CustomFrameDurations() throws {
        let frame1 = ImageFrame(width: 16, height: 16, channels: 3)
        let frame2 = ImageFrame(width: 16, height: 16, channels: 3)
        let frame3 = ImageFrame(width: 16, height: 16, channels: 3)
        
        // Different durations for each frame
        let animConfig = AnimationConfig(
            fps: 30,
            frameDurations: [50, 100, 200]
        )
        let options = EncodingOptions(animationConfig: animConfig)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode([frame1, frame2, frame3])
        
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0x0A)
    }
    
    func testEncode_InfiniteLoop() throws {
        let frame1 = ImageFrame(width: 16, height: 16, channels: 3)
        let frame2 = ImageFrame(width: 16, height: 16, channels: 3)
        
        let animConfig = AnimationConfig(fps: 30, loopCount: 0)
        let options = EncodingOptions(animationConfig: animConfig)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode([frame1, frame2])
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testEncode_FiniteLoopCount() throws {
        let frame1 = ImageFrame(width: 16, height: 16, channels: 3)
        let frame2 = ImageFrame(width: 16, height: 16, channels: 3)
        
        let animConfig = AnimationConfig(fps: 30, loopCount: 3)
        let options = EncodingOptions(animationConfig: animConfig)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode([frame1, frame2])
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Different Frame Rates
    
    func testEncode_24FPS() throws {
        let frames = [
            ImageFrame(width: 16, height: 16, channels: 3),
            ImageFrame(width: 16, height: 16, channels: 3)
        ]
        
        let animConfig = AnimationConfig.fps24
        let options = EncodingOptions(animationConfig: animConfig)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frames)
        
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertEqual(result.data[0], 0xFF)
    }
    
    func testEncode_60FPS() throws {
        let frames = [
            ImageFrame(width: 16, height: 16, channels: 3),
            ImageFrame(width: 16, height: 16, channels: 3),
            ImageFrame(width: 16, height: 16, channels: 3)
        ]
        
        let animConfig = AnimationConfig.fps60
        let options = EncodingOptions(animationConfig: animConfig)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frames)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Lossless Animation
    
    func testEncode_LosslessAnimation() throws {
        let frames = [
            ImageFrame(width: 16, height: 16, channels: 3),
            ImageFrame(width: 16, height: 16, channels: 3)
        ]
        
        let animConfig = AnimationConfig.fps30
        let options = EncodingOptions(
            mode: .lossless,
            animationConfig: animConfig
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frames)
        
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertEqual(result.data[0], 0xFF)
    }
    
    // MARK: - Alpha Channel Animation
    
    func testEncode_AnimationWithAlpha() throws {
        let frame1 = ImageFrame(
            width: 16, height: 16, channels: 4,
            hasAlpha: true
        )
        let frame2 = ImageFrame(
            width: 16, height: 16, channels: 4,
            hasAlpha: true
        )
        
        let animConfig = AnimationConfig.fps30
        let options = EncodingOptions(animationConfig: animConfig)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode([frame1, frame2])
        
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertEqual(result.data[0], 0xFF)
    }
    
    // MARK: - Progressive Animation
    
    func testEncode_ProgressiveAnimation() throws {
        let frames = [
            ImageFrame(width: 32, height: 32, channels: 3),
            ImageFrame(width: 32, height: 32, channels: 3)
        ]
        
        let animConfig = AnimationConfig.fps30
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            progressive: true,
            animationConfig: animConfig
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frames)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Error Cases
    
    func testEncode_EmptyFrames_ThrowsError() {
        let frames: [ImageFrame] = []
        let animConfig = AnimationConfig.fps30
        let options = EncodingOptions(animationConfig: animConfig)
        let encoder = JXLEncoder(options: options)
        
        XCTAssertThrowsError(try encoder.encode(frames)) { error in
            XCTAssertTrue(error is EncoderError)
        }
    }
    
    func testEncode_MultiFrameWithoutConfig_ThrowsError() {
        let frames = [
            ImageFrame(width: 16, height: 16, channels: 3),
            ImageFrame(width: 16, height: 16, channels: 3)
        ]
        
        // No animation config
        let options = EncodingOptions()
        let encoder = JXLEncoder(options: options)
        
        XCTAssertThrowsError(try encoder.encode(frames)) { error in
            guard let encError = error as? EncoderError else {
                XCTFail("Expected EncoderError")
                return
            }
            if case .encodingFailed(let message) = encError {
                XCTAssertTrue(message.contains("Animation configuration required"))
            } else {
                XCTFail("Expected encodingFailed error")
            }
        }
    }
    
    func testEncode_InconsistentDimensions_ThrowsError() {
        let frame1 = ImageFrame(width: 16, height: 16, channels: 3)
        let frame2 = ImageFrame(width: 32, height: 32, channels: 3)
        
        let animConfig = AnimationConfig.fps30
        let options = EncodingOptions(animationConfig: animConfig)
        let encoder = JXLEncoder(options: options)
        
        XCTAssertThrowsError(try encoder.encode([frame1, frame2])) { error in
            guard let encError = error as? EncoderError else {
                XCTFail("Expected EncoderError")
                return
            }
            if case .encodingFailed(let message) = encError {
                XCTAssertTrue(message.contains("dimensions"))
            } else {
                XCTFail("Expected encodingFailed error")
            }
        }
    }
    
    func testEncode_InvalidFrameDimensions_ThrowsError() {
        let frame1 = ImageFrame(width: 0, height: 16, channels: 3)
        let frame2 = ImageFrame(width: 16, height: 16, channels: 3)
        
        let animConfig = AnimationConfig.fps30
        let options = EncodingOptions(animationConfig: animConfig)
        let encoder = JXLEncoder(options: options)
        
        XCTAssertThrowsError(try encoder.encode([frame1, frame2])) { error in
            XCTAssertTrue(error is EncoderError)
        }
    }
    
    // MARK: - Performance Tests
    
    func testEncode_ManyFrames_ReasonablePerformance() throws {
        var frames: [ImageFrame] = []
        for _ in 0..<30 {
            frames.append(ImageFrame(width: 32, height: 32, channels: 3))
        }
        
        let animConfig = AnimationConfig.fps30
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            effort: .falcon,
            animationConfig: animConfig
        )
        let encoder = JXLEncoder(options: options)
        
        measure {
            _ = try? encoder.encode(frames)
        }
    }
    
    // MARK: - Different Pixel Types
    
    func testEncode_16BitAnimation() throws {
        let frames = [
            ImageFrame(
                width: 16, height: 16, channels: 3,
                pixelType: .uint16,
                bitsPerSample: 16
            ),
            ImageFrame(
                width: 16, height: 16, channels: 3,
                pixelType: .uint16,
                bitsPerSample: 16
            )
        ]
        
        let animConfig = AnimationConfig.fps30
        let options = EncodingOptions(animationConfig: animConfig)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frames)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testEncode_Float32Animation() throws {
        let frames = [
            ImageFrame(
                width: 16, height: 16, channels: 3,
                pixelType: .float32
            ),
            ImageFrame(
                width: 16, height: 16, channels: 3,
                pixelType: .float32
            )
        ]
        
        let animConfig = AnimationConfig.fps30
        let options = EncodingOptions(animationConfig: animConfig)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frames)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Compression Ratio Tests
    
    func testEncode_Animation_CompressionRatio() throws {
        var frames: [ImageFrame] = []
        
        // Create frames with some similarity for compression
        for i in 0..<5 {
            var frame = ImageFrame(width: 64, height: 64, channels: 3)
            // Fill with gradient
            for y in 0..<64 {
                for x in 0..<64 {
                    let value = UInt16((x + y + i * 10) % 256)
                    frame.setPixel(x: x, y: y, channel: 0, value: value)
                    frame.setPixel(x: x, y: y, channel: 1, value: value)
                    frame.setPixel(x: x, y: y, channel: 2, value: value)
                }
            }
            frames.append(frame)
        }
        
        let animConfig = AnimationConfig.fps30
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            animationConfig: animConfig
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frames)
        
        XCTAssertGreaterThan(result.stats.compressionRatio, 1.0)
    }
}
