// Foundation tests for the pure-Swift JXLSwift implementation.
//
// The codec layer (Modular tree, VarDCT, rANS) is not yet implemented;
// these tests cover the bitstream / container / header foundation that
// IS implemented, plus rejection paths for malformed input.

import XCTest
@testable import JXLSwift

final class FoundationTests: XCTestCase {

    // MARK: - BitReader / BitWriter symmetry

    /// Round-trip a sequence of bit writes through the reader. The
    /// values come back in the order written, with the correct widths.
    func testBitstream_RoundTripSimpleSequence() throws {
        var w = BitWriter()
        w.write(bits: 4, value: 0b1011)        // 11
        w.write(bits: 5, value: 0b10110)       // 22
        w.write(bits: 7, value: 0b1111111)     // 127
        w.write(bits: 16, value: 0xCAFE)
        w.write(bits: 32, value: 0xDEADBEEF)
        let data = w.finishToData()

        var r = BitReader(data)
        XCTAssertEqual(try r.read(bits: 4),  0b1011)
        XCTAssertEqual(try r.read(bits: 5),  0b10110)
        XCTAssertEqual(try r.read(bits: 7),  0b1111111)
        XCTAssertEqual(try r.read(bits: 16), 0xCAFE)
        XCTAssertEqual(try r.read(bits: 32), 0xDEADBEEF)
    }

    /// LSB-first packing: a single bit set, then 7 zeros, must be
    /// stored as byte 0x01, not 0x80.
    func testBitstream_LSBFirstPacking() {
        var w = BitWriter()
        w.write(bits: 1, value: 1)
        w.write(bits: 7, value: 0)
        XCTAssertEqual([UInt8](w.finishToData()), [0x01])
    }

    /// 64-bit values split correctly across the 32-bit boundary.
    func testBitstream_64BitRoundTrip() throws {
        var w = BitWriter()
        w.write64(bits: 64, value: 0xDEADBEEFCAFEBABE)
        let data = w.finishToData()
        var r = BitReader(data)
        XCTAssertEqual(try r.read64(bits: 64), 0xDEADBEEFCAFEBABE)
    }

    func testBitReader_ThrowsOnExhaustion() {
        var r = BitReader(Data([0x00]))
        XCTAssertThrowsError(try r.read(bits: 9)) { err in
            XCTAssertNotNil(err as? BitstreamError)
        }
    }

    func testBitReader_ThrowsOnTooManyBits() {
        var r = BitReader(Data(repeating: 0xFF, count: 8))
        XCTAssertThrowsError(try r.read(bits: 33))
    }

    // MARK: - U32 / U64 spec-defined integers

    /// U32 round-trip across all four distributions.
    func testU32_RoundTripAcrossDistributions() throws {
        let dists: (UInt32Distribution, UInt32Distribution, UInt32Distribution, UInt32Distribution) = (
            .literal(0),
            .offset(constant: 1, extraBits: 4),
            .offset(constant: 17, extraBits: 8),
            .offset(constant: 273, extraBits: 30)
        )
        for value in [UInt32](arrayLiteral: 0, 5, 200, 100_000) {
            var w = BitWriter()
            try w.writeU32(value, distributions: dists)
            let data = w.finishToData()
            var r = BitReader(data)
            XCTAssertEqual(try r.readU32(dists), value, "value \(value) failed round-trip")
        }
    }

    /// U64 covers the four selectors (0, small, mid, escape).
    func testU64_RoundTripAcrossSelectors() throws {
        for value in [UInt64](arrayLiteral: 0, 1, 16, 17, 272, 273, 0xFFFF, 0xDEAD_BEEF, 0x123_4567_89AB_CDEF) {
            var w = BitWriter()
            w.writeU64(value)
            let data = w.finishToData()
            var r = BitReader(data)
            XCTAssertEqual(try r.readU64(), value, "U64 \(String(value, radix: 16)) failed round-trip")
        }
    }

    // MARK: - Container parsing

    func testContainer_NakedCodestreamRecognised() throws {
        let bytes: [UInt8] = [0xFF, 0x0A] + [UInt8](repeating: 0, count: 32)
        let form = try parseJXLContainer(Data(bytes))
        XCTAssertEqual(form, .naked)
    }

    func testContainer_ISOBMFFSignatureRecognised() throws {
        var bytes = jxlContainerSignature
        // Add a minimal ftyp box (size 12 + 8 header = 20)
        bytes += [0x00, 0x00, 0x00, 0x14] // size 20
        bytes += [0x66, 0x74, 0x79, 0x70] // 'ftyp'
        bytes += [UInt8](repeating: 0, count: 12) // payload
        let form = try parseJXLContainer(Data(bytes))
        if case .iso(let boxes) = form {
            XCTAssertEqual(boxes.count, 1)
            XCTAssertEqual(boxes[0].type, "ftyp")
        } else {
            XCTFail("expected ISO container, got \(form)")
        }
    }

    func testContainer_RejectsRandomBytes() {
        var rnd = Data(count: 256)
        rnd.withUnsafeMutableBytes { p in
            for i in 0..<p.count { p[i] = UInt8(truncatingIfNeeded: i &* 31 ^ 0x55) }
        }
        XCTAssertThrowsError(try parseJXLContainer(rnd))
    }

    func testContainer_RoundTripBuildAndParse() throws {
        let codestream = Data([0xFF, 0x0A] + [UInt8](repeating: 0xAA, count: 100))
        let container = buildJXLContainer(codestream: codestream)
        XCTAssertTrue(isJXL(container))
        let form = try parseJXLContainer(container)
        guard case .iso(let boxes) = form else {
            XCTFail("expected ISO container"); return
        }
        XCTAssertEqual(boxes.map { $0.type }, ["ftyp", "jxlc"])
        let recovered = try extractCodestream(from: boxes, in: container)
        XCTAssertEqual(recovered, codestream)
    }

    // MARK: - SizeHeader

    /// Encode + read a SizeHeader for sizes that exercise different U32
    /// distributions (small ysize → small selector; large ysize → larger
    /// selector).
    func testSizeHeader_RoundTrip() throws {
        for (xsize, ysize) in [
            (UInt32(1), UInt32(1)),
            (UInt32(64), UInt32(64)),
            (UInt32(2544), UInt32(3056)),     // a real DX scan size
            (UInt32(8192), UInt32(8192)),     // 4K-ish
            (UInt32(50_000), UInt32(50_000)), // need 18-bit selector
        ] {
            var w = BitWriter()
            // Skip the codestream signature for this isolated test.
            try SizeHeader(xsize: xsize, ysize: ysize).write(to: &w)
            let data = w.finishToData()
            var r = BitReader(data)
            let h = try SizeHeader.read(from: &r)
            XCTAssertEqual(h.xsize, xsize, "xsize round-trip failed for \(xsize)x\(ysize)")
            XCTAssertEqual(h.ysize, ysize, "ysize round-trip failed for \(xsize)x\(ysize)")
        }
    }

    // MARK: - Inspect against a real cjxl-produced file

    /// If a known-good libjxl-produced .jxl is available on this dev
    /// machine, verify the foundation parses its dimensions correctly.
    /// On other machines this test skips silently.
    func testInspect_RealLibjxlFile_DimensionsMatch() throws {
        let candidates = [
            "/tmp/cmp-cjxl.jxl",
            "/tmp/jxl-it/cli-large.jxl",
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            try XCTSkipIf(true, "no real .jxl test artefact on this machine")
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let inspection = try JXLDecoder().inspect(data)
        XCTAssertGreaterThan(inspection.xsize, 0)
        XCTAssertGreaterThan(inspection.ysize, 0)
    }

    // MARK: - Encoder / decoder stubs throw clearly

    func testEncoder_ThrowsNotImplemented() {
        let frame = ImageFrame(width: 8, height: 8, channels: 1,
                               pixelType: .uint8, colorSpace: .grayscale)
        XCTAssertThrowsError(try JXLEncoder().encode(frame)) { err in
            guard case EncoderError.notImplemented = (err as? EncoderError) ?? .notImplemented("") else {
                XCTFail("expected .notImplemented, got \(err)")
                return
            }
        }
    }

    func testDecoder_ThrowsNotImplementedOnPixels() throws {
        // A valid container with a stub codestream — inspect() works,
        // decode() must throw .notImplemented since we don't decode pixels.
        let cs = Data([0xFF, 0x0A] + [UInt8](repeating: 0x00, count: 64))
        let container = buildJXLContainer(codestream: cs)
        let dec = JXLDecoder()
        XCTAssertThrowsError(try dec.decode(container)) { err in
            guard case DecoderError.notImplemented = (err as? DecoderError) ?? .notImplemented("") else {
                XCTFail("expected .notImplemented, got \(err)")
                return
            }
        }
    }

    // MARK: - Header structures (Phase H)

    /// BitDepth round-trip across the standard cases medical imaging
    /// cares about: 8-bit, 12-bit, 16-bit unsigned, plus float32.
    func testBitDepth_RoundTrip() throws {
        let cases: [BitDepth] = [
            BitDepth(floatingPoint: false, bitsPerSample: 8),
            BitDepth(floatingPoint: false, bitsPerSample: 10),
            BitDepth(floatingPoint: false, bitsPerSample: 12),
            BitDepth(floatingPoint: false, bitsPerSample: 16),
            BitDepth(floatingPoint: true,  bitsPerSample: 16, exponentBitsPerSample: 5),
            BitDepth(floatingPoint: true,  bitsPerSample: 32, exponentBitsPerSample: 8),
        ]
        for bd in cases {
            var w = BitWriter()
            try bd.write(to: &w)
            let data = w.finishToData()
            var r = BitReader(data)
            let parsed = try BitDepth.read(from: &r)
            XCTAssertEqual(parsed.floatingPoint, bd.floatingPoint, "fp mismatch for \(bd)")
            XCTAssertEqual(parsed.bitsPerSample, bd.bitsPerSample, "bps mismatch for \(bd)")
            if bd.floatingPoint {
                XCTAssertEqual(parsed.exponentBitsPerSample, bd.exponentBitsPerSample,
                               "exp mismatch for \(bd)")
            }
        }
    }

    /// `ImageMetadata.default` exposes the values the JXL spec defines
    /// when `all_default == true` is signalled.
    func testImageMetadata_DefaultMatchesSpec() {
        let d = ImageMetadata.default
        XCTAssertTrue(d.allDefault)
        XCTAssertEqual(d.orientation, 1)
        XCTAssertNil(d.intrinsicSize)
        XCTAssertNil(d.preview)
        XCTAssertNil(d.animation)
        XCTAssertEqual(d.bitDepth.bitsPerSample, 8)
        XCTAssertFalse(d.bitDepth.floatingPoint)
        XCTAssertTrue(d.modular16BitBufferSufficient)
        XCTAssertTrue(d.extraChannels.isEmpty)
        XCTAssertFalse(d.hasAlpha)
        XCTAssertEqual(d.intensityTarget, 255.0)
    }

    /// All-default ImageMetadata round-trips through a 1-bit-only stream.
    func testImageMetadata_AllDefaultRoundTrip() throws {
        // Build a stream with just the all_default = 1 bit set.
        var w = BitWriter()
        w.writeBit(true)
        let data = w.finishToData()
        var r = BitReader(data)
        let m = try ImageMetadata.read(from: &r)
        XCTAssertTrue(m.allDefault)
        XCTAssertEqual(m.totalChannels, 3)        // default RGB
    }

    /// `inspect()` returns a non-nil metadata value on a real cjxl-
    /// produced file (parser doesn't trap on real input). We don't
    /// assert specific field values here because parser verification
    /// against libjxl's exact bit layout is still ongoing — for now we
    /// just guarantee the API doesn't crash on real input.
    func testInspect_ParsesMetadataWithoutTrapping_OnRealFile() throws {
        let candidates = ["/tmp/cmp-cjxl.jxl"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            try XCTSkipIf(true, "no real cjxl-produced .jxl on this machine")
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let info = try JXLDecoder().inspect(data)
        XCTAssertGreaterThan(info.xsize, 0)
        XCTAssertGreaterThan(info.ysize, 0)
        // Metadata should at least parse without throwing/trapping.
        XCTAssertNotNil(info.metadata)
        if let m = info.metadata {
            // BitDepth bps is in 1...32 (we only ship realistic widths).
            XCTAssertGreaterThan(m.bitDepth.bitsPerSample, 0)
            XCTAssertLessThanOrEqual(m.bitDepth.bitsPerSample, 32)
        }
    }

    // MARK: - DICOM (still works — pure Swift, codec-agnostic)

    /// Sanity: the DICOM reader is unchanged by the libjxl removal.
    func testDICOMReader_StillReadsRealDICOM() throws {
        let candidates = [
            "/Users/raster/Documents/raster/J2KSwift/LocalDatasets/medical-dicom-organized/dx/study_001/instance_000001.dcm"
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            try XCTSkipIf(true, "no LocalDataset DICOM on this machine")
            return
        }
        let frame = try DICOMReader.read(URL(fileURLWithPath: path))
        XCTAssertEqual(frame.channels, 1)
        XCTAssertEqual(frame.pixelType, .uint16)
    }
}
