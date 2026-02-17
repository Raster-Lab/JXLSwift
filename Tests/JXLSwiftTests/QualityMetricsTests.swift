// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import XCTest
@testable import JXLSwift

final class QualityMetricsTests: XCTestCase {

    // MARK: - Helper

    /// Create a simple test frame filled with a gradient pattern.
    private func makeGradientFrame(width: Int = 32, height: Int = 32, channels: Int = 3) -> ImageFrame {
        var frame = ImageFrame(
            width: width,
            height: height,
            channels: channels,
            pixelType: .uint8,
            colorSpace: channels == 1 ? .grayscale : .sRGB
        )
        for y in 0..<height {
            for x in 0..<width {
                let r = UInt16((x * 255) / max(width - 1, 1))
                let g = UInt16((y * 255) / max(height - 1, 1))
                let b = UInt16(((x + y) * 255) / max(width + height - 2, 1))
                frame.setPixel(x: x, y: y, channel: 0, value: r)
                if channels >= 3 {
                    frame.setPixel(x: x, y: y, channel: 1, value: g)
                    frame.setPixel(x: x, y: y, channel: 2, value: b)
                }
            }
        }
        return frame
    }

    /// Create a copy with controlled noise added.
    private func addNoise(to frame: ImageFrame, amount: Int) -> ImageFrame {
        var noisy = ImageFrame(
            width: frame.width,
            height: frame.height,
            channels: frame.channels,
            pixelType: frame.pixelType,
            colorSpace: frame.colorSpace
        )
        var rng: UInt64 = 12345
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                for c in 0..<frame.channels {
                    let orig = Int(frame.getPixel(x: x, y: y, channel: c))
                    // Deterministic pseudo-random noise
                    rng ^= rng >> 12
                    rng ^= rng << 25
                    rng ^= rng >> 27
                    let noise = Int(rng % UInt64(amount * 2 + 1)) - amount
                    let clamped = max(0, min(255, orig + noise))
                    noisy.setPixel(x: x, y: y, channel: c, value: UInt16(clamped))
                }
            }
        }
        return noisy
    }

    // MARK: - PSNR Tests

    func testPSNR_IdenticalFrames_ReturnsInfinity() throws {
        let frame = makeGradientFrame()
        let psnr = try QualityMetrics.psnr(original: frame, reconstructed: frame)
        XCTAssertTrue(psnr.isInfinite, "PSNR of identical frames should be infinity")
    }

    func testPSNR_SlightlyDifferentFrames_ReturnsHighValue() throws {
        let frame = makeGradientFrame()
        let noisy = addNoise(to: frame, amount: 2)
        let psnr = try QualityMetrics.psnr(original: frame, reconstructed: noisy)
        XCTAssertGreaterThan(psnr, 30.0, "PSNR with small noise should be > 30 dB")
        XCTAssertLessThan(psnr, 70.0, "PSNR with small noise should be finite")
    }

    func testPSNR_LargeNoise_ReturnsLowValue() throws {
        let frame = makeGradientFrame()
        let noisy = addNoise(to: frame, amount: 50)
        let psnr = try QualityMetrics.psnr(original: frame, reconstructed: noisy)
        XCTAssertGreaterThan(psnr, 10.0, "PSNR should be positive even with large noise")
        XCTAssertLessThan(psnr, 40.0, "PSNR with large noise should be low")
    }

    func testPSNR_DimensionMismatch_ThrowsError() {
        let frame1 = makeGradientFrame(width: 32, height: 32)
        let frame2 = makeGradientFrame(width: 16, height: 16)
        XCTAssertThrowsError(try QualityMetrics.psnr(original: frame1, reconstructed: frame2)) { error in
            XCTAssertTrue(error is QualityMetricsError)
        }
    }

    func testPSNR_ChannelMismatch_ThrowsError() {
        let frame1 = makeGradientFrame(channels: 3)
        let frame2 = makeGradientFrame(channels: 1)
        XCTAssertThrowsError(try QualityMetrics.psnr(original: frame1, reconstructed: frame2)) { error in
            XCTAssertTrue(error is QualityMetricsError)
        }
    }

    func testPSNR_Grayscale_ReturnsValidValue() throws {
        let frame = makeGradientFrame(channels: 1)
        let noisy = addNoise(to: frame, amount: 5)
        let psnr = try QualityMetrics.psnr(original: frame, reconstructed: noisy)
        XCTAssertGreaterThan(psnr, 20.0)
        XCTAssertTrue(psnr.isFinite)
    }

    func testPSNR_SmallImage_8x8() throws {
        let frame = makeGradientFrame(width: 8, height: 8)
        let psnr = try QualityMetrics.psnr(original: frame, reconstructed: frame)
        XCTAssertTrue(psnr.isInfinite)
    }

    // MARK: - SSIM Tests

    func testSSIM_IdenticalFrames_ReturnsOne() throws {
        let frame = makeGradientFrame()
        let ssim = try QualityMetrics.ssim(original: frame, reconstructed: frame)
        XCTAssertEqual(ssim, 1.0, accuracy: 0.001, "SSIM of identical frames should be ~1.0")
    }

    func testSSIM_SlightlyDifferentFrames_ReturnsHighValue() throws {
        let frame = makeGradientFrame()
        let noisy = addNoise(to: frame, amount: 3)
        let ssim = try QualityMetrics.ssim(original: frame, reconstructed: noisy)
        XCTAssertGreaterThan(ssim, 0.8, "SSIM with small noise should be high")
        XCTAssertLessThanOrEqual(ssim, 1.0, "SSIM should not exceed 1.0")
    }

    func testSSIM_LargeNoise_ReturnsLowerValue() throws {
        let frame = makeGradientFrame()
        let noisy = addNoise(to: frame, amount: 50)
        let ssim = try QualityMetrics.ssim(original: frame, reconstructed: noisy)
        XCTAssertLessThan(ssim, 0.95, "SSIM with large noise should be lower")
        XCTAssertGreaterThan(ssim, 0.0, "SSIM should be positive")
    }

    func testSSIM_DimensionMismatch_ThrowsError() {
        let frame1 = makeGradientFrame(width: 32, height: 32)
        let frame2 = makeGradientFrame(width: 16, height: 16)
        XCTAssertThrowsError(try QualityMetrics.ssim(original: frame1, reconstructed: frame2))
    }

    func testSSIM_MoreNoiseGivesLowerSSIM() throws {
        let frame = makeGradientFrame()
        let lowNoise = addNoise(to: frame, amount: 2)
        let highNoise = addNoise(to: frame, amount: 30)
        let ssimLow = try QualityMetrics.ssim(original: frame, reconstructed: lowNoise)
        let ssimHigh = try QualityMetrics.ssim(original: frame, reconstructed: highNoise)
        XCTAssertGreaterThan(ssimLow, ssimHigh, "Lower noise should give higher SSIM")
    }

    // MARK: - MS-SSIM Tests

    func testMSSSIM_IdenticalFrames_ReturnsHighValue() throws {
        let frame = makeGradientFrame(width: 64, height: 64)
        let msSSIM = try QualityMetrics.msSSIM(original: frame, reconstructed: frame)
        XCTAssertGreaterThan(msSSIM, 0.95, "MS-SSIM of identical frames should be very high")
    }

    func testMSSSIM_DifferentFrames_ReturnsLowerValue() throws {
        let frame = makeGradientFrame(width: 64, height: 64)
        let noisy = addNoise(to: frame, amount: 20)
        let msSSIM = try QualityMetrics.msSSIM(original: frame, reconstructed: noisy)
        XCTAssertGreaterThan(msSSIM, 0.0, "MS-SSIM should be positive")
        XCTAssertLessThanOrEqual(msSSIM, 1.0, "MS-SSIM should not exceed 1.0")
    }

    func testMSSSIM_SmallImage_StillWorks() throws {
        let frame = makeGradientFrame(width: 16, height: 16)
        let msSSIM = try QualityMetrics.msSSIM(original: frame, reconstructed: frame)
        XCTAssertGreaterThan(msSSIM, 0.0, "MS-SSIM should work on small images")
    }

    // MARK: - Butteraugli Tests

    func testButteraugli_IdenticalFrames_ReturnsZero() throws {
        let frame = makeGradientFrame()
        let butteraugli = try QualityMetrics.butteraugli(original: frame, reconstructed: frame)
        XCTAssertEqual(butteraugli, 0.0, accuracy: 0.001, "Butteraugli of identical frames should be 0")
    }

    func testButteraugli_SlightlyDifferent_ReturnsSmallValue() throws {
        let frame = makeGradientFrame()
        let noisy = addNoise(to: frame, amount: 2)
        let butteraugli = try QualityMetrics.butteraugli(original: frame, reconstructed: noisy)
        XCTAssertGreaterThan(butteraugli, 0.0, "Butteraugli should detect small differences")
    }

    func testButteraugli_LargeNoise_ReturnsLargerValue() throws {
        let frame = makeGradientFrame()
        let lowNoise = addNoise(to: frame, amount: 2)
        let highNoise = addNoise(to: frame, amount: 50)
        let bLow = try QualityMetrics.butteraugli(original: frame, reconstructed: lowNoise)
        let bHigh = try QualityMetrics.butteraugli(original: frame, reconstructed: highNoise)
        XCTAssertGreaterThan(bHigh, bLow, "More noise should give higher Butteraugli distance")
    }

    func testButteraugli_DimensionMismatch_ThrowsError() {
        let frame1 = makeGradientFrame(width: 32, height: 32)
        let frame2 = makeGradientFrame(width: 16, height: 16)
        XCTAssertThrowsError(try QualityMetrics.butteraugli(original: frame1, reconstructed: frame2))
    }

    func testButteraugli_Grayscale_ReturnsValidValue() throws {
        let frame = makeGradientFrame(channels: 1)
        let noisy = addNoise(to: frame, amount: 10)
        let butteraugli = try QualityMetrics.butteraugli(original: frame, reconstructed: noisy)
        XCTAssertGreaterThan(butteraugli, 0.0)
    }

    // MARK: - Full Comparison Tests

    func testCompare_IdenticalFrames_AllMetricsValid() throws {
        let frame = makeGradientFrame()
        let result = try QualityMetrics.compare(original: frame, reconstructed: frame)

        XCTAssertTrue(result.psnr.isInfinite, "PSNR should be infinity for identical frames")
        XCTAssertEqual(result.ssim, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.butteraugli, 0.0, accuracy: 0.001)
        XCTAssertEqual(result.channelPSNR.count, 3)
        for channelPSNR in result.channelPSNR {
            XCTAssertTrue(channelPSNR.isInfinite)
        }
    }

    func testCompare_NoisyFrames_AllMetricsConsistent() throws {
        let frame = makeGradientFrame()
        let noisy = addNoise(to: frame, amount: 10)
        let result = try QualityMetrics.compare(original: frame, reconstructed: noisy)

        XCTAssertGreaterThan(result.psnr, 20.0)
        XCTAssertLessThan(result.psnr, 60.0)
        XCTAssertGreaterThan(result.ssim, 0.5)
        XCTAssertLessThanOrEqual(result.ssim, 1.0)
        XCTAssertGreaterThan(result.msSSIM, 0.0)
        XCTAssertLessThanOrEqual(result.msSSIM, 1.0)
        XCTAssertGreaterThan(result.butteraugli, 0.0)
        XCTAssertEqual(result.channelPSNR.count, 3)
    }

    func testCompare_EmptyImage_ThrowsError() {
        let frame = ImageFrame(width: 0, height: 0, channels: 3, pixelType: .uint8, colorSpace: .sRGB)
        XCTAssertThrowsError(try QualityMetrics.compare(original: frame, reconstructed: frame)) { error in
            guard let metricsError = error as? QualityMetricsError else {
                XCTFail("Expected QualityMetricsError"); return
            }
            if case .emptyImage = metricsError {
                // expected
            } else {
                XCTFail("Expected .emptyImage error")
            }
        }
    }

    // MARK: - Error Type Tests

    func testQualityMetricsError_DimensionMismatch_Description() {
        let error = QualityMetricsError.dimensionMismatch(original: (32, 32), reconstructed: (16, 16))
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("32"))
        XCTAssertTrue(error.errorDescription!.contains("16"))
    }

    func testQualityMetricsError_ChannelMismatch_Description() {
        let error = QualityMetricsError.channelMismatch(original: 3, reconstructed: 1)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("3"))
        XCTAssertTrue(error.errorDescription!.contains("1"))
    }

    func testQualityMetricsError_EmptyImage_Description() {
        let error = QualityMetricsError.emptyImage
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("empty"))
    }

    // MARK: - QualityMetricResult Tests

    func testQualityMetricResult_Properties() throws {
        let frame = makeGradientFrame()
        let noisy = addNoise(to: frame, amount: 5)
        let result = try QualityMetrics.compare(original: frame, reconstructed: noisy)

        // Verify all properties are accessible
        XCTAssertTrue(result.psnr.isFinite)
        XCTAssertTrue(result.ssim >= 0.0 && result.ssim <= 1.0)
        XCTAssertTrue(result.msSSIM >= 0.0 && result.msSSIM <= 1.0)
        XCTAssertTrue(result.butteraugli >= 0.0)
        XCTAssertFalse(result.channelPSNR.isEmpty)
    }

    // MARK: - Edge Cases

    func testPSNR_1x1Image_Works() throws {
        var frame1 = ImageFrame(width: 1, height: 1, channels: 1, pixelType: .uint8, colorSpace: .grayscale)
        frame1.setPixel(x: 0, y: 0, channel: 0, value: 128)

        var frame2 = ImageFrame(width: 1, height: 1, channels: 1, pixelType: .uint8, colorSpace: .grayscale)
        frame2.setPixel(x: 0, y: 0, channel: 0, value: 128)

        let psnr = try QualityMetrics.psnr(original: frame1, reconstructed: frame2)
        XCTAssertTrue(psnr.isInfinite)
    }

    func testPSNR_1x1Image_WithDifference() throws {
        var frame1 = ImageFrame(width: 1, height: 1, channels: 1, pixelType: .uint8, colorSpace: .grayscale)
        frame1.setPixel(x: 0, y: 0, channel: 0, value: 128)

        var frame2 = ImageFrame(width: 1, height: 1, channels: 1, pixelType: .uint8, colorSpace: .grayscale)
        frame2.setPixel(x: 0, y: 0, channel: 0, value: 130)

        let psnr = try QualityMetrics.psnr(original: frame1, reconstructed: frame2)
        XCTAssertTrue(psnr.isFinite)
        XCTAssertGreaterThan(psnr, 30.0, "Small difference should give high PSNR")
    }

    func testPSNR_AllBlack_vs_AllWhite() throws {
        var black = ImageFrame(width: 8, height: 8, channels: 1, pixelType: .uint8, colorSpace: .grayscale)
        var white = ImageFrame(width: 8, height: 8, channels: 1, pixelType: .uint8, colorSpace: .grayscale)
        for y in 0..<8 {
            for x in 0..<8 {
                black.setPixel(x: x, y: y, channel: 0, value: 0)
                white.setPixel(x: x, y: y, channel: 0, value: 255)
            }
        }
        let psnr = try QualityMetrics.psnr(original: black, reconstructed: white)
        XCTAssertTrue(psnr.isFinite)
        XCTAssertLessThan(psnr, 10.0, "Max difference should give very low PSNR")
    }

    // MARK: - Performance Test

    func testPerformance_QualityMetrics_64x64() throws {
        let frame = makeGradientFrame(width: 64, height: 64)
        let noisy = addNoise(to: frame, amount: 10)

        measure {
            _ = try? QualityMetrics.compare(original: frame, reconstructed: noisy)
        }
    }
}
