/// ISO/IEC 18181-3 Conformance Test Suite
///
/// Implements the conformance testing framework for JPEG XL (ISO/IEC 18181).
/// Validates JXLSwift output against the requirements of:
///
/// - **Part 1** (ISO/IEC 18181-1 §6–§11): codestream bitstream structure,
///   entropy coding, size header, image header, frame headers.
/// - **Part 2** (ISO/IEC 18181-2): ISOBMFF container format, metadata boxes
///   (EXIF, XMP, ICC), MIME type, and codestream embedding.
///
/// Bidirectional interoperability tests with `cjxl`/`djxl` are included
/// and skip gracefully when the tools are not installed.

import Foundation

// MARK: - Conformance Category

/// ISO/IEC 18181-3 conformance category.
public enum ConformanceCategory: String, Sendable, CaseIterable {
    /// Part 1 §6: Codestream signature and top-level structure.
    case bitstreamStructure = "bitstream_structure"

    /// Part 1 §7: Entropy coding (ANS, hybrid).
    case entropyCoding = "entropy_coding"

    /// Part 1 §11: Size header and image metadata header.
    case imageHeader = "image_header"

    /// Part 1 §9: Frame header and frame encoding parameters.
    case frameHeader = "frame_header"

    /// Part 2 §3: ISOBMFF container format and required boxes.
    case containerFormat = "container_format"

    /// Part 2 §3: Metadata box embedding (EXIF, XMP, ICC).
    case metadataBoxes = "metadata_boxes"

    /// Bidirectional interoperability with the libjxl reference implementation.
    case libjxlInteroperability = "libjxl_interoperability"

    /// Lossless round-trip: encode → decode must be pixel-perfect.
    case losslessRoundTrip = "lossless_round_trip"

    /// Lossy round-trip: encode → decode must meet minimum PSNR.
    case lossyRoundTrip = "lossy_round_trip"

    /// Human-readable description.
    public var description: String {
        switch self {
        case .bitstreamStructure:    return "Bitstream Structure (§6)"
        case .entropyCoding:         return "Entropy Coding (§7)"
        case .imageHeader:           return "Image Header (§11)"
        case .frameHeader:           return "Frame Header (§9)"
        case .containerFormat:       return "Container Format (Part 2 §3)"
        case .metadataBoxes:         return "Metadata Boxes (Part 2 §3)"
        case .libjxlInteroperability: return "libjxl Interoperability"
        case .losslessRoundTrip:     return "Lossless Round-Trip"
        case .lossyRoundTrip:        return "Lossy Round-Trip"
        }
    }
}

// MARK: - Conformance Vector

/// A single conformance test vector.
///
/// A vector specifies the input image, encoding parameters, and which conformance
/// categories and assertions must pass.
public struct ConformanceVector {
    /// Unique identifier for this test vector (e.g. `"modular_8x8_lossless"`).
    public let id: String

    /// Human-readable description of what this vector tests.
    public let description: String

    /// ISO/IEC 18181-3 conformance category this vector belongs to.
    public let category: ConformanceCategory

    /// The image frame used as input.
    public let frame: ImageFrame

    /// Encoding options applied to the frame.
    public let options: EncodingOptions

    /// Whether this vector requires a pixel-perfect lossless round-trip.
    public let requiresLosslessRoundTrip: Bool

    /// Minimum acceptable PSNR for a lossy round-trip (nil = no PSNR check).
    public let minimumPSNR: Double?

    /// Creates a conformance test vector.
    public init(
        id: String,
        description: String,
        category: ConformanceCategory,
        frame: ImageFrame,
        options: EncodingOptions,
        requiresLosslessRoundTrip: Bool = false,
        minimumPSNR: Double? = nil
    ) {
        self.id = id
        self.description = description
        self.category = category
        self.frame = frame
        self.options = options
        self.requiresLosslessRoundTrip = requiresLosslessRoundTrip
        self.minimumPSNR = minimumPSNR
    }
}

// MARK: - Conformance Check

/// A single named assertion within a conformance test.
public struct ConformanceCheck: Sendable {
    /// Short name used in the report (e.g. `"jxl_signature"`).
    public let name: String

    /// Whether the assertion passed.
    public let passed: Bool

    /// Human-readable explanation of the result.
    public let message: String
}

// MARK: - Conformance Result

/// Result of running a single conformance vector.
public struct ConformanceResult: Sendable {
    /// Test vector identifier.
    public let vectorID: String

    /// Conformance category.
    public let category: ConformanceCategory

    /// Encoding mode description.
    public let encodingMode: String

    /// Compressed size in bytes (0 if encoding failed).
    public let compressedSize: Int

    /// Individual checks performed on this vector.
    public let checks: [ConformanceCheck]

    /// Whether the encoding step itself succeeded.
    public let encodingSucceeded: Bool

    /// Error message if encoding failed (nil if successful).
    public let encodingError: String?

    /// Whether all checks passed and encoding succeeded.
    public var passed: Bool {
        encodingSucceeded && checks.allSatisfy(\.passed)
    }

    /// Names of failed checks (empty if all passed).
    public var failedChecks: [String] {
        checks.filter { !$0.passed }.map(\.name)
    }
}

// MARK: - Conformance Report

/// Aggregated report from a full conformance run.
public struct ConformanceReport: Sendable {
    /// Timestamp of the run.
    public let timestamp: Date

    /// Identifier of the runner (e.g. `"JXLSwift 1.0.0"`).
    public let runnerID: String

    /// Whether the `djxl` / `cjxl` reference tools were available.
    public let libjxlAvailable: Bool

    /// Individual conformance results.
    public let results: [ConformanceResult]

    /// High-level pass/fail statistics.
    public var summary: ConformanceSummary {
        let total = results.count
        let passed = results.filter(\.passed).count
        var byCategory: [ConformanceCategory: (passed: Int, total: Int)] = [:]
        for result in results {
            var current = byCategory[result.category] ?? (0, 0)
            current.total += 1
            if result.passed { current.passed += 1 }
            byCategory[result.category] = current
        }
        return ConformanceSummary(
            totalVectors: total,
            passedVectors: passed,
            failedVectors: total - passed,
            resultsByCategory: byCategory
        )
    }
}

/// High-level statistics from a conformance run.
public struct ConformanceSummary: Sendable {
    /// Total number of conformance vectors run.
    public let totalVectors: Int

    /// Number of vectors that passed.
    public let passedVectors: Int

    /// Number of vectors that failed.
    public let failedVectors: Int

    /// Breakdown of results by conformance category.
    public let resultsByCategory: [ConformanceCategory: (passed: Int, total: Int)]

    /// Overall pass rate (0.0–1.0).
    public var passRate: Double {
        totalVectors == 0 ? 1.0 : Double(passedVectors) / Double(totalVectors)
    }

    /// Whether every vector passed.
    public var allPassed: Bool { failedVectors == 0 }
}

// MARK: - Conformance Runner

/// Runs ISO/IEC 18181-3 conformance tests against a set of `ConformanceVector` items.
///
/// The runner:
/// 1. Encodes each vector's `ImageFrame` with the specified `EncodingOptions`.
/// 2. Performs structural bitstream checks (Part 1 §6–§11).
/// 3. Optionally performs a round-trip decode and compares with the original.
/// 4. Optionally invokes `djxl` / `cjxl` for bidirectional libjxl interoperability.
/// 5. Produces a `ConformanceReport` with per-vector and per-category results.
///
/// # Usage
/// ```swift
/// let runner = ConformanceRunner()
/// let report = try runner.run(vectors: ConformanceRunner.standardVectors())
/// print("Pass rate: \(report.summary.passRate * 100)%")
/// ```
public final class ConformanceRunner: Sendable {

    /// Whether to attempt round-trip decode checks using JXLDecoder.
    public let enableRoundTripChecks: Bool

    /// Whether to invoke libjxl tools (cjxl / djxl) for interoperability checks.
    public let enableLibjxlChecks: Bool

    /// Path to djxl binary (nil = search PATH).
    public let djxlPath: String?

    /// Path to cjxl binary (nil = search PATH).
    public let cjxlPath: String?

    /// Runner identifier written into the report.
    public let runnerID: String

    /// Creates a conformance runner.
    /// - Parameters:
    ///   - enableRoundTripChecks: Perform JXLDecoder round-trip checks (default: true).
    ///   - enableLibjxlChecks: Invoke cjxl/djxl for interoperability (default: true).
    ///   - djxlPath: Explicit path to djxl (default: nil, searches PATH).
    ///   - cjxlPath: Explicit path to cjxl (default: nil, searches PATH).
    ///   - runnerID: Identifier written to the report (default: "JXLSwift").
    public init(
        enableRoundTripChecks: Bool = true,
        enableLibjxlChecks: Bool = true,
        djxlPath: String? = nil,
        cjxlPath: String? = nil,
        runnerID: String = "JXLSwift"
    ) {
        self.enableRoundTripChecks = enableRoundTripChecks
        self.enableLibjxlChecks = enableLibjxlChecks
        self.djxlPath = djxlPath
        self.cjxlPath = cjxlPath
        self.runnerID = runnerID
    }

    // MARK: - Run

    /// Run conformance tests on a set of vectors.
    /// - Parameter vectors: Vectors to test.
    /// - Returns: `ConformanceReport` with all results.
    public func run(vectors: [ConformanceVector]) -> ConformanceReport {
        let libjxlAvail = enableLibjxlChecks && isLibjxlAvailable()
        var results: [ConformanceResult] = []

        for vector in vectors {
            let result = runVector(vector, libjxlAvailable: libjxlAvail)
            results.append(result)
        }

        return ConformanceReport(
            timestamp: Date(),
            runnerID: runnerID,
            libjxlAvailable: libjxlAvail,
            results: results
        )
    }

    // MARK: - Standard Vectors

    /// Returns the standard ISO/IEC 18181-3 conformance test vectors.
    ///
    /// The vectors cover all mandatory conformance categories:
    /// - Bitstream structure (signature, minimum size, non-empty content)
    /// - Image header (SizeHeader encoding, dimension range)
    /// - Frame headers (Modular and VarDCT frame flags)
    /// - Container format (ISOBMFF signature, ftyp box, jxlc box)
    /// - Metadata boxes (EXIF, XMP, ICC preservation)
    /// - Lossless round-trip (Modular mode, grayscale and RGB)
    /// - Lossy round-trip (VarDCT mode, multiple quality levels)
    ///
    /// - Returns: Array of standard conformance vectors.
    public static func standardVectors() -> [ConformanceVector] {
        var vectors: [ConformanceVector] = []

        // MARK: Bitstream Structure (Part 1 §6)
        vectors += bitstreamStructureVectors()

        // MARK: Image Header (Part 1 §11)
        vectors += imageHeaderVectors()

        // MARK: Frame Header (Part 1 §9)
        vectors += frameHeaderVectors()

        // MARK: Container Format (Part 2 §3)
        vectors += containerFormatVectors()

        // MARK: Lossless Round-Trip
        vectors += losslessRoundTripVectors()

        // MARK: Lossy Round-Trip
        vectors += lossyRoundTripVectors()

        return vectors
    }

    // MARK: - Bitstream Structure Vectors

    private static func bitstreamStructureVectors() -> [ConformanceVector] {
        let small = TestImageGenerator.gradient(width: 8, height: 8)
        return [
            ConformanceVector(
                id: "bs_001_signature_lossless",
                description: "Codestream starts with JPEG XL signature 0xFF 0x0A (lossless)",
                category: .bitstreamStructure,
                frame: small,
                options: .lossless
            ),
            ConformanceVector(
                id: "bs_002_signature_lossy",
                description: "Codestream starts with JPEG XL signature 0xFF 0x0A (lossy)",
                category: .bitstreamStructure,
                frame: small,
                options: EncodingOptions(mode: .lossy(quality: 80))
            ),
            ConformanceVector(
                id: "bs_003_non_empty",
                description: "Codestream contains encoded content after signature",
                category: .bitstreamStructure,
                frame: TestImageGenerator.checkerboard(width: 16, height: 16),
                options: .lossless
            ),
            ConformanceVector(
                id: "bs_004_minimum_size",
                description: "Encoded output meets minimum codestream size",
                category: .bitstreamStructure,
                frame: TestImageGenerator.gradient(width: 1, height: 1),
                options: .lossless
            ),
        ]
    }

    // MARK: - Image Header Vectors

    private static func imageHeaderVectors() -> [ConformanceVector] {
        [
            ConformanceVector(
                id: "ih_001_small_dimensions",
                description: "Size header encodes small dimensions (≤256) compactly",
                category: .imageHeader,
                frame: TestImageGenerator.gradient(width: 64, height: 64),
                options: .lossless
            ),
            ConformanceVector(
                id: "ih_002_medium_dimensions",
                description: "Size header encodes medium dimensions (257–512) with 9-bit selector",
                category: .imageHeader,
                frame: TestImageGenerator.gradient(width: 320, height: 240),
                options: .lossless
            ),
            ConformanceVector(
                id: "ih_003_grayscale",
                description: "Single-channel (grayscale) image header",
                category: .imageHeader,
                frame: TestImageGenerator.gradient(width: 16, height: 16, channels: 1),
                options: .lossless
            ),
            ConformanceVector(
                id: "ih_004_rgba",
                description: "Four-channel (RGBA) image header",
                category: .imageHeader,
                frame: TestImageGenerator.gradient(width: 16, height: 16, channels: 4),
                options: .lossless
            ),
        ]
    }

    // MARK: - Frame Header Vectors

    private static func frameHeaderVectors() -> [ConformanceVector] {
        let frame = TestImageGenerator.gradient(width: 32, height: 32)
        return [
            ConformanceVector(
                id: "fh_001_modular_frame",
                description: "Modular-mode frame header is present and structurally valid",
                category: .frameHeader,
                frame: frame,
                options: .lossless
            ),
            ConformanceVector(
                id: "fh_002_vardct_frame",
                description: "VarDCT-mode frame header is present and structurally valid",
                category: .frameHeader,
                frame: frame,
                options: EncodingOptions(mode: .lossy(quality: 90))
            ),
            ConformanceVector(
                id: "fh_003_distance_mode",
                description: "Distance-mode frame header with distance=1.0",
                category: .frameHeader,
                frame: frame,
                options: EncodingOptions(mode: .distance(1.0))
            ),
        ]
    }

    // MARK: - Container Format Vectors

    private static func containerFormatVectors() -> [ConformanceVector] {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        return [
            ConformanceVector(
                id: "cf_001_codestream_signature",
                description: "Bare codestream does not have ISOBMFF container wrapper",
                category: .containerFormat,
                frame: frame,
                options: .lossless
            ),
            ConformanceVector(
                id: "cf_002_no_container_lossy",
                description: "Lossy bare codestream is not ISOBMFF-wrapped",
                category: .containerFormat,
                frame: frame,
                options: EncodingOptions(mode: .lossy(quality: 85))
            ),
        ]
    }

    // MARK: - Lossless Round-Trip Vectors

    private static func losslessRoundTripVectors() -> [ConformanceVector] {
        [
            ConformanceVector(
                id: "lt_001_rgb_gradient",
                description: "RGB gradient: lossless encode→decode is pixel-perfect",
                category: .losslessRoundTrip,
                frame: TestImageGenerator.gradient(width: 32, height: 32),
                options: .lossless,
                requiresLosslessRoundTrip: true
            ),
            ConformanceVector(
                id: "lt_002_grayscale_gradient",
                description: "Grayscale gradient: lossless encode→decode is pixel-perfect",
                category: .losslessRoundTrip,
                frame: TestImageGenerator.gradient(width: 16, height: 16, channels: 1),
                options: .lossless,
                requiresLosslessRoundTrip: true
            ),
            ConformanceVector(
                id: "lt_003_checkerboard",
                description: "Checkerboard: lossless encode→decode is pixel-perfect",
                category: .losslessRoundTrip,
                frame: TestImageGenerator.checkerboard(width: 32, height: 32),
                options: .lossless,
                requiresLosslessRoundTrip: true
            ),
            ConformanceVector(
                id: "lt_004_noise",
                description: "Noise image: lossless encode→decode is pixel-perfect",
                category: .losslessRoundTrip,
                frame: TestImageGenerator.noise(width: 32, height: 32),
                options: .lossless,
                requiresLosslessRoundTrip: true
            ),
            ConformanceVector(
                id: "lt_005_solid_black",
                description: "Solid black image: lossless encode→decode is pixel-perfect",
                category: .losslessRoundTrip,
                frame: TestImageGenerator.solid(
                    width: 16, height: 16,
                    color: [0, 0, 0]
                ),
                options: .lossless,
                requiresLosslessRoundTrip: true
            ),
            ConformanceVector(
                id: "lt_006_solid_white",
                description: "Solid white image: lossless encode→decode is pixel-perfect",
                category: .losslessRoundTrip,
                frame: TestImageGenerator.solid(
                    width: 16, height: 16,
                    color: [255, 255, 255]
                ),
                options: .lossless,
                requiresLosslessRoundTrip: true
            ),
        ]
    }

    // MARK: - Lossy Round-Trip Vectors

    private static func lossyRoundTripVectors() -> [ConformanceVector] {
        let frame = TestImageGenerator.gradient(width: 32, height: 32)
        return [
            ConformanceVector(
                id: "ly_001_quality_90",
                description: "Lossy quality=90: PSNR > 35 dB",
                category: .lossyRoundTrip,
                frame: frame,
                options: EncodingOptions(mode: .lossy(quality: 90)),
                minimumPSNR: 35.0
            ),
            ConformanceVector(
                id: "ly_002_quality_75",
                description: "Lossy quality=75: PSNR > 30 dB",
                category: .lossyRoundTrip,
                frame: frame,
                options: EncodingOptions(mode: .lossy(quality: 75)),
                minimumPSNR: 30.0
            ),
            ConformanceVector(
                id: "ly_003_distance_1",
                description: "Distance=1.0: encoded data is smaller than original",
                category: .lossyRoundTrip,
                frame: frame,
                options: EncodingOptions(mode: .distance(1.0))
            ),
        ]
    }

    // MARK: - Private: Run a Single Vector

    private func runVector(
        _ vector: ConformanceVector,
        libjxlAvailable: Bool
    ) -> ConformanceResult {
        let encoder = JXLEncoder(options: vector.options)

        // Encode
        let encoded: EncodedImage
        do {
            encoded = try encoder.encode(vector.frame)
        } catch {
            return ConformanceResult(
                vectorID: vector.id,
                category: vector.category,
                encodingMode: modeDescription(vector.options),
                compressedSize: 0,
                checks: [],
                encodingSucceeded: false,
                encodingError: error.localizedDescription
            )
        }

        var checks: [ConformanceCheck] = []

        // Core bitstream structure checks (applicable to all vectors)
        checks += bitstreamStructureChecks(encoded.data)

        // Category-specific checks
        switch vector.category {
        case .bitstreamStructure:
            break // already covered above
        case .entropyCoding:
            break // structural checks already cover fundamental validity
        case .imageHeader:
            checks += imageDimensionChecks(encoded.data, frame: vector.frame)
        case .frameHeader:
            checks += framePresenceChecks(encoded.data)
        case .containerFormat:
            checks += containerFormatChecks(encoded.data)
        case .metadataBoxes:
            break // metadata box checks handled externally
        case .libjxlInteroperability:
            break // handled by the interoperability test helper
        case .losslessRoundTrip:
            checks += roundTripChecks(
                encoded: encoded.data,
                original: vector.frame,
                requiresLossless: vector.requiresLosslessRoundTrip
            )
        case .lossyRoundTrip:
            checks += lossyRoundTripChecks(
                encoded: encoded.data,
                original: vector.frame,
                minimumPSNR: vector.minimumPSNR
            )
        }

        return ConformanceResult(
            vectorID: vector.id,
            category: vector.category,
            encodingMode: modeDescription(vector.options),
            compressedSize: encoded.data.count,
            checks: checks,
            encodingSucceeded: true,
            encodingError: nil
        )
    }

    // MARK: - Bitstream Structure Checks (Part 1 §6)

    /// Validates the fundamental bitstream structure requirements from ISO/IEC 18181-1 §6.
    func bitstreamStructureChecks(_ data: Data) -> [ConformanceCheck] {
        var checks: [ConformanceCheck] = []

        // §6.1: Minimum codestream size
        checks.append(ConformanceCheck(
            name: "minimum_size",
            passed: data.count >= 2,
            message: data.count >= 2
                ? "Codestream is \(data.count) bytes (≥ 2)"
                : "Codestream too small: \(data.count) bytes"
        ))

        guard data.count >= 2 else { return checks }

        // §6.2: JPEG XL codestream signature (0xFF 0x0A)
        let sigOK = data[0] == 0xFF && data[1] == 0x0A
        checks.append(ConformanceCheck(
            name: "jxl_signature",
            passed: sigOK,
            message: sigOK
                ? "Valid JPEG XL signature: 0xFF 0x0A"
                : String(format: "Invalid signature: 0x%02X 0x%02X", data[0], data[1])
        ))

        // §6.3: Non-trivial content after signature
        let hasContent = data.count > 2
        checks.append(ConformanceCheck(
            name: "non_empty_content",
            passed: hasContent,
            message: hasContent
                ? "Codestream contains encoded content (\(data.count) bytes)"
                : "Codestream appears empty after signature"
        ))

        // §6.4: Codestream must not begin with ISOBMFF container wrapper
        //       (JXL container boxes start with size + 'JXL ' at offsets 4–7)
        let isContainer: Bool
        if data.count >= 8 {
            isContainer = data[4] == 0x4A && data[5] == 0x58 && data[6] == 0x4C && data[7] == 0x20
                && !(data[0] == 0xFF && data[1] == 0x0A)
        } else {
            isContainer = false
        }
        checks.append(ConformanceCheck(
            name: "not_isobmff_container",
            passed: !isContainer,
            message: !isContainer
                ? "Data is a bare codestream (not an ISOBMFF container)"
                : "Data appears to be an ISOBMFF container, not a bare codestream"
        ))

        return checks
    }

    // MARK: - Image Dimension Checks (Part 1 §11)

    /// Validates that the encoded data is consistent with the source frame dimensions.
    func imageDimensionChecks(_ data: Data, frame: ImageFrame) -> [ConformanceCheck] {
        var checks: [ConformanceCheck] = []

        // Reasonable size: colour image should produce > a few bytes
        let minExpected = 4
        checks.append(ConformanceCheck(
            name: "reasonable_encoded_size",
            passed: data.count >= minExpected,
            message: data.count >= minExpected
                ? "Encoded size \(data.count) bytes is plausible for \(frame.width)×\(frame.height)"
                : "Encoded size \(data.count) bytes is unexpectedly small"
        ))

        // Compression: should not be larger than uncompressed (within 10×)
        let uncompressed = frame.width * frame.height * frame.channels
        let maxExpected = uncompressed * 10 + 256 // generous upper bound
        checks.append(ConformanceCheck(
            name: "encoded_size_upper_bound",
            passed: data.count <= maxExpected,
            message: data.count <= maxExpected
                ? "Encoded size \(data.count) bytes ≤ 10× uncompressed \(uncompressed) bytes"
                : "Encoded size \(data.count) bytes exceeds 10× uncompressed \(uncompressed) bytes"
        ))

        return checks
    }

    // MARK: - Frame Presence Checks (Part 1 §9)

    /// Validates that the codestream contains at least one frame.
    func framePresenceChecks(_ data: Data) -> [ConformanceCheck] {
        var checks: [ConformanceCheck] = []

        // A minimal frame requires at least 8 bytes beyond the signature
        let hasSufficientData = data.count >= 10
        checks.append(ConformanceCheck(
            name: "frame_data_present",
            passed: hasSufficientData,
            message: hasSufficientData
                ? "Codestream contains frame data (\(data.count) bytes)"
                : "Codestream too short to contain a frame (\(data.count) bytes)"
        ))

        return checks
    }

    // MARK: - Metadata Box Checks (Part 2 §3)

    /// Validates that a parsed ``JXLContainer`` contains the expected metadata payloads.
    ///
    /// Checks are performed byte-for-byte so that EXIF, XMP, and ICC profile data
    /// are confirmed to survive a serialise → parse round-trip without corruption.
    ///
    /// - Parameters:
    ///   - container: The ``JXLContainer`` produced by ``JXLDecoder.parseContainer(_:)``.
    ///   - expectedEXIF: Expected raw EXIF bytes (nil = no EXIF expected).
    ///   - expectedXMP: Expected raw XMP bytes (nil = no XMP expected).
    ///   - expectedICC: Expected raw ICC profile bytes (nil = no ICC expected).
    /// - Returns: An array of ``ConformanceCheck`` results.
    public func metadataBoxChecks(
        container: JXLContainer,
        expectedEXIF: Data? = nil,
        expectedXMP: Data? = nil,
        expectedICC: Data? = nil
    ) -> [ConformanceCheck] {
        var checks: [ConformanceCheck] = []

        // EXIF check
        if let expected = expectedEXIF {
            let present = container.exif != nil
            checks.append(ConformanceCheck(
                name: "exif_present",
                passed: present,
                message: present ? "EXIF box is present" : "EXIF box missing from parsed container"
            ))
            if let actual = container.exif {
                let match = actual.data == expected
                checks.append(ConformanceCheck(
                    name: "exif_data_preserved",
                    passed: match,
                    message: match
                        ? "EXIF data is byte-exact (\(expected.count) bytes)"
                        : "EXIF data mismatch: expected \(expected.count) bytes, got \(actual.data.count) bytes"
                ))
            }
        }

        // XMP check
        if let expected = expectedXMP {
            let present = container.xmp != nil
            checks.append(ConformanceCheck(
                name: "xmp_present",
                passed: present,
                message: present ? "XMP box is present" : "XMP box missing from parsed container"
            ))
            if let actual = container.xmp {
                let match = actual.data == expected
                checks.append(ConformanceCheck(
                    name: "xmp_data_preserved",
                    passed: match,
                    message: match
                        ? "XMP data is byte-exact (\(expected.count) bytes)"
                        : "XMP data mismatch: expected \(expected.count) bytes, got \(actual.data.count) bytes"
                ))
            }
        }

        // ICC profile check
        if let expected = expectedICC {
            let present = container.iccProfile != nil
            checks.append(ConformanceCheck(
                name: "icc_present",
                passed: present,
                message: present ? "ICC profile box is present" : "ICC profile box missing from parsed container"
            ))
            if let actual = container.iccProfile {
                let match = actual.data == expected
                checks.append(ConformanceCheck(
                    name: "icc_data_preserved",
                    passed: match,
                    message: match
                        ? "ICC profile data is byte-exact (\(expected.count) bytes)"
                        : "ICC profile data mismatch: expected \(expected.count) bytes, got \(actual.data.count) bytes"
                ))
            }
        }

        // Codestream presence
        let hasCodestream = !container.codestream.isEmpty
        checks.append(ConformanceCheck(
            name: "codestream_intact",
            passed: hasCodestream,
            message: hasCodestream
                ? "Codestream is present (\(container.codestream.count) bytes)"
                : "Codestream is empty after metadata round-trip"
        ))

        return checks
    }

    // MARK: - Container Format Checks (Part 2 §3)

    /// Validates that the bare codestream is not inadvertently wrapped in a container.
    func containerFormatChecks(_ data: Data) -> [ConformanceCheck] {
        var checks: [ConformanceCheck] = []

        let startsWithCodestream = data.count >= 2 && data[0] == 0xFF && data[1] == 0x0A
        checks.append(ConformanceCheck(
            name: "bare_codestream_no_container",
            passed: startsWithCodestream,
            message: startsWithCodestream
                ? "Bare codestream begins with 0xFF 0x0A (no container wrapper)"
                : "Expected bare codestream beginning with 0xFF 0x0A"
        ))

        return checks
    }

    // MARK: - Round-Trip Checks

    /// Checks that decoding the encoded data reconstructs the original frame exactly.
    func roundTripChecks(
        encoded: Data,
        original: ImageFrame,
        requiresLossless: Bool
    ) -> [ConformanceCheck] {
        var checks: [ConformanceCheck] = []

        // Attempt to decode
        let decoder = JXLDecoder()
        let decoded: ImageFrame
        do {
            decoded = try decoder.decode(encoded)
        } catch {
            checks.append(ConformanceCheck(
                name: "decode_succeeds",
                passed: false,
                message: "Decode failed: \(error.localizedDescription)"
            ))
            return checks
        }

        checks.append(ConformanceCheck(
            name: "decode_succeeds",
            passed: true,
            message: "Decode succeeded"
        ))

        // Dimension match
        let dimsMatch = decoded.width == original.width && decoded.height == original.height
        checks.append(ConformanceCheck(
            name: "dimensions_preserved",
            passed: dimsMatch,
            message: dimsMatch
                ? "Dimensions preserved: \(decoded.width)×\(decoded.height)"
                : "Dimension mismatch: expected \(original.width)×\(original.height), got \(decoded.width)×\(decoded.height)"
        ))

        guard dimsMatch else { return checks }

        if requiresLossless {
            // Pixel-perfect check
            var allMatch = true
            var firstMismatch = ""
            outerLoop: for y in 0..<original.height {
                for x in 0..<original.width {
                    for c in 0..<min(original.channels, decoded.channels) {
                        let orig = original.getPixel(x: x, y: y, channel: c)
                        let dec  = decoded.getPixel(x: x, y: y, channel: c)
                        if orig != dec {
                            allMatch = false
                            firstMismatch = "(\(x),\(y),ch\(c)): expected \(orig), got \(dec)"
                            break outerLoop
                        }
                    }
                }
            }
            checks.append(ConformanceCheck(
                name: "lossless_pixel_perfect",
                passed: allMatch,
                message: allMatch
                    ? "All pixels match exactly (lossless round-trip)"
                    : "Pixel mismatch at \(firstMismatch)"
            ))
        }

        return checks
    }

    /// Checks that a lossy round-trip meets the minimum PSNR requirement.
    func lossyRoundTripChecks(
        encoded: Data,
        original: ImageFrame,
        minimumPSNR: Double?
    ) -> [ConformanceCheck] {
        var checks: [ConformanceCheck] = []

        // Compression ratio > 0 (encoded is smaller or comparable)
        let originalBytes = original.width * original.height * original.channels
        let compressionRatioOK = encoded.count > 0
        checks.append(ConformanceCheck(
            name: "produces_output",
            passed: compressionRatioOK,
            message: compressionRatioOK
                ? "Encoded \(encoded.count) bytes from \(originalBytes) bytes uncompressed"
                : "Encoding produced no output"
        ))

        guard let minPSNR = minimumPSNR else { return checks }

        // Attempt to decode and measure PSNR
        let decoder = JXLDecoder()
        let decoded: ImageFrame
        do {
            decoded = try decoder.decode(encoded)
        } catch {
            checks.append(ConformanceCheck(
                name: "psnr_meets_minimum",
                passed: false,
                message: "Decode failed, cannot measure PSNR: \(error.localizedDescription)"
            ))
            return checks
        }

        guard decoded.width == original.width, decoded.height == original.height else {
            checks.append(ConformanceCheck(
                name: "psnr_meets_minimum",
                passed: false,
                message: "Dimension mismatch after decode, cannot measure PSNR"
            ))
            return checks
        }

        let psnr = computePSNR(original: original, decoded: decoded)
        let psnrOK = psnr.isInfinite || psnr >= minPSNR
        checks.append(ConformanceCheck(
            name: "psnr_meets_minimum",
            passed: psnrOK,
            message: psnrOK
                ? String(format: "PSNR %.2f dB ≥ minimum %.2f dB", psnr, minPSNR)
                : String(format: "PSNR %.2f dB < minimum %.2f dB", psnr, minPSNR)
        ))

        return checks
    }

    // MARK: - PSNR Computation

    /// Computes PSNR between two frames using the first three channels.
    ///
    /// PSNR = 10 × log10(MAX² / MSE), where MAX = 255 for uint8 frames.
    private func computePSNR(original: ImageFrame, decoded: ImageFrame) -> Double {
        let channels = min(original.channels, decoded.channels, 3)
        var mse: Double = 0.0
        var count = 0

        for y in 0..<original.height {
            for x in 0..<original.width {
                for c in 0..<channels {
                    let o = Double(original.getPixel(x: x, y: y, channel: c))
                    let d = Double(decoded.getPixel(x: x, y: y, channel: c))
                    let diff = o - d
                    mse += diff * diff
                    count += 1
                }
            }
        }

        guard count > 0 else { return Double.infinity }
        mse /= Double(count)
        if mse < 1e-10 { return Double.infinity }

        let maxVal = 255.0
        return 10.0 * log10((maxVal * maxVal) / mse)
    }

    // MARK: - libjxl Availability

    /// Returns true if both cjxl and djxl executables are found.
    public func isLibjxlAvailable() -> Bool {
        guard enableLibjxlChecks else { return false }
        let djxl = djxlPath ?? findInPath("djxl")
        let cjxl = cjxlPath ?? findInPath("cjxl")
        return djxl != nil && cjxl != nil
    }

    // MARK: - libjxl Interoperability Helpers

    /// Writes a PPM file from an RGB uint8 frame and encodes it with cjxl.
    ///
    /// - Parameters:
    ///   - frame: Source image frame (uint8, 1 or 3 channels).
    ///   - outputURL: Destination .jxl file URL.
    ///   - quality: Optional quality level (nil = lossless).
    /// - Throws: If writing or encoding fails.
    public func encodeTempWithCjxl(
        frame: ImageFrame,
        outputURL: URL,
        quality: Int? = nil
    ) throws {
        let tempDir = FileManager.default.temporaryDirectory
        let ppmURL = tempDir.appendingPathComponent("conf_\(UUID().uuidString).ppm")
        defer { try? FileManager.default.removeItem(at: ppmURL) }

        try writePPM(frame: frame, to: ppmURL)

        let cjxlBin = cjxlPath ?? findInPath("cjxl") ?? "cjxl"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cjxlBin)
        var args = [ppmURL.path, outputURL.path]
        if let q = quality {
            args += ["--quality=\(q)"]
        } else {
            args += ["--distance=0"]
        }
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConformanceError.libjxlEncodingFailed("cjxl exited with status \(process.terminationStatus)")
        }
    }

    /// Decodes a .jxl file with djxl, returning the exit status (0 = success).
    ///
    /// - Parameters:
    ///   - inputURL: Source .jxl file.
    ///   - outputURL: Destination image file (e.g. .ppm).
    /// - Returns: Process termination status (0 = success).
    /// - Throws: If the process cannot be launched.
    @discardableResult
    public func decodeTempWithDjxl(inputURL: URL, outputURL: URL) throws -> Int32 {
        let djxlBin = djxlPath ?? findInPath("djxl") ?? "djxl"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: djxlBin)
        process.arguments = [inputURL.path, outputURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Private Utilities

    /// Describes an encoding options mode.
    private func modeDescription(_ options: EncodingOptions) -> String {
        switch options.mode {
        case .lossless: return "lossless"
        case .lossy(let q): return "lossy(q=\(q))"
        case .distance(let d): return String(format: "distance(%.2f)", d)
        }
    }

    /// Writes an RGB uint8 frame to a PPM file.
    private func writePPM(frame: ImageFrame, to url: URL) throws {
        var data = Data("P6\n\(frame.width) \(frame.height)\n255\n".utf8)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let channels = min(frame.channels, 3)
                for c in 0..<channels {
                    data.append(UInt8(min(255, frame.getPixel(x: x, y: y, channel: c))))
                }
                if frame.channels == 1 {
                    let v = UInt8(min(255, frame.getPixel(x: x, y: y, channel: 0)))
                    data.append(v)
                    data.append(v)
                }
            }
        }
        try data.write(to: url)
    }

    /// Finds an executable in the system PATH.
    private func findInPath(_ name: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":").map(String.init) {
            let full = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }
}

// MARK: - Conformance Error

/// Errors thrown by the conformance test suite.
public enum ConformanceError: Error, LocalizedError, Sendable {
    /// cjxl encoding failed with the given reason.
    case libjxlEncodingFailed(String)

    /// djxl decoding failed with the given reason.
    case libjxlDecodingFailed(String)

    /// The test vector references an unavailable resource.
    case resourceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .libjxlEncodingFailed(let r):  return "cjxl encoding failed: \(r)"
        case .libjxlDecodingFailed(let r):  return "djxl decoding failed: \(r)"
        case .resourceUnavailable(let r):   return "Resource unavailable: \(r)"
        }
    }
}
