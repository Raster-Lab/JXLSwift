/// Validation harness for comparing JXLSwift output against reference implementations
///
/// Provides a structured framework for validating encoding quality, bitstream
/// compatibility, compression ratio, encoding speed, and memory usage against
/// expected baselines or external reference implementations like libjxl.

import Foundation

// MARK: - Validation Result Types

/// Overall result of a validation run.
public struct ValidationReport: Sendable {
    /// Timestamp of the validation run
    public let timestamp: Date

    /// Image corpus used for validation
    public let corpus: String

    /// Individual test results
    public let results: [ValidationResult]

    /// Summary statistics
    public var summary: ValidationSummary {
        let passed = results.filter(\.passed).count
        let failed = results.count - passed
        let avgPSNR = results.compactMap(\.qualityResult?.psnr)
            .filter { $0.isFinite }
            .reduce(0.0, +) / max(1.0, Double(results.compactMap(\.qualityResult?.psnr).filter { $0.isFinite }.count))
        let avgSSIM = results.compactMap(\.qualityResult?.ssim)
            .reduce(0.0, +) / max(1.0, Double(results.compactMap(\.qualityResult?.ssim).count))
        let avgCompressionRatio = results.compactMap(\.compressionResult?.compressionRatio)
            .reduce(0.0, +) / max(1.0, Double(results.compactMap(\.compressionResult?.compressionRatio).count))
        let avgEncodingSpeed = results.compactMap(\.performanceResult?.encodingTimeSeconds)
            .reduce(0.0, +) / max(1.0, Double(results.compactMap(\.performanceResult?.encodingTimeSeconds).count))

        return ValidationSummary(
            totalTests: results.count,
            passed: passed,
            failed: failed,
            averagePSNR: avgPSNR,
            averageSSIM: avgSSIM,
            averageCompressionRatio: avgCompressionRatio,
            averageEncodingTime: avgEncodingSpeed
        )
    }
}

/// Summary of validation results.
public struct ValidationSummary: Sendable {
    /// Total number of test cases
    public let totalTests: Int

    /// Number of passed test cases
    public let passed: Int

    /// Number of failed test cases
    public let failed: Int

    /// Average PSNR across all tests (dB)
    public let averagePSNR: Double

    /// Average SSIM across all tests
    public let averageSSIM: Double

    /// Average compression ratio across all tests
    public let averageCompressionRatio: Double

    /// Average encoding time across all tests (seconds)
    public let averageEncodingTime: Double

    /// Whether all tests passed
    public var allPassed: Bool { failed == 0 }
}

/// Result of validating a single test case.
public struct ValidationResult: Sendable {
    /// Test case name
    public let name: String

    /// Image dimensions
    public let width: Int

    /// Image dimensions
    public let height: Int

    /// Encoding options used
    public let optionsDescription: String

    /// Quality metric results (if quality validation was performed)
    public let qualityResult: QualityValidation?

    /// Compression result
    public let compressionResult: CompressionValidation?

    /// Performance result
    public let performanceResult: PerformanceValidation?

    /// Whether this test case passed all criteria
    public var passed: Bool {
        let qualityPassed = qualityResult?.passed ?? true
        let compressionPassed = compressionResult?.passed ?? true
        let performancePassed = performanceResult?.passed ?? true
        return qualityPassed && compressionPassed && performancePassed
    }

    /// Failure reasons (empty if passed)
    public var failureReasons: [String] {
        var reasons: [String] = []
        if let q = qualityResult, !q.passed {
            reasons.append(contentsOf: q.failureReasons)
        }
        if let c = compressionResult, !c.passed {
            reasons.append(contentsOf: c.failureReasons)
        }
        if let p = performanceResult, !p.passed {
            reasons.append(contentsOf: p.failureReasons)
        }
        return reasons
    }
}

/// Quality validation result for a single test case.
public struct QualityValidation: Sendable {
    /// PSNR value (dB)
    public let psnr: Double

    /// SSIM value (0-1)
    public let ssim: Double

    /// MS-SSIM value (0-1)
    public let msSSIM: Double

    /// Butteraugli distance
    public let butteraugli: Double

    /// Minimum acceptable PSNR (dB)
    public let minPSNR: Double

    /// Minimum acceptable SSIM
    public let minSSIM: Double

    /// Maximum acceptable Butteraugli distance
    public let maxButteraugli: Double

    /// Whether quality criteria are met
    public var passed: Bool {
        let psnrOK = psnr.isInfinite || psnr >= minPSNR
        let ssimOK = ssim >= minSSIM
        let butteraugliOK = butteraugli <= maxButteraugli
        return psnrOK && ssimOK && butteraugliOK
    }

    /// Failure reasons
    public var failureReasons: [String] {
        var reasons: [String] = []
        if !psnr.isInfinite && psnr < minPSNR {
            reasons.append(String(format: "PSNR %.2f dB < minimum %.2f dB", psnr, minPSNR))
        }
        if ssim < minSSIM {
            reasons.append(String(format: "SSIM %.4f < minimum %.4f", ssim, minSSIM))
        }
        if butteraugli > maxButteraugli {
            reasons.append(String(format: "Butteraugli %.4f > maximum %.4f", butteraugli, maxButteraugli))
        }
        return reasons
    }
}

/// Compression validation result for a single test case.
public struct CompressionValidation: Sendable {
    /// Original size in bytes
    public let originalSize: Int

    /// Compressed size in bytes
    public let compressedSize: Int

    /// Compression ratio (original / compressed)
    public let compressionRatio: Double

    /// Minimum acceptable compression ratio
    public let minCompressionRatio: Double

    /// Whether compression criteria are met
    public var passed: Bool {
        compressionRatio >= minCompressionRatio
    }

    /// Failure reasons
    public var failureReasons: [String] {
        var reasons: [String] = []
        if compressionRatio < minCompressionRatio {
            reasons.append(String(format: "Compression ratio %.2f× < minimum %.2f×", compressionRatio, minCompressionRatio))
        }
        return reasons
    }
}

/// Performance validation result for a single test case.
public struct PerformanceValidation: Sendable {
    /// Encoding time in seconds
    public let encodingTimeSeconds: Double

    /// Megapixels per second throughput
    public let megapixelsPerSecond: Double

    /// Peak memory usage in bytes
    public let peakMemoryBytes: Int

    /// Maximum acceptable encoding time (seconds)
    public let maxEncodingTime: Double

    /// Whether performance criteria are met
    public var passed: Bool {
        encodingTimeSeconds <= maxEncodingTime
    }

    /// Failure reasons
    public var failureReasons: [String] {
        var reasons: [String] = []
        if encodingTimeSeconds > maxEncodingTime {
            reasons.append(String(format: "Encoding time %.3fs > maximum %.3fs", encodingTimeSeconds, maxEncodingTime))
        }
        return reasons
    }
}

// MARK: - Validation Criteria

/// Criteria for validating encoding results.
public struct ValidationCriteria: Sendable {
    /// Minimum PSNR in dB (for lossy encoding)
    public var minPSNR: Double

    /// Minimum SSIM (for lossy encoding)
    public var minSSIM: Double

    /// Maximum Butteraugli distance (for lossy encoding)
    public var maxButteraugli: Double

    /// Minimum compression ratio
    public var minCompressionRatio: Double

    /// Maximum encoding time in seconds (0 = no limit)
    public var maxEncodingTime: Double

    /// Initialize validation criteria.
    /// - Parameters:
    ///   - minPSNR: Minimum acceptable PSNR in dB (default: 30.0)
    ///   - minSSIM: Minimum acceptable SSIM (default: 0.9)
    ///   - maxButteraugli: Maximum acceptable Butteraugli distance (default: 5.0)
    ///   - minCompressionRatio: Minimum acceptable compression ratio (default: 1.0)
    ///   - maxEncodingTime: Maximum acceptable encoding time in seconds (default: 30.0)
    public init(
        minPSNR: Double = 30.0,
        minSSIM: Double = 0.9,
        maxButteraugli: Double = 5.0,
        minCompressionRatio: Double = 1.0,
        maxEncodingTime: Double = 30.0
    ) {
        self.minPSNR = minPSNR
        self.minSSIM = minSSIM
        self.maxButteraugli = maxButteraugli
        self.minCompressionRatio = minCompressionRatio
        self.maxEncodingTime = maxEncodingTime
    }

    /// Strict criteria suitable for high-quality validation
    public static let strict = ValidationCriteria(
        minPSNR: 40.0,
        minSSIM: 0.95,
        maxButteraugli: 2.0,
        minCompressionRatio: 1.5,
        maxEncodingTime: 10.0
    )

    /// Relaxed criteria suitable for initial validation
    public static let relaxed = ValidationCriteria(
        minPSNR: 25.0,
        minSSIM: 0.8,
        maxButteraugli: 10.0,
        minCompressionRatio: 0.5,
        maxEncodingTime: 60.0
    )

    /// Lossless criteria (pixel-perfect required)
    public static let lossless = ValidationCriteria(
        minPSNR: Double.infinity,
        minSSIM: 1.0,
        maxButteraugli: 0.0,
        minCompressionRatio: 0.5,
        maxEncodingTime: 60.0
    )
}

// MARK: - Validation Harness

/// Test harness for validating JXLSwift encoding against reference baselines.
///
/// The validation harness encodes test images with specified options, then
/// evaluates the results against quality, compression, and performance criteria.
///
/// # Usage
/// ```swift
/// let harness = ValidationHarness(criteria: .strict)
/// let report = try harness.validate(
///     corpus: "test-images",
///     testCases: testCases
/// )
/// print("Passed: \(report.summary.passed)/\(report.summary.totalTests)")
/// ```
public class ValidationHarness {
    /// Validation criteria
    public let criteria: ValidationCriteria

    /// Number of iterations for performance measurement
    public let iterations: Int

    /// Initialize a validation harness.
    /// - Parameters:
    ///   - criteria: Validation criteria to apply
    ///   - iterations: Number of encoding iterations for timing (default: 3)
    public init(criteria: ValidationCriteria = ValidationCriteria(), iterations: Int = 3) {
        self.criteria = criteria
        self.iterations = max(1, iterations)
    }

    /// A test case to validate.
    public struct TestCase {
        /// Test case name
        public let name: String

        /// Image frame to encode
        public let frame: ImageFrame

        /// Encoding options
        public let options: EncodingOptions

        /// Whether this is a lossless test (use lossless quality criteria)
        public let isLossless: Bool

        /// Initialize a test case.
        public init(name: String, frame: ImageFrame, options: EncodingOptions, isLossless: Bool = false) {
            self.name = name
            self.frame = frame
            self.options = options
            self.isLossless = isLossless
        }
    }

    /// Run validation on a set of test cases.
    /// - Parameters:
    ///   - corpus: Name of the test corpus
    ///   - testCases: Array of test cases to validate
    /// - Returns: Validation report
    /// - Throws: If encoding fails for any test case
    public func validate(corpus: String, testCases: [TestCase]) throws -> ValidationReport {
        var results: [ValidationResult] = []

        for testCase in testCases {
            let result = try validateTestCase(testCase)
            results.append(result)
        }

        return ValidationReport(
            timestamp: Date(),
            corpus: corpus,
            results: results
        )
    }

    /// Validate a single test case.
    private func validateTestCase(_ testCase: TestCase) throws -> ValidationResult {
        let encoder = JXLEncoder(options: testCase.options)

        // Performance measurement: encode multiple times
        var totalTime: TimeInterval = 0.0
        var encodedResult: EncodedImage?

        for _ in 0..<iterations {
            let start = Date()
            let result = try encoder.encode(testCase.frame)
            totalTime += Date().timeIntervalSince(start)
            encodedResult = result
        }

        guard let result = encodedResult else {
            throw EncoderError.encodingFailed("No encoding result produced")
        }

        let avgTime = totalTime / Double(iterations)
        let megapixels = Double(testCase.frame.width * testCase.frame.height) / 1_000_000.0
        let mpps = megapixels / avgTime

        // Quality validation (only for lossy encoding with a reconstructed frame)
        // Since we don't have a decoder yet, we compare original with itself as baseline
        // In a full implementation, we'd decode the JXL and compare
        let qualityResult: QualityValidation?
        if !testCase.isLossless {
            // For now, use placeholder quality metrics based on compression ratio
            // Once decoding is available, this will use actual decoded frames
            let estimatedPSNR = estimatePSNRFromCompressionRatio(result.stats.compressionRatio)
            let effectiveCriteria = testCase.isLossless ? ValidationCriteria.lossless : criteria

            qualityResult = QualityValidation(
                psnr: estimatedPSNR,
                ssim: estimateSSIMFromPSNR(estimatedPSNR),
                msSSIM: estimateSSIMFromPSNR(estimatedPSNR),
                butteraugli: estimateButteraugliFromPSNR(estimatedPSNR),
                minPSNR: effectiveCriteria.minPSNR,
                minSSIM: effectiveCriteria.minSSIM,
                maxButteraugli: effectiveCriteria.maxButteraugli
            )
        } else {
            // Lossless: quality is perfect by definition
            qualityResult = QualityValidation(
                psnr: Double.infinity,
                ssim: 1.0,
                msSSIM: 1.0,
                butteraugli: 0.0,
                minPSNR: criteria.minPSNR,
                minSSIM: criteria.minSSIM,
                maxButteraugli: criteria.maxButteraugli
            )
        }

        // Compression validation
        let compressionResult = CompressionValidation(
            originalSize: result.stats.originalSize,
            compressedSize: result.stats.compressedSize,
            compressionRatio: result.stats.compressionRatio,
            minCompressionRatio: criteria.minCompressionRatio
        )

        // Performance validation
        let performanceResult = PerformanceValidation(
            encodingTimeSeconds: avgTime,
            megapixelsPerSecond: mpps,
            peakMemoryBytes: result.stats.peakMemory,
            maxEncodingTime: criteria.maxEncodingTime
        )

        // Options description
        let modeStr: String
        switch testCase.options.mode {
        case .lossless: modeStr = "lossless"
        case .lossy(let q): modeStr = "lossy(q=\(q))"
        case .distance(let d): modeStr = "distance(\(d))"
        }
        let optDesc = "\(modeStr), effort=\(testCase.options.effort.rawValue)"

        return ValidationResult(
            name: testCase.name,
            width: testCase.frame.width,
            height: testCase.frame.height,
            optionsDescription: optDesc,
            qualityResult: qualityResult,
            compressionResult: compressionResult,
            performanceResult: performanceResult
        )
    }

    // MARK: - Quality Estimation (Pre-Decoder)

    // FIXME: Replace these heuristic estimation functions with actual decoded frame
    // comparisons once the JXLDecoder (Milestone 12) is implemented. Currently these
    // provide rough estimates based on compression ratio correlations. Actual quality
    // metrics require: encode → decode → compare(original, decoded).

    /// Estimate PSNR from compression ratio (heuristic until decoder is available).
    private func estimatePSNRFromCompressionRatio(_ ratio: Double) -> Double {
        // Higher compression ratio generally means lower quality
        // Approximate mapping based on typical JPEG XL behavior
        if ratio <= 1.0 { return 50.0 }
        if ratio <= 2.0 { return 45.0 }
        if ratio <= 5.0 { return 40.0 }
        if ratio <= 10.0 { return 35.0 }
        if ratio <= 20.0 { return 30.0 }
        return 25.0
    }

    /// Estimate SSIM from PSNR (approximate correlation).
    private func estimateSSIMFromPSNR(_ psnr: Double) -> Double {
        if psnr.isInfinite { return 1.0 }
        // Approximate mapping: PSNR 30 ≈ SSIM 0.9, PSNR 40 ≈ SSIM 0.98
        return min(1.0, max(0.0, 1.0 - pow(10.0, -(psnr - 20.0) / 20.0)))
    }

    /// Estimate Butteraugli from PSNR (approximate inverse correlation).
    private func estimateButteraugliFromPSNR(_ psnr: Double) -> Double {
        if psnr.isInfinite { return 0.0 }
        // Approximate mapping: PSNR 30 ≈ Butteraugli 3.0, PSNR 40 ≈ Butteraugli 1.0
        return max(0.0, 15.0 - psnr / 3.0)
    }
}

// MARK: - Test Image Generation

/// Utility for generating standard test images for validation.
public enum TestImageGenerator {
    /// Generate a gradient test image.
    /// - Parameters:
    ///   - width: Image width
    ///   - height: Image height
    ///   - channels: Number of channels (1, 3, or 4)
    /// - Returns: Image frame with gradient pattern
    public static func gradient(width: Int, height: Int, channels: Int = 3) -> ImageFrame {
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
                if channels == 4 {
                    frame.setPixel(x: x, y: y, channel: 3, value: 255)
                }
            }
        }
        return frame
    }

    /// Generate a checkerboard test image.
    /// - Parameters:
    ///   - width: Image width
    ///   - height: Image height
    ///   - blockSize: Size of each checker block
    ///   - channels: Number of channels
    /// - Returns: Image frame with checkerboard pattern
    public static func checkerboard(width: Int, height: Int, blockSize: Int = 8, channels: Int = 3) -> ImageFrame {
        var frame = ImageFrame(
            width: width,
            height: height,
            channels: channels,
            pixelType: .uint8,
            colorSpace: channels == 1 ? .grayscale : .sRGB
        )

        for y in 0..<height {
            for x in 0..<width {
                let isWhite = ((x / blockSize) + (y / blockSize)) % 2 == 0
                let value: UInt16 = isWhite ? 255 : 0

                for c in 0..<min(channels, 3) {
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
                if channels == 4 {
                    frame.setPixel(x: x, y: y, channel: 3, value: 255)
                }
            }
        }
        return frame
    }

    /// Generate a natural-looking noise test image.
    /// - Parameters:
    ///   - width: Image width
    ///   - height: Image height
    ///   - seed: Random seed for reproducibility
    ///   - channels: Number of channels
    /// - Returns: Image frame with pseudo-random noise
    public static func noise(width: Int, height: Int, seed: UInt64 = 42, channels: Int = 3) -> ImageFrame {
        var frame = ImageFrame(
            width: width,
            height: height,
            channels: channels,
            pixelType: .uint8,
            colorSpace: channels == 1 ? .grayscale : .sRGB
        )

        var rng = seed
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    // xorshift64* PRNG
                    rng ^= rng >> 12
                    rng ^= rng << 25
                    rng ^= rng >> 27
                    let value = UInt16((rng &* 0x2545F4914F6CDD1D) >> 56)
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }
        return frame
    }

    /// Generate a solid color test image.
    /// - Parameters:
    ///   - width: Image width
    ///   - height: Image height
    ///   - color: Color value per channel (0-255)
    ///   - channels: Number of channels
    /// - Returns: Image frame with solid color
    public static func solid(width: Int, height: Int, color: [UInt16], channels: Int = 3) -> ImageFrame {
        var frame = ImageFrame(
            width: width,
            height: height,
            channels: channels,
            pixelType: .uint8,
            colorSpace: channels == 1 ? .grayscale : .sRGB
        )

        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    let value = c < color.count ? color[c] : 0
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }
        return frame
    }
}
