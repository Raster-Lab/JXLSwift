/// Bitstream compatibility validation for JXLSwift output
///
/// Validates that JXLSwift-produced JPEG XL bitstreams are structurally correct
/// and decodable by the reference libjxl implementation. Supports both structural
/// validation (signature, header, frame structure) and external tool validation
/// (invoking `djxl` for decode verification).

import Foundation

// MARK: - Validation Result Types

/// Result of validating a single bitstream.
public struct BitstreamValidationResult: Sendable {
    /// Test case name
    public let name: String

    /// Image dimensions
    public let width: Int

    /// Image dimensions
    public let height: Int

    /// Encoding mode description
    public let mode: String

    /// Compressed data size in bytes
    public let compressedSize: Int

    /// Structural validation checks
    public let structuralChecks: [StructuralCheck]

    /// libjxl decode result (nil if libjxl not available)
    public let libjxlResult: LibjxlDecodeResult?

    /// Whether all validation checks passed
    public var passed: Bool {
        let structuralPassed = structuralChecks.allSatisfy(\.passed)
        let libjxlPassed = libjxlResult?.passed ?? true
        return structuralPassed && libjxlPassed
    }

    /// Failure reasons
    public var failureReasons: [String] {
        var reasons: [String] = []
        for check in structuralChecks where !check.passed {
            reasons.append("\(check.name): \(check.message)")
        }
        if let ljr = libjxlResult, !ljr.passed {
            reasons.append("libjxl decode: \(ljr.errorMessage)")
        }
        return reasons
    }
}

/// A single structural validation check.
public struct StructuralCheck: Sendable {
    /// Check name
    public let name: String

    /// Whether the check passed
    public let passed: Bool

    /// Human-readable message
    public let message: String
}

/// Result of attempting to decode with libjxl.
public struct LibjxlDecodeResult: Sendable {
    /// Whether libjxl successfully decoded the file
    public let passed: Bool

    /// Error message if decoding failed
    public let errorMessage: String

    /// Decode time in seconds (if successful)
    public let decodeTimeSeconds: Double?
}

// MARK: - Bitstream Validation Report

/// Report from a full bitstream compatibility validation run.
public struct BitstreamValidationReport: Sendable {
    /// Timestamp of the validation run
    public let timestamp: Date

    /// Description of the test corpus
    public let corpus: String

    /// Whether libjxl was available for external validation
    public let libjxlAvailable: Bool

    /// Individual validation results
    public let results: [BitstreamValidationResult]

    /// Summary statistics
    public var summary: BitstreamValidationSummary {
        let totalTests = results.count
        let passed = results.filter(\.passed).count
        let structuralPassed = results.filter { $0.structuralChecks.allSatisfy(\.passed) }.count
        let libjxlTested = results.filter { $0.libjxlResult != nil }.count
        let libjxlPassed = results.filter { $0.libjxlResult?.passed == true }.count

        return BitstreamValidationSummary(
            totalTests: totalTests,
            passed: passed,
            failed: totalTests - passed,
            structuralPassed: structuralPassed,
            libjxlTested: libjxlTested,
            libjxlPassed: libjxlPassed
        )
    }
}

/// Summary of bitstream validation results.
public struct BitstreamValidationSummary: Sendable {
    /// Total number of test cases
    public let totalTests: Int

    /// Number of fully passed test cases
    public let passed: Int

    /// Number of failed test cases
    public let failed: Int

    /// Number passing structural validation
    public let structuralPassed: Int

    /// Number tested with libjxl
    public let libjxlTested: Int

    /// Number passing libjxl decode
    public let libjxlPassed: Int

    /// Whether all tests passed
    public var allPassed: Bool { failed == 0 }
}

// MARK: - Bitstream Validator

/// Validates JPEG XL bitstreams for structural correctness and libjxl compatibility.
///
/// The validator performs two levels of validation:
/// 1. **Structural validation** — checks signature, minimum size, header presence,
///    and byte alignment without requiring external tools.
/// 2. **libjxl validation** — optionally invokes the `djxl` command-line tool to
///    verify that the bitstream can be decoded by the reference implementation.
///
/// # Usage
/// ```swift
/// let validator = BitstreamValidator()
/// let report = try validator.validate(
///     corpus: "test-images",
///     testCases: testCases
/// )
/// print("Passed: \(report.summary.passed)/\(report.summary.totalTests)")
/// ```
public class BitstreamValidator {
    /// Whether to attempt libjxl validation
    public let useLibjxl: Bool

    /// Path to the djxl binary (or nil to search PATH)
    public let djxlPath: String?

    /// Initialize a bitstream validator.
    /// - Parameters:
    ///   - useLibjxl: Whether to attempt libjxl decode validation (default: true)
    ///   - djxlPath: Explicit path to `djxl` binary (default: nil, searches PATH)
    public init(useLibjxl: Bool = true, djxlPath: String? = nil) {
        self.useLibjxl = useLibjxl
        self.djxlPath = djxlPath
    }

    /// A test case for bitstream validation.
    public struct TestCase {
        /// Test case name
        public let name: String

        /// Image frame to encode
        public let frame: ImageFrame

        /// Encoding options
        public let options: EncodingOptions

        /// Initialize a test case.
        public init(name: String, frame: ImageFrame, options: EncodingOptions) {
            self.name = name
            self.frame = frame
            self.options = options
        }
    }

    /// Run bitstream compatibility validation on a set of test cases.
    /// - Parameters:
    ///   - corpus: Name of the test corpus
    ///   - testCases: Array of test cases to validate
    /// - Returns: Bitstream validation report
    /// - Throws: If encoding fails for any test case
    public func validate(corpus: String, testCases: [TestCase]) throws -> BitstreamValidationReport {
        let djxlAvailable = useLibjxl && isLibjxlAvailable()
        var results: [BitstreamValidationResult] = []

        for testCase in testCases {
            let result = try validateTestCase(testCase, djxlAvailable: djxlAvailable)
            results.append(result)
        }

        return BitstreamValidationReport(
            timestamp: Date(),
            corpus: corpus,
            libjxlAvailable: djxlAvailable,
            results: results
        )
    }

    // MARK: - Single Test Case Validation

    /// Validate a single test case.
    private func validateTestCase(
        _ testCase: TestCase,
        djxlAvailable: Bool
    ) throws -> BitstreamValidationResult {
        let encoder = JXLEncoder(options: testCase.options)
        let encoded = try encoder.encode(testCase.frame)

        // Run structural checks
        let structuralChecks = validateStructure(encoded.data)

        // Mode description
        let modeStr: String
        switch testCase.options.mode {
        case .lossless: modeStr = "lossless"
        case .lossy(let q): modeStr = "lossy(q=\(q))"
        case .distance(let d): modeStr = "distance(\(d))"
        }

        // Run libjxl decode if available
        let libjxlResult: LibjxlDecodeResult?
        if djxlAvailable {
            libjxlResult = decodeWithLibjxl(encoded.data)
        } else {
            libjxlResult = nil
        }

        return BitstreamValidationResult(
            name: testCase.name,
            width: testCase.frame.width,
            height: testCase.frame.height,
            mode: modeStr,
            compressedSize: encoded.data.count,
            structuralChecks: structuralChecks,
            libjxlResult: libjxlResult
        )
    }

    // MARK: - Structural Validation

    /// Validate the structural integrity of a JPEG XL bitstream.
    /// - Parameter data: Encoded JPEG XL data
    /// - Returns: Array of structural check results
    public func validateStructure(_ data: Data) -> [StructuralCheck] {
        var checks: [StructuralCheck] = []

        // Check 1: Minimum size
        checks.append(StructuralCheck(
            name: "minimum_size",
            passed: data.count >= 2,
            message: data.count >= 2
                ? "Data size \(data.count) bytes meets minimum"
                : "Data too small (\(data.count) bytes), minimum is 2"
        ))

        // Check 2: JPEG XL codestream signature (0xFF 0x0A)
        let hasSignature = data.count >= 2 && data[0] == 0xFF && data[1] == 0x0A
        checks.append(StructuralCheck(
            name: "jxl_signature",
            passed: hasSignature,
            message: hasSignature
                ? "Valid JPEG XL codestream signature (0xFF 0x0A)"
                : "Missing or invalid JPEG XL signature"
        ))

        // Check 3: Header present (at least signature + some header bits)
        let hasHeader = data.count >= 4
        checks.append(StructuralCheck(
            name: "header_present",
            passed: hasHeader,
            message: hasHeader
                ? "Header data present (\(data.count) bytes total)"
                : "Insufficient data for header (\(data.count) bytes)"
        ))

        // Check 4: Not an ISOBMFF container masquerading as codestream
        // ISOBMFF containers start with box size + 'JXL ' or 'ftyp'
        let isNotContainer: Bool
        if data.count >= 12 {
            let byte4 = data[4]
            let byte5 = data[5]
            let byte6 = data[6]
            let byte7 = data[7]
            // Check for ISOBMFF 'JXL ' box type at offset 4
            let isISOBMFF = byte4 == 0x4A && byte5 == 0x58 && byte6 == 0x4C && byte7 == 0x20
            isNotContainer = !isISOBMFF || !hasSignature
        } else {
            isNotContainer = true
        }
        checks.append(StructuralCheck(
            name: "codestream_format",
            passed: isNotContainer,
            message: isNotContainer
                ? "Valid codestream format (not ISOBMFF container)"
                : "Unexpected container format detected"
        ))

        // Check 5: Data is not all zeros after signature
        let hasContent: Bool
        if data.count > 4 {
            let headerBytes = data[2..<min(data.count, 10)]
            hasContent = headerBytes.contains(where: { $0 != 0 })
        } else {
            hasContent = data.count > 2
        }
        checks.append(StructuralCheck(
            name: "non_empty_content",
            passed: hasContent,
            message: hasContent
                ? "Bitstream contains encoded content"
                : "Bitstream appears empty after signature"
        ))

        // Check 6: Reasonable size (not suspiciously small for an image)
        let reasonableSize = data.count >= 10
        checks.append(StructuralCheck(
            name: "reasonable_size",
            passed: reasonableSize,
            message: reasonableSize
                ? "Bitstream size \(data.count) bytes is reasonable"
                : "Bitstream suspiciously small (\(data.count) bytes)"
        ))

        return checks
    }

    // MARK: - libjxl Integration

    /// Check if the djxl tool is available.
    /// - Returns: true if djxl is found in PATH or at the specified path
    public func isLibjxlAvailable() -> Bool {
        let path = djxlPath ?? findInPath("djxl")
        guard let resolvedPath = path else { return false }
        return FileManager.default.isExecutableFile(atPath: resolvedPath)
    }

    /// Attempt to decode data with libjxl's djxl tool.
    /// - Parameter data: JPEG XL encoded data
    /// - Returns: Decode result
    private func decodeWithLibjxl(_ data: Data) -> LibjxlDecodeResult {
        let tempDir = FileManager.default.temporaryDirectory
        let inputPath = tempDir.appendingPathComponent("jxlswift_validate_\(UUID().uuidString).jxl")
        let outputPath = tempDir.appendingPathComponent("jxlswift_validate_\(UUID().uuidString).ppm")

        defer {
            try? FileManager.default.removeItem(at: inputPath)
            try? FileManager.default.removeItem(at: outputPath)
        }

        do {
            try data.write(to: inputPath)
        } catch {
            return LibjxlDecodeResult(
                passed: false,
                errorMessage: "Failed to write temp file: \(error.localizedDescription)",
                decodeTimeSeconds: nil
            )
        }

        let djxl = djxlPath ?? findInPath("djxl") ?? "djxl"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: djxl)
        process.arguments = [inputPath.path, outputPath.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        let startTime = ProcessInfo.processInfo.systemUptime

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return LibjxlDecodeResult(
                passed: false,
                errorMessage: "Failed to run djxl: \(error.localizedDescription)",
                decodeTimeSeconds: nil
            )
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - startTime

        if process.terminationStatus == 0 {
            return LibjxlDecodeResult(
                passed: true,
                errorMessage: "",
                decodeTimeSeconds: elapsed
            )
        } else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            return LibjxlDecodeResult(
                passed: false,
                errorMessage: "djxl exited with status \(process.terminationStatus): \(errorStr.prefix(500))",
                decodeTimeSeconds: nil
            )
        }
    }

    /// Find an executable in the system PATH.
    /// - Parameter name: Executable name
    /// - Returns: Full path if found, nil otherwise
    private func findInPath(_ name: String) -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        let paths = pathEnv.split(separator: ":").map(String.init)
        for dir in paths {
            let fullPath = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    // MARK: - Standard Test Suites

    /// Generate standard test cases for bitstream compatibility validation.
    ///
    /// Produces test cases covering:
    /// - Lossless mode (gradient, checkerboard, noise images)
    /// - Lossy mode at multiple quality levels
    /// - Various image sizes (small, medium)
    /// - Single-channel and multi-channel images
    ///
    /// - Parameters:
    ///   - width: Image width (default: 32 for fast testing)
    ///   - height: Image height (default: 32 for fast testing)
    /// - Returns: Array of standard test cases
    public static func standardTestCases(width: Int = 32, height: Int = 32) -> [TestCase] {
        var cases: [TestCase] = []

        // Lossless test cases
        let gradientFrame = TestImageGenerator.gradient(width: width, height: height)
        let checkerFrame = TestImageGenerator.checkerboard(width: width, height: height)
        let noiseFrame = TestImageGenerator.noise(width: width, height: height)

        cases.append(TestCase(
            name: "lossless_gradient",
            frame: gradientFrame,
            options: .lossless
        ))
        cases.append(TestCase(
            name: "lossless_checker",
            frame: checkerFrame,
            options: .lossless
        ))
        cases.append(TestCase(
            name: "lossless_noise",
            frame: noiseFrame,
            options: .lossless
        ))

        // Lossy test cases at various quality levels
        for quality: Float in [50, 75, 90] {
            let options = EncodingOptions(
                mode: .lossy(quality: quality),
                effort: .squirrel
            )
            cases.append(TestCase(
                name: "lossy_q\(Int(quality))_gradient",
                frame: gradientFrame,
                options: options
            ))
        }

        // Distance mode
        cases.append(TestCase(
            name: "distance_1.0_gradient",
            frame: gradientFrame,
            options: EncodingOptions(mode: .distance(1.0))
        ))

        // Grayscale image
        let grayFrame = TestImageGenerator.gradient(width: width, height: height, channels: 1)
        cases.append(TestCase(
            name: "lossless_grayscale",
            frame: grayFrame,
            options: .lossless
        ))

        // Small image edge case
        let tinyFrame = TestImageGenerator.gradient(width: 1, height: 1)
        cases.append(TestCase(
            name: "lossless_1x1",
            frame: tinyFrame,
            options: .lossless
        ))

        return cases
    }
}
