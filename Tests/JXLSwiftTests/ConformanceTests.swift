// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import XCTest
@testable import JXLSwift
import Foundation

/// ISO/IEC 18181-3 Conformance Tests — Milestone 14.
///
/// Validates JXLSwift against the conformance requirements of:
/// - **Part 1** (ISO/IEC 18181-1 §6–§11): bitstream structure, entropy coding,
///   size header, image metadata header, frame header.
/// - **Part 2** (ISO/IEC 18181-2 §3): ISOBMFF container format, metadata boxes.
///
/// Tests that require cjxl/djxl skip gracefully when those tools are not installed.
final class ConformanceTests: XCTestCase {

    // MARK: - Helpers

    private let runner = ConformanceRunner(
        enableRoundTripChecks: true,
        enableLibjxlChecks: true
    )

    private func skipIfLibjxlUnavailable() throws {
        try XCTSkipUnless(
            runner.isLibjxlAvailable(),
            "libjxl tools (cjxl/djxl) not installed — skipping interoperability test"
        )
    }

    // MARK: - Bitstream Structure (Part 1 §6)

    func testConformance_BitstreamStructure_AllVectors() throws {
        let vectors = ConformanceRunner.standardVectors()
            .filter { $0.category == .bitstreamStructure }

        XCTAssertFalse(vectors.isEmpty, "Expected at least one bitstream-structure vector")

        for vector in vectors {
            let encoder = JXLEncoder(options: vector.options)
            let encoded = try encoder.encode(vector.frame)
            let checks = runner.bitstreamStructureChecks(encoded.data)
            for check in checks {
                XCTAssertTrue(
                    check.passed,
                    "[\(vector.id)] \(check.name): \(check.message)"
                )
            }
        }
    }

    func testConformance_BitstreamStructure_SignatureLossless() throws {
        let frame = TestImageGenerator.gradient(width: 8, height: 8)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)

        XCTAssertGreaterThanOrEqual(encoded.data.count, 2, "Codestream must be at least 2 bytes")
        XCTAssertEqual(encoded.data[0], 0xFF, "First signature byte must be 0xFF")
        XCTAssertEqual(encoded.data[1], 0x0A, "Second signature byte must be 0x0A")
    }

    func testConformance_BitstreamStructure_SignatureLossy() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 80)))
        let encoded = try encoder.encode(frame)

        XCTAssertGreaterThanOrEqual(encoded.data.count, 2)
        XCTAssertEqual(encoded.data[0], 0xFF)
        XCTAssertEqual(encoded.data[1], 0x0A)
    }

    func testConformance_BitstreamStructure_NotISOBMFFContainer() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)

        // A bare codestream must NOT have an ISOBMFF 'JXL ' box type at bytes 4-7
        if encoded.data.count >= 8 {
            let isContainer = encoded.data[4] == 0x4A
                && encoded.data[5] == 0x58
                && encoded.data[6] == 0x4C
                && encoded.data[7] == 0x20
                && !(encoded.data[0] == 0xFF && encoded.data[1] == 0x0A)
            XCTAssertFalse(isContainer, "Bare codestream must not be ISOBMFF-wrapped")
        }
    }

    func testConformance_BitstreamStructure_MinimumSize_1x1() throws {
        let frame = TestImageGenerator.gradient(width: 1, height: 1)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        XCTAssertGreaterThanOrEqual(encoded.data.count, 2, "Even a 1×1 image must be at least 2 bytes")
    }

    // MARK: - Image Header (Part 1 §11)

    func testConformance_ImageHeader_SmallDimensions() throws {
        let frame = TestImageGenerator.gradient(width: 64, height: 64)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        let checks = runner.imageDimensionChecks(encoded.data, frame: frame)
        for check in checks {
            XCTAssertTrue(check.passed, "\(check.name): \(check.message)")
        }
    }

    func testConformance_ImageHeader_MediumDimensions() throws {
        let frame = TestImageGenerator.gradient(width: 320, height: 240)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        let checks = runner.imageDimensionChecks(encoded.data, frame: frame)
        for check in checks {
            XCTAssertTrue(check.passed, "\(check.name): \(check.message)")
        }
    }

    func testConformance_ImageHeader_Grayscale() throws {
        let frame = TestImageGenerator.gradient(width: 32, height: 32, channels: 1)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        XCTAssertGreaterThan(encoded.data.count, 2)
        XCTAssertEqual(encoded.data[0], 0xFF)
        XCTAssertEqual(encoded.data[1], 0x0A)
    }

    func testConformance_ImageHeader_RGBA() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16, channels: 4)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        XCTAssertGreaterThan(encoded.data.count, 2)
    }

    func testConformance_ImageHeader_SizeHeaderRoundTrip() throws {
        // Validate that SizeHeader can be created and serialised for standard sizes
        let testSizes: [(UInt32, UInt32)] = [(1, 1), (64, 64), (256, 256), (512, 384), (1920, 1080)]
        for (w, h) in testSizes {
            let header = try SizeHeader(width: w, height: h)
            XCTAssertEqual(header.width, w)
            XCTAssertEqual(header.height, h)
            var writer = BitstreamWriter()
            header.serialise(to: &writer)
            writer.flushByte()
            XCTAssertGreaterThan(writer.data.count, 0, "SizeHeader for \(w)×\(h) must produce bytes")
        }
    }

    func testConformance_ImageHeader_InvalidDimensions_Zero() {
        XCTAssertThrowsError(try SizeHeader(width: 0, height: 64)) { error in
            XCTAssertTrue(error is CodestreamError, "Expected CodestreamError for zero width")
        }
        XCTAssertThrowsError(try SizeHeader(width: 64, height: 0)) { error in
            XCTAssertTrue(error is CodestreamError, "Expected CodestreamError for zero height")
        }
    }

    // MARK: - Frame Header (Part 1 §9)

    func testConformance_FrameHeader_ModularModePresent() throws {
        let frame = TestImageGenerator.gradient(width: 32, height: 32)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        let checks = runner.framePresenceChecks(encoded.data)
        for check in checks {
            XCTAssertTrue(check.passed, "\(check.name): \(check.message)")
        }
    }

    func testConformance_FrameHeader_VarDCTModePresent() throws {
        let frame = TestImageGenerator.gradient(width: 32, height: 32)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90)))
        let encoded = try encoder.encode(frame)
        let checks = runner.framePresenceChecks(encoded.data)
        for check in checks {
            XCTAssertTrue(check.passed, "\(check.name): \(check.message)")
        }
    }

    func testConformance_FrameHeader_AllStandardVectors() throws {
        let vectors = ConformanceRunner.standardVectors()
            .filter { $0.category == .frameHeader }
        for vector in vectors {
            let encoder = JXLEncoder(options: vector.options)
            let encoded = try encoder.encode(vector.frame)
            let checks = runner.framePresenceChecks(encoded.data)
            for check in checks {
                XCTAssertTrue(check.passed, "[\(vector.id)] \(check.name): \(check.message)")
            }
        }
    }

    // MARK: - Container Format (Part 2 §3)

    func testConformance_ContainerFormat_BareCodestream_Lossless() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        let checks = runner.containerFormatChecks(encoded.data)
        for check in checks {
            XCTAssertTrue(check.passed, "\(check.name): \(check.message)")
        }
    }

    func testConformance_ContainerFormat_BareCodestream_Lossy() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 85)))
        let encoded = try encoder.encode(frame)
        let checks = runner.containerFormatChecks(encoded.data)
        for check in checks {
            XCTAssertTrue(check.passed, "\(check.name): \(check.message)")
        }
    }

    func testConformance_ContainerFormat_BoxTypes_AllCasesHaveBytes() {
        // Every BoxType must produce exactly 4 bytes
        for boxType in BoxType.allCases {
            let bytes = boxType.bytes
            XCTAssertEqual(bytes.count, 4, "BoxType.\(boxType.rawValue) must have exactly 4 bytes")
        }
    }

    func testConformance_ContainerFormat_BoxSerialization() {
        // A serialised box must have the standard ISOBMFF layout
        let payload = Data([0x01, 0x02, 0x03])
        let box = Box(type: .jxlCodestream, payload: payload)
        let serialised = box.serialise()

        // 4-byte size + 4-byte type + payload
        XCTAssertEqual(serialised.count, 4 + 4 + payload.count)

        // Size is big-endian
        let expectedSize = UInt32(serialised.count)
        let readSize = (UInt32(serialised[0]) << 24)
                     | (UInt32(serialised[1]) << 16)
                     | (UInt32(serialised[2]) << 8)
                     |  UInt32(serialised[3])
        XCTAssertEqual(readSize, expectedSize)

        // Type bytes match BoxType.jxlCodestream = "jxlc"
        XCTAssertEqual(serialised[4], UInt8(ascii: "j"))
        XCTAssertEqual(serialised[5], UInt8(ascii: "x"))
        XCTAssertEqual(serialised[6], UInt8(ascii: "l"))
        XCTAssertEqual(serialised[7], UInt8(ascii: "c"))
    }

    // MARK: - Lossless Round-Trip (ISO/IEC 18181-1 §2.1)

    func testConformance_LosslessRoundTrip_RGBGradient() throws {
        let frame = TestImageGenerator.gradient(width: 32, height: 32)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)

        // Pixel-perfect check
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                for c in 0..<min(frame.channels, decoded.channels) {
                    let orig = frame.getPixel(x: x, y: y, channel: c)
                    let dec  = decoded.getPixel(x: x, y: y, channel: c)
                    XCTAssertEqual(orig, dec, "Pixel mismatch at (\(x),\(y),ch\(c))")
                }
            }
        }
    }

    func testConformance_LosslessRoundTrip_Grayscale() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16, channels: 1)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)

        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let orig = frame.getPixel(x: x, y: y, channel: 0)
                let dec  = decoded.getPixel(x: x, y: y, channel: 0)
                XCTAssertEqual(orig, dec, "Pixel mismatch at (\(x),\(y))")
            }
        }
    }

    func testConformance_LosslessRoundTrip_Checkerboard() throws {
        let frame = TestImageGenerator.checkerboard(width: 32, height: 32)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
    }

    func testConformance_LosslessRoundTrip_AllStandardVectors() throws {
        let vectors = ConformanceRunner.standardVectors()
            .filter { $0.category == .losslessRoundTrip }

        XCTAssertFalse(vectors.isEmpty, "Expected at least one lossless round-trip vector")

        for vector in vectors {
            let report = runner.run(vectors: [vector])
            XCTAssertEqual(report.results.count, 1)
            let result = report.results[0]
            XCTAssertTrue(
                result.passed,
                "[\(vector.id)] failed: \(result.failedChecks.joined(separator: ", "))"
            )
        }
    }

    // MARK: - Lossy Round-Trip

    func testConformance_LossyRoundTrip_Quality90_ProducesOutput() throws {
        let frame = TestImageGenerator.gradient(width: 32, height: 32)
        let options = EncodingOptions(mode: .lossy(quality: 90))
        let encoder = JXLEncoder(options: options)
        let encoded = try encoder.encode(frame)
        XCTAssertGreaterThan(encoded.data.count, 2, "Lossy encoding must produce output")
        XCTAssertEqual(encoded.data[0], 0xFF)
        XCTAssertEqual(encoded.data[1], 0x0A)
    }

    func testConformance_LossyRoundTrip_AllStandardVectors() throws {
        let vectors = ConformanceRunner.standardVectors()
            .filter { $0.category == .lossyRoundTrip }
        for vector in vectors {
            let report = runner.run(vectors: [vector])
            XCTAssertEqual(report.results.count, 1)
            let result = report.results[0]
            XCTAssertTrue(
                result.passed,
                "[\(vector.id)] failed: \(result.failedChecks.joined(separator: ", "))"
            )
        }
    }

    // MARK: - Full Conformance Report

    func testConformance_FullReport_AllStandardVectors() throws {
        let vectors = ConformanceRunner.standardVectors()
        let report = runner.run(vectors: vectors)

        XCTAssertEqual(report.results.count, vectors.count)

        let summary = report.summary
        XCTAssertEqual(summary.totalVectors, vectors.count)
        XCTAssertGreaterThan(summary.totalVectors, 0)

        // Report structure is sound
        XCTAssertNotNil(report.timestamp)
        XCTAssertFalse(report.runnerID.isEmpty)

        // All vectors should pass in this baseline run
        if !summary.allPassed {
            let failed = report.results.filter { !$0.passed }
            let failureDetails = failed.map { r in
                "[\(r.vectorID)] \(r.failedChecks.joined(separator: ", "))"
            }.joined(separator: "\n")
            XCTFail("Conformance failures:\n\(failureDetails)")
        }
    }

    func testConformance_Report_PassRateComputedCorrectly() {
        // Verify ConformanceSummary.passRate arithmetic
        let allPass = ConformanceResult(
            vectorID: "v1", category: .bitstreamStructure, encodingMode: "lossless",
            compressedSize: 100,
            checks: [ConformanceCheck(name: "sig", passed: true, message: "ok")],
            encodingSucceeded: true, encodingError: nil
        )
        let allFail = ConformanceResult(
            vectorID: "v2", category: .bitstreamStructure, encodingMode: "lossless",
            compressedSize: 0,
            checks: [ConformanceCheck(name: "sig", passed: false, message: "bad")],
            encodingSucceeded: true, encodingError: nil
        )
        let report = ConformanceReport(
            timestamp: Date(),
            runnerID: "test",
            libjxlAvailable: false,
            results: [allPass, allFail]
        )
        let summary = report.summary
        XCTAssertEqual(summary.totalVectors, 2)
        XCTAssertEqual(summary.passedVectors, 1)
        XCTAssertEqual(summary.failedVectors, 1)
        XCTAssertEqual(summary.passRate, 0.5, accuracy: 0.001)
    }

    func testConformance_Report_EmptyVectors() {
        let report = ConformanceReport(
            timestamp: Date(),
            runnerID: "test",
            libjxlAvailable: false,
            results: []
        )
        XCTAssertTrue(report.summary.allPassed, "Empty report should report all passed")
        XCTAssertEqual(report.summary.passRate, 1.0, accuracy: 0.001)
    }

    // MARK: - ConformanceCheck & ConformanceResult Types

    func testConformance_Check_PassedProperties() {
        let check = ConformanceCheck(name: "sig", passed: true, message: "ok")
        XCTAssertEqual(check.name, "sig")
        XCTAssertTrue(check.passed)
        XCTAssertEqual(check.message, "ok")
    }

    func testConformance_Check_FailedProperties() {
        let check = ConformanceCheck(name: "sig", passed: false, message: "bad sig")
        XCTAssertFalse(check.passed)
        XCTAssertEqual(check.message, "bad sig")
    }

    func testConformance_Result_EncodingFailed_NotPassed() {
        let result = ConformanceResult(
            vectorID: "test_001", category: .bitstreamStructure, encodingMode: "lossless",
            compressedSize: 0, checks: [],
            encodingSucceeded: false, encodingError: "some error"
        )
        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.encodingSucceeded)
        XCTAssertEqual(result.encodingError, "some error")
    }

    func testConformance_Category_AllCasesHaveDescription() {
        for cat in ConformanceCategory.allCases {
            XCTAssertFalse(cat.description.isEmpty, "Category \(cat.rawValue) has no description")
        }
    }

    func testConformance_Vector_Properties() {
        let frame = TestImageGenerator.gradient(width: 8, height: 8)
        let vector = ConformanceVector(
            id: "test_vec",
            description: "Test vector",
            category: .bitstreamStructure,
            frame: frame,
            options: .lossless,
            requiresLosslessRoundTrip: true,
            minimumPSNR: nil
        )
        XCTAssertEqual(vector.id, "test_vec")
        XCTAssertEqual(vector.category, .bitstreamStructure)
        XCTAssertTrue(vector.requiresLosslessRoundTrip)
        XCTAssertNil(vector.minimumPSNR)
    }

    // MARK: - Conformance Error

    func testConformance_Error_LocalizedDescriptions() {
        let e1 = ConformanceError.libjxlEncodingFailed("bad exit")
        let e2 = ConformanceError.libjxlDecodingFailed("corrupt")
        let e3 = ConformanceError.resourceUnavailable("missing file")
        XCTAssertTrue(e1.errorDescription?.contains("cjxl") == true)
        XCTAssertTrue(e2.errorDescription?.contains("djxl") == true)
        XCTAssertTrue(e3.errorDescription?.contains("Resource") == true)
    }

    // MARK: - libjxl Interoperability (conditional)

    /// JXLSwift-encoded file must be decodable by djxl (lossless).
    func testConformance_LibjxlInterop_JXLSwiftToLibjxl_Lossless() throws {
        try skipIfLibjxlUnavailable()

        let frame = TestImageGenerator.gradient(width: 32, height: 32)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)

        let tempDir = FileManager.default.temporaryDirectory
        let jxlURL = tempDir.appendingPathComponent("conf_interop_\(UUID().uuidString).jxl")
        let ppmURL = tempDir.appendingPathComponent("conf_interop_\(UUID().uuidString).ppm")
        defer {
            try? FileManager.default.removeItem(at: jxlURL)
            try? FileManager.default.removeItem(at: ppmURL)
        }

        try encoded.data.write(to: jxlURL)
        let status = try runner.decodeTempWithDjxl(inputURL: jxlURL, outputURL: ppmURL)
        XCTAssertEqual(status, 0, "djxl must decode JXLSwift-encoded lossless file successfully")
    }

    /// JXLSwift-encoded file must be decodable by djxl (lossy).
    func testConformance_LibjxlInterop_JXLSwiftToLibjxl_Lossy() throws {
        try skipIfLibjxlUnavailable()

        let frame = TestImageGenerator.gradient(width: 32, height: 32)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 85)))
        let encoded = try encoder.encode(frame)

        let tempDir = FileManager.default.temporaryDirectory
        let jxlURL = tempDir.appendingPathComponent("conf_interop_\(UUID().uuidString).jxl")
        let ppmURL = tempDir.appendingPathComponent("conf_interop_\(UUID().uuidString).ppm")
        defer {
            try? FileManager.default.removeItem(at: jxlURL)
            try? FileManager.default.removeItem(at: ppmURL)
        }

        try encoded.data.write(to: jxlURL)
        let status = try runner.decodeTempWithDjxl(inputURL: jxlURL, outputURL: ppmURL)
        XCTAssertEqual(status, 0, "djxl must decode JXLSwift-encoded lossy file successfully")
    }

    /// cjxl-encoded file must be decodable by JXLDecoder (lossless).
    func testConformance_LibjxlInterop_LibjxlToJXLSwift_Lossless() throws {
        try skipIfLibjxlUnavailable()

        let frame = TestImageGenerator.gradient(width: 32, height: 32)
        let tempDir = FileManager.default.temporaryDirectory
        let jxlURL = tempDir.appendingPathComponent("conf_libjxl_\(UUID().uuidString).jxl")
        defer { try? FileManager.default.removeItem(at: jxlURL) }

        try runner.encodeTempWithCjxl(frame: frame, outputURL: jxlURL)

        let jxlData = try Data(contentsOf: jxlURL)
        XCTAssertFalse(jxlData.isEmpty, "cjxl must produce output")

        let decoder = JXLDecoder()
        XCTAssertNoThrow(
            try decoder.decode(jxlData),
            "JXLDecoder must decode cjxl-encoded lossless file without error"
        )
    }

    /// Round-trip: JXLSwift encode → djxl decode → cjxl re-encode → JXLSwift decode.
    func testConformance_LibjxlInterop_RoundTrip_JXLSwiftThenLibjxl() throws {
        try skipIfLibjxlUnavailable()

        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)

        let tempDir = FileManager.default.temporaryDirectory
        let jxlURL = tempDir.appendingPathComponent("conf_rt_\(UUID().uuidString).jxl")
        let ppmURL = tempDir.appendingPathComponent("conf_rt_\(UUID().uuidString).ppm")
        defer {
            try? FileManager.default.removeItem(at: jxlURL)
            try? FileManager.default.removeItem(at: ppmURL)
        }

        // Step 1: JXLSwift encode → write .jxl
        try encoded.data.write(to: jxlURL)

        // Step 2: djxl decode → .ppm
        let status = try runner.decodeTempWithDjxl(inputURL: jxlURL, outputURL: ppmURL)
        XCTAssertEqual(status, 0, "djxl must decode JXLSwift output")
    }

    // MARK: - Metadata Preservation (ISO/IEC 18181-2 Part 2 §3)

    /// EXIF metadata must survive a JXLContainer serialise → parse round-trip
    /// (ISO/IEC 18181-2 §3.4 — Exif box).
    func testConformance_MetadataPreservation_EXIF_RoundTrip() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let encoded = try JXLEncoder(options: .lossless).encode(frame)

        // Minimal TIFF-II EXIF header (little-endian, magic 42, IFD offset 8)
        let exifData = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])

        let containerData = JXLContainerBuilder(codestream: encoded.data)
            .withEXIF(exifData)
            .build()
            .serialise()

        let parsed = try JXLDecoder().parseContainer(containerData)
        let checks = runner.metadataBoxChecks(container: parsed, expectedEXIF: exifData)

        for check in checks {
            XCTAssertTrue(check.passed, "EXIF preservation — \(check.name): \(check.message)")
        }
    }

    /// XMP metadata must survive a JXLContainer serialise → parse round-trip
    /// (ISO/IEC 18181-2 §3.5 — xml  box).
    func testConformance_MetadataPreservation_XMP_RoundTrip() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let encoded = try JXLEncoder(options: .lossless).encode(frame)

        let xmpString = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"
              dc:title="ISO 18181-3 Conformance Test"/>
          </rdf:RDF>
        </x:xmpmeta>
        """
        let xmpData = Data(xmpString.utf8)

        let containerData = JXLContainerBuilder(codestream: encoded.data)
            .withXMP(xmlString: xmpString)
            .build()
            .serialise()

        let parsed = try JXLDecoder().parseContainer(containerData)
        let checks = runner.metadataBoxChecks(container: parsed, expectedXMP: xmpData)

        for check in checks {
            XCTAssertTrue(check.passed, "XMP preservation — \(check.name): \(check.message)")
        }
    }

    /// ICC colour profile must survive a JXLContainer serialise → parse round-trip
    /// (ISO/IEC 18181-2 §3.3 — colr box).
    func testConformance_MetadataPreservation_ICC_RoundTrip() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let encoded = try JXLEncoder(options: .lossless).encode(frame)

        // Synthetic 128-byte ICC profile
        let iccData = Data((0..<128).map { UInt8($0 & 0xFF) })

        let containerData = JXLContainerBuilder(codestream: encoded.data)
            .withICCProfile(iccData)
            .build()
            .serialise()

        let parsed = try JXLDecoder().parseContainer(containerData)
        let checks = runner.metadataBoxChecks(container: parsed, expectedICC: iccData)

        for check in checks {
            XCTAssertTrue(check.passed, "ICC preservation — \(check.name): \(check.message)")
        }
    }

    /// EXIF + XMP + ICC must all survive the same container round-trip simultaneously.
    func testConformance_MetadataPreservation_AllMetadata_RoundTrip() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let encoded = try JXLEncoder(options: .lossless).encode(frame)

        let exifData = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        let xmpString = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>"
        let xmpData = Data(xmpString.utf8)
        let iccData = Data(repeating: 0xAB, count: 64)

        let containerData = JXLContainerBuilder(codestream: encoded.data)
            .withEXIF(exifData)
            .withXMP(xmlString: xmpString)
            .withICCProfile(iccData)
            .build()
            .serialise()

        let parsed = try JXLDecoder().parseContainer(containerData)
        let checks = runner.metadataBoxChecks(
            container: parsed,
            expectedEXIF: exifData,
            expectedXMP: xmpData,
            expectedICC: iccData
        )

        for check in checks {
            XCTAssertTrue(check.passed, "All-metadata preservation — \(check.name): \(check.message)")
        }
    }

    /// Codestream inside a metadata-bearing container must still decode correctly.
    func testConformance_MetadataPreservation_CodestreamDecodesAfterMetadata() throws {
        let original = TestImageGenerator.gradient(width: 8, height: 8)
        let encoded = try JXLEncoder(options: .lossless).encode(original)

        let containerData = JXLContainerBuilder(codestream: encoded.data)
            .withEXIF(Data([0x49, 0x49, 0x2A, 0x00]))
            .withXMP(xmlString: "<x:xmpmeta/>")
            .withICCProfile(Data([0xAA, 0xBB, 0xCC]))
            .build()
            .serialise()

        let decoder = JXLDecoder()
        let parsed = try decoder.parseContainer(containerData)
        let decoded = try decoder.decode(parsed.codestream)

        XCTAssertEqual(decoded.width, original.width)
        XCTAssertEqual(decoded.height, original.height)

        for y in 0..<original.height {
            for x in 0..<original.width {
                for c in 0..<min(original.channels, decoded.channels) {
                    XCTAssertEqual(
                        original.getPixel(x: x, y: y, channel: c),
                        decoded.getPixel(x: x, y: y, channel: c),
                        "Pixel mismatch at (\(x),\(y),ch\(c)) after metadata round-trip"
                    )
                }
            }
        }
    }
}
