// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import XCTest
@testable import JXLSwift

final class BitstreamValidatorTests: XCTestCase {

    // MARK: - StructuralCheck Tests

    func testStructuralCheck_Properties() {
        let check = StructuralCheck(name: "test_check", passed: true, message: "All good")
        XCTAssertEqual(check.name, "test_check")
        XCTAssertTrue(check.passed)
        XCTAssertEqual(check.message, "All good")
    }

    func testStructuralCheck_FailedProperties() {
        let check = StructuralCheck(name: "sig_check", passed: false, message: "Missing signature")
        XCTAssertEqual(check.name, "sig_check")
        XCTAssertFalse(check.passed)
        XCTAssertEqual(check.message, "Missing signature")
    }

    // MARK: - Structural Validation Tests

    func testValidateStructure_ValidJXLData() throws {
        let frame = TestImageGenerator.gradient(width: 8, height: 8)
        let encoder = JXLEncoder(options: .lossless)
        let result = try encoder.encode(frame)

        let validator = BitstreamValidator(useLibjxl: false)
        let checks = validator.validateStructure(result.data)

        XCTAssertGreaterThanOrEqual(checks.count, 6)
        for check in checks {
            XCTAssertTrue(check.passed, "Check '\(check.name)' failed: \(check.message)")
        }
    }

    func testValidateStructure_ValidLossyData() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90)))
        let result = try encoder.encode(frame)

        let validator = BitstreamValidator(useLibjxl: false)
        let checks = validator.validateStructure(result.data)

        for check in checks {
            XCTAssertTrue(check.passed, "Check '\(check.name)' failed: \(check.message)")
        }
    }

    func testValidateStructure_EmptyData() {
        let validator = BitstreamValidator(useLibjxl: false)
        let checks = validator.validateStructure(Data())

        let sizeCheck = checks.first { $0.name == "minimum_size" }
        XCTAssertNotNil(sizeCheck)
        XCTAssertFalse(sizeCheck!.passed)
    }

    func testValidateStructure_SingleByte() {
        let validator = BitstreamValidator(useLibjxl: false)
        let checks = validator.validateStructure(Data([0xFF]))

        let sizeCheck = checks.first { $0.name == "minimum_size" }
        XCTAssertNotNil(sizeCheck)
        XCTAssertFalse(sizeCheck!.passed)
    }

    func testValidateStructure_InvalidSignature() {
        let validator = BitstreamValidator(useLibjxl: false)
        let data = Data([0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let checks = validator.validateStructure(data)

        let sigCheck = checks.first { $0.name == "jxl_signature" }
        XCTAssertNotNil(sigCheck)
        XCTAssertFalse(sigCheck!.passed)
    }

    func testValidateStructure_CorrectSignature() {
        let validator = BitstreamValidator(useLibjxl: false)
        let data = Data([0xFF, 0x0A, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let checks = validator.validateStructure(data)

        let sigCheck = checks.first { $0.name == "jxl_signature" }
        XCTAssertNotNil(sigCheck)
        XCTAssertTrue(sigCheck!.passed)
    }

    func testValidateStructure_TooSmallForHeader() {
        let validator = BitstreamValidator(useLibjxl: false)
        let data = Data([0xFF, 0x0A, 0x01])
        let checks = validator.validateStructure(data)

        let headerCheck = checks.first { $0.name == "header_present" }
        XCTAssertNotNil(headerCheck)
        XCTAssertFalse(headerCheck!.passed)
    }

    func testValidateStructure_AllZerosAfterSignature() {
        let validator = BitstreamValidator(useLibjxl: false)
        let data = Data([0xFF, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let checks = validator.validateStructure(data)

        let contentCheck = checks.first { $0.name == "non_empty_content" }
        XCTAssertNotNil(contentCheck)
        XCTAssertFalse(contentCheck!.passed)
    }

    func testValidateStructure_ReasonableSize() {
        let validator = BitstreamValidator(useLibjxl: false)

        // Too small
        let smallData = Data([0xFF, 0x0A, 0x01, 0x02])
        let smallChecks = validator.validateStructure(smallData)
        let smallSizeCheck = smallChecks.first { $0.name == "reasonable_size" }
        XCTAssertNotNil(smallSizeCheck)
        XCTAssertFalse(smallSizeCheck!.passed)

        // Reasonable
        let goodData = Data([0xFF, 0x0A, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let goodChecks = validator.validateStructure(goodData)
        let goodSizeCheck = goodChecks.first { $0.name == "reasonable_size" }
        XCTAssertNotNil(goodSizeCheck)
        XCTAssertTrue(goodSizeCheck!.passed)
    }

    func testValidateStructure_CheckCount() {
        let validator = BitstreamValidator(useLibjxl: false)
        let data = Data([0xFF, 0x0A, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let checks = validator.validateStructure(data)

        XCTAssertEqual(checks.count, 6, "Should have exactly 6 structural checks")
    }

    // MARK: - BitstreamValidationResult Tests

    func testBitstreamValidationResult_AllPassed() {
        let checks = [
            StructuralCheck(name: "sig", passed: true, message: "OK"),
            StructuralCheck(name: "size", passed: true, message: "OK"),
        ]
        let result = BitstreamValidationResult(
            name: "test", width: 8, height: 8, mode: "lossless",
            compressedSize: 100, structuralChecks: checks, libjxlResult: nil
        )
        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.failureReasons.isEmpty)
    }

    func testBitstreamValidationResult_StructuralFailure() {
        let checks = [
            StructuralCheck(name: "sig", passed: false, message: "Missing signature"),
            StructuralCheck(name: "size", passed: true, message: "OK"),
        ]
        let result = BitstreamValidationResult(
            name: "test", width: 8, height: 8, mode: "lossless",
            compressedSize: 100, structuralChecks: checks, libjxlResult: nil
        )
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.failureReasons.count, 1)
        XCTAssertTrue(result.failureReasons[0].contains("Missing signature"))
    }

    func testBitstreamValidationResult_LibjxlFailure() {
        let checks = [
            StructuralCheck(name: "sig", passed: true, message: "OK"),
        ]
        let ljResult = LibjxlDecodeResult(
            passed: false,
            errorMessage: "decode failed",
            decodeTimeSeconds: nil
        )
        let result = BitstreamValidationResult(
            name: "test", width: 8, height: 8, mode: "lossless",
            compressedSize: 100, structuralChecks: checks, libjxlResult: ljResult
        )
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.failureReasons.count, 1)
        XCTAssertTrue(result.failureReasons[0].contains("libjxl decode"))
    }

    func testBitstreamValidationResult_LibjxlPassed() {
        let checks = [
            StructuralCheck(name: "sig", passed: true, message: "OK"),
        ]
        let ljResult = LibjxlDecodeResult(
            passed: true,
            errorMessage: "",
            decodeTimeSeconds: 0.05
        )
        let result = BitstreamValidationResult(
            name: "test", width: 8, height: 8, mode: "lossless",
            compressedSize: 100, structuralChecks: checks, libjxlResult: ljResult
        )
        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.failureReasons.isEmpty)
    }

    func testBitstreamValidationResult_BothFailures() {
        let checks = [
            StructuralCheck(name: "sig", passed: false, message: "bad sig"),
        ]
        let ljResult = LibjxlDecodeResult(
            passed: false,
            errorMessage: "decode error",
            decodeTimeSeconds: nil
        )
        let result = BitstreamValidationResult(
            name: "test", width: 8, height: 8, mode: "lossless",
            compressedSize: 100, structuralChecks: checks, libjxlResult: ljResult
        )
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.failureReasons.count, 2)
    }

    // MARK: - LibjxlDecodeResult Tests

    func testLibjxlDecodeResult_Success() {
        let result = LibjxlDecodeResult(
            passed: true,
            errorMessage: "",
            decodeTimeSeconds: 0.123
        )
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.errorMessage, "")
        if let time = result.decodeTimeSeconds {
            XCTAssertEqual(time, 0.123, accuracy: 0.001)
        } else {
            XCTFail("decodeTimeSeconds should not be nil")
        }
    }

    func testLibjxlDecodeResult_Failure() {
        let result = LibjxlDecodeResult(
            passed: false,
            errorMessage: "djxl exited with status 1",
            decodeTimeSeconds: nil
        )
        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.errorMessage.isEmpty)
        XCTAssertNil(result.decodeTimeSeconds)
    }

    // MARK: - BitstreamValidationReport Tests

    func testBitstreamValidationReport_EmptyResults() {
        let report = BitstreamValidationReport(
            timestamp: Date(),
            corpus: "test",
            libjxlAvailable: false,
            results: []
        )
        XCTAssertEqual(report.summary.totalTests, 0)
        XCTAssertEqual(report.summary.passed, 0)
        XCTAssertEqual(report.summary.failed, 0)
        XCTAssertTrue(report.summary.allPassed)
    }

    func testBitstreamValidationReport_AllPassed() {
        let checks = [StructuralCheck(name: "sig", passed: true, message: "OK")]
        let results = [
            BitstreamValidationResult(
                name: "test1", width: 8, height: 8, mode: "lossless",
                compressedSize: 100, structuralChecks: checks, libjxlResult: nil
            ),
            BitstreamValidationResult(
                name: "test2", width: 16, height: 16, mode: "lossy(q=90.0)",
                compressedSize: 200, structuralChecks: checks, libjxlResult: nil
            ),
        ]
        let report = BitstreamValidationReport(
            timestamp: Date(),
            corpus: "test",
            libjxlAvailable: false,
            results: results
        )
        XCTAssertEqual(report.summary.totalTests, 2)
        XCTAssertEqual(report.summary.passed, 2)
        XCTAssertEqual(report.summary.failed, 0)
        XCTAssertTrue(report.summary.allPassed)
    }

    func testBitstreamValidationReport_SomeFailed() {
        let passChecks = [StructuralCheck(name: "sig", passed: true, message: "OK")]
        let failChecks = [StructuralCheck(name: "sig", passed: false, message: "bad")]
        let results = [
            BitstreamValidationResult(
                name: "test1", width: 8, height: 8, mode: "lossless",
                compressedSize: 100, structuralChecks: passChecks, libjxlResult: nil
            ),
            BitstreamValidationResult(
                name: "test2", width: 8, height: 8, mode: "lossless",
                compressedSize: 50, structuralChecks: failChecks, libjxlResult: nil
            ),
        ]
        let report = BitstreamValidationReport(
            timestamp: Date(),
            corpus: "test",
            libjxlAvailable: false,
            results: results
        )
        XCTAssertEqual(report.summary.totalTests, 2)
        XCTAssertEqual(report.summary.passed, 1)
        XCTAssertEqual(report.summary.failed, 1)
        XCTAssertFalse(report.summary.allPassed)
    }

    func testBitstreamValidationReport_LibjxlCounts() {
        let checks = [StructuralCheck(name: "sig", passed: true, message: "OK")]
        let ljPass = LibjxlDecodeResult(passed: true, errorMessage: "", decodeTimeSeconds: 0.1)
        let ljFail = LibjxlDecodeResult(passed: false, errorMessage: "error", decodeTimeSeconds: nil)
        let results = [
            BitstreamValidationResult(
                name: "test1", width: 8, height: 8, mode: "lossless",
                compressedSize: 100, structuralChecks: checks, libjxlResult: ljPass
            ),
            BitstreamValidationResult(
                name: "test2", width: 8, height: 8, mode: "lossless",
                compressedSize: 100, structuralChecks: checks, libjxlResult: ljFail
            ),
            BitstreamValidationResult(
                name: "test3", width: 8, height: 8, mode: "lossless",
                compressedSize: 100, structuralChecks: checks, libjxlResult: nil
            ),
        ]
        let report = BitstreamValidationReport(
            timestamp: Date(),
            corpus: "test",
            libjxlAvailable: true,
            results: results
        )
        XCTAssertEqual(report.summary.libjxlTested, 2)
        XCTAssertEqual(report.summary.libjxlPassed, 1)
        XCTAssertEqual(report.summary.structuralPassed, 3)
    }

    // MARK: - BitstreamValidationSummary Tests

    func testBitstreamValidationSummary_AllPassed() {
        let summary = BitstreamValidationSummary(
            totalTests: 5, passed: 5, failed: 0,
            structuralPassed: 5, libjxlTested: 3, libjxlPassed: 3
        )
        XCTAssertTrue(summary.allPassed)
        XCTAssertEqual(summary.totalTests, 5)
        XCTAssertEqual(summary.passed, 5)
        XCTAssertEqual(summary.failed, 0)
    }

    func testBitstreamValidationSummary_SomeFailed() {
        let summary = BitstreamValidationSummary(
            totalTests: 5, passed: 3, failed: 2,
            structuralPassed: 4, libjxlTested: 3, libjxlPassed: 2
        )
        XCTAssertFalse(summary.allPassed)
        XCTAssertEqual(summary.failed, 2)
    }

    // MARK: - BitstreamValidator Initialization Tests

    func testBitstreamValidator_DefaultInit() {
        let validator = BitstreamValidator()
        XCTAssertTrue(validator.useLibjxl)
        XCTAssertNil(validator.djxlPath)
    }

    func testBitstreamValidator_NoLibjxlInit() {
        let validator = BitstreamValidator(useLibjxl: false)
        XCTAssertFalse(validator.useLibjxl)
    }

    func testBitstreamValidator_CustomDjxlPath() {
        let validator = BitstreamValidator(djxlPath: "/usr/local/bin/djxl")
        XCTAssertEqual(validator.djxlPath, "/usr/local/bin/djxl")
    }

    // MARK: - Standard Test Cases Tests

    func testStandardTestCases_Count() {
        let cases = BitstreamValidator.standardTestCases()
        XCTAssertEqual(cases.count, 9)
    }

    func testStandardTestCases_UniqueNames() {
        let cases = BitstreamValidator.standardTestCases()
        let names = Set(cases.map(\.name))
        XCTAssertEqual(names.count, cases.count, "All test case names should be unique")
    }

    func testStandardTestCases_IncludesLossless() {
        let cases = BitstreamValidator.standardTestCases()
        let losslessCases = cases.filter { $0.name.contains("lossless") }
        XCTAssertGreaterThanOrEqual(losslessCases.count, 3)
    }

    func testStandardTestCases_IncludesLossy() {
        let cases = BitstreamValidator.standardTestCases()
        let lossyCases = cases.filter { $0.name.contains("lossy") }
        XCTAssertGreaterThanOrEqual(lossyCases.count, 3)
    }

    func testStandardTestCases_IncludesDistance() {
        let cases = BitstreamValidator.standardTestCases()
        let distCases = cases.filter { $0.name.contains("distance") }
        XCTAssertGreaterThanOrEqual(distCases.count, 1)
    }

    func testStandardTestCases_IncludesGrayscale() {
        let cases = BitstreamValidator.standardTestCases()
        let grayCases = cases.filter { $0.name.contains("grayscale") }
        XCTAssertGreaterThanOrEqual(grayCases.count, 1)
    }

    func testStandardTestCases_Includes1x1() {
        let cases = BitstreamValidator.standardTestCases()
        let tinyCases = cases.filter { $0.name.contains("1x1") }
        XCTAssertGreaterThanOrEqual(tinyCases.count, 1)
    }

    func testStandardTestCases_CustomDimensions() {
        let cases = BitstreamValidator.standardTestCases(width: 64, height: 48)
        let gradientCase = cases.first { $0.name == "lossless_gradient" }
        XCTAssertNotNil(gradientCase)
        XCTAssertEqual(gradientCase?.frame.width, 64)
        XCTAssertEqual(gradientCase?.frame.height, 48)
    }

    // MARK: - Full Validation Pipeline Tests

    func testValidate_LosslessGradient() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let testCase = BitstreamValidator.TestCase(
            name: "lossless_gradient",
            frame: frame,
            options: .lossless
        )

        let validator = BitstreamValidator(useLibjxl: false)
        let report = try validator.validate(corpus: "test", testCases: [testCase])

        XCTAssertEqual(report.results.count, 1)
        XCTAssertEqual(report.corpus, "test")
        XCTAssertFalse(report.libjxlAvailable)
        XCTAssertTrue(report.results[0].passed)
        XCTAssertEqual(report.results[0].name, "lossless_gradient")
        XCTAssertEqual(report.results[0].width, 16)
        XCTAssertEqual(report.results[0].height, 16)
        XCTAssertEqual(report.results[0].mode, "lossless")
        XCTAssertGreaterThan(report.results[0].compressedSize, 0)
        XCTAssertNil(report.results[0].libjxlResult)
    }

    func testValidate_LossyGradient() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let testCase = BitstreamValidator.TestCase(
            name: "lossy_q90",
            frame: frame,
            options: EncodingOptions(mode: .lossy(quality: 90))
        )

        let validator = BitstreamValidator(useLibjxl: false)
        let report = try validator.validate(corpus: "test", testCases: [testCase])

        XCTAssertTrue(report.results[0].passed)
        XCTAssertTrue(report.results[0].mode.contains("lossy"))
    }

    func testValidate_DistanceMode() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let testCase = BitstreamValidator.TestCase(
            name: "distance_1.0",
            frame: frame,
            options: EncodingOptions(mode: .distance(1.0))
        )

        let validator = BitstreamValidator(useLibjxl: false)
        let report = try validator.validate(corpus: "test", testCases: [testCase])

        XCTAssertTrue(report.results[0].passed)
        XCTAssertTrue(report.results[0].mode.contains("distance"))
    }

    func testValidate_MultipleTestCases() throws {
        let cases = [
            BitstreamValidator.TestCase(
                name: "gradient",
                frame: TestImageGenerator.gradient(width: 8, height: 8),
                options: .lossless
            ),
            BitstreamValidator.TestCase(
                name: "checker",
                frame: TestImageGenerator.checkerboard(width: 8, height: 8),
                options: .lossless
            ),
            BitstreamValidator.TestCase(
                name: "noise",
                frame: TestImageGenerator.noise(width: 8, height: 8),
                options: .lossless
            ),
        ]

        let validator = BitstreamValidator(useLibjxl: false)
        let report = try validator.validate(corpus: "multi", testCases: cases)

        XCTAssertEqual(report.results.count, 3)
        XCTAssertEqual(report.summary.totalTests, 3)
        XCTAssertEqual(report.summary.passed, 3)
        XCTAssertTrue(report.summary.allPassed)
    }

    func testValidate_StandardTestCases() throws {
        let cases = BitstreamValidator.standardTestCases(width: 8, height: 8)
        let validator = BitstreamValidator(useLibjxl: false)
        let report = try validator.validate(corpus: "standard", testCases: cases)

        XCTAssertEqual(report.results.count, cases.count)
        for result in report.results {
            XCTAssertTrue(result.passed, "Test case '\(result.name)' failed: \(result.failureReasons)")
        }
        XCTAssertTrue(report.summary.allPassed)
    }

    func testValidate_ReportTimestamp() throws {
        let beforeTime = Date()
        let frame = TestImageGenerator.gradient(width: 8, height: 8)
        let testCase = BitstreamValidator.TestCase(
            name: "test", frame: frame, options: .lossless
        )
        let validator = BitstreamValidator(useLibjxl: false)
        let report = try validator.validate(corpus: "test", testCases: [testCase])
        let afterTime = Date()

        XCTAssertGreaterThanOrEqual(report.timestamp, beforeTime)
        XCTAssertLessThanOrEqual(report.timestamp, afterTime)
    }

    // MARK: - libjxl Availability Tests

    func testIsLibjxlAvailable_InvalidPath() {
        let validator = BitstreamValidator(djxlPath: "/nonexistent/path/djxl")
        XCTAssertFalse(validator.isLibjxlAvailable())
    }

    func testIsLibjxlAvailable_NoLibjxl() {
        // Verify the useLibjxl property is correctly set to false when initialized with false
        let validator = BitstreamValidator(useLibjxl: false)
        XCTAssertFalse(validator.useLibjxl)
    }

    // MARK: - Edge Case Tests

    func testValidate_GrayscaleImage() throws {
        let frame = TestImageGenerator.gradient(width: 8, height: 8, channels: 1)
        let testCase = BitstreamValidator.TestCase(
            name: "grayscale",
            frame: frame,
            options: .lossless
        )

        let validator = BitstreamValidator(useLibjxl: false)
        let report = try validator.validate(corpus: "test", testCases: [testCase])

        XCTAssertTrue(report.results[0].passed)
    }

    func testValidate_SmallImage_1x1() throws {
        let frame = TestImageGenerator.gradient(width: 1, height: 1)
        let testCase = BitstreamValidator.TestCase(
            name: "tiny",
            frame: frame,
            options: .lossless
        )

        let validator = BitstreamValidator(useLibjxl: false)
        let report = try validator.validate(corpus: "test", testCases: [testCase])

        XCTAssertTrue(report.results[0].passed)
    }

    func testValidate_CheckerboardPattern() throws {
        let frame = TestImageGenerator.checkerboard(width: 16, height: 16, blockSize: 4)
        let testCase = BitstreamValidator.TestCase(
            name: "checker",
            frame: frame,
            options: EncodingOptions(mode: .lossy(quality: 75))
        )

        let validator = BitstreamValidator(useLibjxl: false)
        let report = try validator.validate(corpus: "test", testCases: [testCase])

        XCTAssertTrue(report.results[0].passed)
    }

    func testValidate_SolidColor() throws {
        let frame = TestImageGenerator.solid(width: 8, height: 8, color: [128, 128, 128])
        let testCase = BitstreamValidator.TestCase(
            name: "solid",
            frame: frame,
            options: .lossless
        )

        let validator = BitstreamValidator(useLibjxl: false)
        let report = try validator.validate(corpus: "test", testCases: [testCase])

        XCTAssertTrue(report.results[0].passed)
    }

    func testValidate_NoiseImage() throws {
        let frame = TestImageGenerator.noise(width: 16, height: 16, seed: 99)
        let testCase = BitstreamValidator.TestCase(
            name: "noise",
            frame: frame,
            options: EncodingOptions(mode: .lossy(quality: 50))
        )

        let validator = BitstreamValidator(useLibjxl: false)
        let report = try validator.validate(corpus: "test", testCases: [testCase])

        XCTAssertTrue(report.results[0].passed)
    }

    // MARK: - TestCase Tests

    func testTestCase_Properties() {
        let frame = TestImageGenerator.gradient(width: 8, height: 8)
        let options = EncodingOptions.lossless
        let tc = BitstreamValidator.TestCase(name: "test", frame: frame, options: options)
        XCTAssertEqual(tc.name, "test")
        XCTAssertEqual(tc.frame.width, 8)
        XCTAssertEqual(tc.frame.height, 8)
    }

    // MARK: - Performance Tests

    func testPerformance_StructuralValidation() throws {
        let frame = TestImageGenerator.gradient(width: 32, height: 32)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)

        let validator = BitstreamValidator(useLibjxl: false)
        measure {
            _ = validator.validateStructure(encoded.data)
        }
    }

    func testPerformance_FullValidation() throws {
        let cases = BitstreamValidator.standardTestCases(width: 8, height: 8)
        let validator = BitstreamValidator(useLibjxl: false)
        measure {
            _ = try? validator.validate(corpus: "perf", testCases: cases)
        }
    }
}
