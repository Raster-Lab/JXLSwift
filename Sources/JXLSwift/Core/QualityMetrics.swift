/// Quality metrics for image comparison
///
/// Provides PSNR, SSIM, and Butteraugli metric calculations for comparing
/// original and reconstructed images. Used for validation against reference
/// implementations and regression detection.

import Foundation

// MARK: - Quality Metric Results

/// Container for all quality metric results between two images.
public struct QualityMetricResult: Sendable {
    /// Peak Signal-to-Noise Ratio in decibels (higher is better)
    public let psnr: Double

    /// Structural Similarity Index (0.0 to 1.0, higher is better)
    public let ssim: Double

    /// Multi-Scale Structural Similarity Index (0.0 to 1.0, higher is better)
    public let msSSIM: Double

    /// Butteraugli distance score (lower is better, 0.0 = identical)
    public let butteraugli: Double

    /// Per-channel PSNR values (one per channel)
    public let channelPSNR: [Double]
}

// MARK: - Quality Metrics Calculator

/// Calculator for image quality metrics.
///
/// Computes PSNR, SSIM, MS-SSIM, and Butteraugli metrics between an original
/// and a reconstructed image frame. These metrics are essential for validating
/// encoding quality against reference implementations.
///
/// # Usage
/// ```swift
/// let metrics = try QualityMetrics.compare(original: frame, reconstructed: decoded)
/// print("PSNR: \(metrics.psnr) dB")
/// print("SSIM: \(metrics.ssim)")
/// ```
public enum QualityMetrics {

    // MARK: - Full Comparison

    /// Compare two image frames and compute all quality metrics.
    /// - Parameters:
    ///   - original: The reference image frame
    ///   - reconstructed: The image frame to evaluate
    /// - Returns: Quality metric results
    /// - Throws: `QualityMetricsError` if frames are incompatible
    public static func compare(
        original: ImageFrame,
        reconstructed: ImageFrame
    ) throws -> QualityMetricResult {
        try validateFrames(original: original, reconstructed: reconstructed)

        let psnrResult = computePSNR(original: original, reconstructed: reconstructed)
        let ssimResult = computeSSIM(original: original, reconstructed: reconstructed)
        let msSSIMResult = computeMSSSIM(original: original, reconstructed: reconstructed)
        let butteraugliResult = computeButteraugli(original: original, reconstructed: reconstructed)

        return QualityMetricResult(
            psnr: psnrResult.overall,
            ssim: ssimResult,
            msSSIM: msSSIMResult,
            butteraugli: butteraugliResult,
            channelPSNR: psnrResult.perChannel
        )
    }

    // MARK: - Individual Metrics

    /// Compute Peak Signal-to-Noise Ratio (PSNR) between two frames.
    ///
    /// PSNR is defined as 10 * log10(MAX^2 / MSE) where MAX is the maximum
    /// possible pixel value and MSE is the mean squared error.
    ///
    /// - Parameters:
    ///   - original: The reference image frame
    ///   - reconstructed: The image frame to evaluate
    /// - Returns: PSNR in decibels (higher is better, infinity for identical images)
    /// - Throws: `QualityMetricsError` if frames are incompatible
    public static func psnr(
        original: ImageFrame,
        reconstructed: ImageFrame
    ) throws -> Double {
        try validateFrames(original: original, reconstructed: reconstructed)
        return computePSNR(original: original, reconstructed: reconstructed).overall
    }

    /// Compute Structural Similarity Index (SSIM) between two frames.
    ///
    /// SSIM compares luminance, contrast, and structure of two images using
    /// a sliding window approach. Returns a value between 0.0 and 1.0.
    ///
    /// - Parameters:
    ///   - original: The reference image frame
    ///   - reconstructed: The image frame to evaluate
    /// - Returns: SSIM value (0.0 to 1.0, higher is better)
    /// - Throws: `QualityMetricsError` if frames are incompatible
    public static func ssim(
        original: ImageFrame,
        reconstructed: ImageFrame
    ) throws -> Double {
        try validateFrames(original: original, reconstructed: reconstructed)
        return computeSSIM(original: original, reconstructed: reconstructed)
    }

    /// Compute Multi-Scale Structural Similarity (MS-SSIM) between two frames.
    ///
    /// MS-SSIM extends SSIM by computing at multiple scales, providing a more
    /// robust quality metric that better correlates with human perception.
    ///
    /// - Parameters:
    ///   - original: The reference image frame
    ///   - reconstructed: The image frame to evaluate
    /// - Returns: MS-SSIM value (0.0 to 1.0, higher is better)
    /// - Throws: `QualityMetricsError` if frames are incompatible
    public static func msSSIM(
        original: ImageFrame,
        reconstructed: ImageFrame
    ) throws -> Double {
        try validateFrames(original: original, reconstructed: reconstructed)
        return computeMSSSIM(original: original, reconstructed: reconstructed)
    }

    /// Compute Butteraugli perceptual distance between two frames.
    ///
    /// Butteraugli estimates the psychovisual difference between two images,
    /// modelling the human visual system. Lower values indicate less perceptible
    /// difference. A value of 0.0 means identical images.
    ///
    /// - Parameters:
    ///   - original: The reference image frame
    ///   - reconstructed: The image frame to evaluate
    /// - Returns: Butteraugli distance (lower is better, 0.0 = identical)
    /// - Throws: `QualityMetricsError` if frames are incompatible
    public static func butteraugli(
        original: ImageFrame,
        reconstructed: ImageFrame
    ) throws -> Double {
        try validateFrames(original: original, reconstructed: reconstructed)
        return computeButteraugli(original: original, reconstructed: reconstructed)
    }

    // MARK: - Validation

    /// Validate that two frames are compatible for comparison.
    private static func validateFrames(
        original: ImageFrame,
        reconstructed: ImageFrame
    ) throws {
        guard original.width == reconstructed.width,
              original.height == reconstructed.height else {
            throw QualityMetricsError.dimensionMismatch(
                original: (original.width, original.height),
                reconstructed: (reconstructed.width, reconstructed.height)
            )
        }
        guard original.channels == reconstructed.channels else {
            throw QualityMetricsError.channelMismatch(
                original: original.channels,
                reconstructed: reconstructed.channels
            )
        }
        guard original.width > 0, original.height > 0 else {
            throw QualityMetricsError.emptyImage
        }
    }

    // MARK: - PSNR Implementation

    private struct PSNRResult {
        let overall: Double
        let perChannel: [Double]
    }

    private static func computePSNR(
        original: ImageFrame,
        reconstructed: ImageFrame
    ) -> PSNRResult {
        let maxValue = maxPixelValue(for: original.pixelType)
        let maxSquared = maxValue * maxValue
        let channels = original.channels

        var channelMSE = [Double](repeating: 0.0, count: channels)
        let pixelCount = Double(original.width * original.height)

        for c in 0..<channels {
            var sumSquaredError: Double = 0.0
            for y in 0..<original.height {
                for x in 0..<original.width {
                    let origVal = Double(original.getPixel(x: x, y: y, channel: c))
                    let recVal = Double(reconstructed.getPixel(x: x, y: y, channel: c))
                    let diff = origVal - recVal
                    sumSquaredError += diff * diff
                }
            }
            channelMSE[c] = sumSquaredError / pixelCount
        }

        // Per-channel PSNR
        let channelPSNR = channelMSE.map { mse -> Double in
            if mse == 0.0 { return Double.infinity }
            return 10.0 * log10(maxSquared / mse)
        }

        // Overall PSNR (average MSE across channels)
        let overallMSE = channelMSE.reduce(0.0, +) / Double(channels)
        let overallPSNR: Double
        if overallMSE == 0.0 {
            overallPSNR = Double.infinity
        } else {
            overallPSNR = 10.0 * log10(maxSquared / overallMSE)
        }

        return PSNRResult(overall: overallPSNR, perChannel: channelPSNR)
    }

    // MARK: - SSIM Implementation

    /// SSIM constants (from the original paper by Wang et al.)
    private static let ssimK1: Double = 0.01
    private static let ssimK2: Double = 0.03
    private static let ssimWindowSize: Int = 8

    private static func computeSSIM(
        original: ImageFrame,
        reconstructed: ImageFrame
    ) -> Double {
        let maxValue = maxPixelValue(for: original.pixelType)
        let c1 = (ssimK1 * maxValue) * (ssimK1 * maxValue)
        let c2 = (ssimK2 * maxValue) * (ssimK2 * maxValue)

        let channels = original.channels
        var totalSSIM: Double = 0.0

        for c in 0..<channels {
            var channelSSIM: Double = 0.0
            var windowCount: Int = 0

            let stepY = max(1, original.height / 32)
            let stepX = max(1, original.width / 32)

            var wy = 0
            while wy + ssimWindowSize <= original.height {
                var wx = 0
                while wx + ssimWindowSize <= original.width {
                    let ssimVal = computeSSIMWindow(
                        original: original,
                        reconstructed: reconstructed,
                        channel: c,
                        startX: wx,
                        startY: wy,
                        windowSize: ssimWindowSize,
                        c1: c1,
                        c2: c2
                    )
                    channelSSIM += ssimVal
                    windowCount += 1
                    wx += stepX
                }
                wy += stepY
            }

            if windowCount > 0 {
                totalSSIM += channelSSIM / Double(windowCount)
            }
        }

        return totalSSIM / Double(channels)
    }

    private static func computeSSIMWindow(
        original: ImageFrame,
        reconstructed: ImageFrame,
        channel: Int,
        startX: Int,
        startY: Int,
        windowSize: Int,
        c1: Double,
        c2: Double
    ) -> Double {
        let n = Double(windowSize * windowSize)

        var sumX: Double = 0.0
        var sumY: Double = 0.0
        var sumXX: Double = 0.0
        var sumYY: Double = 0.0
        var sumXY: Double = 0.0

        for dy in 0..<windowSize {
            for dx in 0..<windowSize {
                let x = startX + dx
                let y = startY + dy
                let origVal = Double(original.getPixel(x: x, y: y, channel: channel))
                let recVal = Double(reconstructed.getPixel(x: x, y: y, channel: channel))

                sumX += origVal
                sumY += recVal
                sumXX += origVal * origVal
                sumYY += recVal * recVal
                sumXY += origVal * recVal
            }
        }

        let muX = sumX / n
        let muY = sumY / n
        let sigmaXX = sumXX / n - muX * muX
        let sigmaYY = sumYY / n - muY * muY
        let sigmaXY = sumXY / n - muX * muY

        let numerator = (2.0 * muX * muY + c1) * (2.0 * sigmaXY + c2)
        let denominator = (muX * muX + muY * muY + c1) * (sigmaXX + sigmaYY + c2)

        return numerator / denominator
    }

    // MARK: - MS-SSIM Implementation

    /// Weights for MS-SSIM levels (from original paper by Wang et al.)
    private static let msSSIMWeights: [Double] = [0.0448, 0.2856, 0.3001, 0.2363, 0.1333]

    private static func computeMSSSIM(
        original: ImageFrame,
        reconstructed: ImageFrame
    ) -> Double {
        let maxValue = maxPixelValue(for: original.pixelType)
        let c1 = (ssimK1 * maxValue) * (ssimK1 * maxValue)
        let c2 = (ssimK2 * maxValue) * (ssimK2 * maxValue)

        var origPixels = extractFloatPixels(from: original)
        var recPixels = extractFloatPixels(from: reconstructed)
        var currentWidth = original.width
        var currentHeight = original.height
        let channels = original.channels

        var csValues: [Double] = []
        var luminanceValue: Double = 0.0
        let levels = min(msSSIMWeights.count, maxScaleLevels(width: currentWidth, height: currentHeight))

        for level in 0..<levels {
            // Compute luminance and contrast-structure at this scale
            var totalLuminance: Double = 0.0
            var totalCS: Double = 0.0
            var windowCount: Int = 0

            for c in 0..<channels {
                let channelOffset = c * currentWidth * currentHeight
                var wy = 0
                while wy + ssimWindowSize <= currentHeight {
                    var wx = 0
                    while wx + ssimWindowSize <= currentWidth {
                        let (lum, cs) = computeSSIMComponents(
                            origPixels: origPixels,
                            recPixels: recPixels,
                            offset: channelOffset,
                            width: currentWidth,
                            startX: wx,
                            startY: wy,
                            windowSize: ssimWindowSize,
                            c1: c1,
                            c2: c2
                        )
                        totalLuminance += lum
                        totalCS += cs
                        windowCount += 1
                        wx += ssimWindowSize
                    }
                    wy += ssimWindowSize
                }
            }

            if windowCount > 0 {
                luminanceValue = totalLuminance / Double(windowCount)
                csValues.append(totalCS / Double(windowCount))
            }

            // Downsample for next level (unless last level)
            if level < levels - 1 {
                let newWidth = currentWidth / 2
                let newHeight = currentHeight / 2
                guard newWidth >= ssimWindowSize, newHeight >= ssimWindowSize else { break }

                origPixels = downsample(origPixels, width: currentWidth, height: currentHeight, channels: channels)
                recPixels = downsample(recPixels, width: currentWidth, height: currentHeight, channels: channels)
                currentWidth = newWidth
                currentHeight = newHeight
            }
        }

        // Combine across scales
        guard !csValues.isEmpty else { return 0.0 }

        var result: Double = 1.0
        let actualLevels = csValues.count
        for i in 0..<actualLevels {
            let weight = i < msSSIMWeights.count ? msSSIMWeights[i] : msSSIMWeights.last ?? 0.1
            if i == actualLevels - 1 {
                // Last level uses luminance
                result *= pow(max(0.0, luminanceValue), weight)
            }
            result *= pow(max(0.0, csValues[i]), weight)
        }

        return min(1.0, max(0.0, result))
    }

    private static func computeSSIMComponents(
        origPixels: [Double],
        recPixels: [Double],
        offset: Int,
        width: Int,
        startX: Int,
        startY: Int,
        windowSize: Int,
        c1: Double,
        c2: Double
    ) -> (luminance: Double, contrastStructure: Double) {
        let n = Double(windowSize * windowSize)

        var sumX: Double = 0.0
        var sumY: Double = 0.0
        var sumXX: Double = 0.0
        var sumYY: Double = 0.0
        var sumXY: Double = 0.0

        for dy in 0..<windowSize {
            for dx in 0..<windowSize {
                let idx = offset + (startY + dy) * width + (startX + dx)
                let origVal = origPixels[idx]
                let recVal = recPixels[idx]

                sumX += origVal
                sumY += recVal
                sumXX += origVal * origVal
                sumYY += recVal * recVal
                sumXY += origVal * recVal
            }
        }

        let muX = sumX / n
        let muY = sumY / n
        let sigmaXX = sumXX / n - muX * muX
        let sigmaYY = sumYY / n - muY * muY
        let sigmaXY = sumXY / n - muX * muY

        let luminance = (2.0 * muX * muY + c1) / (muX * muX + muY * muY + c1)
        let cs = (2.0 * sigmaXY + c2) / (sigmaXX + sigmaYY + c2)

        return (luminance, cs)
    }

    // MARK: - Butteraugli Implementation

    /// Simplified Butteraugli-inspired perceptual distance metric.
    ///
    /// This approximation models key aspects of the Butteraugli algorithm:
    /// - Opponent color space conversion (similar to XYB)
    /// - Frequency-dependent contrast sensitivity
    /// - Masking effects from local image structure
    private static func computeButteraugli(
        original: ImageFrame,
        reconstructed: ImageFrame
    ) -> Double {
        let width = original.width
        let height = original.height
        let channels = min(original.channels, 3)

        // Convert to perceptual opponent color space (approximation of XYB)
        var origOpponent = convertToOpponentSpace(original)
        var recOpponent = convertToOpponentSpace(reconstructed)

        // Compute per-pixel perceptual difference with masking
        var maxDiff: Double = 0.0
        var totalDiff: Double = 0.0
        let pixelCount = Double(width * height)

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x

                var perceptualDiff: Double = 0.0
                // Channel weights reflecting human visual sensitivity
                let channelWeights: [Double] = [1.0, 0.7, 0.3]

                for c in 0..<min(channels, 3) {
                    let origVal = origOpponent[c * width * height + idx]
                    let recVal = recOpponent[c * width * height + idx]
                    let diff = abs(origVal - recVal)

                    // Apply local masking: differences are less visible in
                    // high-contrast areas (Weber's law approximation)
                    let localIntensity = max(abs(origVal), 1.0)
                    let maskedDiff = diff / (1.0 + 0.3 * localIntensity)

                    perceptualDiff += maskedDiff * maskedDiff * channelWeights[c]
                }

                let pixelDiff = sqrt(perceptualDiff)
                totalDiff += pixelDiff
                maxDiff = max(maxDiff, pixelDiff)
            }
        }

        // Butteraugli combines average and peak differences
        let avgDiff = totalDiff / pixelCount
        // Weight peak more heavily as Butteraugli focuses on worst-case perceptual error
        let result = 0.6 * maxDiff + 0.4 * avgDiff

        return result
    }

    // MARK: - Helper Functions

    /// Maximum pixel value for a given pixel type.
    private static func maxPixelValue(for pixelType: PixelType) -> Double {
        switch pixelType {
        case .uint8: return 255.0
        case .uint16: return 65535.0
        case .int16: return 65535.0
        case .float32: return 1.0
        }
    }

    /// Maximum scale levels for MS-SSIM based on image dimensions.
    private static func maxScaleLevels(width: Int, height: Int) -> Int {
        var levels = 1
        var w = width
        var h = height
        while w / 2 >= ssimWindowSize && h / 2 >= ssimWindowSize && levels < 5 {
            w /= 2
            h /= 2
            levels += 1
        }
        return levels
    }

    /// Extract all pixel values as Double array (channels × width × height).
    private static func extractFloatPixels(from frame: ImageFrame) -> [Double] {
        let totalPixels = frame.channels * frame.width * frame.height
        var pixels = [Double](repeating: 0.0, count: totalPixels)

        for c in 0..<frame.channels {
            let channelOffset = c * frame.width * frame.height
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    pixels[channelOffset + y * frame.width + x] = Double(frame.getPixel(x: x, y: y, channel: c))
                }
            }
        }
        return pixels
    }

    /// Downsample pixel data by 2× using box filter (averaging).
    private static func downsample(
        _ pixels: [Double],
        width: Int,
        height: Int,
        channels: Int
    ) -> [Double] {
        let newWidth = width / 2
        let newHeight = height / 2
        var result = [Double](repeating: 0.0, count: channels * newWidth * newHeight)

        for c in 0..<channels {
            let srcOffset = c * width * height
            let dstOffset = c * newWidth * newHeight

            for y in 0..<newHeight {
                for x in 0..<newWidth {
                    let sx = x * 2
                    let sy = y * 2
                    let avg = (
                        pixels[srcOffset + sy * width + sx] +
                        pixels[srcOffset + sy * width + sx + 1] +
                        pixels[srcOffset + (sy + 1) * width + sx] +
                        pixels[srcOffset + (sy + 1) * width + sx + 1]
                    ) / 4.0
                    result[dstOffset + y * newWidth + x] = avg
                }
            }
        }
        return result
    }

    /// Convert image frame to opponent color space for perceptual comparison.
    ///
    /// For RGB images: converts to an approximation of XYB space used by JPEG XL.
    /// For grayscale: returns intensity-only representation.
    private static func convertToOpponentSpace(_ frame: ImageFrame) -> [Double] {
        let width = frame.width
        let height = frame.height
        let totalPixels = width * height
        let channels = min(frame.channels, 3)

        if channels < 3 {
            // Grayscale — return normalized values
            var result = [Double](repeating: 0.0, count: totalPixels)
            let scale = 1.0 / maxPixelValue(for: frame.pixelType)
            for y in 0..<height {
                for x in 0..<width {
                    result[y * width + x] = Double(frame.getPixel(x: x, y: y, channel: 0)) * scale
                }
            }
            return result
        }

        // RGB → opponent space (XYB-inspired)
        // X = R - G (red-green opponent)
        // Y = (R + G) / 2 (luminance-like)
        // B = B - (R + G) / 2 (blue-yellow opponent)
        var result = [Double](repeating: 0.0, count: 3 * totalPixels)
        let scale = 1.0 / maxPixelValue(for: frame.pixelType)

        for y in 0..<height {
            for x in 0..<width {
                let r = Double(frame.getPixel(x: x, y: y, channel: 0)) * scale
                let g = Double(frame.getPixel(x: x, y: y, channel: 1)) * scale
                let b = Double(frame.getPixel(x: x, y: y, channel: 2)) * scale
                let idx = y * width + x

                // Apply gamma-like nonlinearity for perceptual uniformity
                let rLin = pow(max(r, 0.0), 1.0 / 3.0)
                let gLin = pow(max(g, 0.0), 1.0 / 3.0)
                let bLin = pow(max(b, 0.0), 1.0 / 3.0)

                result[idx] = rLin - gLin                       // X: red-green
                result[totalPixels + idx] = (rLin + gLin) / 2.0 // Y: luminance
                result[2 * totalPixels + idx] = bLin - (rLin + gLin) / 2.0 // B: blue-yellow
            }
        }

        return result
    }
}

// MARK: - Errors

/// Errors that can occur during quality metric computation.
public enum QualityMetricsError: Error, LocalizedError {
    /// Image dimensions do not match.
    case dimensionMismatch(original: (Int, Int), reconstructed: (Int, Int))

    /// Channel count does not match.
    case channelMismatch(original: Int, reconstructed: Int)

    /// One or both images are empty (zero dimensions).
    case emptyImage

    public var errorDescription: String? {
        switch self {
        case .dimensionMismatch(let orig, let rec):
            return "Image dimension mismatch: original \(orig.0)×\(orig.1), reconstructed \(rec.0)×\(rec.1)"
        case .channelMismatch(let orig, let rec):
            return "Channel count mismatch: original \(orig), reconstructed \(rec)"
        case .emptyImage:
            return "Cannot compute quality metrics for empty images"
        }
    }
}
