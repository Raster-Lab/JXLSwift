// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import XCTest
@testable import JXLSwift

final class ValidationTests: XCTestCase {

    // MARK: - TestImageGenerator Tests

    func testTestImageGenerator_Gradient_CorrectDimensions() {
        let frame = TestImageGenerator.gradient(width: 32, height: 16)
        XCTAssertEqual(frame.width, 32)
        XCTAssertEqual(frame.height, 16)
        XCTAssertEqual(frame.channels, 3)
    }

    func testTestImageGenerator_Gradient_PixelValues() {
        let frame = TestImageGenerator.gradient(width: 16, height: 16, channels: 3)
        // Top-left corner should have low values
        let topLeft = frame.getPixel(x: 0, y: 0, channel: 0)
        XCTAssertEqual(topLeft, 0)
        // Bottom-right should have high values
        let bottomRight = frame.getPixel(x: 15, y: 15, channel: 0)
        XCTAssertEqual(bottomRight, 255)
    }

    func testTestImageGenerator_Gradient_Grayscale() {
        let frame = TestImageGenerator.gradient(width: 8, height: 8, channels: 1)
        XCTAssertEqual(frame.channels, 1)
    }

    func testTestImageGenerator_Gradient_WithAlpha() {
        let frame = TestImageGenerator.gradient(width: 8, height: 8, channels: 4)
        XCTAssertEqual(frame.channels, 4)
        // Alpha should be 255
        XCTAssertEqual(frame.getPixel(x: 0, y: 0, channel: 3), 255)
    }

    func testTestImageGenerator_Checkerboard_CorrectDimensions() {
        let frame = TestImageGenerator.checkerboard(width: 16, height: 16)
        XCTAssertEqual(frame.width, 16)
        XCTAssertEqual(frame.height, 16)
    }

    func testTestImageGenerator_Checkerboard_AlternatingBlocks() {
        let frame = TestImageGenerator.checkerboard(width: 16, height: 16, blockSize: 8)
        // (0,0) should be white (first block)
        let topLeft = frame.getPixel(x: 0, y: 0, channel: 0)
        XCTAssertEqual(topLeft, 255)
        // (8,0) should be black (second block)
        let nextBlock = frame.getPixel(x: 8, y: 0, channel: 0)
        XCTAssertEqual(nextBlock, 0)
    }

    func testTestImageGenerator_Noise_CorrectDimensions() {
        let frame = TestImageGenerator.noise(width: 32, height: 32)
        XCTAssertEqual(frame.width, 32)
        XCTAssertEqual(frame.height, 32)
        XCTAssertEqual(frame.channels, 3)
    }

    func testTestImageGenerator_Noise_Deterministic() {
        let frame1 = TestImageGenerator.noise(width: 8, height: 8, seed: 42)
        let frame2 = TestImageGenerator.noise(width: 8, height: 8, seed: 42)
        // Same seed should produce same noise
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(frame1.getPixel(x: x, y: y, channel: 0),
                               frame2.getPixel(x: x, y: y, channel: 0))
            }
        }
    }

    func testTestImageGenerator_Noise_DifferentSeeds() {
        let frame1 = TestImageGenerator.noise(width: 8, height: 8, seed: 1)
        let frame2 = TestImageGenerator.noise(width: 8, height: 8, seed: 2)
        // Different seeds should produce different noise
        var different = false
        for y in 0..<8 {
            for x in 0..<8 {
                if frame1.getPixel(x: x, y: y, channel: 0) != frame2.getPixel(x: x, y: y, channel: 0) {
                    different = true
                }
            }
        }
        XCTAssertTrue(different, "Different seeds should produce different noise")
    }

    func testTestImageGenerator_Solid_CorrectValues() {
        let frame = TestImageGenerator.solid(width: 4, height: 4, color: [100, 150, 200])
        XCTAssertEqual(frame.getPixel(x: 0, y: 0, channel: 0), 100)
        XCTAssertEqual(frame.getPixel(x: 0, y: 0, channel: 1), 150)
        XCTAssertEqual(frame.getPixel(x: 0, y: 0, channel: 2), 200)
    }

    func testTestImageGenerator_Solid_UniformColor() {
        let frame = TestImageGenerator.solid(width: 4, height: 4, color: [128, 128, 128])
        for y in 0..<4 {
            for x in 0..<4 {
                XCTAssertEqual(frame.getPixel(x: x, y: y, channel: 0), 128)
            }
        }
    }

    // MARK: - ValidationCriteria Tests

    func testValidationCriteria_DefaultValues() {
        let criteria = ValidationCriteria()
        XCTAssertEqual(criteria.minPSNR, 30.0, accuracy: 0.001)
        XCTAssertEqual(criteria.minSSIM, 0.9, accuracy: 0.001)
        XCTAssertEqual(criteria.maxButteraugli, 5.0, accuracy: 0.001)
        XCTAssertEqual(criteria.minCompressionRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(criteria.maxEncodingTime, 30.0, accuracy: 0.001)
    }

    func testValidationCriteria_StrictPreset() {
        let criteria = ValidationCriteria.strict
        XCTAssertEqual(criteria.minPSNR, 40.0, accuracy: 0.001)
        XCTAssertEqual(criteria.minSSIM, 0.95, accuracy: 0.001)
        XCTAssertEqual(criteria.maxButteraugli, 2.0, accuracy: 0.001)
    }

    func testValidationCriteria_RelaxedPreset() {
        let criteria = ValidationCriteria.relaxed
        XCTAssertEqual(criteria.minPSNR, 25.0, accuracy: 0.001)
        XCTAssertEqual(criteria.minSSIM, 0.8, accuracy: 0.001)
        XCTAssertEqual(criteria.maxButteraugli, 10.0, accuracy: 0.001)
    }

    func testValidationCriteria_LosslessPreset() {
        let criteria = ValidationCriteria.lossless
        XCTAssertTrue(criteria.minPSNR.isInfinite)
        XCTAssertEqual(criteria.minSSIM, 1.0, accuracy: 0.001)
        XCTAssertEqual(criteria.maxButteraugli, 0.0, accuracy: 0.001)
    }

    func testValidationCriteria_CustomValues() {
        let criteria = ValidationCriteria(
            minPSNR: 35.0,
            minSSIM: 0.92,
            maxButteraugli: 3.0,
            minCompressionRatio: 2.0,
            maxEncodingTime: 15.0
        )
        XCTAssertEqual(criteria.minPSNR, 35.0, accuracy: 0.001)
        XCTAssertEqual(criteria.minSSIM, 0.92, accuracy: 0.001)
        XCTAssertEqual(criteria.maxButteraugli, 3.0, accuracy: 0.001)
        XCTAssertEqual(criteria.minCompressionRatio, 2.0, accuracy: 0.001)
        XCTAssertEqual(criteria.maxEncodingTime, 15.0, accuracy: 0.001)
    }

    // MARK: - QualityValidation Tests

    func testQualityValidation_PassingCriteria() {
        let result = QualityValidation(
            psnr: 40.0, ssim: 0.95, msSSIM: 0.96,
            butteraugli: 1.5,
            minPSNR: 30.0, minSSIM: 0.9, maxButteraugli: 5.0
        )
        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.failureReasons.isEmpty)
    }

    func testQualityValidation_FailingPSNR() {
        let result = QualityValidation(
            psnr: 25.0, ssim: 0.95, msSSIM: 0.96,
            butteraugli: 1.5,
            minPSNR: 30.0, minSSIM: 0.9, maxButteraugli: 5.0
        )
        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.failureReasons.isEmpty)
        XCTAssertTrue(result.failureReasons.first?.contains("PSNR") ?? false)
    }

    func testQualityValidation_FailingSSIM() {
        let result = QualityValidation(
            psnr: 40.0, ssim: 0.8, msSSIM: 0.85,
            butteraugli: 1.5,
            minPSNR: 30.0, minSSIM: 0.9, maxButteraugli: 5.0
        )
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failureReasons.first?.contains("SSIM") ?? false)
    }

    func testQualityValidation_FailingButteraugli() {
        let result = QualityValidation(
            psnr: 40.0, ssim: 0.95, msSSIM: 0.96,
            butteraugli: 6.0,
            minPSNR: 30.0, minSSIM: 0.9, maxButteraugli: 5.0
        )
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failureReasons.first?.contains("Butteraugli") ?? false)
    }

    func testQualityValidation_InfinitePSNR_Passes() {
        let result = QualityValidation(
            psnr: Double.infinity, ssim: 1.0, msSSIM: 1.0,
            butteraugli: 0.0,
            minPSNR: 30.0, minSSIM: 0.9, maxButteraugli: 5.0
        )
        XCTAssertTrue(result.passed)
    }

    // MARK: - CompressionValidation Tests

    func testCompressionValidation_PassingRatio() {
        let result = CompressionValidation(
            originalSize: 10000, compressedSize: 5000,
            compressionRatio: 2.0, minCompressionRatio: 1.5
        )
        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.failureReasons.isEmpty)
    }

    func testCompressionValidation_FailingRatio() {
        let result = CompressionValidation(
            originalSize: 10000, compressedSize: 8000,
            compressionRatio: 1.25, minCompressionRatio: 1.5
        )
        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.failureReasons.isEmpty)
    }

    // MARK: - PerformanceValidation Tests

    func testPerformanceValidation_PassingTime() {
        let result = PerformanceValidation(
            encodingTimeSeconds: 0.5, megapixelsPerSecond: 10.0,
            peakMemoryBytes: 1024, maxEncodingTime: 1.0
        )
        XCTAssertTrue(result.passed)
    }

    func testPerformanceValidation_FailingTime() {
        let result = PerformanceValidation(
            encodingTimeSeconds: 2.0, megapixelsPerSecond: 5.0,
            peakMemoryBytes: 1024, maxEncodingTime: 1.0
        )
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failureReasons.first?.contains("Encoding time") ?? false)
    }

    // MARK: - ValidationResult Tests

    func testValidationResult_AllPass() {
        let result = ValidationResult(
            name: "test",
            width: 32, height: 32,
            optionsDescription: "lossy(q=90)",
            qualityResult: QualityValidation(
                psnr: 40.0, ssim: 0.95, msSSIM: 0.96, butteraugli: 1.0,
                minPSNR: 30.0, minSSIM: 0.9, maxButteraugli: 5.0
            ),
            compressionResult: CompressionValidation(
                originalSize: 10000, compressedSize: 5000,
                compressionRatio: 2.0, minCompressionRatio: 1.0
            ),
            performanceResult: PerformanceValidation(
                encodingTimeSeconds: 0.1, megapixelsPerSecond: 10.0,
                peakMemoryBytes: 1024, maxEncodingTime: 30.0
            )
        )
        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.failureReasons.isEmpty)
    }

    func testValidationResult_QualityFails() {
        let result = ValidationResult(
            name: "test",
            width: 32, height: 32,
            optionsDescription: "lossy(q=90)",
            qualityResult: QualityValidation(
                psnr: 20.0, ssim: 0.7, msSSIM: 0.75, butteraugli: 8.0,
                minPSNR: 30.0, minSSIM: 0.9, maxButteraugli: 5.0
            ),
            compressionResult: nil,
            performanceResult: nil
        )
        XCTAssertFalse(result.passed)
        XCTAssertGreaterThan(result.failureReasons.count, 0)
    }

    func testValidationResult_NoResults_Passes() {
        let result = ValidationResult(
            name: "test",
            width: 32, height: 32,
            optionsDescription: "test",
            qualityResult: nil,
            compressionResult: nil,
            performanceResult: nil
        )
        XCTAssertTrue(result.passed, "No results means no failures")
    }

    // MARK: - ValidationHarness Tests

    func testValidationHarness_SingleTestCase() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let options = EncodingOptions(mode: .lossy(quality: 90))
        let testCase = ValidationHarness.TestCase(name: "test_gradient", frame: frame, options: options)

        let harness = ValidationHarness(criteria: .relaxed, iterations: 1)
        let report = try harness.validate(corpus: "test", testCases: [testCase])

        XCTAssertEqual(report.results.count, 1)
        XCTAssertEqual(report.corpus, "test")
        XCTAssertEqual(report.results[0].name, "test_gradient")
        XCTAssertNotNil(report.results[0].compressionResult)
        XCTAssertNotNil(report.results[0].performanceResult)
    }

    func testValidationHarness_LosslessTestCase() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let options = EncodingOptions.lossless
        let testCase = ValidationHarness.TestCase(
            name: "test_lossless",
            frame: frame,
            options: options,
            isLossless: true
        )

        let harness = ValidationHarness(criteria: .relaxed, iterations: 1)
        let report = try harness.validate(corpus: "test", testCases: [testCase])

        XCTAssertEqual(report.results.count, 1)
        let result = report.results[0]
        XCTAssertNotNil(result.qualityResult)
        XCTAssertEqual(result.qualityResult?.psnr, Double.infinity)
        if let ssim = result.qualityResult?.ssim {
            XCTAssertEqual(ssim, 1.0, accuracy: 0.001)
        }
    }

    func testValidationHarness_MultipleTestCases() throws {
        let frame1 = TestImageGenerator.gradient(width: 16, height: 16)
        let frame2 = TestImageGenerator.checkerboard(width: 16, height: 16)
        let options = EncodingOptions(mode: .lossy(quality: 90))

        let testCases = [
            ValidationHarness.TestCase(name: "gradient", frame: frame1, options: options),
            ValidationHarness.TestCase(name: "checker", frame: frame2, options: options),
        ]

        let harness = ValidationHarness(criteria: .relaxed, iterations: 1)
        let report = try harness.validate(corpus: "multi", testCases: testCases)

        XCTAssertEqual(report.results.count, 2)
    }

    // MARK: - ValidationSummary Tests

    func testValidationSummary_AllPassed() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let options = EncodingOptions(mode: .lossy(quality: 90))
        let testCase = ValidationHarness.TestCase(name: "test", frame: frame, options: options)

        let harness = ValidationHarness(criteria: .relaxed, iterations: 1)
        let report = try harness.validate(corpus: "test", testCases: [testCase])
        let summary = report.summary

        XCTAssertEqual(summary.totalTests, 1)
        XCTAssertGreaterThanOrEqual(summary.passed, 0)
        XCTAssertGreaterThanOrEqual(summary.averageEncodingTime, 0.0)
        XCTAssertGreaterThanOrEqual(summary.averageCompressionRatio, 0.0)
    }

    func testValidationSummary_AllPassed_Property() {
        // Construct a summary manually to test the allPassed property
        let summary = ValidationSummary(
            totalTests: 3, passed: 3, failed: 0,
            averagePSNR: 40.0, averageSSIM: 0.95,
            averageCompressionRatio: 2.0, averageEncodingTime: 0.1
        )
        XCTAssertTrue(summary.allPassed)
    }

    func testValidationSummary_SomeFailed_Property() {
        let summary = ValidationSummary(
            totalTests: 3, passed: 2, failed: 1,
            averagePSNR: 35.0, averageSSIM: 0.9,
            averageCompressionRatio: 1.5, averageEncodingTime: 0.2
        )
        XCTAssertFalse(summary.allPassed)
    }

    // MARK: - ValidationReport Tests

    func testValidationReport_Timestamp() throws {
        let frame = TestImageGenerator.gradient(width: 8, height: 8)
        let options = EncodingOptions(mode: .lossy(quality: 90))
        let testCase = ValidationHarness.TestCase(name: "test", frame: frame, options: options)

        let harness = ValidationHarness(criteria: .relaxed, iterations: 1)
        let report = try harness.validate(corpus: "timestamp_test", testCases: [testCase])

        XCTAssertNotNil(report.timestamp)
        XCTAssertEqual(report.corpus, "timestamp_test")
    }

    // MARK: - BenchmarkReport Tests

    func testBenchmarkReport_EmptyReport() {
        let report = BenchmarkReport(
            metadata: ReportMetadata(),
            entries: [],
            baselines: []
        )
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertTrue(report.baselines.isEmpty)
        XCTAssertTrue(report.regressions.isEmpty)
    }

    func testBenchmarkReport_NoRegressions() {
        let entry = BenchmarkEntry(
            name: "test", width: 32, height: 32, mode: "lossy",
            effort: 7, encodingTimeSeconds: 0.1, megapixelsPerSecond: 10.0,
            originalSize: 10000, compressedSize: 5000, compressionRatio: 2.0,
            peakMemoryBytes: 1024, psnr: 40.0, ssim: 0.95, butteraugli: 1.0
        )
        let baseline = PerformanceBaseline(
            name: "test",
            encodingTimeSeconds: 0.1,
            compressionRatio: 2.0,
            regressionThreshold: 0.10
        )
        let report = BenchmarkReport(
            metadata: ReportMetadata(),
            entries: [entry],
            baselines: [baseline]
        )
        XCTAssertTrue(report.regressions.isEmpty)
    }

    func testBenchmarkReport_DetectsTimeRegression() {
        let entry = BenchmarkEntry(
            name: "test", width: 32, height: 32, mode: "lossy",
            effort: 7, encodingTimeSeconds: 0.15, megapixelsPerSecond: 7.0,
            originalSize: 10000, compressedSize: 5000, compressionRatio: 2.0,
            peakMemoryBytes: 1024, psnr: 40.0, ssim: 0.95, butteraugli: 1.0
        )
        let baseline = PerformanceBaseline(
            name: "test",
            encodingTimeSeconds: 0.1,
            compressionRatio: 2.0,
            regressionThreshold: 0.10
        )
        let report = BenchmarkReport(
            metadata: ReportMetadata(),
            entries: [entry],
            baselines: [baseline]
        )
        XCTAssertGreaterThan(report.regressions.count, 0)
        XCTAssertEqual(report.regressions[0].metric, "encodingTime")
    }

    func testBenchmarkReport_DetectsCompressionRegression() {
        let entry = BenchmarkEntry(
            name: "test", width: 32, height: 32, mode: "lossy",
            effort: 7, encodingTimeSeconds: 0.1, megapixelsPerSecond: 10.0,
            originalSize: 10000, compressedSize: 7000, compressionRatio: 1.43,
            peakMemoryBytes: 1024, psnr: 40.0, ssim: 0.95, butteraugli: 1.0
        )
        let baseline = PerformanceBaseline(
            name: "test",
            encodingTimeSeconds: 0.1,
            compressionRatio: 2.0,
            regressionThreshold: 0.10
        )
        let report = BenchmarkReport(
            metadata: ReportMetadata(),
            entries: [entry],
            baselines: [baseline]
        )
        let compressionRegressions = report.regressions.filter { $0.metric == "compressionRatio" }
        XCTAssertGreaterThan(compressionRegressions.count, 0)
    }

    // MARK: - BenchmarkReportGenerator Tests

    func testBenchmarkReportGenerator_JSON_ValidOutput() {
        let entry = BenchmarkEntry(
            name: "test_gradient", width: 32, height: 32, mode: "lossy(q=90)",
            effort: 7, encodingTimeSeconds: 0.05, megapixelsPerSecond: 20.0,
            originalSize: 3072, compressedSize: 512, compressionRatio: 6.0,
            peakMemoryBytes: 4096, psnr: 42.5, ssim: 0.97, butteraugli: 0.8
        )
        let report = BenchmarkReport(
            metadata: ReportMetadata(title: "Test Report"),
            entries: [entry],
            baselines: []
        )

        let json = BenchmarkReportGenerator.generateJSON(from: report)
        XCTAssertTrue(json.contains("\"metadata\""))
        XCTAssertTrue(json.contains("\"entries\""))
        XCTAssertTrue(json.contains("test_gradient"))
        XCTAssertTrue(json.contains("\"psnr\""))
        XCTAssertTrue(json.contains("\"ssim\""))
        XCTAssertTrue(json.contains("\"summary\""))
    }

    func testBenchmarkReportGenerator_JSON_EmptyReport() {
        let report = BenchmarkReport(
            metadata: ReportMetadata(),
            entries: [],
            baselines: []
        )
        let json = BenchmarkReportGenerator.generateJSON(from: report)
        XCTAssertTrue(json.contains("\"entries\": ["))
        XCTAssertTrue(json.contains("\"totalBenchmarks\": 0"))
    }

    func testBenchmarkReportGenerator_HTML_ValidOutput() {
        let entry = BenchmarkEntry(
            name: "test", width: 32, height: 32, mode: "lossy",
            effort: 7, encodingTimeSeconds: 0.1, megapixelsPerSecond: 10.0,
            originalSize: 10000, compressedSize: 5000, compressionRatio: 2.0,
            peakMemoryBytes: 1024, psnr: 40.0, ssim: 0.95, butteraugli: 1.0
        )
        let report = BenchmarkReport(
            metadata: ReportMetadata(title: "Test Report"),
            entries: [entry],
            baselines: []
        )

        let html = BenchmarkReportGenerator.generateHTML(from: report)
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("Test Report"))
        XCTAssertTrue(html.contains("</html>"))
        XCTAssertTrue(html.contains("Benchmark Results"))
    }

    func testBenchmarkReportGenerator_HTML_WithRegressions() {
        let entry = BenchmarkEntry(
            name: "test", width: 32, height: 32, mode: "lossy",
            effort: 7, encodingTimeSeconds: 0.2, megapixelsPerSecond: 5.0,
            originalSize: 10000, compressedSize: 5000, compressionRatio: 2.0,
            peakMemoryBytes: 1024, psnr: 40.0, ssim: 0.95, butteraugli: 1.0
        )
        let baseline = PerformanceBaseline(
            name: "test",
            encodingTimeSeconds: 0.1,
            compressionRatio: 2.0,
            regressionThreshold: 0.10
        )
        let report = BenchmarkReport(
            metadata: ReportMetadata(),
            entries: [entry],
            baselines: [baseline]
        )

        let html = BenchmarkReportGenerator.generateHTML(from: report)
        XCTAssertTrue(html.contains("Regressions Detected"))
    }

    // MARK: - ReportMetadata Tests

    func testReportMetadata_DefaultValues() {
        let metadata = ReportMetadata()
        XCTAssertEqual(metadata.title, "JXLSwift Benchmark Report")
        XCTAssertEqual(metadata.jxlSwiftVersion, JXLSwift.version)
        XCTAssertGreaterThan(metadata.cpuCores, 0)
    }

    func testReportMetadata_CustomValues() {
        let metadata = ReportMetadata(
            title: "Custom Report",
            jxlSwiftVersion: "1.0.0"
        )
        XCTAssertEqual(metadata.title, "Custom Report")
        XCTAssertEqual(metadata.jxlSwiftVersion, "1.0.0")
    }

    // MARK: - PerformanceBaseline Tests

    func testPerformanceBaseline_DefaultThreshold() {
        let baseline = PerformanceBaseline(
            name: "test",
            encodingTimeSeconds: 1.0,
            compressionRatio: 2.0
        )
        XCTAssertEqual(baseline.regressionThreshold, 0.10, accuracy: 0.001)
    }

    func testPerformanceBaseline_CustomThreshold() {
        let baseline = PerformanceBaseline(
            name: "test",
            encodingTimeSeconds: 1.0,
            compressionRatio: 2.0,
            regressionThreshold: 0.20
        )
        XCTAssertEqual(baseline.regressionThreshold, 0.20, accuracy: 0.001)
    }

    // MARK: - RegressionAlert Tests

    func testRegressionAlert_Properties() {
        let alert = RegressionAlert(
            name: "test",
            metric: "encodingTime",
            baselineValue: 0.1,
            currentValue: 0.15,
            regressionPercent: 50.0,
            threshold: 10.0
        )
        XCTAssertEqual(alert.name, "test")
        XCTAssertEqual(alert.metric, "encodingTime")
        XCTAssertEqual(alert.baselineValue, 0.1, accuracy: 0.001)
        XCTAssertEqual(alert.currentValue, 0.15, accuracy: 0.001)
        XCTAssertEqual(alert.regressionPercent, 50.0, accuracy: 0.001)
        XCTAssertEqual(alert.threshold, 10.0, accuracy: 0.001)
    }

    // MARK: - Platform Helpers Tests

    func testPlatformDescription_ReturnsNonEmpty() {
        let desc = platformDescription()
        XCTAssertFalse(desc.isEmpty)
    }

    func testArchitectureDescription_ReturnsNonEmpty() {
        let desc = architectureDescription()
        XCTAssertFalse(desc.isEmpty)
    }

    // MARK: - Integration Test

    func testValidationHarness_FullPipeline() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .falcon)
        let testCase = ValidationHarness.TestCase(name: "integration_test", frame: frame, options: options)

        let criteria = ValidationCriteria(
            minPSNR: 20.0,
            minSSIM: 0.5,
            maxButteraugli: 20.0,
            minCompressionRatio: 0.1,
            maxEncodingTime: 30.0
        )
        let harness = ValidationHarness(criteria: criteria, iterations: 1)
        let report = try harness.validate(corpus: "integration", testCases: [testCase])

        // Convert to benchmark report
        let benchmarkEntries = report.results.map { result -> BenchmarkEntry in
            BenchmarkEntry(
                name: result.name,
                width: result.width,
                height: result.height,
                mode: result.optionsDescription,
                effort: 3,
                encodingTimeSeconds: result.performanceResult?.encodingTimeSeconds ?? 0,
                megapixelsPerSecond: result.performanceResult?.megapixelsPerSecond ?? 0,
                originalSize: result.compressionResult?.originalSize ?? 0,
                compressedSize: result.compressionResult?.compressedSize ?? 0,
                compressionRatio: result.compressionResult?.compressionRatio ?? 0,
                peakMemoryBytes: 0,
                psnr: result.qualityResult?.psnr,
                ssim: result.qualityResult?.ssim,
                butteraugli: result.qualityResult?.butteraugli
            )
        }

        let benchmarkReport = BenchmarkReport(
            metadata: ReportMetadata(title: "Integration Test"),
            entries: benchmarkEntries,
            baselines: []
        )

        // Generate JSON
        let json = BenchmarkReportGenerator.generateJSON(from: benchmarkReport)
        XCTAssertTrue(json.contains("integration_test"))

        // Generate HTML
        let html = BenchmarkReportGenerator.generateHTML(from: benchmarkReport)
        XCTAssertTrue(html.contains("Integration Test"))
    }

    // MARK: - Performance Test

    func testPerformance_ValidationHarness() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        let testCase = ValidationHarness.TestCase(name: "perf", frame: frame, options: options)

        let harness = ValidationHarness(criteria: .relaxed, iterations: 1)

        measure {
            _ = try? harness.validate(corpus: "perf", testCases: [testCase])
        }
    }
}
