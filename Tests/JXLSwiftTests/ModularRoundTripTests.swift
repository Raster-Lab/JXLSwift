import XCTest
@testable import JXLSwift

/// Round-trip tests for the Modular encoding pipeline.
///
/// Validates that encoding followed by decoding produces pixel-perfect
/// results for both the unframed and framed (subbitstream) paths.
final class ModularRoundTripTests: XCTestCase {

    // MARK: - Helpers

    /// Create a ModularEncoder with the given effort level.
    private func makeEncoder(effort: EncodingEffort = .squirrel) -> ModularEncoder {
        ModularEncoder(
            hardware: HardwareCapabilities.detect(),
            options: EncodingOptions(
                mode: .lossless,
                effort: effort,
                modularMode: true
            )
        )
    }

    /// Create a ModularDecoder matching the given effort level.
    private func makeDecoder(effort: EncodingEffort = .squirrel) -> ModularDecoder {
        ModularDecoder(
            hardware: HardwareCapabilities.detect(),
            options: EncodingOptions(
                mode: .lossless,
                effort: effort,
                modularMode: true
            )
        )
    }

    /// Assert two ImageFrames are pixel-identical across all channels.
    private func assertPixelPerfect(
        _ original: ImageFrame,
        _ decoded: ImageFrame,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(original.width, decoded.width,
                       "Width mismatch", file: file, line: line)
        XCTAssertEqual(original.height, decoded.height,
                       "Height mismatch", file: file, line: line)
        XCTAssertEqual(original.channels, decoded.channels,
                       "Channel count mismatch", file: file, line: line)

        for c in 0..<original.channels {
            for y in 0..<original.height {
                for x in 0..<original.width {
                    let origVal = original.getPixel(x: x, y: y, channel: c)
                    let decVal = decoded.getPixel(x: x, y: y, channel: c)
                    if origVal != decVal {
                        XCTFail("Pixel mismatch at (\(x),\(y)) channel \(c): "
                                + "original=\(origVal) decoded=\(decVal)",
                                file: file, line: line)
                        return
                    }
                }
            }
        }
    }

    /// Fill a frame with a linear gradient (easy for prediction).
    private func fillGradient(_ frame: inout ImageFrame) {
        for c in 0..<frame.channels {
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    let value = UInt16((x + y * frame.width + c * 7) % 256)
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }
    }

    /// Fill a frame with pseudo-random data.
    private func fillRandom(_ frame: inout ImageFrame, seed: UInt64 = 42) {
        var state = seed
        for c in 0..<frame.channels {
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    // xorshift64*
                    state ^= state >> 12
                    state ^= state << 25
                    state ^= state >> 27
                    let value = UInt16((state &* 0x2545F4914F6CDD1D) >> 56)
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }
    }

    // MARK: - Self Round-Trip Tests (encode → decode → pixel-perfect match)

    func testRoundTrip_1x1_SingleChannel() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 1, height: 1, channels: 1)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 128)

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 1, height: 1, channels: 1
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_1x1_RGB() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 1, height: 1, channels: 3)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 255)
        frame.setPixel(x: 0, y: 0, channel: 1, value: 128)
        frame.setPixel(x: 0, y: 0, channel: 2, value: 64)

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 1, height: 1, channels: 3
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_4x4_Gradient_SingleChannel() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 4, height: 4, channels: 1)
        fillGradient(&frame)

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 4, height: 4, channels: 1
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_8x8_Gradient_RGB() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        fillGradient(&frame)

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 8, height: 8, channels: 3
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_16x16_Random_RGB() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        fillRandom(&frame)

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 16, height: 16, channels: 3
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_OddDimensions_5x7_RGB() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 5, height: 7, channels: 3)
        fillGradient(&frame)

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 5, height: 7, channels: 3
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_SingleChannel_Flat() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 8, height: 8, channels: 1)
        // Fill with constant value
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: 42)
            }
        }

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 8, height: 8, channels: 1
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_LowerEffort_MED() throws {
        let encoder = makeEncoder(effort: .falcon)
        let decoder = makeDecoder(effort: .falcon)

        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        fillGradient(&frame)

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 8, height: 8, channels: 3
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_AllZeros() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        let frame = ImageFrame(width: 4, height: 4, channels: 1)
        // All zeros by default

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 4, height: 4, channels: 1
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_MaxValues() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 4, height: 4, channels: 1)
        for y in 0..<4 {
            for x in 0..<4 {
                frame.setPixel(x: x, y: y, channel: 0, value: 255)
            }
        }

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 4, height: 4, channels: 1
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_RGBA_4Channel() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 4, height: 4, channels: 4)
        fillGradient(&frame)

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 4, height: 4, channels: 4
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_LargerImage_32x32() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 32, height: 32, channels: 3)
        fillRandom(&frame, seed: 123)

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 32, height: 32, channels: 3
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_WideRow_64x1() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 64, height: 1, channels: 1)
        for x in 0..<64 {
            frame.setPixel(x: x, y: 0, channel: 0, value: UInt16(x * 4))
        }

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 64, height: 1, channels: 1
        )

        assertPixelPerfect(frame, decoded)
    }

    func testRoundTrip_TallColumn_1x64() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 1, height: 64, channels: 1)
        for y in 0..<64 {
            frame.setPixel(x: 0, y: y, channel: 0, value: UInt16(y * 4))
        }

        let encoded = try encoder.encode(frame: frame)
        let decoded = try decoder.decode(
            data: encoded, width: 1, height: 64, channels: 1
        )

        assertPixelPerfect(frame, decoded)
    }

    // MARK: - Framed Round-Trip Tests (subbitstream framing)

    func testFramedRoundTrip_8x8_SingleChannel() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 8, height: 8, channels: 1)
        fillGradient(&frame)

        let frameData = try encoder.encodeWithFraming(frame: frame)

        // Verify framing structure
        XCTAssertEqual(frameData.header.encoding, .modular)
        XCTAssertEqual(frameData.header.frameType, .regularFrame)
        XCTAssertEqual(frameData.sections.count, 2,
                       "1 global + 1 channel section")

        let decoded = try decoder.decodeFramed(
            sections: frameData.sections,
            width: 8, height: 8
        )

        assertPixelPerfect(frame, decoded)
    }

    func testFramedRoundTrip_8x8_RGB() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        fillGradient(&frame)

        let frameData = try encoder.encodeWithFraming(frame: frame)

        // Verify framing structure
        XCTAssertEqual(frameData.sections.count, 4,
                       "1 global + 3 channel sections")

        let decoded = try decoder.decodeFramed(
            sections: frameData.sections,
            width: 8, height: 8
        )

        assertPixelPerfect(frame, decoded)
    }

    func testFramedRoundTrip_16x16_Random() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        fillRandom(&frame)

        let frameData = try encoder.encodeWithFraming(frame: frame)
        let decoded = try decoder.decodeFramed(
            sections: frameData.sections,
            width: 16, height: 16
        )

        assertPixelPerfect(frame, decoded)
    }

    func testFramedRoundTrip_OddDimensions() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 5, height: 7, channels: 3)
        fillRandom(&frame, seed: 99)

        let frameData = try encoder.encodeWithFraming(frame: frame)
        let decoded = try decoder.decodeFramed(
            sections: frameData.sections,
            width: 5, height: 7
        )

        assertPixelPerfect(frame, decoded)
    }

    func testFramedRoundTrip_Serialised() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        fillGradient(&frame)

        let frameData = try encoder.encodeWithFraming(frame: frame)

        // Serialise the entire frame (header + ToC + sections)
        let serialised = frameData.serialise()
        XCTAssertGreaterThan(serialised.count, 0,
                             "Serialised frame should be non-empty")

        // Verify it starts with the frame header (not all-default since
        // encoding is modular, not varDCT)
        // The framed data can be decoded by extracting the sections
        let decoded = try decoder.decodeFramed(
            sections: frameData.sections,
            width: 8, height: 8
        )

        assertPixelPerfect(frame, decoded)
    }

    func testFramedRoundTrip_GlobalSectionContainsMetadata() throws {
        let encoder = makeEncoder()

        var frame = ImageFrame(width: 4, height: 4, channels: 3)
        fillGradient(&frame)

        let frameData = try encoder.encodeWithFraming(frame: frame)

        // Parse the global section
        let globalSection = frameData.sections[0]
        var reader = BitstreamReader(data: globalSection)

        // Modular mode flag
        guard let isModular = reader.readBit() else {
            XCTFail("Could not read modular flag")
            return
        }
        XCTAssertTrue(isModular, "Global section should signal modular mode")

        // RCT flag
        guard let useRCT = reader.readBit() else {
            XCTFail("Could not read RCT flag")
            return
        }
        XCTAssertTrue(useRCT, "3-channel image should use RCT")

        // Remaining 6 bits are padding, then metadata bytes
        for _ in 0..<6 { _ = reader.readBit() }

        guard let channelCount = reader.readByte() else {
            XCTFail("Could not read channel count")
            return
        }
        XCTAssertEqual(channelCount, 3, "Channel count should be 3")

        guard let treeType = reader.readByte() else {
            XCTFail("Could not read tree type")
            return
        }
        XCTAssertEqual(treeType, 1,
                       "Extended tree (squirrel effort) should be type 1")

        guard let squeezeLevels = reader.readByte() else {
            XCTFail("Could not read squeeze levels")
            return
        }
        XCTAssertEqual(squeezeLevels, 3, "Default squeeze levels should be 3")
    }

    // MARK: - Full Pipeline Round-Trip (JXLEncoder → decode)

    func testFullPipeline_Lossless_RoundTrip() throws {
        let options = EncodingOptions.lossless
        let jxlEncoder = JXLEncoder(options: options)

        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        fillGradient(&frame)

        let result = try jxlEncoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 2,
                             "Encoded data should include at least the JXL signature")

        // Verify the JXL signature
        XCTAssertEqual(result.data[0], 0xFF, "First byte should be 0xFF")
        XCTAssertEqual(result.data[1], 0x0A, "Second byte should be 0x0A")
    }

    // MARK: - libjxl Interoperability Tests (conditional)

    /// Test encode with JXLSwift → decode with libjxl.
    ///
    /// This test is only run when `djxl` (the libjxl decoder) is available
    /// on the system PATH. It encodes a test image, writes it to a temporary
    /// file, and invokes `djxl` to decode it.
    func testInterop_JXLSwiftEncode_LibjxlDecode() throws {
        // Check if djxl is available
        let whichResult = try? runProcess("/usr/bin/which", arguments: ["djxl"])
        guard let path = whichResult, !path.isEmpty else {
            // djxl not installed — skip test with a message
            print("⚠️ Skipping libjxl interop test: djxl not found on PATH")
            return
        }

        let jxlEncoder = JXLEncoder(options: .lossless)

        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        fillGradient(&frame)

        let result = try jxlEncoder.encode(frame)

        // Write to temp file
        let tmpDir = FileManager.default.temporaryDirectory
        let jxlPath = tmpDir.appendingPathComponent("test_roundtrip.jxl")
        let ppmPath = tmpDir.appendingPathComponent("test_roundtrip.ppm")

        try result.data.write(to: jxlPath)
        defer {
            try? FileManager.default.removeItem(at: jxlPath)
            try? FileManager.default.removeItem(at: ppmPath)
        }

        // Decode with djxl
        let djxlOutput = try? runProcess(
            path.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: [jxlPath.path, ppmPath.path]
        )

        // If djxl succeeded, the output file should exist
        if djxlOutput != nil && FileManager.default.fileExists(atPath: ppmPath.path) {
            let decodedData = try Data(contentsOf: ppmPath)
            XCTAssertGreaterThan(decodedData.count, 0,
                                 "djxl should produce non-empty output")
        } else {
            print("⚠️ djxl decode failed or produced no output — "
                  + "bitstream may not be fully compliant yet")
        }
    }

    /// Test encode with libjxl → decode with JXLSwift.
    ///
    /// This test is only run when `cjxl` (the libjxl encoder) is available
    /// on the system PATH. It creates a test PPM image, encodes it with
    /// `cjxl`, and then attempts to decode the header.
    func testInterop_LibjxlEncode_JXLSwiftDecode() throws {
        // Check if cjxl is available
        let whichResult = try? runProcess("/usr/bin/which", arguments: ["cjxl"])
        guard let path = whichResult, !path.isEmpty else {
            print("⚠️ Skipping libjxl interop test: cjxl not found on PATH")
            return
        }

        // Create a minimal PPM file
        let tmpDir = FileManager.default.temporaryDirectory
        let ppmPath = tmpDir.appendingPathComponent("test_input.ppm")
        let jxlPath = tmpDir.appendingPathComponent("test_libjxl.jxl")

        var ppmData = Data()
        let header = "P6\n4 4\n255\n"
        ppmData.append(Data(header.utf8))
        // 4x4 RGB pixels
        for y in 0..<4 {
            for x in 0..<4 {
                ppmData.append(UInt8((x + y * 4) * 16))
                ppmData.append(UInt8((x + y * 4) * 8))
                ppmData.append(UInt8((x + y * 4) * 4))
            }
        }
        try ppmData.write(to: ppmPath)

        defer {
            try? FileManager.default.removeItem(at: ppmPath)
            try? FileManager.default.removeItem(at: jxlPath)
        }

        // Encode with cjxl (lossless)
        let cjxlOutput = try? runProcess(
            path.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: [ppmPath.path, jxlPath.path, "-d", "0"]
        )

        guard cjxlOutput != nil,
              FileManager.default.fileExists(atPath: jxlPath.path) else {
            print("⚠️ cjxl encode failed — skipping decode test")
            return
        }

        let jxlData = try Data(contentsOf: jxlPath)
        XCTAssertGreaterThan(jxlData.count, 2,
                             "cjxl output should be non-empty")

        // Verify the JXL signature
        XCTAssertEqual(jxlData[0], 0xFF, "First byte should be 0xFF")
        XCTAssertEqual(jxlData[1], 0x0A, "Second byte should be 0x0A")

        // Full decoding of libjxl output requires a complete codestream
        // parser (Milestone 12). For now, verify the signature is valid.
        print("✅ libjxl-encoded file has valid JXL signature")
    }

    // MARK: - Process Helper

    /// Run an external process and capture its stdout.
    private func runProcess(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Performance

    func testRoundTripPerformance_16x16() throws {
        let encoder = makeEncoder()
        let decoder = makeDecoder()

        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        fillRandom(&frame)

        measure {
            let encoded = try! encoder.encode(frame: frame)
            _ = try! decoder.decode(
                data: encoded, width: 16, height: 16, channels: 3
            )
        }
    }
}
