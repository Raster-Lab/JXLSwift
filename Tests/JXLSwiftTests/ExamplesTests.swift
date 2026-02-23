/// Tests verifying that the Examples/ code compiles and produces reasonable
/// output when invoked programmatically.  Each test mirrors the logic in the
/// corresponding example file so that CI catches API changes early.

import XCTest
@testable import JXLSwift

final class ExamplesTests: XCTestCase {

    // MARK: - BasicEncoding example

    func testBasicEncoding_ProducesCompressedOutput() throws {
        var frame = ImageFrame(width: 64, height: 64, channels: 3,
                               pixelType: .uint8, colorSpace: .sRGB)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0,
                               value: UInt16((x * 255) / (frame.width - 1)))
                frame.setPixel(x: x, y: y, channel: 1,
                               value: UInt16((y * 255) / (frame.height - 1)))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        let result = try JXLEncoder().encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.stats.compressionRatio, 0)
    }

    // MARK: - LosslessEncoding example

    func testLosslessEncoding_RoundTripIsExact() throws {
        var frame = ImageFrame(width: 32, height: 32, channels: 3,
                               pixelType: .uint8, colorSpace: .sRGB)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let v = UInt16((x + y) % 256)
                frame.setPixel(x: x, y: y, channel: 0, value: v)
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(255 - v))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        let encoded = try JXLEncoder(options: .lossless).encode(frame)
        let decoded = try JXLDecoder().decode(encoded.data)

        for y in 0..<frame.height {
            for x in 0..<frame.width {
                for c in 0..<frame.channels {
                    XCTAssertEqual(
                        frame.getPixel(x: x, y: y, channel: c),
                        decoded.getPixel(x: x, y: y, channel: c),
                        "Pixel mismatch at (\(x),\(y)) channel \(c)"
                    )
                }
            }
        }
    }

    // MARK: - LossyEncoding example

    func testLossyEncoding_MultipleQualityLevels() throws {
        var frame = ImageFrame(width: 32, height: 32, channels: 3,
                               pixelType: .uint8, colorSpace: .sRGB)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 8))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 8))
                frame.setPixel(x: x, y: y, channel: 2, value: 100)
            }
        }

        for quality: Float in [50, 75, 90] {
            let options = EncodingOptions(mode: .lossy(quality: quality))
            let result = try JXLEncoder(options: options).encode(frame)
            XCTAssertGreaterThan(result.stats.compressedSize, 0,
                                 "quality=\(quality) produced empty output")
        }
    }

    // MARK: - DecodingExample

    func testDecoding_RoundTrip_ProducesExpectedDimensions() throws {
        let frame = ImageFrame(width: 16, height: 16, channels: 3,
                               pixelType: .uint8, colorSpace: .sRGB)
        let encoded = try JXLEncoder(options: .lossless).encode(frame)
        let decoded = try JXLDecoder().decode(encoded.data)

        XCTAssertEqual(decoded.width, 16)
        XCTAssertEqual(decoded.height, 16)
        XCTAssertEqual(decoded.channels, 3)
    }

    func testDecoding_ParseImageHeader_ReturnsCorrectDimensions() throws {
        let frame = ImageFrame(width: 24, height: 16, channels: 3,
                               pixelType: .uint8, colorSpace: .sRGB)
        let encoded = try JXLEncoder(options: .lossless).encode(frame)
        let decoder = JXLDecoder()
        let codestream = try decoder.extractCodestream(encoded.data)
        let header = try decoder.parseImageHeader(codestream)

        XCTAssertEqual(Int(header.width), 24)
        XCTAssertEqual(Int(header.height), 16)
    }

    // MARK: - AlphaChannelExample

    func testAlphaChannel_StraightAlpha_LosslessRoundTrip() throws {
        var frame = ImageFrame(width: 16, height: 16, channels: 4,
                               pixelType: .uint8, colorSpace: .sRGB,
                               hasAlpha: true, alphaMode: .straight)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 3, value: UInt16(x * 16))
            }
        }
        let encoded = try JXLEncoder(options: .lossless).encode(frame)
        let decoded = try JXLDecoder().decode(encoded.data)

        XCTAssertEqual(decoded.getPixel(x: 0,  y: 0,  channel: 3), 0)
        XCTAssertEqual(decoded.getPixel(x: 15, y: 0,  channel: 3), 240)
    }

    // MARK: - ExtraChannelsExample

    func testExtraChannels_EncodeAndRead() throws {
        var frame = ImageFrame(
            width: 16, height: 16, channels: 3,
            pixelType: .uint16, colorSpace: .sRGB,
            extraChannels: [ExtraChannelInfo.depth(bitsPerSample: 16)]
        )
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 4000))
                frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 0,
                                           value: UInt16(y * 4000))
            }
        }
        let depth = frame.getExtraChannelValue(x: 0, y: 8, extraChannelIndex: 0)
        XCTAssertEqual(depth, UInt16(8 * 4000))
    }

    // MARK: - HDRExample

    func testHDR_Rec2020PQ_ProducesOutput() throws {
        var frame = ImageFrame(width: 16, height: 16, channels: 3,
                               pixelType: .float32, colorSpace: .rec2020PQ)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixelFloat(x: x, y: y, channel: 0,
                                    value: Float(x) / Float(frame.width - 1))
                frame.setPixelFloat(x: x, y: y, channel: 1,
                                    value: Float(y) / Float(frame.height - 1))
                frame.setPixelFloat(x: x, y: y, channel: 2, value: 0.5)
            }
        }
        let result = try JXLEncoder().encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }

    // MARK: - ROIExample

    func testROI_Encoding_ProducesOutput() throws {
        var frame = ImageFrame(width: 64, height: 64, channels: 3,
                               pixelType: .uint8, colorSpace: .sRGB)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 4))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 4))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        let roi = RegionOfInterest(x: 16, y: 16, width: 32, height: 32,
                                   qualityBoost: 10.0, featherWidth: 4)
        let options = EncodingOptions(mode: .lossy(quality: 75),
                                      regionOfInterest: roi)
        let result = try JXLEncoder(options: options).encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }

    // MARK: - NoiseSynthesisExample

    func testNoiseSynthesis_Encoding_ProducesOutput() throws {
        var frame = ImageFrame(width: 32, height: 32, channels: 3,
                               pixelType: .uint8, colorSpace: .sRGB)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let v = UInt16((x + y) * 4)
                frame.setPixel(x: x, y: y, channel: 0, value: v)
                frame.setPixel(x: x, y: y, channel: 1, value: v)
                frame.setPixel(x: x, y: y, channel: 2, value: v)
            }
        }
        let noiseConfig = NoiseConfig(enabled: true, amplitude: 0.03,
                                      lumaStrength: 0.8, chromaStrength: 0.3,
                                      seed: 42)
        let options = EncodingOptions(mode: .lossy(quality: 80),
                                      noiseConfig: noiseConfig)
        let result = try JXLEncoder(options: options).encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }

    // MARK: - SplineEncodingExample

    func testSplineEncoding_ProducesOutput() throws {
        var frame = ImageFrame(width: 32, height: 32, channels: 3,
                               pixelType: .uint8, colorSpace: .sRGB)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: 255)
                frame.setPixel(x: x, y: y, channel: 1, value: 255)
                frame.setPixel(x: x, y: y, channel: 2, value: 255)
            }
        }
        let splineConfig = SplineConfig(enabled: true,
                                        quantizationAdjustment: 0,
                                        minControlPointDistance: 4,
                                        maxSplinesPerFrame: 10,
                                        edgeThreshold: 0.1,
                                        minEdgeLength: 3)
        let options = EncodingOptions(mode: .lossy(quality: 90),
                                      splineConfig: splineConfig)
        let result = try JXLEncoder(options: options).encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }

    // MARK: - HardwareDetectionExample

    func testHardwareDetection_ReturnsPositiveCoreCount() {
        let caps = HardwareCapabilities.detect()
        XCTAssertGreaterThan(caps.coreCount, 0)
    }

    func testHardwareDetection_CPUArchitectureKnown() {
        XCTAssertNotEqual(CPUArchitecture.current, .unknown)
    }

    // MARK: - DICOMWorkflowExample

    func testDICOM_MedicalSigned16bit_LosslessRoundTrip() throws {
        var frame = ImageFrame.medicalSigned16bit(width: 32, height: 32)
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixelSigned(x: x, y: y, channel: 0,
                                     value: Int16(-500 + x * 30))
            }
        }
        XCTAssertNoThrow(try MedicalImageValidator.validate(frame))

        let encoded = try JXLEncoder(options: .medicalLossless).encode(frame)
        let decoded = try JXLDecoder().decode(encoded.data)

        let original = frame.getPixelSigned(x: 10, y: 10, channel: 0)
        let restored = decoded.getPixelSigned(x: 10, y: 10, channel: 0)
        XCTAssertEqual(original, restored)
    }

    // MARK: - BatchProcessingExample

    func testBatchProcessing_MultipleImagesEncoded() throws {
        let sizes = [(16, 16), (32, 32), (24, 24)]
        let encoder = JXLEncoder(options: .fast)

        for (w, h) in sizes {
            var frame = ImageFrame(width: w, height: h, channels: 3,
                                   pixelType: .uint8, colorSpace: .sRGB)
            for y in 0..<h {
                for x in 0..<w {
                    frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x))
                    frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y))
                    frame.setPixel(x: x, y: y, channel: 2, value: 128)
                }
            }
            let result = try encoder.encode(frame)
            XCTAssertGreaterThan(result.data.count, 0,
                                 "Empty output for \(w)×\(h) image")
        }
    }

    // MARK: - BenchmarkingExample

    func testBenchmarking_QualityMetrics_PSNRPositive() throws {
        var original = ImageFrame(width: 32, height: 32, channels: 3,
                                  pixelType: .uint8, colorSpace: .sRGB)
        for y in 0..<32 {
            for x in 0..<32 {
                original.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 8))
                original.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 8))
                original.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        let encoded = try JXLEncoder(options: .highQuality).encode(original)
        let decoded = try JXLDecoder().decode(encoded.data)
        let metrics = try QualityMetrics.compare(original: original,
                                                  reconstructed: decoded)
        XCTAssertGreaterThan(metrics.psnr, 20.0)
        XCTAssertGreaterThan(metrics.ssim, 0.5)
    }

    // MARK: - AnimationExample

    func testAnimationEncoding_MultipleFrames_ProducesOutput() throws {
        var frames: [ImageFrame] = []
        for i in 0..<3 {
            var f = ImageFrame(width: 16, height: 16, channels: 3,
                               pixelType: .uint8, colorSpace: .sRGB)
            for y in 0..<16 {
                for x in 0..<16 {
                    f.setPixel(x: x, y: y, channel: 0, value: UInt16(i * 80))
                    f.setPixel(x: x, y: y, channel: 1, value: UInt16(x * 16))
                    f.setPixel(x: x, y: y, channel: 2, value: UInt16(y * 16))
                }
            }
            frames.append(f)
        }
        let options = EncodingOptions(mode: .lossy(quality: 85),
                                      animationConfig: .fps30)
        let result = try JXLEncoder(options: options).encode(frames)
        XCTAssertGreaterThan(result.data.count, 0)
    }

    // MARK: - PatchEncodingExample

    func testPatchEncoding_ScreenContent_ProducesOutput() throws {
        let w = 32, h = 32
        var frames: [ImageFrame] = []
        for i in 0..<4 {
            var f = ImageFrame(width: w, height: h, channels: 3,
                               pixelType: .uint8, colorSpace: .sRGB)
            for y in 0..<h {
                for x in 0..<w {
                    f.setPixel(x: x, y: y, channel: 0, value: 128)
                    f.setPixel(x: x, y: y, channel: 1, value: 128)
                    f.setPixel(x: x, y: y, channel: 2, value: 128)
                }
            }
            // Moving pixel
            let px = i * 4
            if px < w {
                f.setPixel(x: px, y: 8, channel: 0, value: 255)
            }
            frames.append(f)
        }
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            animationConfig: .fps30,
            referenceFrameConfig: .balanced,
            patchConfig: .screenContent
        )
        let result = try JXLEncoder(options: options).encode(frames)
        XCTAssertGreaterThan(result.data.count, 0)
    }
}
