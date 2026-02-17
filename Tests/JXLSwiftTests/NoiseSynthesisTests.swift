// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import XCTest
@testable import JXLSwift

final class NoiseSynthesisTests: XCTestCase {
    
    // MARK: - NoiseConfig Tests
    
    func testNoiseConfig_DefaultValues() {
        let config = NoiseConfig()
        
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.amplitude, 0.1, accuracy: 0.001)
        XCTAssertEqual(config.lumaStrength, 1.0, accuracy: 0.001)
        XCTAssertEqual(config.chromaStrength, 0.5, accuracy: 0.001)
        XCTAssertEqual(config.seed, 0)
    }
    
    func testNoiseConfig_CustomValues() {
        let config = NoiseConfig(
            enabled: true,
            amplitude: 0.5,
            lumaStrength: 1.2,
            chromaStrength: 0.8,
            seed: 12345
        )
        
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.amplitude, 0.5, accuracy: 0.001)
        XCTAssertEqual(config.lumaStrength, 1.2, accuracy: 0.001)
        XCTAssertEqual(config.chromaStrength, 0.8, accuracy: 0.001)
        XCTAssertEqual(config.seed, 12345)
    }
    
    func testNoiseConfig_ClampsAmplitude() {
        let configLow = NoiseConfig(amplitude: -1.0)
        XCTAssertEqual(configLow.amplitude, 0.0, accuracy: 0.001)
        
        let configHigh = NoiseConfig(amplitude: 2.0)
        XCTAssertEqual(configHigh.amplitude, 1.0, accuracy: 0.001)
    }
    
    func testNoiseConfig_ClampsLumaStrength() {
        let configLow = NoiseConfig(lumaStrength: -1.0)
        XCTAssertEqual(configLow.lumaStrength, 0.0, accuracy: 0.001)
        
        let configHigh = NoiseConfig(lumaStrength: 3.0)
        XCTAssertEqual(configHigh.lumaStrength, 2.0, accuracy: 0.001)
    }
    
    func testNoiseConfig_ClampsChromaStrength() {
        let configLow = NoiseConfig(chromaStrength: -1.0)
        XCTAssertEqual(configLow.chromaStrength, 0.0, accuracy: 0.001)
        
        let configHigh = NoiseConfig(chromaStrength: 3.0)
        XCTAssertEqual(configHigh.chromaStrength, 2.0, accuracy: 0.001)
    }
    
    func testNoiseConfig_Validation() {
        let validConfig = NoiseConfig(amplitude: 0.5)
        XCTAssertNoThrow(try validConfig.validate())
    }
    
    // MARK: - Preset Tests
    
    func testNoiseConfig_SubtlePreset() {
        let config = NoiseConfig.subtle
        
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.amplitude, 0.15, accuracy: 0.001)
        XCTAssertEqual(config.lumaStrength, 1.0, accuracy: 0.001)
        XCTAssertEqual(config.chromaStrength, 0.4, accuracy: 0.001)
    }
    
    func testNoiseConfig_ModeratePreset() {
        let config = NoiseConfig.moderate
        
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.amplitude, 0.35, accuracy: 0.001)
        XCTAssertEqual(config.lumaStrength, 1.0, accuracy: 0.001)
        XCTAssertEqual(config.chromaStrength, 0.5, accuracy: 0.001)
    }
    
    func testNoiseConfig_HeavyPreset() {
        let config = NoiseConfig.heavy
        
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.amplitude, 0.65, accuracy: 0.001)
        XCTAssertEqual(config.lumaStrength, 1.2, accuracy: 0.001)
        XCTAssertEqual(config.chromaStrength, 0.6, accuracy: 0.001)
    }
    
    func testNoiseConfig_FilmGrainPreset() {
        let config = NoiseConfig.filmGrain
        
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.amplitude, 0.45, accuracy: 0.001)
        XCTAssertEqual(config.lumaStrength, 1.1, accuracy: 0.001)
        XCTAssertEqual(config.chromaStrength, 0.7, accuracy: 0.001)
    }
    
    // MARK: - NoiseGenerator Tests
    
    func testNoiseGenerator_DeterministicWithSeed() {
        var gen1 = NoiseGenerator(seed: 12345)
        var gen2 = NoiseGenerator(seed: 12345)
        
        let value1 = gen1.nextFloat()
        let value2 = gen2.nextFloat()
        
        XCTAssertEqual(value1, value2, accuracy: 0.0001)
    }
    
    func testNoiseGenerator_NextFloat_InRange() {
        var gen = NoiseGenerator(seed: 12345)
        
        for _ in 0..<100 {
            let value = gen.nextFloat()
            XCTAssertGreaterThanOrEqual(value, 0.0)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
    }
    
    func testNoiseGenerator_NextFloatSymmetric_InRange() {
        var gen = NoiseGenerator(seed: 12345)
        
        for _ in 0..<100 {
            let value = gen.nextFloatSymmetric()
            XCTAssertGreaterThanOrEqual(value, -1.0)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
    }
    
    func testNoiseGenerator_NextGaussian() {
        var gen = NoiseGenerator(seed: 12345)
        
        var sum = 0.0
        var sumSquares = 0.0
        let count = 10000
        
        for _ in 0..<count {
            let value = Double(gen.nextGaussian(sigma: 1.0))
            sum += value
            sumSquares += value * value
        }
        
        let mean = sum / Double(count)
        let variance = sumSquares / Double(count) - mean * mean
        let stdDev = sqrt(variance)
        
        // Mean should be close to 0
        XCTAssertEqual(mean, 0.0, accuracy: 0.05)
        
        // Std dev should be close to 1.0
        XCTAssertEqual(stdDev, 1.0, accuracy: 0.1)
    }
    
    func testNoiseGenerator_UniqueSequences() {
        var gen1 = NoiseGenerator(seed: 111)
        var gen2 = NoiseGenerator(seed: 222)
        
        let value1 = gen1.nextFloat()
        let value2 = gen2.nextFloat()
        
        XCTAssertNotEqual(value1, value2)
    }
    
    // MARK: - NoiseSynthesizer Tests
    
    func testNoiseSynthesizer_DisabledConfig() {
        let config = NoiseConfig(enabled: false)
        var synthesizer = NoiseSynthesizer(config: config)
        
        let originalValue: Float = 128.0
        let noisyValue = synthesizer.applyNoise(value: originalValue, maxValue: 255.0, isLuma: true)
        
        XCTAssertEqual(noisyValue, originalValue)
    }
    
    func testNoiseSynthesizer_ZeroAmplitude() {
        let config = NoiseConfig(enabled: true, amplitude: 0.0)
        var synthesizer = NoiseSynthesizer(config: config)
        
        let originalValue: Float = 128.0
        let noisyValue = synthesizer.applyNoise(value: originalValue, maxValue: 255.0, isLuma: true)
        
        XCTAssertEqual(noisyValue, originalValue)
    }
    
    func testNoiseSynthesizer_AppliesNoise() {
        let config = NoiseConfig(enabled: true, amplitude: 0.5, seed: 12345)
        var synthesizer = NoiseSynthesizer(config: config)
        
        let originalValue: Float = 128.0
        let noisyValue = synthesizer.applyNoise(value: originalValue, maxValue: 255.0, isLuma: true)
        
        // Value should be different from original (with high probability)
        XCTAssertNotEqual(noisyValue, originalValue)
        
        // Value should be clamped to valid range
        XCTAssertGreaterThanOrEqual(noisyValue, 0.0)
        XCTAssertLessThanOrEqual(noisyValue, 255.0)
    }
    
    func testNoiseSynthesizer_LumaVsChroma() {
        let config = NoiseConfig(
            enabled: true,
            amplitude: 0.5,
            lumaStrength: 1.0,
            chromaStrength: 0.5,
            seed: 12345
        )
        
        var synthLuma = NoiseSynthesizer(config: config)
        var synthChroma = NoiseSynthesizer(config: config)
        
        let originalValue: Float = 128.0
        let noisyLuma = synthLuma.applyNoise(value: originalValue, maxValue: 255.0, isLuma: true)
        let noisyChroma = synthChroma.applyNoise(value: originalValue, maxValue: 255.0, isLuma: false)
        
        // Both should be different from original
        XCTAssertNotEqual(noisyLuma, originalValue)
        XCTAssertNotEqual(noisyChroma, originalValue)
        
        // With same seed, both should produce same initial noise pattern
        // but scaled differently (tested implicitly by different strength multipliers)
    }
    
    func testNoiseSynthesizer_ApplyNoiseToArray() {
        let config = NoiseConfig(enabled: true, amplitude: 0.3, seed: 12345)
        var synthesizer = NoiseSynthesizer(config: config)
        
        var values: [Float] = [100.0, 128.0, 150.0, 200.0]
        let originalValues = values
        
        synthesizer.applyNoise(values: &values, maxValue: 255.0, isLuma: true)
        
        // At least some values should change
        var changedCount = 0
        for i in 0..<values.count {
            if values[i] != originalValues[i] {
                changedCount += 1
            }
            // All values should be in valid range
            XCTAssertGreaterThanOrEqual(values[i], 0.0)
            XCTAssertLessThanOrEqual(values[i], 255.0)
        }
        
        XCTAssertGreaterThan(changedCount, 0)
    }
    
    func testNoiseSynthesizer_ApplyNoiseToCoefficients() {
        let config = NoiseConfig(enabled: true, amplitude: 0.5, seed: 12345)
        var synthesizer = NoiseSynthesizer(config: config)
        
        var coefficients: [Float] = Array(repeating: 10.0, count: 64)
        let originalCoefficients = coefficients
        
        synthesizer.applyNoiseToCoefficients(coefficients: &coefficients, isLuma: true)
        
        // At least some coefficients should change
        var changedCount = 0
        for i in 0..<coefficients.count {
            if coefficients[i] != originalCoefficients[i] {
                changedCount += 1
            }
        }
        
        XCTAssertGreaterThan(changedCount, 0)
    }
    
    func testNoiseSynthesizer_ClampsToBounds() {
        let config = NoiseConfig(enabled: true, amplitude: 1.0, seed: 12345)
        var synthesizer = NoiseSynthesizer(config: config)
        
        // Test near boundaries
        let nearZero = synthesizer.applyNoise(value: 0.0, maxValue: 255.0, isLuma: true)
        XCTAssertGreaterThanOrEqual(nearZero, 0.0)
        
        let nearMax = synthesizer.applyNoise(value: 255.0, maxValue: 255.0, isLuma: true)
        XCTAssertLessThanOrEqual(nearMax, 255.0)
    }
    
    // MARK: - Integration with EncodingOptions Tests
    
    func testEncodingOptions_WithNoiseConfig() {
        let noiseConfig = NoiseConfig.moderate
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            noiseConfig: noiseConfig
        )
        
        XCTAssertNotNil(options.noiseConfig)
        if let amplitude = options.noiseConfig?.amplitude {
            XCTAssertEqual(amplitude, 0.35, accuracy: 0.001)
        } else {
            XCTFail("noiseConfig amplitude should not be nil")
        }
    }
    
    func testEncodingOptions_WithoutNoiseConfig() {
        let options = EncodingOptions(mode: .lossy(quality: 90))
        
        XCTAssertNil(options.noiseConfig)
    }
    
    // MARK: - Encoding Tests
    
    func testEncoding_WithNoiseSynthesis_Lossless() throws {
        // Create a simple test image
        var frame = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 4))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 4))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let noiseConfig = NoiseConfig.subtle
        let options = EncodingOptions(
            mode: .lossless,
            noiseConfig: noiseConfig
        )
        
        let encoder = JXLEncoder(options: options)
        
        // Noise synthesis should work even with lossless mode
        // (though it will be applied in spatial domain if using Modular mode)
        XCTAssertNoThrow(try encoder.encode(frame))
    }
    
    func testEncoding_WithNoiseSynthesis_Lossy() throws {
        // Create a simple test image
        var frame = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 4))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 4))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let noiseConfig = NoiseConfig.moderate
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            noiseConfig: noiseConfig
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.stats.compressionRatio, 1.0)
    }
    
    func testEncoding_CompareWithAndWithoutNoise() throws {
        // Create identical test images
        var frame1 = ImageFrame(width: 64, height: 64, channels: 3)
        var frame2 = ImageFrame(width: 64, height: 64, channels: 3)
        
        for y in 0..<64 {
            for x in 0..<64 {
                let value = UInt16((x + y) * 2)
                for channel in 0..<3 {
                    frame1.setPixel(x: x, y: y, channel: channel, value: value)
                    frame2.setPixel(x: x, y: y, channel: channel, value: value)
                }
            }
        }
        
        // Encode without noise
        let optionsNoNoise = EncodingOptions(mode: .lossy(quality: 85))
        let encoderNoNoise = JXLEncoder(options: optionsNoNoise)
        let resultNoNoise = try encoderNoNoise.encode(frame1)
        
        // Encode with noise
        let optionsWithNoise = EncodingOptions(
            mode: .lossy(quality: 85),
            noiseConfig: NoiseConfig.moderate
        )
        let encoderWithNoise = JXLEncoder(options: optionsWithNoise)
        let resultWithNoise = try encoderWithNoise.encode(frame2)
        
        // Both should produce valid output
        XCTAssertGreaterThan(resultNoNoise.data.count, 0)
        XCTAssertGreaterThan(resultWithNoise.data.count, 0)
        
        // File sizes may differ slightly due to noise
        // (not asserting specific size relationship as it depends on noise pattern)
    }
    
    func testEncoding_DifferentNoisePresets() throws {
        var frame = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: 128)
                frame.setPixel(x: x, y: y, channel: 1, value: 128)
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let presets: [NoiseConfig] = [.subtle, .moderate, .heavy, .filmGrain]
        
        for preset in presets {
            let options = EncodingOptions(
                mode: .lossy(quality: 85),
                noiseConfig: preset
            )
            let encoder = JXLEncoder(options: options)
            
            XCTAssertNoThrow(try encoder.encode(frame), "Failed with preset amplitude: \(preset.amplitude)")
        }
    }
    
    func testEncoding_WithProgressive_AndNoise() throws {
        var frame = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 4))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 4))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            progressive: true,
            noiseConfig: NoiseConfig.moderate
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testEncoding_WithANS_AndNoise() throws {
        var frame = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 4))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 4))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            useANS: true,
            noiseConfig: NoiseConfig.moderate
        )
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0)
    }
}
