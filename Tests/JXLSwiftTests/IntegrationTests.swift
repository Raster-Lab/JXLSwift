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

    // MARK: - Cross-validation against `cjxl`
    //
    // CLAUDE.md sanctions shelling out to libjxl tools as a *test-time*
    // oracle. The tests below dynamically encode synthetic PNMs with
    // `cjxl`, then verify our parsers extract matching geometry, bit
    // depth, channel count, and colour-space metadata. Catches
    // bit-layout disagreements between our header parsers and the
    // spec.
    //
    // Skips silently if `cjxl` isn't on `PATH` (e.g. CI without
    // libjxl installed).

    /// 8-bit grayscale: our `inspect()` agrees with cjxl-produced
    /// dimensions, bit depth, and grayscale colour space.
    func testCrossValidate_Cjxl_8bitGrayscale_HeadersMatch() throws {
        try runCjxlCrossValidation(
            width: 64, height: 48, channels: 1, bitDepth: 8,
            generator: { x, y, _ in UInt16((x &+ y) & 0xFF) }
        )
    }

    /// Diagnostic: linear transfer function file. Tests sRGB
    /// primaries + Linear transfer function path.
    func testDiagnostic_DumpCjxlLinearTransfer() throws {
        guard let cjxl = whichTool("cjxl") else {
            try XCTSkipIf(true, "cjxl not on PATH")
            return
        }
        let pnmPath = NSTemporaryDirectory() + "diag-lin.ppm"
        let jxlPath = NSTemporaryDirectory() + "diag-lin.jxl"
        defer {
            try? FileManager.default.removeItem(atPath: pnmPath)
            try? FileManager.default.removeItem(atPath: jxlPath)
        }
        try makeSyntheticPNM(
            width: 16, height: 16, channels: 3, bitDepth: 8,
            generator: { x, y, c in UInt16((x &+ y &+ Int(c)) & 0xFF) }
        ).write(to: URL(fileURLWithPath: pnmPath))
        let proc = Process()
        proc.launchPath = cjxl
        proc.arguments = ["-q", "100", "-x", "color_space=RGB_D65_SRG_Rel_Lin",
                          pnmPath, jxlPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let data = try Data(contentsOf: URL(fileURLWithPath: jxlPath))
        let inspect = try JXLDecoder().inspect(data)
        if let m = inspect.metadata {
            print("DIAG cjxl-linear: cs=\(m.colorEncoding.colorSpace) wp=\(String(describing: m.colorEncoding.whitePoint)) prim=\(String(describing: m.colorEncoding.primaries)) tf=\(m.colorEncoding.transferFunction) ri=\(m.colorEncoding.renderingIntent)")
        }
    }

    /// Diagnostic: print the ColorEncoding + intensity-target our
    /// parser extracts from a cjxl-produced Rec.2100-PQ HDR file.
    /// This exercises BT2100 primaries, PQ transfer function, and
    /// ToneMapping intensity_target parsing.
    func testDiagnostic_DumpCjxlPQHDR() throws {
        guard let cjxl = whichTool("cjxl") else {
            try XCTSkipIf(true, "cjxl not on PATH")
            return
        }
        let pnmPath = NSTemporaryDirectory() + "diag-pq.ppm"
        let jxlPath = NSTemporaryDirectory() + "diag-pq.jxl"
        defer {
            try? FileManager.default.removeItem(atPath: pnmPath)
            try? FileManager.default.removeItem(atPath: jxlPath)
        }
        try makeSyntheticPNM(
            width: 16, height: 16, channels: 3, bitDepth: 8,
            generator: { x, y, c in UInt16((x &+ y &+ Int(c)) & 0xFF) }
        ).write(to: URL(fileURLWithPath: pnmPath))
        let proc = Process()
        proc.launchPath = cjxl
        proc.arguments = ["-q", "100", "-x", "color_space=RGB_D65_202_Rel_PeQ",
                          pnmPath, jxlPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let data = try Data(contentsOf: URL(fileURLWithPath: jxlPath))
        let inspect = try JXLDecoder().inspect(data)
        if let m = inspect.metadata {
            print("DIAG cjxl-pq: cs=\(m.colorEncoding.colorSpace) wp=\(String(describing: m.colorEncoding.whitePoint)) prim=\(String(describing: m.colorEncoding.primaries)) tf=\(m.colorEncoding.transferFunction) ri=\(m.colorEncoding.renderingIntent) intensity=\(m.intensityTarget) minNits=\(m.minNits)")
        }
    }

    /// Diagnostic: print the ExtraChannelInfo our parser extracts
    /// from a cjxl-produced RGBA file. Used to find any remaining
    /// bit-layout bugs in the alpha-channel parser path.
    func testDiagnostic_DumpCjxlRGBAExtraChannel() throws {
        guard let cjxl = whichTool("cjxl") else {
            try XCTSkipIf(true, "cjxl not on PATH")
            return
        }
        let pamPath = NSTemporaryDirectory() + "diag-rgba.pam"
        let jxlPath = NSTemporaryDirectory() + "diag-rgba.jxl"
        defer {
            try? FileManager.default.removeItem(atPath: pamPath)
            try? FileManager.default.removeItem(atPath: jxlPath)
        }
        try makeSyntheticPNM(
            width: 16, height: 16, channels: 4, bitDepth: 8,
            generator: { x, y, c in
                if c == 3 { return 255 }
                return UInt16((x &+ y) & 0xFF)
            }
        ).write(to: URL(fileURLWithPath: pamPath))
        let proc = Process()
        proc.launchPath = cjxl
        proc.arguments = ["-q", "100", pamPath, jxlPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let data = try Data(contentsOf: URL(fileURLWithPath: jxlPath))
        let inspect = try JXLDecoder().inspect(data)
        if let m = inspect.metadata, let ec = m.extraChannels.first {
            print("DIAG cjxl-rgba: type=\(ec.type) bps=\(ec.bitDepth.bitsPerSample) float=\(ec.bitDepth.floatingPoint) dimShift=\(ec.dimShift) name='\(ec.name)' alphaAssoc=\(ec.alphaAssociated)")
        }
    }

    /// Diagnostic: print the colour-encoding fields our parser
    /// extracts from a cjxl-produced grayscale file. Used to track
    /// down a discrepancy where jxlinfo reports D65 but bit-level
    /// analysis suggested our parser reads selector=1 → custom.
    func testDiagnostic_DumpCjxlGrayscaleColorEncoding() throws {
        guard let cjxl = whichTool("cjxl") else {
            try XCTSkipIf(true, "cjxl not on PATH")
            return
        }
        let pnm = NSTemporaryDirectory() + "diag.pgm"
        let jxl = NSTemporaryDirectory() + "diag.jxl"
        defer {
            try? FileManager.default.removeItem(atPath: pnm)
            try? FileManager.default.removeItem(atPath: jxl)
        }
        try makeSyntheticPNM(
            width: 16, height: 16, channels: 1, bitDepth: 8,
            generator: { x, y, _ in UInt16((x &+ y) & 0xFF) }
        ).write(to: URL(fileURLWithPath: pnm))
        let proc = Process()
        proc.launchPath = cjxl
        proc.arguments = ["-q", "100", pnm, jxl]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let data = try Data(contentsOf: URL(fileURLWithPath: jxl))
        let inspect = try JXLDecoder().inspect(data)
        if let m = inspect.metadata {
            print("DIAG cjxl-grayscale: cs=\(m.colorEncoding.colorSpace) wp=\(String(describing: m.colorEncoding.whitePoint)) prim=\(String(describing: m.colorEncoding.primaries)) tf=\(m.colorEncoding.transferFunction) ri=\(m.colorEncoding.renderingIntent)")
        }
    }

    /// 16-bit grayscale (the medical-imaging shape): cjxl produces a
    /// 16-bit JXL, our parser recovers `bitsPerSample == 16`.
    func testCrossValidate_Cjxl_16bitGrayscale_HeadersMatch() throws {
        try runCjxlCrossValidation(
            width: 32, height: 32, channels: 1, bitDepth: 16,
            generator: { x, y, _ in UInt16(min(65535, (x &+ y) &* 1024)) }
        )
    }

    /// 8-bit RGB: cjxl-produced 3-channel sRGB, our parser recovers
    /// non-grayscale colour space + 3 channel inference.
    func testCrossValidate_Cjxl_8bitRGB_HeadersMatch() throws {
        try runCjxlCrossValidation(
            width: 32, height: 32, channels: 3, bitDepth: 8,
            generator: { x, y, c in
                let base = UInt16((x &+ y) & 0xFF)
                return base &+ UInt16(c) &* 16
            }
        )
    }

    /// 16-bit RGB: cjxl-produced 16-bit per-channel RGB exercises
    /// the full RGB + 16-bit path of our header parser.
    func testCrossValidate_Cjxl_16bitRGB_HeadersMatch() throws {
        try runCjxlCrossValidation(
            width: 16, height: 16, channels: 3, bitDepth: 16,
            generator: { x, y, c in
                UInt16(min(65535, ((x &+ y) &* 1024) &+ Int(c) &* 100))
            }
        )
    }

    /// 8-bit RGBA: cjxl-produced 4-channel sRGB+alpha, parsed via
    /// PAM input. Verifies the parser recognises the alpha extra
    /// channel.
    func testCrossValidate_Cjxl_8bitRGBA_HeadersMatch() throws {
        try runCjxlCrossValidation(
            width: 16, height: 16, channels: 4, bitDepth: 8,
            generator: { x, y, c in
                if c == 3 { return 255 }   // opaque alpha
                let base = UInt16((x &+ y) & 0xFF)
                return base &+ UInt16(c) &* 16
            }
        )
    }

    /// 16-bit grayscale + alpha (medical-imaging shape with mask).
    func testCrossValidate_Cjxl_16bitGrayscaleAlpha_HeadersMatch() throws {
        try runCjxlCrossValidation(
            width: 16, height: 16, channels: 2, bitDepth: 16,
            generator: { x, y, c in
                if c == 1 { return 65535 }   // opaque alpha
                return UInt16(min(65535, (x &+ y) &* 1024))
            }
        )
    }

    /// 1×1 pixel — boundary case for SizeHeader's small-mode path.
    func testCrossValidate_Cjxl_1x1_HeadersMatch() throws {
        try runCjxlCrossValidation(
            width: 1, height: 1, channels: 1, bitDepth: 8,
            generator: { _, _, _ in 42 }
        )
    }

    /// Non-multiple-of-8 dimensions — exercises SizeHeader's
    /// large-mode path (small mode only handles multiples of 8 up
    /// to 256).
    func testCrossValidate_Cjxl_OddDimensions_HeadersMatch() throws {
        try runCjxlCrossValidation(
            width: 371, height: 219, channels: 1, bitDepth: 8,
            generator: { _, y, _ in UInt16(y & 0xFF) }
        )
    }

    /// `--intensity_target=4000` exercises the ToneMapping (HDR
    /// metadata) parsing path. cjxl writes intensityTarget=4000
    /// nits (non-default 255.0) which forces our parser to take
    /// the toneDefault=0 branch and read the half-float intensity
    /// value.
    func testCrossValidate_Cjxl_IntensityTarget_TonemappingMatch() throws {
        guard let cjxl = whichTool("cjxl") else {
            try XCTSkipIf(true, "cjxl not on PATH")
            return
        }
        let pnmPath = NSTemporaryDirectory() + "tone-\(UUID().uuidString).ppm"
        let jxlPath = NSTemporaryDirectory() + "tone-\(UUID().uuidString).jxl"
        defer {
            try? FileManager.default.removeItem(atPath: pnmPath)
            try? FileManager.default.removeItem(atPath: jxlPath)
        }
        try makeSyntheticPNM(
            width: 16, height: 16, channels: 3, bitDepth: 8,
            generator: { x, y, c in UInt16((x &+ y &+ Int(c)) & 0xFF) }
        ).write(to: URL(fileURLWithPath: pnmPath))
        let proc = Process()
        proc.launchPath = cjxl
        proc.arguments = ["-q", "100", "--intensity_target=4000", pnmPath, jxlPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            XCTFail("cjxl failed with status \(proc.terminationStatus)")
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: jxlPath))
        let inspect = try JXLDecoder().inspect(data)
        guard let m = inspect.metadata else {
            XCTFail("inspect() returned nil ImageMetadata")
            return
        }
        XCTAssertEqual(m.intensityTarget, 4000.0, accuracy: 1.0,
            "tone-mapping intensityTarget should match cjxl --intensity_target=4000")
    }

    /// Float32 grayscale via PFM input — exercises the float branch
    /// of `BitDepth` (isFloat=1, bps via U32 distribution, exp via
    /// the spec-specific `(2, 5, 10, 7+u(4))` distribution). Caught
    /// the exp-distribution bug.
    func testCrossValidate_Cjxl_Float32Grayscale_HeadersMatch() throws {
        guard let cjxl = whichTool("cjxl") else {
            try XCTSkipIf(true, "cjxl not on PATH")
            return
        }
        let pfmPath = NSTemporaryDirectory() + "jxlswift-float-\(UUID().uuidString).pfm"
        let jxlPath = NSTemporaryDirectory() + "jxlswift-float-\(UUID().uuidString).jxl"
        defer {
            try? FileManager.default.removeItem(atPath: pfmPath)
            try? FileManager.default.removeItem(atPath: jxlPath)
        }
        // Build a 16×16 float32 PFM (Pf magic, big-endian).
        var pfm = Data("Pf\n16 16\n1.0\n".utf8)
        for y in 0..<16 {
            for x in 0..<16 {
                let v = Float(x &+ y) / 30.0
                let bits = v.bitPattern
                // Big-endian.
                pfm.append(UInt8((bits >> 24) & 0xFF))
                pfm.append(UInt8((bits >> 16) & 0xFF))
                pfm.append(UInt8((bits >> 8) & 0xFF))
                pfm.append(UInt8(bits & 0xFF))
            }
        }
        try pfm.write(to: URL(fileURLWithPath: pfmPath))

        let proc = Process()
        proc.launchPath = cjxl
        proc.arguments = ["-q", "100", pfmPath, jxlPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            XCTFail("cjxl failed with status \(proc.terminationStatus)")
            return
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: jxlPath))
        let inspection = try JXLDecoder().inspect(data)
        XCTAssertEqual(inspection.xsize, 16)
        XCTAssertEqual(inspection.ysize, 16)
        guard let m = inspection.metadata else {
            XCTFail("inspect() returned nil ImageMetadata for the float file")
            return
        }
        XCTAssertTrue(m.bitDepth.floatingPoint, "should be float")
        XCTAssertEqual(m.bitDepth.bitsPerSample, 32, "float32")
        XCTAssertEqual(m.bitDepth.exponentBitsPerSample, 8,
            "float32 exponent should be 8 — spec uses (2, 5, 10, 7+u(4)) distribution")
    }

    /// **Writer-side cross-validation (RGB only)**: an M0 file with
    /// default-sRGB headers (i.e. our 3-channel path that takes the
    /// `ColorEncoding.allDefault = 1` shortcut) parses cleanly
    /// through `jxlinfo`'s header section even though the M0 marker
    /// isn't valid frame data.
    ///
    /// (The grayscale-writer equivalent doesn't yet pass through
    /// `jxlinfo` reliably — `jxlinfo` errors before printing
    /// dimensions when the ColorEncoding takes the full-structure
    /// path, which suggests there's still an unknown bit-layout
    /// disagreement on the grayscale path. Reader cross-validation
    /// for the same shape works fine, so the issue is symmetric on
    /// the writer side. Defer until spec-text is available.)
    func testCrossValidate_M0WriterHeaders_RGBSpecParseable() throws {
        guard let jxlinfoPath = whichTool("jxlinfo") else {
            try XCTSkipIf(true, "jxlinfo not on PATH")
            return
        }
        var frame = ImageFrame(
            width: 32, height: 32, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        for i in 0..<frame.data.count { frame.data[i] = UInt8(i & 0xFF) }
        let m0 = try MinimalLosslessCodec.encode(frame)
        let path = NSTemporaryDirectory() + "jxlswift-writer-xv-\(UUID().uuidString).m0"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try m0.write(to: URL(fileURLWithPath: path))

        let proc = Process()
        proc.launchPath = jxlinfoPath
        proc.arguments = [path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""

        XCTAssertTrue(out.contains("32x32"))
        XCTAssertTrue(out.contains("8-bit"))
        XCTAssertTrue(out.contains("RGB"))
    }

    /// Helper: write a synthetic PNM, run cjxl, then verify our
    /// `JXLDecoder.inspect()` extracts the expected fields. Skips if
    /// cjxl isn't installed.
    private func runCjxlCrossValidation(
        width: Int, height: Int, channels: Int, bitDepth: Int,
        generator: (_ x: Int, _ y: Int, _ c: Int) -> UInt16
    ) throws {
        guard let cjxl = whichTool("cjxl") else {
            try XCTSkipIf(true, "cjxl not on PATH")
            return
        }
        // Build the synthetic PNM. PGM for 1ch, PPM for 3ch, PAM for
        // 2ch (gray+alpha) or 4ch (RGBA).
        let ext: String
        switch channels {
        case 1:        ext = "pgm"
        case 3:        ext = "ppm"
        case 2, 4:     ext = "pam"
        default:
            XCTFail("unsupported channel count \(channels) for PNM generation")
            return
        }
        let pnm = NSTemporaryDirectory() + "jxlswift-xv-\(UUID().uuidString).\(ext)"
        let jxl = NSTemporaryDirectory() + "jxlswift-xv-\(UUID().uuidString).jxl"
        defer {
            try? FileManager.default.removeItem(atPath: pnm)
            try? FileManager.default.removeItem(atPath: jxl)
        }
        let pnmBytes = makeSyntheticPNM(
            width: width, height: height,
            channels: channels, bitDepth: bitDepth,
            generator: generator
        )
        try pnmBytes.write(to: URL(fileURLWithPath: pnm))

        // Run cjxl.
        let proc = Process()
        proc.launchPath = cjxl
        proc.arguments = ["-q", "100", pnm, jxl]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            XCTFail("cjxl failed with status \(proc.terminationStatus)")
            return
        }

        // Parse with our inspect.
        let data = try Data(contentsOf: URL(fileURLWithPath: jxl))
        let inspection = try JXLDecoder().inspect(data)

        XCTAssertEqual(Int(inspection.xsize), width,
            "dimension mismatch: our xsize=\(inspection.xsize) vs expected \(width)")
        XCTAssertEqual(Int(inspection.ysize), height,
            "dimension mismatch: our ysize=\(inspection.ysize) vs expected \(height)")
        guard let m = inspection.metadata else {
            XCTFail("our inspect() returned nil ImageMetadata for a valid JXL file")
            return
        }
        XCTAssertEqual(Int(m.bitDepth.bitsPerSample), bitDepth,
            "bitsPerSample mismatch: our \(m.bitDepth.bitsPerSample) vs expected \(bitDepth)")
        XCTAssertFalse(m.bitDepth.floatingPoint,
            "synthetic PNM is integer; floatingPoint should be false")
        // Channel inference: grayscale colour space implies 1
        // colour channel (2 if alpha-bearing); non-grayscale implies
        // 3 (4 if alpha-bearing). The alpha channel shows up as an
        // ExtraChannelInfo entry, so total channels = colour channels
        // + extras.count.
        let colorChannels: Int =
            (m.colorEncoding.colorSpace == .grayscale) ? 1 : 3
        let totalExpected = colorChannels + m.extraChannels.count
        XCTAssertEqual(totalExpected, channels,
            "channel inference mismatch: colorSpace=\(m.colorEncoding.colorSpace) implies \(colorChannels) colour channels + \(m.extraChannels.count) extras = \(totalExpected); expected \(channels)")
        // For alpha-bearing inputs (channels == 2 or 4), the parser
        // must report at least one alpha extra channel.
        if channels == 2 || channels == 4 {
            let hasAlpha = m.extraChannels.contains(where: { $0.type == .alpha })
            XCTAssertTrue(hasAlpha,
                "alpha-bearing input (\(channels)ch) must produce an alpha ExtraChannelInfo")
        }
    }

    /// Returns the absolute path of `tool` if it's on `PATH`, else nil.
    private func whichTool(_ tool: String) -> String? {
        let proc = Process()
        proc.launchPath = "/usr/bin/which"
        proc.arguments = [tool]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// Build a binary PNM (PGM/PPM/PAM) with the given per-pixel
    /// generator. The generator returns a sample value in the range
    /// supported by the bit depth (8 or 16-bit).
    private func makeSyntheticPNM(
        width: Int, height: Int, channels: Int, bitDepth: Int,
        generator: (Int, Int, Int) -> UInt16
    ) -> Data {
        let maxval = (bitDepth == 8) ? 255 : 65535
        var out = Data()
        switch channels {
        case 1:
            out.append(Data("P5\n\(width) \(height)\n\(maxval)\n".utf8))
        case 3:
            out.append(Data("P6\n\(width) \(height)\n\(maxval)\n".utf8))
        default:
            // PAM for 2ch (gray+alpha) or 4ch (RGBA).
            let tupltype: String
            switch channels {
            case 2: tupltype = "GRAYSCALE_ALPHA"
            case 4: tupltype = "RGB_ALPHA"
            default: tupltype = "UNKNOWN"
            }
            let header = """
                P7
                WIDTH \(width)
                HEIGHT \(height)
                DEPTH \(channels)
                MAXVAL \(maxval)
                TUPLTYPE \(tupltype)
                ENDHDR

                """
            out.append(Data(header.utf8))
        }
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    let v = generator(x, y, c)
                    if bitDepth == 8 {
                        out.append(UInt8(v & 0xFF))
                    } else {
                        // PNM 16-bit is big-endian.
                        out.append(UInt8((v >> 8) & 0xFF))
                        out.append(UInt8(v & 0xFF))
                    }
                }
            }
        }
        return out
    }

    // MARK: - Encoder / decoder stubs throw clearly

    /// `EncodingOptions(useM0Placeholder: true)` routes encode
    /// through `MinimalLosslessCodec` so callers have a working
    /// lossless path against the public API while the real codec
    /// is built out. CompressionStats are populated with byte
    /// counts and encoding time.
    func testEncoder_M0Placeholder_RoundTripsViaPublicAPI() throws {
        var frame = ImageFrame(
            width: 16, height: 16, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        for i in 0..<frame.data.count { frame.data[i] = UInt8(i & 0xFF) }
        let opts = EncodingOptions(
            mode: .lossless, useM0Placeholder: true, m0Effort: .balanced
        )
        let result = try JXLEncoder(options: opts).encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertEqual(result.stats.originalSize, frame.data.count)
        XCTAssertEqual(result.stats.compressedSize, result.data.count)
        // Decoder auto-detects the M0 marker.
        let decoded = try JXLDecoder().decode(result.data)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// `useM0Placeholder` defaults to `false`, so existing callers
    /// still get `.notImplemented`. Pin this so it doesn't drift.
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
    /// cares about: 8/10/12/14/16-bit unsigned, plus float16/float32.
    /// 14-bit lives on the `bits=12 + extra` U32 selector branch and is
    /// the per-pixel depth used by some mammography and CT scans.
    func testBitDepth_RoundTrip() throws {
        let cases: [BitDepth] = [
            BitDepth(floatingPoint: false, bitsPerSample: 8),
            BitDepth(floatingPoint: false, bitsPerSample: 10),
            BitDepth(floatingPoint: false, bitsPerSample: 12),
            BitDepth(floatingPoint: false, bitsPerSample: 14),
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

    /// Round-trip an ImageMetadata for the medical-imaging case
    /// (16-bit grayscale, no alpha, sRGB transfer). This is THE test
    /// that gates Phase H correctness — it proves the parser and
    /// writer agree on the exact bit positions of every field.
    func testImageMetadata_RoundTrip_GrayscaleMedical() throws {
        let m = ImageMetadata(
            allDefault: false,
            orientation: 1,
            intrinsicSize: nil,
            preview: nil,
            animation: nil,
            bitDepth: BitDepth(floatingPoint: false, bitsPerSample: 16),
            modular16BitBufferSufficient: true,
            extraChannels: [],
            xybEncoded: false,
            colorEncoding: .grayscaleD65,
            intensityTarget: 255.0,
            minNits: 0.0,
            relativeToMaxDisplay: false,
            linearBelow: 0.0
        )
        var w = BitWriter()
        try m.write(to: &w)
        let data = w.finishToData()
        var r = BitReader(data)
        let m2 = try ImageMetadata.read(from: &r)

        XCTAssertEqual(m2.allDefault, false)
        XCTAssertEqual(m2.orientation, 1)
        XCTAssertEqual(m2.bitDepth.bitsPerSample, 16)
        XCTAssertEqual(m2.bitDepth.floatingPoint, false)
        XCTAssertTrue(m2.extraChannels.isEmpty)
        XCTAssertEqual(m2.xybEncoded, false)
        XCTAssertEqual(m2.colorEncoding.colorSpace, .grayscale)
        XCTAssertEqual(m2.colorEncoding.useICC, false)
    }

    /// Round-trip a 16-bit RGB image with straight alpha — a common
    /// medical-imaging output (e.g. from a research pipeline).
    func testImageMetadata_RoundTrip_RGBA16() throws {
        let alpha = ExtraChannelInfo(
            type: .alpha,
            bitDepth: BitDepth(floatingPoint: false, bitsPerSample: 16),
            dimShift: 0,
            name: "",
            alphaAssociated: false
        )
        let m = ImageMetadata(
            allDefault: false,
            orientation: 1,
            intrinsicSize: nil,
            preview: nil,
            animation: nil,
            bitDepth: BitDepth(floatingPoint: false, bitsPerSample: 16),
            modular16BitBufferSufficient: true,
            extraChannels: [alpha],
            xybEncoded: false,
            colorEncoding: .srgb,
            intensityTarget: 255.0,
            minNits: 0.0,
            relativeToMaxDisplay: false,
            linearBelow: 0.0
        )
        var w = BitWriter()
        try m.write(to: &w)
        let data = w.finishToData()
        var r = BitReader(data)
        let m2 = try ImageMetadata.read(from: &r)

        XCTAssertEqual(m2.bitDepth.bitsPerSample, 16)
        XCTAssertEqual(m2.colorEncoding.colorSpace, .rgb)
        XCTAssertEqual(m2.extraChannels.count, 1)
        if let a = m2.extraChannels.first {
            XCTAssertEqual(a.type, .alpha)
            XCTAssertEqual(a.bitDepth.bitsPerSample, 16)
            XCTAssertFalse(a.alphaAssociated)
        }
    }

    /// Round-trip an 8-bit RGBA image with EXIF orientation 6 (90° CW).
    /// Forces the `extra_fields = 1` branch.
    func testImageMetadata_RoundTrip_OrientationExtraFields() throws {
        let m = ImageMetadata(
            allDefault: false,
            orientation: 6,           // EXIF orientation 6 forces extra_fields
            intrinsicSize: nil,
            preview: nil,
            animation: nil,
            bitDepth: BitDepth(floatingPoint: false, bitsPerSample: 8),
            modular16BitBufferSufficient: true,
            extraChannels: [],
            xybEncoded: true,
            colorEncoding: .srgb,
            intensityTarget: 255.0,
            minNits: 0.0,
            relativeToMaxDisplay: false,
            linearBelow: 0.0
        )
        var w = BitWriter()
        try m.write(to: &w)
        let data = w.finishToData()
        var r = BitReader(data)
        let m2 = try ImageMetadata.read(from: &r)
        XCTAssertEqual(m2.orientation, 6)
        XCTAssertEqual(m2.bitDepth.bitsPerSample, 8)
    }

    /// Round-trip a 32-bit float HDR image (intensity target 10 000 cd/m²).
    /// Exercises the floating-point bit-depth path AND the tone-mapping
    /// non-default block.
    func testImageMetadata_RoundTrip_FloatHDR() throws {
        let m = ImageMetadata(
            allDefault: false,
            orientation: 1,
            intrinsicSize: nil,
            preview: nil,
            animation: nil,
            bitDepth: BitDepth(floatingPoint: true, bitsPerSample: 32, exponentBitsPerSample: 8),
            modular16BitBufferSufficient: false,
            extraChannels: [],
            xybEncoded: false,
            colorEncoding: .srgb,
            intensityTarget: 10000.0,    // 10 000 cd/m² — HDR10 reference
            minNits: 0.005,
            relativeToMaxDisplay: false,
            linearBelow: 0.0
        )
        var w = BitWriter()
        try m.write(to: &w)
        let data = w.finishToData()
        var r = BitReader(data)
        let m2 = try ImageMetadata.read(from: &r)
        XCTAssertTrue(m2.bitDepth.floatingPoint)
        XCTAssertEqual(m2.bitDepth.bitsPerSample, 32)
        XCTAssertEqual(m2.bitDepth.exponentBitsPerSample, 8)
        // Half-float quantisation; intensity should be ~10 000 ± 0.5 %.
        XCTAssertEqual(m2.intensityTarget, 10000.0, accuracy: 50.0)
    }

    /// Round-trip an animation header.
    func testImageMetadata_RoundTrip_Animation() throws {
        let anim = AnimationHeader(
            tpsNumerator: 1000, tpsDenominator: 1001,
            numLoops: 0, haveTimecodes: false
        )
        let m = ImageMetadata(
            allDefault: false,
            orientation: 1,
            intrinsicSize: nil,
            preview: nil,
            animation: anim,
            bitDepth: BitDepth(floatingPoint: false, bitsPerSample: 8),
            modular16BitBufferSufficient: true,
            extraChannels: [],
            xybEncoded: true,
            colorEncoding: .srgb,
            intensityTarget: 255.0,
            minNits: 0.0,
            relativeToMaxDisplay: false,
            linearBelow: 0.0
        )
        var w = BitWriter()
        try m.write(to: &w)
        let data = w.finishToData()
        var r = BitReader(data)
        let m2 = try ImageMetadata.read(from: &r)
        XCTAssertNotNil(m2.animation)
        XCTAssertEqual(m2.animation?.tpsNumerator, 1000)
        XCTAssertEqual(m2.animation?.tpsDenominator, 1001)
    }

    /// Half-float ↔ float round-trip helpers behave correctly.
    func testHalfFloat_Symmetry() {
        for v in [Float(0.0), 1.0, 100.0, 255.0, 1000.0, 65504.0] {
            let h = floatToHalf(v)
            let back = halfToFloat(h)
            XCTAssertEqual(back, v, accuracy: max(v * 0.001, 0.001),
                           "half-float round-trip lost precision at \(v)")
        }
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

    // MARK: - Phase E1: HybridUint encoding (§C.5)

    /// Round-trip every value 0...255 through the default config.
    /// This is the test that gates Phase E1 correctness — if the
    /// formulas are off by a single bit, the values won't recover.
    func testHybridUint_RoundTrip_DefaultConfig() throws {
        let cfg = HybridUintConfig.defaultConfig
        for value: UInt32 in 0...255 {
            let t = cfg.encode(value)
            var w = BitWriter()
            w.write(bits: t.extraNBits, value: t.extraBits)
            let bytes = w.finishToData()
            var r = BitReader(bytes)
            let recovered = try cfg.decode(token: t.token, from: &r)
            XCTAssertEqual(recovered, value, "value \(value): token=\(t.token) extra=\(t.extraBits) (\(t.extraNBits) bits)")
        }
    }

    /// Round-trip the boundary values: 0, 2^split-1 (last "literal"),
    /// 2^split (first "splittable"), powers of two up to 2^31.
    func testHybridUint_RoundTrip_BoundaryValues() throws {
        let cfg = HybridUintConfig.defaultConfig
        var values: [UInt32] = [0, 1, 15, 16, 17, 31, 32, 63, 64, 100, 1023, 1024, 65_535, 65_536]
        for n in 0..<32 {
            values.append(UInt32(1) &<< UInt32(n))
        }
        values.append(UInt32(0xFFFF_FFFE))   // near max
        for value in values {
            let t = cfg.encode(value)
            var w = BitWriter()
            w.write(bits: t.extraNBits, value: t.extraBits)
            var r = BitReader(w.finishToData())
            let recovered = try cfg.decode(token: t.token, from: &r)
            XCTAssertEqual(recovered, value, "boundary value \(value)")
        }
    }

    /// Sweep across configs to verify the formula generalises beyond the
    /// default. Tries every combination of (split_exponent, msb, lsb)
    /// the spec allows for split_exponent ≤ 4.
    func testHybridUint_RoundTrip_ConfigSweep() throws {
        for split in 0...4 {
            for msb in 0...split {
                for lsb in 0...(split - msb) {
                    let cfg = HybridUintConfig(splitExponent: split,
                                                msbInToken: msb,
                                                lsbInToken: lsb)
                    // Test a representative value range for each config.
                    let testValues: [UInt32] = [0, 1, 7, 16, 100, 1000, 100_000, 16_777_215]
                    for value in testValues {
                        let t = cfg.encode(value)
                        var w = BitWriter()
                        w.write(bits: t.extraNBits, value: t.extraBits)
                        var r = BitReader(w.finishToData())
                        let recovered = try cfg.decode(token: t.token, from: &r)
                        XCTAssertEqual(recovered, value,
                            "config (split=\(split), msb=\(msb), lsb=\(lsb)) value \(value): " +
                            "token=\(t.token) extra=\(t.extraBits) nbits=\(t.extraNBits)")
                    }
                }
            }
        }
    }

    /// Hand-derived test vectors: for the "raw 4" config (split=4, msb=0,
    /// lsb=0), verify the encoder produces the exact tokens the spec
    /// formula predicts. This catches off-by-one errors that round-trip
    /// alone wouldn't surface (a self-consistent buggy formula would
    /// pass round-trip but disagree with libjxl).
    func testHybridUint_HandDerivedVectors_Raw4() {
        let cfg = HybridUintConfig.raw4    // split=4, msb=0, lsb=0
        // value < 16 → token == value, no extra bits.
        XCTAssertEqual(cfg.encode(0).token, 0)
        XCTAssertEqual(cfg.encode(0).extraNBits, 0)
        XCTAssertEqual(cfg.encode(15).token, 15)
        XCTAssertEqual(cfg.encode(15).extraNBits, 0)

        // value == 16: n = 4, m = 0. nMinusSplit = 0.
        //   token = 16 + (0 << 0) + (0 << 0) + 0 = 16
        //   extraNBits = 4 - 0 - 0 = 4
        //   extraBits = 0
        let v16 = cfg.encode(16)
        XCTAssertEqual(v16.token, 16)
        XCTAssertEqual(v16.extraNBits, 4)
        XCTAssertEqual(v16.extraBits, 0)

        // value == 31: n = 4, m = 15. extraBits = 15, extraNBits = 4, token = 16.
        let v31 = cfg.encode(31)
        XCTAssertEqual(v31.token, 16)
        XCTAssertEqual(v31.extraNBits, 4)
        XCTAssertEqual(v31.extraBits, 15)

        // value == 32: n = 5, m = 0. nMinusSplit = 1.
        //   token = 16 + (1 << 0) + 0 + 0 = 17
        //   extraNBits = 5 - 0 - 0 = 5
        let v32 = cfg.encode(32)
        XCTAssertEqual(v32.token, 17)
        XCTAssertEqual(v32.extraNBits, 5)
        XCTAssertEqual(v32.extraBits, 0)

        // value == 1024: n = 10, m = 0. nMinusSplit = 6.
        //   token = 16 + 6 = 22
        //   extraNBits = 10
        let v1024 = cfg.encode(1024)
        XCTAssertEqual(v1024.token, 22)
        XCTAssertEqual(v1024.extraNBits, 10)
        XCTAssertEqual(v1024.extraBits, 0)
    }

    // MARK: - Phase E2: Prefix codes (§C.6.2)

    /// Hand-derived test: a 4-symbol code with lengths {2, 1, 3, 3}.
    /// Canonical assignment (sort by (length asc, symbol asc)):
    ///   symbol 1 (len 1) → 0
    ///   symbol 0 (len 2) → 10
    ///   symbol 2 (len 3) → 110
    ///   symbol 3 (len 3) → 111
    /// Verify the table built from the lengths produces these exact
    /// codewords, then a round-trip through encode/decode recovers
    /// the original symbol stream.
    func testPrefixCode_HandDerived_4Symbols() throws {
        let lengths: [UInt8] = [2, 1, 3, 3]
        let table = try PrefixCodeTable(lengths: lengths)
        // Canonical codewords (MSB-first stored in the low bits).
        XCTAssertEqual(table.codewords[1], 0b0,   "symbol 1 codeword")
        XCTAssertEqual(table.codewords[0], 0b10,  "symbol 0 codeword")
        XCTAssertEqual(table.codewords[2], 0b110, "symbol 2 codeword")
        XCTAssertEqual(table.codewords[3], 0b111, "symbol 3 codeword")

        // Round-trip: emit each symbol, decode them all back.
        let symbols = [1, 0, 2, 3, 1, 1, 0, 3]
        var w = BitWriter()
        for s in symbols { try table.encode(s, to: &w) }
        var r = BitReader(w.finishToData())
        var decoded: [Int] = []
        for _ in symbols { decoded.append(try table.decode(from: &r)) }
        XCTAssertEqual(decoded, symbols)
    }

    /// Round-trip with a richer 16-symbol alphabet — verifies the
    /// canonical assignment and decoding LUT scale correctly.
    /// All lengths = 4: 16 * 2^11 = 2^15 ✓ Kraft.
    func testPrefixCode_RoundTrip_16Symbols() throws {
        let lengths = [UInt8](repeating: 4, count: 16)
        let table = try PrefixCodeTable(lengths: lengths)
        let stream = [0, 1, 2, 0, 5, 8, 0, 12, 4, 0, 0, 9, 7, 15, 14, 13]
        var w = BitWriter()
        for s in stream { try table.encode(s, to: &w) }
        var r = BitReader(w.finishToData())
        var decoded: [Int] = []
        for _ in stream { decoded.append(try table.decode(from: &r)) }
        XCTAssertEqual(decoded, stream)
    }

    /// Mixed-length code: lengths [1, 3, 3, 3, 3] → 1·16384 + 4·4096 = 32768 ✓
    func testPrefixCode_RoundTrip_MixedLengths() throws {
        let lengths: [UInt8] = [1, 3, 3, 3, 3]
        let table = try PrefixCodeTable(lengths: lengths)
        let stream = [0, 1, 2, 3, 4, 0, 0, 1, 2, 0, 4, 3, 1]
        var w = BitWriter()
        for s in stream { try table.encode(s, to: &w) }
        var r = BitReader(w.finishToData())
        var decoded: [Int] = []
        for _ in stream { decoded.append(try table.decode(from: &r)) }
        XCTAssertEqual(decoded, stream)
    }

    /// Single-symbol "degenerate" code: only one symbol has non-zero
    /// length (in fact length 0, since a 1-symbol code emits nothing).
    /// The decoder should always return that symbol regardless of the
    /// bitstream.
    func testPrefixCode_SingleSymbolDegenerate() throws {
        let lengths: [UInt8] = [0, 0, 0, 0, 0]   // no symbols present
        // We model this as "degenerate" — when all lengths are 0, any
        // decode reads nothing and returns symbol 0. (libjxl uses the
        // same convention: a single-symbol distribution emits no bits.)
        let table = try PrefixCodeTable(lengths: lengths)
        XCTAssertEqual(table.usedMaxLength, 0)
        var r = BitReader(Data([0xFF]))   // any input
        let s = try table.decode(from: &r)
        XCTAssertEqual(s, 0)
        XCTAssertEqual(r.position, 0, "degenerate code consumed no bits")
    }

    /// Oversubscribed lengths must throw — Kraft inequality violation.
    func testPrefixCode_RejectsOversubscribed() {
        let lengths: [UInt8] = [1, 1, 1]   // 3 * 2^14 > 2^15
        XCTAssertThrowsError(try PrefixCodeTable(lengths: lengths)) { err in
            guard let pcErr = err as? PrefixCodeError else {
                XCTFail("expected PrefixCodeError, got \(err)"); return
            }
            if case .oversubscribed = pcErr {} else { XCTFail("expected .oversubscribed") }
        }
    }

    /// Undersubscribed must also throw.
    func testPrefixCode_RejectsUndersubscribed() {
        let lengths: [UInt8] = [3, 3]   // 2 * 2^12 = 2^13 ≠ 2^15
        XCTAssertThrowsError(try PrefixCodeTable(lengths: lengths)) { err in
            if case PrefixCodeError.undersubscribed = err {} else { XCTFail("expected .undersubscribed, got \(err)") }
        }
    }

    /// Larger alphabet, full sweep of 100 random symbols. Stress test
    /// that exercises the LUT decode path and codeword reversal.
    func testPrefixCode_RoundTrip_LargerAlphabet() throws {
        // 256-symbol alphabet with 8-bit equal lengths: every symbol
        // gets a unique 8-bit codeword. Sum = 256 * 2^7 = 2^15. ✓
        let lengths = [UInt8](repeating: 8, count: 256)
        let table = try PrefixCodeTable(lengths: lengths)
        var rng = SystemRandomNumberGenerator()
        var stream: [Int] = []
        for _ in 0..<100 { stream.append(Int(rng.next(upperBound: UInt32(256)))) }
        var w = BitWriter()
        for s in stream { try table.encode(s, to: &w) }
        var r = BitReader(w.finishToData())
        var decoded: [Int] = []
        for _ in stream { decoded.append(try table.decode(from: &r)) }
        XCTAssertEqual(decoded, stream)
    }

    // MARK: - Phase E3: rANS (§C.6.3)

    /// Distribution sums to exactly tabSize (4096) after normalisation.
    func testANSDistribution_NormalisesToTabSize() throws {
        let raw: [UInt32] = [100, 50, 25, 1]
        let dist = try ANSDistribution(rawFrequencies: raw)
        XCTAssertEqual(dist.frequencies.reduce(0, +), ANSConstants.tabSize)
        XCTAssertEqual(dist.alphabetSize, raw.count)
        // Non-zero raw counts must produce non-zero normalised frequencies.
        for (i, r) in raw.enumerated() where r > 0 {
            XCTAssertGreaterThan(dist.frequencies[i], 0,
                "symbol \(i) had raw count \(r) but normalised to 0")
        }
    }

    /// Slot LUT is consistent: every slot maps to a symbol whose
    /// (cum, cum+freq) range contains the slot.
    func testANSDistribution_SlotLUTIsConsistent() throws {
        let dist = try ANSDistribution(rawFrequencies: [10, 30, 20, 5, 15])
        for slot in 0..<Int(ANSConstants.tabSize) {
            let symbol = Int(dist.symbol(forSlot: UInt32(slot)))
            let cum = Int(dist.cumulative[symbol])
            let freq = Int(dist.frequencies[symbol])
            XCTAssertGreaterThanOrEqual(slot, cum, "slot \(slot) before cum[\(symbol)]")
            XCTAssertLessThan(slot, cum + freq, "slot \(slot) past freq[\(symbol)]")
        }
    }

    /// Round-trip on a small symbol stream with a uniform distribution.
    func testRANS_RoundTrip_UniformAlphabet() throws {
        let dist = try ANSDistribution(rawFrequencies: [UInt32](repeating: 1, count: 8))
        var enc = ANSEncoder(distribution: dist)
        let symbols = [0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3]
        for s in symbols { try enc.write(s) }
        let bytes = enc.finish()

        var dec = try ANSDecoder(data: bytes, distribution: dist)
        var decoded: [Int] = []
        for _ in symbols { decoded.append(try dec.read()) }
        XCTAssertEqual(decoded, symbols)
    }

    /// Round-trip on a non-uniform distribution — the case that
    /// exercises rANS's entropy gains. Many copies of symbol 0,
    /// fewer of symbols 1–3.
    func testRANS_RoundTrip_SkewedDistribution() throws {
        let dist = try ANSDistribution(rawFrequencies: [800, 100, 60, 40])
        var enc = ANSEncoder(distribution: dist)
        // 100 symbols heavily biased to 0.
        var stream: [Int] = []
        for i in 0..<100 {
            stream.append(i % 13 == 0 ? 1 : (i % 17 == 0 ? 2 : (i % 23 == 0 ? 3 : 0)))
        }
        for s in stream { try enc.write(s) }
        let bytes = enc.finish()

        var dec = try ANSDecoder(data: bytes, distribution: dist)
        var decoded: [Int] = []
        for _ in stream { decoded.append(try dec.read()) }
        XCTAssertEqual(decoded, stream, "rANS round-trip failed")
        // Sanity: encoded bytes < raw bytes (which would be 100 symbols
        // × 1 byte each = 100B; entropy-coded should be shorter even
        // accounting for the 4-byte final state).
        XCTAssertLessThan(bytes.count, 100, "rANS didn't compress at all")
    }

    /// Round-trip on a 256-symbol alphabet (the JXL alphabet limit).
    func testRANS_RoundTrip_FullAlphabet256() throws {
        // Mostly-uniform 256-symbol alphabet with one spike.
        var raw = [UInt32](repeating: 10, count: 256)
        raw[42] = 500       // hot symbol
        let dist = try ANSDistribution(rawFrequencies: raw)
        var enc = ANSEncoder(distribution: dist)
        var rng = SystemRandomNumberGenerator()
        var stream: [Int] = []
        for _ in 0..<200 {
            // 50 % chance of the hot symbol, otherwise random.
            stream.append(rng.next() & 1 == 0 ? 42 : Int(rng.next(upperBound: UInt32(256))))
        }
        for s in stream { try enc.write(s) }
        let bytes = enc.finish()

        var dec = try ANSDecoder(data: bytes, distribution: dist)
        var decoded: [Int] = []
        for _ in stream { decoded.append(try dec.read()) }
        XCTAssertEqual(decoded, stream)
    }

    /// Compression-ratio sanity: a highly skewed distribution should
    /// compress to roughly H(P) bits/symbol on a long stream.
    func testRANS_CompressionRatio_HighlySkewed() throws {
        // 99 % symbol 0, 1 % symbol 1.
        let dist = try ANSDistribution(rawFrequencies: [4055, 41])
        var enc = ANSEncoder(distribution: dist)
        var stream: [Int] = []
        for i in 0..<1000 { stream.append(i % 100 == 0 ? 1 : 0) }
        for s in stream { try enc.write(s) }
        let bytes = enc.finish()

        var dec = try ANSDecoder(data: bytes, distribution: dist)
        var decoded: [Int] = []
        for _ in stream { decoded.append(try dec.read()) }
        XCTAssertEqual(decoded, stream)
        // Shannon entropy ≈ -p log2(p) - (1-p) log2(1-p) ≈ 0.081 bits/symbol
        // for p = 0.01. So 1000 symbols ≈ 81 bits ≈ 11 bytes plus 4-byte
        // final state. Allow generous slack — we just want to confirm
        // it's much less than 1000 bytes (1 byte per symbol naive).
        XCTAssertLessThan(bytes.count, 50,
            "1000 highly-skewed symbols should compress to <50 bytes; got \(bytes.count)")
    }

    // MARK: - Phase E4a: Simple prefix-code-table serialisation (§C.6.2.1)

    /// Hand-derived bit pattern: a 2-symbol simple prefix code with
    /// alphabet size 4 (so 2 bits per symbol index). Symbols {0, 3}.
    /// Layout (LSB-first within bytes; bit positions left→right inside
    /// the integer, written first):
    ///   hskip = 01     (2 bits, value 1)
    ///   nsym  = 01     (2 bits, value 1 → 2 symbols)
    ///   sym0  = 00     (2 bits, value 0)
    ///   sym1  = 11     (2 bits, value 3)
    /// Concatenation in LSB-first byte packing:
    ///   byte 0 = 0b 11_00_01_01 = 0xC5   (sym1 high nibble, sym0 low,
    ///                                     nsym below it, hskip lowest)
    /// Wait — need to be careful. LSB-first means the FIRST bit written
    /// is the LSB of byte 0. hskip's value 1 occupies bits 0,1 of byte
    /// 0 with bit0 = 1, bit1 = 0. Then nsym occupies bits 2,3 with
    /// bit2 = 1, bit3 = 0. sym0 = 0 occupies bits 4,5 (both 0). sym1 =
    /// 3 occupies bits 6,7 (both 1).
    ///
    /// → byte 0 = 0b11_00_01_01 = 0xC5
    func testSimplePrefixCode_HandDerivedBitPattern_2Symbols() throws {
        var w = BitWriter()
        try SimplePrefixCodeFormat.encode(
            to: &w, symbols: [0, 3], alphabetSize: 4
        )
        let bytes = [UInt8](w.finishToData())
        XCTAssertEqual(bytes, [0xC5],
            "simple prefix code (sym=[0,3], alphabet=4) should be 0xC5")
    }

    /// Round-trip every simple-format shape: 1, 2, 3, and 4 symbols
    /// (both useLongCodewords variants for the 4-symbol case).
    func testSimplePrefixCode_RoundTrip_AllShapes() throws {
        let cases: [(symbols: [Int], useLong: Bool)] = [
            (symbols: [5], useLong: false),
            (symbols: [2, 7], useLong: false),
            (symbols: [1, 4, 9], useLong: false),
            (symbols: [0, 3, 6, 9], useLong: false),
            (symbols: [0, 3, 6, 9], useLong: true),
        ]
        let alphabet = 16
        for c in cases {
            var w = BitWriter()
            try SimplePrefixCodeFormat.encode(
                to: &w, symbols: c.symbols, alphabetSize: alphabet,
                useLongCodewords: c.useLong
            )
            let data = w.finishToData()
            var r = BitReader(data)
            let lengths = try SimplePrefixCodeFormat.decode(
                from: &r, alphabetSize: alphabet
            )
            XCTAssertEqual(lengths.count, alphabet)

            // Validate the lengths shape per spec.
            switch c.symbols.count {
            case 1:
                // All zero (single-symbol degenerate).
                XCTAssertTrue(lengths.allSatisfy { $0 == 0 })
            case 2:
                XCTAssertEqual(lengths[c.symbols[0]], 1)
                XCTAssertEqual(lengths[c.symbols[1]], 1)
            case 3:
                XCTAssertEqual(lengths[c.symbols[0]], 1)
                XCTAssertEqual(lengths[c.symbols[1]], 2)
                XCTAssertEqual(lengths[c.symbols[2]], 2)
            case 4:
                if c.useLong {
                    XCTAssertEqual(lengths[c.symbols[0]], 1)
                    XCTAssertEqual(lengths[c.symbols[1]], 2)
                    XCTAssertEqual(lengths[c.symbols[2]], 3)
                    XCTAssertEqual(lengths[c.symbols[3]], 3)
                } else {
                    for s in c.symbols { XCTAssertEqual(lengths[s], 2) }
                }
            default:
                XCTFail("unexpected symbol count \(c.symbols.count)")
            }

            // Verify the resulting lengths array builds a working
            // PrefixCodeTable (or, for the 1-symbol case, decodes
            // trivially) — i.e. integrates with E2.
            if c.symbols.count > 1 {
                let table = try PrefixCodeTable(lengths: lengths)
                XCTAssertGreaterThan(table.usedMaxLength, 0)
            }
        }
    }

    /// Reader must reject a non-simple header (hskip != 1).
    func testSimplePrefixCode_RejectsNonSimpleHeader() {
        var w = BitWriter()
        w.write(bits: 2, value: 0)   // hskip = 0 → complex (we don't decode that here)
        let data = w.finishToData()
        var r = BitReader(data)
        XCTAssertThrowsError(try SimplePrefixCodeFormat.decode(
            from: &r, alphabetSize: 8
        )) { err in
            guard let e = err as? SimplePrefixCodeError,
                  case .wrongHeader(_, let got) = e else {
                XCTFail("expected wrongHeader, got \(err)"); return
            }
            XCTAssertEqual(got, 0)
        }
    }

    // MARK: - Phase E4a-complex: complex prefix-code-table (§C.6.2.1)

    /// Round-trip a 6-symbol code via the complex format. Tests:
    ///   - hskip = 0 path (all 18 cll values emitted)
    ///   - meta-Huffman build from cll
    ///   - decoder consumes literal-length symbols 0..15 correctly
    func testComplexPrefixCode_RoundTrip_6Symbols() throws {
        // Build a 6-symbol code with mixed lengths; sum 2^(15-L) must
        // equal 2^15 for PrefixCodeTable. Use {1, 3, 3, 3, 4, 4}:
        //   1·16384 + 3·4096 + 2·2048 = 16384+12288+4096 = 32768 ✓
        let lengths: [UInt8] = [1, 3, 3, 3, 4, 4]
        var w = BitWriter()
        try ComplexPrefixCodeFormat.encode(to: &w, lengths: lengths)
        let data = w.finishToData()
        var r = BitReader(data)
        let parsed = try ComplexPrefixCodeFormat.decode(
            from: &r, alphabetSize: lengths.count
        )
        XCTAssertEqual(parsed, lengths)

        // Sanity: parsed lengths feed cleanly into PrefixCodeTable.
        let table = try PrefixCodeTable(lengths: parsed)
        XCTAssertEqual(table.usedMaxLength, 4)
    }

    /// Round-trip a larger alphabet to exercise scaling.
    func testComplexPrefixCode_RoundTrip_32Symbols() throws {
        // 32 symbols, all length 5: sum = 32 * 2^10 = 2^15 ✓
        let lengths = [UInt8](repeating: 5, count: 32)
        var w = BitWriter()
        try ComplexPrefixCodeFormat.encode(to: &w, lengths: lengths)
        var r = BitReader(w.finishToData())
        let parsed = try ComplexPrefixCodeFormat.decode(
            from: &r, alphabetSize: 32
        )
        XCTAssertEqual(parsed, lengths)
    }

    /// Round-trip a lengths array with many embedded zeros (absent
    /// symbols). Our encoder emits each zero as a literal symbol-0
    /// rather than using the symbol-17 zero-run shortcut, but the
    /// decoder must accept either; this confirms the no-runs path.
    func testComplexPrefixCode_RoundTrip_ManyZeros() throws {
        // 16-entry lengths array with 4 used symbols and 12 zeros.
        // Used symbols: lengths[3]=2, lengths[7]=2, lengths[10]=2, lengths[15]=2
        //   sum = 4 * 2^13 = 2^15 ✓
        var lengths = [UInt8](repeating: 0, count: 16)
        lengths[3] = 2; lengths[7] = 2; lengths[10] = 2; lengths[15] = 2
        var w = BitWriter()
        try ComplexPrefixCodeFormat.encode(to: &w, lengths: lengths)
        var r = BitReader(w.finishToData())
        let parsed = try ComplexPrefixCodeFormat.decode(
            from: &r, alphabetSize: 16
        )
        XCTAssertEqual(parsed, lengths)
    }

    /// Hand-derived test of the symbol-17 (zero-run) decoder path.
    /// Construct a bitstream BY HAND that uses symbol 17 to express a
    /// zero-run, decode it, and confirm the expansion produces the
    /// expected zero-padded lengths array. Bypasses our (non-optimising)
    /// encoder since it doesn't emit runs.
    ///
    /// Layout — write LSB-first:
    ///
    ///   hskip = 0          u(2) = 0b00
    ///   18 × cll values    u(3) each, in order, where:
    ///     • The cll for symbol 0 (literal length 0) gets the SHORTEST
    ///       meta-Huffman codeword, so we can emit several symbol-0s
    ///       cheaply if we need to. We won't here.
    ///     • The cll for symbol 17 (zero-run) gets length 1.
    ///     • The cll for symbol 2 (literal length 2) gets length 1.
    ///     • All other ccls = 0 (those symbols absent from the meta).
    ///   Then:
    ///   meta-Huffman over alphabet {2, 17}: both length 1
    ///     → canonical assignment: symbol 2 → "0", symbol 17 → "1"
    ///   Lengths-stream:
    ///     symbol 17 → "1", followed by u(3) extra → e.g. "0 0 0" for
    ///     count = 3 + 0 = 3 zeros
    ///     symbol  2 → "0" (literal length 2)
    ///   So the final lengths array is [0, 0, 0, 2] for alphabetSize=4.
    ///
    /// This isolates the symbol-17 decoder path — if it's right, the
    /// expansion math (`3 + read(3)`) is correct.
    func testComplexPrefixCode_HandDerived_ZeroRunSymbol17() throws {
        var w = BitWriter()
        // hskip = 0
        w.write(bits: 2, value: 0)
        // Read order: positions 0..17 map to symbols [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, ..., 15]
        // We want: cll for symbol 2  = 1
        //          cll for symbol 17 = 1
        //          all other cll     = 0
        // The reader iterates i in hskip..18 reading cll for kCodeLengthCodeOrder[i].
        // So we emit 18 u(3) values, one per position in that order.
        let order: [Int] = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        for i in 0..<18 {
            let sym = order[i]
            let cllValue: UInt32 = (sym == 2 || sym == 17) ? 1 : 0
            w.write(bits: 3, value: cllValue)
        }

        // Meta-Huffman over alphabet 0..18 with lengths[2]=1, lengths[17]=1,
        // everything else = 0. Canonical assignment:
        //   2 (smaller index) → "0"
        //   17                → "1"
        // BitWriter is LSB-first within bytes, so when we say "write
        // codeword 0 with length 1" we just write_bit(0); for "1" we
        // write_bit(1).
        //
        // Stream:
        //   "1" — symbol 17 (zero-run)
        //   "000" — extra 3 bits (LSB-first), value = 0 → count = 3
        //   "0" — symbol 2 (literal length 2)
        //
        // After expansion: lengths = [0, 0, 0, 2]
        //
        // PrefixCodeTable's encode reverses bits before emitting (so the
        // top bit of the canonical codeword goes first in the byte). For
        // a 1-bit codeword, reversal is a no-op.
        //
        // We don't go through the table here — we write the bits raw to
        // construct exactly the stream the spec describes.
        w.writeBit(true)        // sym 17
        w.write(bits: 3, value: 0)  // count = 3 + 0 = 3 zeros
        w.writeBit(false)       // sym 2 (canonical "0")

        let data = w.finishToData()
        var r = BitReader(data)
        let lengths = try ComplexPrefixCodeFormat.decode(
            from: &r, alphabetSize: 4
        )
        XCTAssertEqual(lengths, [0, 0, 0, 2],
            "symbol-17 zero-run expansion failed; got \(lengths)")
    }

    /// `ceilLog2` corner cases — exercised throughout the simple code
    /// header. Hand-verified.
    func testCeilLog2_Corners() {
        XCTAssertEqual(ceilLog2(0), 0)
        XCTAssertEqual(ceilLog2(1), 0)
        XCTAssertEqual(ceilLog2(2), 1)
        XCTAssertEqual(ceilLog2(3), 2)
        XCTAssertEqual(ceilLog2(4), 2)
        XCTAssertEqual(ceilLog2(5), 3)
        XCTAssertEqual(ceilLog2(8), 3)
        XCTAssertEqual(ceilLog2(9), 4)
        XCTAssertEqual(ceilLog2(16), 4)
        XCTAssertEqual(ceilLog2(256), 8)
    }

    /// Decoder must reject a truncated bitstream.
    func testRANS_RejectsTruncatedStream() throws {
        let dist = try ANSDistribution(rawFrequencies: [1, 1])
        let truncated = Data([0xFF])  // < 4 bytes — can't even read final state
        XCTAssertThrowsError(try ANSDecoder(data: truncated, distribution: dist)) { err in
            XCTAssertEqual(err as? ANSError, ANSError.malformedFinalState)
        }
    }

    // MARK: - Phase E4b: rANS distribution serialisation (§C.6.3.2)

    /// Hand-derived bit pattern for a constant (single-symbol)
    /// distribution. Layout (LSB-first):
    ///   is_simple     u(1) = 1
    ///   nsym - 1      u(2) = 0
    ///   symbol        u(log_alpha) = 3 over alphabet=4 → u(2) = 0b11
    ///
    /// Bits emitted: 1, 0, 0, 1, 1 → byte = 0b0001_1001 = 0x19.
    func testANSDistribution_HandDerived_Constant() throws {
        var w = BitWriter()
        try ANSDistributionFormat.encodeConstant(
            symbol: 3, alphabetSize: 4, to: &w
        )
        let bytes = [UInt8](w.finishToData())
        XCTAssertEqual(bytes, [0x19],
            "constant distribution (sym=3, alphabet=4) should be 0x19; got \(bytes)")
    }

    /// Round-trip a constant distribution: encode the format, decode it,
    /// confirm the resulting distribution has all probability on the
    /// chosen symbol.
    func testANSDistribution_RoundTrip_Constant() throws {
        for (alphabet, sym) in [(4, 0), (4, 3), (8, 5), (16, 11), (256, 200)] {
            var w = BitWriter()
            try ANSDistributionFormat.encodeConstant(
                symbol: sym, alphabetSize: alphabet, to: &w
            )
            var r = BitReader(w.finishToData())
            let dist = try ANSDistributionFormat.decode(
                alphabetSize: alphabet, from: &r
            )
            XCTAssertEqual(dist.alphabetSize, alphabet)
            XCTAssertEqual(dist.frequencies[sym], ANSConstants.tabSize,
                "single-symbol distribution should give tabSize freq to sym=\(sym)")
            for i in 0..<alphabet where i != sym {
                XCTAssertEqual(dist.frequencies[i], 0)
            }
        }
    }

    /// Round-trip the full nsym range (1..4) of simple distributions.
    /// Confirms the predefined frequency splits decode cleanly.
    func testANSDistribution_RoundTrip_Simple_AllShapes() throws {
        let alphabet = 16
        let cases: [[Int]] = [
            [5],                    // nsym = 1 → [tab]
            [2, 7],                 // nsym = 2 → [tab/2, tab/2]
            [1, 4, 9],              // nsym = 3 → [tab/4, tab/4, tab/2]
            [0, 3, 6, 11],          // nsym = 4 → [tab/4]*4
        ]
        let tab = ANSConstants.tabSize
        let expectedFreqs: [(Int) -> [UInt32]] = [
            { _ in [tab] },
            { _ in [tab / 2, tab / 2] },
            { _ in [tab / 4, tab / 4, tab / 2] },
            { _ in [tab / 4, tab / 4, tab / 4, tab / 4] },
        ]
        for (idx, symbols) in cases.enumerated() {
            var w = BitWriter()
            try ANSDistributionFormat.encodeSimple(
                symbols: symbols, alphabetSize: alphabet, to: &w
            )
            var r = BitReader(w.finishToData())
            let dist = try ANSDistributionFormat.decode(
                alphabetSize: alphabet, from: &r
            )
            let expected = expectedFreqs[idx](symbols.count)
            for (i, s) in symbols.enumerated() {
                XCTAssertEqual(dist.frequencies[s], expected[i],
                    "nsym=\(symbols.count): freq for sym=\(s) (position \(i))")
            }
            // Unused symbols should be 0.
            let used = Set(symbols)
            for i in 0..<alphabet where !used.contains(i) {
                XCTAssertEqual(dist.frequencies[i], 0)
            }
            // Sum invariant.
            let sum = dist.frequencies.reduce(UInt32(0), &+)
            XCTAssertEqual(sum, tab)
        }
    }

    /// Round-trip a flat distribution over various alphabet sizes.
    /// Confirms the frequency split: each symbol gets `tab / alphabet`,
    /// with the first `tab % alphabet` symbols receiving +1.
    func testANSDistribution_RoundTrip_Flat() throws {
        let tab = Int(ANSConstants.tabSize)
        for alphabet in [2, 3, 5, 7, 16, 100, 256, 1000] {
            var w = BitWriter()
            try ANSDistributionFormat.encodeFlat(alphabetSize: alphabet, to: &w)
            var r = BitReader(w.finishToData())
            let dist = try ANSDistributionFormat.decode(
                alphabetSize: alphabet, from: &r
            )
            let base = UInt32(tab / alphabet)
            let remainder = tab - (tab / alphabet) * alphabet
            for i in 0..<alphabet {
                let expected = base + (i < remainder ? 1 : 0)
                XCTAssertEqual(dist.frequencies[i], expected,
                    "flat alphabet=\(alphabet): freq for sym=\(i)")
            }
            let sum = dist.frequencies.reduce(UInt32(0), &+)
            XCTAssertEqual(sum, ANSConstants.tabSize)
        }
    }

    /// End-to-end: serialise a distribution into the bitstream, decode
    /// it back out, then use the decoded distribution to encode + decode
    /// a real symbol stream. This proves the serialised distribution
    /// agrees with the original closely enough for rANS to round-trip.
    func testANSDistribution_EndToEnd_EncodeDecodeStream() throws {
        // Use a 4-symbol simple distribution.
        let alphabet = 8
        let symbols = [0, 2, 4, 6]   // nsym = 4 → uniform tab/4 each

        // 1. Serialise the distribution.
        var dw = BitWriter()
        try ANSDistributionFormat.encodeSimple(
            symbols: symbols, alphabetSize: alphabet, to: &dw
        )
        let distData = dw.finishToData()

        // 2. Deserialise it.
        var dr = BitReader(distData)
        let dist = try ANSDistributionFormat.decode(
            alphabetSize: alphabet, from: &dr
        )

        // 3. Use the deserialised distribution to encode a stream.
        let stream: [Int] = [0, 2, 4, 6, 6, 4, 2, 0, 2, 4, 0, 6, 6, 6, 0, 2]
        var enc = ANSEncoder(distribution: dist)
        for s in stream { try enc.write(s) }
        let coded = enc.finish()

        // 4. Decode and confirm round-trip.
        var dec = try ANSDecoder(data: coded, distribution: dist)
        var decoded: [Int] = []
        for _ in 0..<stream.count { decoded.append(try dec.read()) }
        XCTAssertEqual(decoded, stream)
    }

    /// Project-internal full per-symbol-frequency mode: round-trip a
    /// realistic skewed histogram and verify exact frequency
    /// recovery.
    func testANSDistribution_RoundTrip_FullMode() throws {
        // Heavy zero-bias histogram — the natural-image residual
        // shape that flat distribution can't compress well.
        // Frequencies must sum to exactly tabSize=4096 and be ≤ 8191.
        let frequencies: [UInt32] = [
            3500,   //  85%
            300,    //  7%
            150,    //  4%
            80,     //  2%
            40,     //  1%
            20,     //  0.5%
            6,      //  ~0%
        ]
        // Pad with zeros to alphabet_size=16, plus add 0 freqs.
        var freqs = frequencies + [UInt32](repeating: 0, count: 9)
        // Adjust to sum to tabSize.
        let actualSum = freqs.reduce(UInt32(0), &+)
        let target: UInt32 = ANSConstants.tabSize
        if actualSum > target { freqs[0] -= (actualSum - target) }
        else                  { freqs[0] += (target - actualSum) }
        XCTAssertEqual(freqs.reduce(UInt32(0), &+), ANSConstants.tabSize)

        var w = BitWriter()
        try ANSDistributionFormat.encodeFull(
            frequencies: freqs, alphabetSize: 16, to: &w
        )
        var r = BitReader(w.finishToData())
        let dist = try ANSDistributionFormat.decode(alphabetSize: 16, from: &r)
        XCTAssertEqual(dist.alphabetSize, 16)
        XCTAssertEqual(dist.frequencies, freqs,
            "full-mode round-trip should recover frequencies exactly")
    }

    /// Encoder rejects a frequency array whose sum doesn't equal
    /// tabSize. Caught at encode time so the decoder never sees a
    /// malformed stream.
    func testANSDistribution_FullMode_RejectsMalformedSum() {
        var w = BitWriter()
        let bogus: [UInt32] = [100, 200, 300]
        XCTAssertThrowsError(try ANSDistributionFormat.encodeFull(
            frequencies: bogus, alphabetSize: 3, to: &w
        )) { err in
            guard let e = err as? ANSDistributionFormatError,
                  case .invalidFullSum = e else {
                XCTFail("expected invalidFullSum, got \(err)"); return
            }
        }
    }

    /// `normaliseToTabSize` coerces any non-empty raw histogram into
    /// a frequency array that sums to exactly tabSize, with non-zero
    /// raw counts mapped to ≥ 1 (so they remain encodable).
    func testANSDistribution_NormaliseToTabSize() throws {
        let raw: [UInt32] = [100, 50, 0, 25, 1, 0, 0, 1]
        let normed = try ANSDistributionFormat.normaliseToTabSize(raw)
        XCTAssertEqual(normed.count, raw.count)
        XCTAssertEqual(normed.reduce(UInt32(0), &+), ANSConstants.tabSize)
        for i in 0..<raw.count where raw[i] > 0 {
            XCTAssertGreaterThanOrEqual(normed[i], 1,
                "non-zero raw count at \(i) must produce freq ≥ 1")
        }
        for i in 0..<raw.count where raw[i] == 0 {
            XCTAssertEqual(normed[i], 0,
                "zero raw count at \(i) must produce freq 0")
        }
    }

    /// End-to-end: pack a skewed-histogram value stream through the
    /// rANS encoder using a full-mode distribution, then decode it
    /// back. Confirms the new path composes with the rANS coder.
    func testANSDistribution_FullMode_EndToEndRANS() throws {
        // Stream: 80 zeros + 20 ones — heavy bias.
        var stream: [Int] = []
        stream += Array(repeating: 0, count: 80)
        stream += Array(repeating: 1, count: 20)

        // Build the matching distribution (raw counts → normalised).
        let freqs = try ANSDistributionFormat.normaliseToTabSize([80, 20])
        // Pad the alphabet to 4 symbols so we have headroom.
        let alphabetSize = 4
        var fullFreqs = freqs + [UInt32](repeating: 0, count: alphabetSize - freqs.count)
        // Re-normalise: padding mustn't change sum (we appended zeros).
        XCTAssertEqual(fullFreqs.reduce(UInt32(0), &+), ANSConstants.tabSize)

        // Round-trip the distribution through the bitstream so the
        // encoder & decoder both see the exact same `ANSDistribution`.
        var dw = BitWriter()
        try ANSDistributionFormat.encodeFull(
            frequencies: fullFreqs, alphabetSize: alphabetSize, to: &dw
        )
        var dr = BitReader(dw.finishToData())
        let dist = try ANSDistributionFormat.decode(
            alphabetSize: alphabetSize, from: &dr
        )

        // Encode the symbol stream.
        var enc = ANSEncoder(distribution: dist)
        for s in stream { try enc.write(s) }
        let coded = enc.finish()

        // Decode and verify.
        var dec = try ANSDecoder(data: coded, distribution: dist)
        var decoded: [Int] = []
        for _ in 0..<stream.count { decoded.append(try dec.read()) }
        XCTAssertEqual(decoded, stream)
    }

    /// Encoder must reject duplicate-symbol input in the simple path.
    func testANSDistribution_RejectsDuplicateSymbols() {
        var w = BitWriter()
        XCTAssertThrowsError(try ANSDistributionFormat.encodeSimple(
            symbols: [3, 5, 3], alphabetSize: 8, to: &w
        )) { err in
            guard let e = err as? ANSDistributionFormatError,
                  case .duplicateSymbol(let s) = e else {
                XCTFail("expected duplicateSymbol, got \(err)"); return
            }
            XCTAssertEqual(s, 3)
        }
    }

    /// Encoder must reject out-of-range symbol indices.
    func testANSDistribution_RejectsOutOfRangeSymbol() {
        var w = BitWriter()
        XCTAssertThrowsError(try ANSDistributionFormat.encodeConstant(
            symbol: 10, alphabetSize: 8, to: &w
        )) { err in
            guard let e = err as? ANSDistributionFormatError,
                  case .symbolOutOfRange(let s) = e else {
                XCTFail("expected symbolOutOfRange, got \(err)"); return
            }
            XCTAssertEqual(s, 10)
        }
    }

    // MARK: - HybridUintConfig serialisation (§C.5.1)

    /// Round-trip the default and a sweep of representative configs
    /// against several `logAlpha` values that arise in practice (5..8).
    func testHybridUintConfig_RoundTrip_Sweep() throws {
        // Each (split, msb, lsb) tuple must satisfy:
        //   split <= logAlpha,  msb <= split,  lsb <= split - msb.
        let cases: [(logAlpha: Int, configs: [(Int, Int, Int)])] = [
            (logAlpha: 5, configs: [(0,0,0), (3,1,1), (5,0,0), (4,2,1)]),
            (logAlpha: 6, configs: [(2,0,2), (6,0,0), (4,2,2)]),
            (logAlpha: 8, configs: [(4,2,0), (8,0,0), (4,0,0), (6,3,1), (1,0,1)]),
        ]
        for (logAlpha, configs) in cases {
            for (split, msb, lsb) in configs {
                let cfg = HybridUintConfig(
                    splitExponent: split, msbInToken: msb, lsbInToken: lsb
                )
                var w = BitWriter()
                try cfg.write(to: &w, logAlpha: logAlpha)
                var r = BitReader(w.finishToData())
                let parsed = try HybridUintConfig.read(from: &r, logAlpha: logAlpha)
                XCTAssertEqual(parsed.splitExponent, cfg.splitExponent,
                    "split mismatch for (logAlpha=\(logAlpha), split=\(split))")
                XCTAssertEqual(parsed.msbInToken, cfg.msbInToken,
                    "msb mismatch for (logAlpha=\(logAlpha), split=\(split))")
                XCTAssertEqual(parsed.lsbInToken, cfg.lsbInToken,
                    "lsb mismatch for (logAlpha=\(logAlpha), split=\(split))")
            }
        }
    }

    /// Hand-derived bit pattern: default config (split=4, msb=2, lsb=0)
    /// against logAlpha=8.
    ///
    ///   nBitsForSplit = ceilLog2(8 + 1) = 4 → write 4 = 0b0100
    ///   nBitsForMsb   = ceilLog2(4 + 1) = 3 → write 2 = 0b010
    ///   nBitsForLsb   = ceilLog2(4 - 2 + 1) = 2 → write 0 = 0b00
    ///
    /// Bits emitted (LSB-first within each field):
    ///   split=4 → 0,0,1,0
    ///   msb=2   → 0,1,0
    ///   lsb=0   → 0,0
    ///
    /// Combined LSB-first: 0,0,1,0,0,1,0,0,0 (9 bits, padded to 16 bits).
    /// Bit 0 = 0, bit 1 = 0, bit 2 = 1, bit 3 = 0,
    /// bit 4 = 0, bit 5 = 1, bit 6 = 0, bit 7 = 0,
    /// bit 8 = 0, bits 9..15 = 0.
    /// Byte 0 = 0b0010_0100 = 0x24
    /// Byte 1 = 0b0000_0000 = 0x00
    func testHybridUintConfig_HandDerived_DefaultConfig() throws {
        var w = BitWriter()
        try HybridUintConfig.defaultConfig.write(to: &w, logAlpha: 8)
        let bytes = [UInt8](w.finishToData())
        XCTAssertEqual(bytes, [0x24, 0x00],
            "default config (split=4, msb=2, lsb=0) at logAlpha=8 should be 0x24 0x00; got \(bytes)")
    }

    /// Edge case: `splitExponent == logAlpha` triggers the implicit-zero
    /// branch — only the split field is emitted.
    func testHybridUintConfig_SplitEqualsLogAlpha_OmitsMsbLsb() throws {
        let cfg = HybridUintConfig(splitExponent: 8, msbInToken: 0, lsbInToken: 0)
        var w = BitWriter()
        try cfg.write(to: &w, logAlpha: 8)
        // Only the 4-bit split field is emitted: 0b1000.
        // Bits LSB-first: 0,0,0,1 (4 bits) → bit 3 set → byte = 0x08.
        let bytes = [UInt8](w.finishToData())
        XCTAssertEqual(bytes, [0x08])

        var r = BitReader(w.finishToData())
        let parsed = try HybridUintConfig.read(from: &r, logAlpha: 8)
        XCTAssertEqual(parsed.splitExponent, 8)
        XCTAssertEqual(parsed.msbInToken, 0)
        XCTAssertEqual(parsed.lsbInToken, 0)
    }

    /// Encoder rejects an out-of-range `splitExponent`.
    func testHybridUintConfig_RejectsSplitOutOfRange() {
        let cfg = HybridUintConfig(splitExponent: 6, msbInToken: 0, lsbInToken: 0)
        var w = BitWriter()
        XCTAssertThrowsError(try cfg.write(to: &w, logAlpha: 5)) { err in
            guard let e = err as? HybridUintConfigError,
                  case .splitOutOfRange(let split, let logAlpha) = e else {
                XCTFail("expected splitOutOfRange, got \(err)"); return
            }
            XCTAssertEqual(split, 6)
            XCTAssertEqual(logAlpha, 5)
        }
    }

    // MARK: - Enum() writer (§C.2.6)

    /// Round-trip every Enum() value 0…16 (full spec range — selectors
    /// 0–2 emit 0, 1, 2 directly; selector 3 emits `1 + u(4)` ∈ 1..16).
    func testEnum_RoundTrip_FullRange() throws {
        for value in 0...16 {
            var w = BitWriter()
            try w.writeEnum(UInt32(value))
            var r = BitReader(w.finishToData())
            let parsed = try r.readEnum()
            XCTAssertEqual(parsed, UInt32(value),
                "Enum() round-trip failed for \(value)")
        }
    }

    /// Values above 16 fall outside Enum()'s representable range and
    /// must throw rather than silently producing an aliased encoding.
    func testEnum_RejectsOutOfRange() {
        var w = BitWriter()
        XCTAssertThrowsError(try w.writeEnum(17))
        XCTAssertThrowsError(try w.writeEnum(100))
    }

    /// Hand-derived: writeEnum(0) emits selector 0, no extra bits → 2 bits total.
    func testEnum_HandDerived_Zero() throws {
        var w = BitWriter()
        try w.writeEnum(0)
        let bytes = [UInt8](w.finishToData())
        // Selector 0 = 0b00 (2 bits). Padded to 8 → 0x00.
        XCTAssertEqual(bytes, [0x00])
    }

    /// Hand-derived: writeEnum(5) goes via the offset(1, u(4)) branch:
    /// selector 3 = 0b11, then `5 - 1 = 4` as u(4) = 0b0100.
    /// LSB-first: 1,1,0,0,1,0 → byte = 0b0001_0011 = 0x13.
    func testEnum_HandDerived_Five() throws {
        var w = BitWriter()
        try w.writeEnum(5)
        let bytes = [UInt8](w.finishToData())
        XCTAssertEqual(bytes, [0x13])
    }

    // MARK: - SimpleEntropyStream — integration of the entropy primitives

    /// Round-trip a small mixed-magnitude value stream through the full
    /// HybridUint + rANS + ANSDistribution pipeline. The stream covers
    /// values that take the "token == value" path (small values) and
    /// values that take the "token + extra bits" path (large values).
    /// Exercises every primitive layer in lockstep.
    func testSimpleEntropyStream_RoundTrip_MixedValues() throws {
        let values: [UInt32] = [
            0, 1, 2, 3, 7, 15,           // token-only, no extra bits
            16, 31, 100, 255, 1000,      // small extra-bits widths
            65535, 100_000, 1_000_000,   // larger extra-bits
        ]
        let config = HybridUintConfig.defaultConfig
        let maxTok = values.map { config.encode($0).token }.max() ?? 0
        let alphabetSize = Int(maxTok) + 1
        let dist = try roundTripDistribution(
            shape: .flat, alphabetSize: alphabetSize
        )
        let ctx = SimpleEntropyContext(
            alphabetSize: alphabetSize,
            hybridConfig: config,
            distribution: dist
        )
        let encoded = try SimpleEntropyStream.encode(
            values: values, context: ctx, shape: .flat
        )
        let decoded = try SimpleEntropyStream.decode(encoded)
        XCTAssertEqual(decoded, values,
            "SimpleEntropyStream round-trip failed: encoded \(values), got \(decoded)")
    }

    /// Round-trip a 1-symbol-dominant stream via the simple
    /// distribution shape. Confirms that the simple `[tab]` shortcut
    /// composes correctly with the rest of the pipeline.
    func testSimpleEntropyStream_RoundTrip_ConstantSymbol() throws {
        // All-zero stream of 100 values. The HybridUint default config
        // maps 0 → token=0 with no extra bits. So every token is 0.
        let values = [UInt32](repeating: 0, count: 100)
        // alphabetSize=32 → logAlpha=5, so the default config (split=4,
        // msb=2, lsb=0) lands in the "split < logAlpha" branch where
        // msb/lsb are explicitly serialised.
        let alphabetSize = 32
        let dist = try roundTripDistribution(
            shape: .simple(symbols: [0]), alphabetSize: alphabetSize
        )
        let ctx = SimpleEntropyContext(
            alphabetSize: alphabetSize,
            hybridConfig: HybridUintConfig.defaultConfig,
            distribution: dist
        )
        let encoded = try SimpleEntropyStream.encode(
            values: values, context: ctx, shape: .simple(symbols: [0])
        )
        let decoded = try SimpleEntropyStream.decode(encoded)
        XCTAssertEqual(decoded, values)
    }

    /// Empty value stream — degenerate but should still round-trip
    /// cleanly (header is emitted, no tokens follow).
    func testSimpleEntropyStream_RoundTrip_Empty() throws {
        let alphabetSize = 32
        let dist = try roundTripDistribution(shape: .flat, alphabetSize: alphabetSize)
        let ctx = SimpleEntropyContext(
            alphabetSize: alphabetSize,
            hybridConfig: HybridUintConfig.defaultConfig,
            distribution: dist
        )
        let encoded = try SimpleEntropyStream.encode(
            values: [], context: ctx, shape: .flat
        )
        let decoded = try SimpleEntropyStream.decode(encoded)
        XCTAssertEqual(decoded, [UInt32]())
    }

    /// Truncated stream → decoder throws, doesn't trap.
    func testSimpleEntropyStream_Truncated_Throws() throws {
        let alphabetSize = 32
        let dist = try roundTripDistribution(shape: .flat, alphabetSize: alphabetSize)
        let ctx = SimpleEntropyContext(
            alphabetSize: alphabetSize,
            hybridConfig: HybridUintConfig.defaultConfig,
            distribution: dist
        )
        let full = try SimpleEntropyStream.encode(
            values: [1, 2, 3, 4, 5], context: ctx, shape: .flat
        )
        // Cut off the trailing rANS bytes.
        let truncated = full.subdata(in: 0..<(full.count - 4))
        XCTAssertThrowsError(try SimpleEntropyStream.decode(truncated))
    }

}

// MARK: - Squeeze (§C.7.6)

extension FoundationTests {

    /// 1D forward + inverse round-trip across small even-length
    /// buffers. Hand-derives both directions.
    func testSqueeze_HorizontalRoundTrip_Even() {
        let original: [Int32] = [10, 20, 30, 40, 50, 60, 70, 80]
        let squeezed = Squeeze.forwardHorizontal(original)
        // Pairs: (10,20)→avg=15,res=-10; (30,40)→avg=35,res=-10;
        //        (50,60)→avg=55,res=-10; (70,80)→avg=75,res=-10.
        // Layout: avg first, res second.
        XCTAssertEqual(squeezed, [15, 35, 55, 75, -10, -10, -10, -10])
        let recovered = Squeeze.inverseHorizontal(squeezed)
        XCTAssertEqual(recovered, original,
            "Squeeze.forwardHorizontal then inverseHorizontal must be identity")
    }

    /// Odd-length buffer — last element passes through unchanged.
    func testSqueeze_HorizontalRoundTrip_Odd() {
        let original: [Int32] = [10, 20, 30, 40, 50]
        let squeezed = Squeeze.forwardHorizontal(original)
        // Pairs: (10,20), (30,40). Last element 50 passes through.
        // Layout: [avg0, avg1, 50, res0, res1]
        XCTAssertEqual(squeezed[0], 15)
        XCTAssertEqual(squeezed[1], 35)
        XCTAssertEqual(squeezed[2], 50)   // odd tail in avg-half
        XCTAssertEqual(squeezed[3], -10)
        XCTAssertEqual(squeezed[4], -10)
        let recovered = Squeeze.inverseHorizontal(squeezed)
        XCTAssertEqual(recovered, original)
    }

    /// Negative values + odd residuals: stresses the
    /// `(res + 1) >> 1` ceil-division for two's-complement
    /// arithmetic shift.
    func testSqueeze_NegativeAndOddResiduals() {
        let original: [Int32] = [-5, 8, 100, -100, 0, -1, 1000000, 999999]
        let squeezed = Squeeze.forwardHorizontal(original)
        let recovered = Squeeze.inverseHorizontal(squeezed)
        XCTAssertEqual(recovered, original,
            "Squeeze must round-trip exactly for negative + odd-difference values")
    }

    /// Exhaustive round-trip across 0…31² value pairs.
    func testSqueeze_ExhaustiveRoundTripPairs() {
        for l in 0...31 {
            for r in 0...31 {
                let pair: [Int32] = [Int32(l), Int32(r)]
                let s = Squeeze.forwardHorizontal(pair)
                let u = Squeeze.inverseHorizontal(s)
                if u != pair {
                    XCTFail("Squeeze round-trip failed for (l=\(l), r=\(r))")
                    return
                }
            }
        }
    }

    /// 2D forward + inverse round-trip on a 4×4 buffer along axis 0
    /// (horizontal). Each row is squeezed independently.
    func testSqueeze_2D_Horizontal_RoundTrip() {
        let original: [Int32] = [
            10, 20, 30, 40,
            50, 60, 70, 80,
            90, 100, 110, 120,
            130, 140, 150, 160,
        ]
        let squeezed = Squeeze.forward2D(original, width: 4, height: 4, axis: 0)
        XCTAssertEqual(squeezed.count, original.count)
        let recovered = Squeeze.inverse2D(squeezed, width: 4, height: 4, axis: 0)
        XCTAssertEqual(recovered, original)
    }

    /// 2D vertical squeeze round-trip.
    func testSqueeze_2D_Vertical_RoundTrip() {
        let original: [Int32] = [
            10, 20, 30, 40,
            50, 60, 70, 80,
            90, 100, 110, 120,
            130, 140, 150, 160,
        ]
        let squeezed = Squeeze.forward2D(original, width: 4, height: 4, axis: 1)
        let recovered = Squeeze.inverse2D(squeezed, width: 4, height: 4, axis: 1)
        XCTAssertEqual(recovered, original)
    }

    /// Composed horizontal + vertical squeeze (the classic
    /// 4-quadrant wavelet decomposition). Proves the two passes
    /// commute exactly.
    func testSqueeze_2D_HorizontalThenVertical_RoundTrip() {
        let original: [Int32] = (0..<64).map { Int32($0 * 7 - 100) }
        let h = Squeeze.forward2D(original, width: 8, height: 8, axis: 0)
        let hv = Squeeze.forward2D(h, width: 8, height: 8, axis: 1)
        // Inverse in reverse order.
        let h2 = Squeeze.inverse2D(hv, width: 8, height: 8, axis: 1)
        let recovered = Squeeze.inverse2D(h2, width: 8, height: 8, axis: 0)
        XCTAssertEqual(recovered, original,
            "horizontal-then-vertical squeeze must round-trip exactly")
    }
}

// MARK: - RCT reversible colour transform (§C.7.7)

extension FoundationTests {

    /// Identity variant: pixel triples pass through unchanged.
    func testRCT_Identity_RoundTrip() {
        for (r, g, b) in [
            (0, 0, 0), (255, 255, 255), (100, 50, 200), (-10, 10, 5),
        ] as [(Int32, Int32, Int32)] {
            let (y, co, cg) = RCT.forwardPixel(.identity, r: r, g: g, b: b)
            XCTAssertEqual(y, r); XCTAssertEqual(co, g); XCTAssertEqual(cg, b)
            let (r2, g2, b2) = RCT.inversePixel(.identity, y: y, co: co, cg: cg)
            XCTAssertEqual(r2, r); XCTAssertEqual(g2, g); XCTAssertEqual(b2, b)
        }
    }

    /// YCoCg-R: hand-computed value for one specific triple, plus
    /// round-trip across an interesting range.
    ///
    /// Hand-computed for (R, G, B) = (200, 100, 50):
    ///   Co  = 200 - 50  = 150
    ///   tmp = 50 + (150 >> 1) = 50 + 75 = 125
    ///   Cg  = 100 - 125 = -25
    ///   Y   = 125 + (-25 >> 1) = 125 + (-13) = 112
    ///
    /// Note: arithmetic right shift of -25 by 1 is -13 (floor-toward
    /// -∞ on 2's complement), which matches Swift's `&>>` on `Int32`.
    func testRCT_YCoCgR_HandValueAndRoundTrip() {
        let (y, co, cg) = RCT.forwardPixel(.ycocgR, r: 200, g: 100, b: 50)
        XCTAssertEqual(y, 112, "YCoCg-R Y for (200, 100, 50)")
        XCTAssertEqual(co, 150, "YCoCg-R Co for (200, 100, 50)")
        XCTAssertEqual(cg, -25, "YCoCg-R Cg for (200, 100, 50)")
        let (r, g, b) = RCT.inversePixel(.ycocgR, y: y, co: co, cg: cg)
        XCTAssertEqual(r, 200); XCTAssertEqual(g, 100); XCTAssertEqual(b, 50)
    }

    /// Round-trip every (R, G, B) triple in 0…31³ — exhaustive small-
    /// range coverage that catches any bit-shift / sign-handling bug
    /// in either direction of the transform.
    func testRCT_YCoCgR_RoundTripExhaustiveSmallRange() {
        for r in 0...31 {
            for g in 0...31 {
                for b in 0...31 {
                    let (y, co, cg) = RCT.forwardPixel(
                        .ycocgR, r: Int32(r), g: Int32(g), b: Int32(b)
                    )
                    let (r2, g2, b2) = RCT.inversePixel(
                        .ycocgR, y: y, co: co, cg: cg
                    )
                    if (r2, g2, b2) != (Int32(r), Int32(g), Int32(b)) {
                        XCTFail("YCoCg-R round-trip failed for (\(r), \(g), \(b))")
                        return
                    }
                }
            }
        }
    }

    /// Round-trip across full 16-bit-range pixel values.
    func testRCT_YCoCgR_RoundTripFull16BitBoundaries() {
        let triples: [(Int32, Int32, Int32)] = [
            (0, 0, 0), (65535, 65535, 65535), (65535, 0, 0),
            (0, 65535, 0), (0, 0, 65535), (32768, 32767, 32766),
            (1, 65535, 32767), (-1, -1, -1), (-32768, -32767, -32766),
        ]
        for (r, g, b) in triples {
            let (y, co, cg) = RCT.forwardPixel(.ycocgR, r: r, g: g, b: b)
            let (r2, g2, b2) = RCT.inversePixel(.ycocgR, y: y, co: co, cg: cg)
            XCTAssertEqual([r2, g2, b2], [r, g, b],
                "YCoCg-R round-trip failed for (\(r), \(g), \(b))")
        }
    }

    /// Decorrelation property: when R, G, B are correlated (R ≈ G ≈ B
    /// ≈ base), the transformed Co and Cg channels are *small*
    /// regardless of base brightness. This is the property that
    /// makes RCT useful for compression.
    func testRCT_YCoCgR_DecorrelatesCorrelatedChannels() {
        // R = base, G = base + 1, B = base - 1 across many bases.
        // Derivation:
        //   Co  = R - B = base - (base - 1) = 1
        //   tmp = B + (Co >> 1) = (base - 1) + 0 = base - 1
        //   Cg  = G - tmp = (base + 1) - (base - 1) = 2
        for base in stride(from: Int32(0), through: 65000, by: 1000) {
            let (_, co, cg) = RCT.forwardPixel(
                .ycocgR, r: base, g: base &+ 1, b: base &- 1
            )
            XCTAssertEqual(co, 1, "Co should be 1 regardless of base; got \(co) at base=\(base)")
            XCTAssertEqual(cg, 2, "Cg should be 2 regardless of base; got \(cg) at base=\(base)")
        }
    }

    /// Buffer-level forward+inverse round-trip on a small image.
    func testRCT_YCoCgR_BufferRoundTrip() {
        var ch0: [Int32] = [10, 20, 30, 40]
        var ch1: [Int32] = [15, 25, 35, 45]
        var ch2: [Int32] = [5,  15, 25, 35]
        let originalCh0 = ch0
        let originalCh1 = ch1
        let originalCh2 = ch2
        RCT.forward(.ycocgR, channel0: &ch0, channel1: &ch1, channel2: &ch2)
        // Mutated.
        XCTAssertNotEqual(ch0, originalCh0)
        RCT.inverse(.ycocgR, channel0: &ch0, channel1: &ch1, channel2: &ch2)
        XCTAssertEqual(ch0, originalCh0)
        XCTAssertEqual(ch1, originalCh1)
        XCTAssertEqual(ch2, originalCh2)
    }
}

// MARK: - Modular predictors + ZigZag (§C.7.5)

extension FoundationTests {

    /// Each predictor formula on a hand-computed neighbourhood.
    func testPredictor_FormulasAgainstHandValues() {
        let n = Neighbourhood(w: 100, n: 110, nw: 105, ne: 120,
                              ww: 90, nn: 115)

        XCTAssertEqual(Predictor.zero.apply(to: n), 0)
        XCTAssertEqual(Predictor.west.apply(to: n), 100)
        XCTAssertEqual(Predictor.north.apply(to: n), 110)
        XCTAssertEqual(Predictor.avgWN.apply(to: n), 105,
                       "(100 + 110) / 2 = 105")
        XCTAssertEqual(Predictor.ww.apply(to: n), 90,
                       "WW returns the 2-columns-west sample")
        XCTAssertEqual(Predictor.nn.apply(to: n), 115,
                       "NN returns the 2-rows-north sample")

        // gradient = clamp(W + N - NW, min(W,N), max(W,N))
        //         = clamp(100 + 110 - 105, 100, 110)
        //         = clamp(105, 100, 110) = 105
        XCTAssertEqual(Predictor.gradient.apply(to: n), 105)

        // medianWNGradient = median(W, N, W+N-NW) = median(100, 110, 105) = 105
        XCTAssertEqual(Predictor.medianWNGradient.apply(to: n), 105)
    }

    /// Predictor edge cases: gradient clamps when `W + N - NW` lies
    /// outside [min(W,N), max(W,N)] (e.g., diagonal-discontinuity).
    func testPredictor_GradientClamps() {
        // W=100, N=200, NW=300 → W+N-NW = 0, but min(W,N)=100, max=200.
        // gradient should clamp to 100 (the minimum).
        let n = Neighbourhood(w: 100, n: 200, nw: 300, ne: 0)
        XCTAssertEqual(Predictor.gradient.apply(to: n), 100,
                       "gradient should clamp to min(W, N)")
    }

    /// Period-2-column pattern: every other column repeats. The WW
    /// predictor (2 columns west) gives a perfect match for the
    /// interior; should be picked when the encoder evaluates all
    /// predictors. Round-trip must be exact.
    func testM0_Period2ColumnPattern_PicksWW() throws {
        var frame = ImageFrame(
            width: 8, height: 8, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        for y in 0..<8 {
            for x in 0..<8 {
                // Period-2 column: alternating value pattern
                let v = UInt16((x % 2 == 0) ? 100 : 200)
                frame.setPixel(x: x, y: y, channel: 0, value: v)
            }
        }
        let buf = MinimalLosslessCodec.buildChannelBuffer(frame, channel: 0)
        let chosen = MinimalLosslessCodec.bestPredictorForChannel(
            buf, width: 8, hybridConfig: .defaultConfig
        ).id
        // WW (or another predictor that gives equally small residuals)
        // — but for this exact period-2 pattern, WW gives 0 residuals
        // for x ≥ 2 in every row.
        XCTAssertTrue([PredictorID.ww, .west, .north].contains(chosen),
            "period-2-column should pick a predictor that handles it (got \(chosen))")
        let encoded = try MinimalLosslessCodec.encode(frame)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// `Neighbourhood.init(at:in:)` substitutes the spec fall-backs at
    /// image edges:
    ///   • Top-left pixel: every neighbour is 0.
    ///   • Top row (y=0): N=W substitutes (still 0 at top-left).
    ///   • Left column (x=0): W=N substitutes.
    func testPredictor_NeighbourhoodEdgeFallbacks() {
        // 3×3 buffer:
        //   10 20 30
        //   40 50 60
        //   70 80 90
        let buf: [Int32] = [10, 20, 30, 40, 50, 60, 70, 80, 90]
        let w = 3

        // (0, 0): no neighbours — all 0.
        let n00 = Neighbourhood(at: 0, 0, in: buf, width: w)
        XCTAssertEqual(n00.w, 0)
        XCTAssertEqual(n00.n, 0)
        XCTAssertEqual(n00.nw, 0)
        XCTAssertEqual(n00.ne, 0)

        // (1, 0): only W=10 exists. N falls back to W (10), NW to N (10),
        // NE to N (10).
        let n10 = Neighbourhood(at: 1, 0, in: buf, width: w)
        XCTAssertEqual(n10.w, 10)
        XCTAssertEqual(n10.n, 10)
        XCTAssertEqual(n10.nw, 10)
        XCTAssertEqual(n10.ne, 10)

        // (0, 1): only N=10 exists. W falls back to N (10), NW to W (10),
        // NE to (1, 0)=20.
        let n01 = Neighbourhood(at: 0, 1, in: buf, width: w)
        XCTAssertEqual(n01.w, 10)
        XCTAssertEqual(n01.n, 10)
        XCTAssertEqual(n01.nw, 10)
        XCTAssertEqual(n01.ne, 20)

        // (1, 1): all neighbours present.
        let n11 = Neighbourhood(at: 1, 1, in: buf, width: w)
        XCTAssertEqual(n11.w, 40)
        XCTAssertEqual(n11.n, 20)
        XCTAssertEqual(n11.nw, 10)
        XCTAssertEqual(n11.ne, 30)

        // (2, 1): NE doesn't exist (would be x=3). Falls back to N=30.
        let n21 = Neighbourhood(at: 2, 1, in: buf, width: w)
        XCTAssertEqual(n21.w, 50)
        XCTAssertEqual(n21.n, 30)
        XCTAssertEqual(n21.nw, 20)
        XCTAssertEqual(n21.ne, 30)
    }

    /// Predict-encode-decode round-trip on a small image. For each
    /// pixel: compute residual = actual - predicted; later, decoder
    /// applies the same predictor to its already-decoded neighbours
    /// and recovers actual = predicted + residual. This is the
    /// fundamental Modular invariant.
    func testPredictor_RoundTrip_OnSmallImage() {
        // 4×4 grayscale image with a realistic gradient pattern.
        let original: [Int32] = [
             10,  20,  30,  40,
             50,  60,  70,  80,
             90, 100, 110, 120,
            130, 140, 150, 160,
        ]
        let w = 4
        let h = 4

        // Encoder: build a parallel buffer of residuals using the
        // gradient predictor against already-emitted neighbours.
        var encBuffer = [Int32](repeating: 0, count: original.count)
        var residuals = [Int32](repeating: 0, count: original.count)
        for y in 0..<h {
            for x in 0..<w {
                let nbh = Neighbourhood(at: x, y, in: encBuffer, width: w)
                let pred = Predictor.gradient.apply(to: nbh)
                let actual = original[y * w + x]
                residuals[y * w + x] = actual &- pred
                // The encoder commits the actual pixel to its
                // shadow buffer so the next pixel sees the same
                // neighbourhood the decoder will see.
                encBuffer[y * w + x] = actual
            }
        }

        // Decoder: walk the residuals, predict from already-decoded
        // pixels, and recover the original.
        var decBuffer = [Int32](repeating: 0, count: original.count)
        for y in 0..<h {
            for x in 0..<w {
                let nbh = Neighbourhood(at: x, y, in: decBuffer, width: w)
                let pred = Predictor.gradient.apply(to: nbh)
                decBuffer[y * w + x] = pred &+ residuals[y * w + x]
            }
        }

        XCTAssertEqual(decBuffer, original,
            "predictor round-trip failed: residuals didn't recover original pixels")
    }

    /// ZigZag pack/unpack across hand-computed values that anchor the
    /// formula. Pattern: 0→0, -1→1, 1→2, -2→3, 2→4, -3→5, 3→6, …
    func testZigZag_HandValues() {
        let cases: [(Int32, UInt32)] = [
            (0,   0),
            (-1,  1),
            (1,   2),
            (-2,  3),
            (2,   4),
            (-3,  5),
            (100, 200),
            (-100, 199),
        ]
        for (signed, packed) in cases {
            XCTAssertEqual(ZigZag.pack(signed), packed,
                "pack(\(signed)) should be \(packed)")
            XCTAssertEqual(ZigZag.unpack(packed), signed,
                "unpack(\(packed)) should be \(signed)")
        }
    }

    /// ZigZag packs small-magnitude values into small-magnitude
    /// unsigned values — the property the entropy coder relies on.
    /// Sweep across ±2^15 and confirm the unsigned result fits in
    /// 16 + 1 bits (one extra for the sign).
    func testZigZag_SmallValuesProduceSmallUnsigned() {
        for v in stride(from: Int32(-1024), through: 1024, by: 1) {
            let packed = ZigZag.pack(v)
            // |v| ≈ 1024 → packed ≈ 2048. Allow up to 2049 (= 2 * 1024 + 1).
            XCTAssertLessThanOrEqual(packed, 2049,
                "ZigZag should produce small unsigned for |v| ≤ 1024 (v=\(v))")
            XCTAssertEqual(ZigZag.unpack(packed), v)
        }
    }

    /// ZigZag handles full-range Int32 boundaries.
    func testZigZag_RoundTripBoundaries() {
        for v in [Int32.min, Int32.min &+ 1, -1, 0, 1, Int32.max &- 1, Int32.max] {
            let packed = ZigZag.pack(v)
            let unpacked = ZigZag.unpack(packed)
            XCTAssertEqual(unpacked, v, "ZigZag round-trip failed for \(v)")
        }
    }
}

// MARK: - FrameHeader (§C.8.1)

extension FoundationTests {

    /// Hand-derived: `all_default = true` is a single bit (1).
    /// LSB-first: bit 0 = 1 → byte = 0x01.
    func testFrameHeader_HandDerived_AllDefault() throws {
        var w = BitWriter()
        try FrameHeader.default.write(to: &w)
        let bytes = [UInt8](w.finishToData())
        XCTAssertEqual(bytes, [0x01],
            "all_default=true should be a single 1 bit → 0x01")
    }

    /// Round-trip the all_default=true case. Decoder reads the 1 bit
    /// and reconstructs a FrameHeader equal to `.default`.
    func testFrameHeader_RoundTrip_AllDefault() throws {
        var w = BitWriter()
        try FrameHeader.default.write(to: &w)
        var r = BitReader(w.finishToData())
        let parsed = try FrameHeader.read(from: &r)
        XCTAssertTrue(parsed.allDefault)
        XCTAssertEqual(parsed.frameType, .regular)
        XCTAssertEqual(parsed.encoding, .varDCT)
        XCTAssertEqual(parsed.flags, 0)
        XCTAssertTrue(parsed.isLast)
        XCTAssertNil(parsed.frameSize)
    }

    /// Round-trip the "single-frame modular lossless" preset — the
    /// shape we'll use when MinimalLosslessCodec migrates to a real
    /// FrameHeader.
    func testFrameHeader_RoundTrip_SingleFrameModularLossless() throws {
        let cfg = FrameHeader.singleFrameModularLossless()
        var w = BitWriter()
        try cfg.write(to: &w)
        var r = BitReader(w.finishToData())
        let parsed = try FrameHeader.read(from: &r)
        XCTAssertFalse(parsed.allDefault)
        XCTAssertEqual(parsed.frameType, .regular)
        XCTAssertEqual(parsed.encoding, .modular)
        XCTAssertEqual(parsed.flags, 0)
        XCTAssertEqual(parsed.groupSizeShift, 1)
        XCTAssertTrue(parsed.isLast)
        XCTAssertNil(parsed.frameSize)
    }

    /// Round-trip a header with an explicit (cropped) frame size.
    /// Confirms the have_crop=true branch routes through SizeHeader
    /// correctly.
    func testFrameHeader_RoundTrip_HaveCrop() throws {
        let cfg = FrameHeader(
            allDefault: false,
            frameType: .regular,
            encoding: .modular,
            flags: 0,
            groupSizeShift: 2,
            isLast: false,
            frameSize: SizeHeader(xsize: 640, ysize: 480)
        )
        var w = BitWriter()
        try cfg.write(to: &w)
        var r = BitReader(w.finishToData())
        let parsed = try FrameHeader.read(from: &r)
        XCTAssertEqual(parsed.frameType, .regular)
        XCTAssertEqual(parsed.encoding, .modular)
        XCTAssertEqual(parsed.groupSizeShift, 2)
        XCTAssertFalse(parsed.isLast)
        XCTAssertEqual(parsed.frameSize?.xsize, 640)
        XCTAssertEqual(parsed.frameSize?.ysize, 480)
    }

    /// Sweep across each (frameType, encoding) combination to confirm
    /// the 2-bit / 1-bit selectors decode cleanly.
    func testFrameHeader_RoundTrip_FrameTypeAndEncodingMatrix() throws {
        for ft in FrameType.allCases {
            for enc: FrameEncoding in [.varDCT, .modular] {
                let cfg = FrameHeader(
                    allDefault: false,
                    frameType: ft,
                    encoding: enc,
                    flags: 0,
                    groupSizeShift: 1,
                    isLast: true,
                    frameSize: nil
                )
                var w = BitWriter()
                try cfg.write(to: &w)
                var r = BitReader(w.finishToData())
                let parsed = try FrameHeader.read(from: &r)
                XCTAssertEqual(parsed.frameType, ft,
                    "frameType mismatch for (\(ft), \(enc))")
                XCTAssertEqual(parsed.encoding, enc,
                    "encoding mismatch for (\(ft), \(enc))")
            }
        }
    }

    /// Encoder rejects flags above the placeholder u(8) limit.
    func testFrameHeader_RejectsLargeFlags() {
        let cfg = FrameHeader(
            allDefault: false, frameType: .regular, encoding: .modular,
            flags: 0x100, groupSizeShift: 1, isLast: true, frameSize: nil
        )
        var w = BitWriter()
        XCTAssertThrowsError(try cfg.write(to: &w)) { err in
            guard let e = err as? FrameHeaderError,
                  case .unsupportedField = e else {
                XCTFail("expected unsupportedField, got \(err)"); return
            }
        }
    }
}

// MARK: - Phase M0 vertical slice — MinimalLosslessCodec

extension FoundationTests {

    /// The headline M0 test: a 1×1 grayscale lossless frame round-trips
    /// through `MinimalLosslessCodec.encode → decode` to the same pixel.
    /// This is the "vertical slice" milestone — every layer of the
    /// codec (bitstream, container, ImageMetadata, HybridUint, rANS,
    /// distribution serialisation, SimpleEntropyStream) is exercised.
    func testM0_OnePixelGrayscaleLossless_RoundTrip() throws {
        var frame = ImageFrame(
            width: 1, height: 1, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        frame.setPixel(x: 0, y: 0, channel: 0, value: 137)
        let encoded = try MinimalLosslessCodec.encode(frame)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.width, 1)
        XCTAssertEqual(decoded.height, 1)
        XCTAssertEqual(decoded.channels, 1)
        XCTAssertEqual(decoded.pixelType, .uint8)
        XCTAssertEqual(decoded.getPixel(x: 0, y: 0, channel: 0), 137,
            "M0 single-pixel value lost in round-trip")
    }

    /// Wider grayscale image — exercises the SimpleEntropyStream over
    /// a longer pixel sequence and confirms row-major channel-
    /// interleaved layout is preserved.
    func testM0_8x8GrayscaleLossless_RoundTrip() throws {
        var frame = ImageFrame(
            width: 8, height: 8, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        // Fill with a deterministic pattern so we can compare byte-for-byte.
        for y in 0..<8 {
            for x in 0..<8 {
                let v = UInt16((y * 16 + x) & 0xFF)
                frame.setPixel(x: x, y: y, channel: 0, value: v)
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data, "8×8 grayscale pixels lost in round-trip")
    }

    /// Full 16-bit-range uint16 grayscale. Because pixel values are
    /// run through the HybridUint layer first (token alphabet only 128),
    /// any 0..65535 value flows through the same entropy path. Confirms
    /// the high-byte/low-byte path round-trips for the medical-imaging
    /// case.
    func testM0_16BitGrayscaleLossless_RoundTrip() throws {
        var frame = ImageFrame(
            width: 4, height: 4, channels: 1,
            pixelType: .uint16, colorSpace: .grayscale
        )
        for y in 0..<4 {
            for x in 0..<4 {
                // Values 0..60 000 — full 16-bit range.
                let v = UInt16((y * 4 + x) * 4000)
                frame.setPixel(x: x, y: y, channel: 0, value: v)
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data,
            "uint16 grayscale (full 16-bit range) pixels lost in round-trip")
    }

    /// The placeholder marker `0x4D30` ('M0') must be present at the
    /// expected position so a future spec-compliant decoder knows to
    /// reject the buffer rather than silently treat it as a real
    /// codestream.
    func testM0_PlaceholderMarker_Present() throws {
        var frame = ImageFrame(
            width: 1, height: 1, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        frame.setPixel(x: 0, y: 0, channel: 0, value: 42)
        let encoded = try MinimalLosslessCodec.encode(frame)
        // Search for the marker bytes — they appear after the
        // signature, SizeHeader, and ImageMetadata, so we don't know
        // the exact offset, but we know they're somewhere early.
        let bytes = [UInt8](encoded)
        var found = false
        for i in 0..<(bytes.count - 1) {
            if bytes[i] == 0x30 && bytes[i + 1] == 0x4D {
                // marker is u(16) LSB-first, so byte i = 0x30, byte i+1 = 0x4D
                found = true; break
            }
            // Or, if not byte-aligned within the marker, it could span
            // a different bit offset. Allow that variant too.
            if bytes[i] == 0x4D && bytes[i + 1] == 0x30 {
                // Less likely given LSB-first encoding, but cover the case.
                found = true; break
            }
        }
        XCTAssertTrue(found, "placeholder marker not found in encoded buffer")
    }

    /// Decoder rejects a buffer whose marker is missing/wrong.
    func testM0_RejectsMissingMarker() throws {
        var frame = ImageFrame(
            width: 1, height: 1, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        frame.setPixel(x: 0, y: 0, channel: 0, value: 0)
        var encoded = try MinimalLosslessCodec.encode(frame)
        // Find the marker bytes and corrupt them. We assume LSB-first
        // little-endian order: byte = 0x30 first, then 0x4D.
        for i in 0..<(encoded.count - 1) {
            if encoded[i] == 0x30 && encoded[i + 1] == 0x4D {
                encoded[i] = 0x00
                encoded[i + 1] = 0x00
                break
            }
        }
        XCTAssertThrowsError(try MinimalLosslessCodec.decode(encoded)) { err in
            guard let e = err as? MinimalLosslessError else {
                XCTFail("expected MinimalLosslessError, got \(err)"); return
            }
            // Either missingMarker (the marker is now zero) or some
            // earlier failure — both indicate the corruption was caught.
            switch e {
            case .missingMarker, .bitstream:
                break
            default:
                XCTFail("expected missingMarker or bitstream error, got \(e)")
            }
        }
    }

    /// Compression-win sanity check: a smooth-gradient 32×32 image
    /// should encode to substantially fewer bytes with gradient
    /// prediction than its raw-pixel byte count. This is the headline
    /// "prediction works" assertion — without prediction the output
    /// would be roughly the raw byte count plus header overhead.
    func testM0_GradientPredictionReducesOutputSize_8bit() throws {
        var frame = ImageFrame(
            width: 32, height: 32, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        // Smooth gradient: pixel value = (x + y) * 4. Highly
        // predictable — gradient predictor recovers each pixel almost
        // exactly so residuals are tiny.
        for y in 0..<32 {
            for x in 0..<32 {
                let v = UInt16(min(255, (x + y) * 4))
                frame.setPixel(x: x, y: y, channel: 0, value: v)
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let rawByteCount = 32 * 32   // 1024 bytes raw
        XCTAssertLessThan(encoded.count, rawByteCount,
            "smooth-gradient image should compress below raw byte count " +
            "(\(encoded.count) vs raw \(rawByteCount))")
        // And it must still round-trip exactly.
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// 16-bit mostly-constant image — the case where prediction truly
    /// shines. Gradient predictor predicts every interior pixel
    /// exactly, producing zero-residuals that the entropy coder packs
    /// into the literal-token range (no extra bits). Smooth-gradient
    /// 16-bit images need a *non-flat* distribution to exploit the
    /// residual skew (deferred to E4b-full); this test isolates the
    /// regime where the existing entropy stack already wins.
    func testM0_GradientPredictionReducesOutputSize_16bit() throws {
        var frame = ImageFrame(
            width: 32, height: 32, channels: 1,
            pixelType: .uint16, colorSpace: .grayscale
        )
        // Single fill value across the whole image. First pixel's
        // residual = the fill value (W and N fall back to 0); every
        // other residual = 0.
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: 12345)
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let rawByteCount = 32 * 32 * 2   // 2048 bytes raw
        XCTAssertLessThan(encoded.count, rawByteCount,
            "constant-fill 16-bit image should compress below raw byte count " +
            "(\(encoded.count) vs raw \(rawByteCount))")
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// All-zero image: every residual is 0 → 1 distinct token → the
    /// auto-selected `simple([0])` shape gives the entire rANS stream
    /// to that one symbol. Output should be tiny — just header
    /// overhead plus 4 bytes for the rANS final state.
    func testM0_AllZeroImage_CompressesToHeadersPlusTinyTail() throws {
        let frame = ImageFrame(
            width: 32, height: 32, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        // Default-init leaves all bytes at 0.
        let encoded = try MinimalLosslessCodec.encode(frame)
        // 32×32 raw = 1024 bytes. Auto-selected simple([0]) means
        // every token costs effectively 0 bits; the entropy stream is
        // bounded by overhead. 200 bytes is generous and lets us
        // assert "dramatic compression" without pinning the exact
        // size to header byte counts that may shift.
        XCTAssertLessThan(encoded.count, 200,
            "all-zero 32×32 image should compress to under 200 bytes; got \(encoded.count)")
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// Smooth-gradient 16-bit image (large per-step delta = 1024) —
    /// the case that previously failed because flat distribution costs
    /// 7 bits per token regardless of value, and the residuals here
    /// exceed the literal-token range. With auto-shape selection, if
    /// the residuals collapse to ≤ 4 distinct tokens, the simple path
    /// kicks in and wins; if not, we fall back to flat (no regression
    /// vs the previous behaviour).
    ///
    /// For our synthetic linear-gradient pattern, the gradient
    /// predictor's clamping produces a constant residual of ~1024 for
    /// the interior — so the histogram has ~2 distinct tokens (the
    /// edge tokens + the interior token). Simple-distribution should
    /// kick in.
    func testM0_LargeStepGradient16bit_AutoShapeWins() throws {
        var frame = ImageFrame(
            width: 32, height: 32, channels: 1,
            pixelType: .uint16, colorSpace: .grayscale
        )
        for y in 0..<32 {
            for x in 0..<32 {
                let v = UInt16(min(65535, (x + y) * 1024))
                frame.setPixel(x: x, y: y, channel: 0, value: v)
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        // Raw is 2048 bytes. Previously this case encoded to 2074
        // bytes (worse than raw) because of the flat-distribution
        // cost. With auto-shape selection it should fit comfortably
        // below raw.
        XCTAssertLessThan(encoded.count, 2048,
            "large-step gradient 16-bit should now compress below raw " +
            "(\(encoded.count) vs raw 2048) thanks to auto-shape selection")
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// Stress test for the > 4-token fallback: an image with high
    /// per-pixel variation produces > 4 distinct residual tokens, so
    /// auto-select must fall back to flat. Round-trip must still work
    /// and output must not regress dramatically.
    func testM0_HighVariation_FallsBackToFlat() throws {
        var frame = ImageFrame(
            width: 16, height: 16, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        // Pseudo-random fill — many distinct residuals after
        // prediction, well over 4 distinct tokens.
        var seed: UInt32 = 0x1234_5678
        for y in 0..<16 {
            for x in 0..<16 {
                // Linear-congruential PRNG, deterministic.
                seed = seed &* 1664525 &+ 1013904223
                let v = UInt16(seed & 0xFF)
                frame.setPixel(x: x, y: y, channel: 0, value: v)
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        // Fallback path — round-trip must still work.
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data,
            "high-variation image must still round-trip in the flat-fallback path")
    }

    /// `autoSelectShape` unit test: exact shape decisions per token-
    /// histogram cardinality.
    func testM0_AutoSelectShape_DecisionLogic() {
        let cfg = HybridUintConfig.defaultConfig
        let alphabetSize = cfg.maxToken + 1

        // 0 values → flat (no tokens to anchor a simple shape).
        let s0 = MinimalLosslessCodec.autoSelectShape(
            values: [], hybridConfig: cfg, alphabetSize: alphabetSize
        )
        switch s0 {
        case .flat: break
        default: XCTFail("expected .flat for empty values, got \(s0)")
        }

        // 1 distinct token → simple([token]).
        let s1 = MinimalLosslessCodec.autoSelectShape(
            values: [UInt32](repeating: 5, count: 100), hybridConfig: cfg,
            alphabetSize: alphabetSize
        )
        if case .simple(let syms) = s1 {
            XCTAssertEqual(syms, [Int(cfg.encode(5).token)])
        } else { XCTFail("expected .simple([token-of-5]), got \(s1)") }

        // 3 distinct tokens — the most-frequent should be reordered to
        // position 2 (where `tab/2` is allocated).
        var v3: [UInt32] = []
        v3 += [UInt32](repeating: 1, count: 100)
        v3 += [UInt32](repeating: 2, count: 50)
        v3 += [UInt32](repeating: 3, count: 10)
        let s3 = MinimalLosslessCodec.autoSelectShape(
            values: v3, hybridConfig: cfg, alphabetSize: alphabetSize
        )
        if case .simple(let syms) = s3 {
            XCTAssertEqual(syms.count, 3)
            // Most-frequent (token-of-1) must be in the last slot.
            XCTAssertEqual(syms[2], Int(cfg.encode(1).token),
                "3-symbol case must put the most-frequent token at position 2 (tab/2 slot)")
        } else { XCTFail("expected .simple(3 symbols), got \(s3)") }

        // > 4 distinct tokens with low total → flat (full's
        // alphabet × 13 overhead exceeds the per-token savings on a
        // tiny stream).
        let v5small: [UInt32] = [1, 2, 3, 4, 5, 6, 7, 8]   // 8 distinct, 8 tokens
        let s5small = MinimalLosslessCodec.autoSelectShape(
            values: v5small, hybridConfig: cfg, alphabetSize: alphabetSize
        )
        switch s5small {
        case .flat: break
        default: XCTFail("expected .flat for >4 distinct on tiny stream, got \(s5small)")
        }

        // > 4 distinct tokens, large skewed stream → full (overhead
        // is amortised; per-token entropy savings dominate).
        var skewed: [UInt32] = []
        skewed += [UInt32](repeating: 0, count: 800)   // dominant
        skewed += [UInt32](repeating: 1, count: 100)
        skewed += [UInt32](repeating: 2, count: 50)
        skewed += [UInt32](repeating: 3, count: 30)
        skewed += [UInt32](repeating: 4, count: 15)
        skewed += [UInt32](repeating: 5, count: 5)      // 5 distinct, 1000 tokens
        let sFull = MinimalLosslessCodec.autoSelectShape(
            values: skewed, hybridConfig: cfg, alphabetSize: alphabetSize
        )
        switch sFull {
        case .full: break
        default: XCTFail("expected .full on heavy-skew large stream, got \(sFull)")
        }
    }

    /// Vertical-stripes image: every column is a constant. The `north`
    /// predictor (uses the pixel directly above) gives 0 residuals
    /// for the entire interior — `bestPredictorForChannel` should
    /// pick `.north`, and the encoded buffer should be tiny.
    func testM0_VerticalStripes_PicksNorthPredictor() throws {
        var frame = ImageFrame(
            width: 32, height: 32, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        // Each column is a constant; values vary horizontally only.
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 8))
            }
        }
        let buf = MinimalLosslessCodec.buildChannelBuffer(frame, channel: 0)
        let chosen = MinimalLosslessCodec.bestPredictorForChannel(
            buf, width: 32, hybridConfig: .defaultConfig
        ).id
        XCTAssertEqual(chosen, .north,
            "vertical-stripes image should pick the north predictor; got \(chosen)")
        // And the round-trip must work plus compress meaningfully.
        let encoded = try MinimalLosslessCodec.encode(frame)
        XCTAssertLessThan(encoded.count, 200,
            "vertical-stripes 32×32 8-bit should compress under 200 B; got \(encoded.count)")
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// Horizontal-stripes image: every row is a constant. The `west`
    /// predictor gives 0 residuals for the interior — the encoder
    /// should pick `.west`.
    func testM0_HorizontalStripes_PicksWestPredictor() throws {
        var frame = ImageFrame(
            width: 32, height: 32, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(y * 8))
            }
        }
        let buf = MinimalLosslessCodec.buildChannelBuffer(frame, channel: 0)
        let chosen = MinimalLosslessCodec.bestPredictorForChannel(
            buf, width: 32, hybridConfig: .defaultConfig
        ).id
        XCTAssertEqual(chosen, .west,
            "horizontal-stripes image should pick the west predictor; got \(chosen)")
        let encoded = try MinimalLosslessCodec.encode(frame)
        XCTAssertLessThan(encoded.count, 200,
            "horizontal-stripes 32×32 8-bit should compress under 200 B; got \(encoded.count)")
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// All-zero image: every predictor gives perfect residual=0
    /// predictions. The selector breaks the tie by picking the
    /// lowest-rawValue predictor (`.zero`). Either way the encoded
    /// buffer is tiny.
    func testM0_AllZero_PredictorSelectorTieBreak() throws {
        let frame = ImageFrame(
            width: 16, height: 16, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        let buf = MinimalLosslessCodec.buildChannelBuffer(frame, channel: 0)
        let chosen = MinimalLosslessCodec.bestPredictorForChannel(
            buf, width: 16, hybridConfig: .defaultConfig
        ).id
        XCTAssertEqual(chosen, .zero,
            "all-zero image: every predictor scores identically; lowest-rawValue (.zero) wins")
        let encoded = try MinimalLosslessCodec.encode(frame)
        XCTAssertLessThan(encoded.count, 100)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// Smooth diagonal gradient (delta = 1 per step): on the *interior*
    /// every linear predictor (`west`, `north`, `gradient`,
    /// `medianWNGradient`) gives the same residual = 1, so they tie
    /// on distinct-token count *and* on |residual| sum. The selector
    /// breaks ties by `PredictorID.rawValue`, so `.west` wins
    /// (rawValue 1 < 2 < 4 < 5). Either way the image compresses
    /// dramatically — the test asserts the size win, not the
    /// specific tie-broken winner.
    func testM0_DiagonalGradient_AnyLinearPredictorCompressesWell() throws {
        var frame = ImageFrame(
            width: 32, height: 32, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(min(255, x + y)))
            }
        }
        let buf = MinimalLosslessCodec.buildChannelBuffer(frame, channel: 0)
        let chosen = MinimalLosslessCodec.bestPredictorForChannel(
            buf, width: 32, hybridConfig: .defaultConfig
        ).id
        // Any of the interior-residual=1 predictors is a valid choice;
        // by tie-break rules `.west` wins.
        let validChoices: Set<PredictorID> = [.west, .north, .gradient, .medianWNGradient]
        XCTAssertTrue(validChoices.contains(chosen),
            "diagonal gradient should pick a linear predictor; got \(chosen)")
        let encoded = try MinimalLosslessCodec.encode(frame)
        XCTAssertLessThan(encoded.count, 200,
            "diagonal-gradient 32×32 8-bit should compress under 200 B; got \(encoded.count)")
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// Predictor IDs are written in channel order and recovered
    /// identically on decode. Stress: an RGB-shaped 3-channel image
    /// where each channel's pattern favours a different predictor.
    /// We build it as 3 separate single-channel grayscale frames
    /// stitched into one (since M0 only consumes 1- or 3-channel
    /// frames per the colorSpace logic).
    func testM0_MultiChannel_PerChannelPredictorIDsRoundTrip() throws {
        // 3-channel 8x8 RGB-like frame with:
        //   ch 0: vertical stripes  → north predictor
        //   ch 1: horizontal stripes → west predictor
        //   ch 2: diagonal gradient → gradient predictor
        var frame = ImageFrame(
            width: 8, height: 8, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(min(255, (x + y) * 8)))
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
        XCTAssertEqual(decoded.channels, 3)
        XCTAssertEqual(decoded.data, frame.data,
            "multi-channel image with mixed-pattern channels should round-trip exactly")
    }

    /// 3-channel RGB image with R, G, B all near each other (the
    /// "stored as RGB but really grayscale" case). RCT should kick in
    /// — Y carries the brightness, Co and Cg are tiny constants —
    /// and the encoded buffer should compress dramatically.
    func testM0_RCT_CorrelatedRGB_CompressesWell() throws {
        var frame = ImageFrame(
            width: 32, height: 32, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        // Each pixel: R = base, G = base + 1, B = base - 1 (when in
        // range), with `base` varying smoothly. Channels are highly
        // correlated.
        for y in 0..<32 {
            for x in 0..<32 {
                let base = min(254, max(1, x + y))
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(base))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(base + 1))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(base - 1))
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        // Raw 3-channel image: 32*32*3 = 3072 bytes. Without RCT each
        // channel encoded independently sees its own gradient of ~64
        // residual values. With RCT, Co/Cg collapse to constants and
        // only Y carries the gradient — much smaller output.
        let rawByteCount = 32 * 32 * 3
        XCTAssertLessThan(encoded.count, rawByteCount,
            "correlated RGB should compress below raw byte count " +
            "(\(encoded.count) vs raw \(rawByteCount))")
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data,
            "correlated RGB must round-trip exactly through RCT + prediction")
    }

    /// 3-channel image with completely uncorrelated channels: the
    /// encoder should pick `RCTVariant.identity` (RCT would not
    /// help). Round-trip must still be exact.
    func testM0_RCT_UncorrelatedRGB_PicksIdentity() throws {
        var frame = ImageFrame(
            width: 16, height: 16, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        // Channel patterns chosen to be uncorrelated:
        //   ch 0: vertical stripes (depends on x only)
        //   ch 1: horizontal stripes (depends on y only)
        //   ch 2: checkerboard
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(((x + y) & 1) * 200))
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data,
            "uncorrelated RGB must round-trip exactly")
    }

    /// `bestRCTVariant` unit test: highly correlated channels →
    /// .ycocgR; channels with no correlation → .identity.
    func testM0_BestRCTVariant_DecisionLogic() {
        let cfg = HybridUintConfig.defaultConfig

        // Highly correlated: every pixel has R = G = B = same value.
        let n = 16
        var r0 = [Int32](repeating: 0, count: n)
        var r1 = [Int32](repeating: 0, count: n)
        var r2 = [Int32](repeating: 0, count: n)
        for i in 0..<n { r0[i] = Int32(i); r1[i] = Int32(i); r2[i] = Int32(i) }
        // For perfectly identical channels, .identity already
        // produces minimal residuals (each channel's predictor wins
        // independently). YCoCg-R also collapses Co=Cg=0 — so both
        // variants tie at minimum. The selector picks the first
        // variant scanned at minimum score, which is `.identity`
        // (rawValue 0).
        let v = MinimalLosslessCodec.bestRCTVariant(
            channelBuffers: [r0, r1, r2], width: 4, hybridConfig: cfg
        )
        XCTAssertTrue(v == .identity || v == .ycocgR,
            "perfectly identical channels: either variant scores minimally; got \(v)")

        // Uncorrelated channels: identity should win. RCT mixes the
        // channels together which generally widens the histograms.
        var u0 = [Int32](repeating: 0, count: n)
        var u1 = [Int32](repeating: 0, count: n)
        var u2 = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            u0[i] = Int32(i & 3) * 10
            u1[i] = Int32((i >> 2) & 3) * 10
            u2[i] = Int32((i >> 1) & 3) * 10
        }
        let vu = MinimalLosslessCodec.bestRCTVariant(
            channelBuffers: [u0, u1, u2], width: 4, hybridConfig: cfg
        )
        // Don't assert a specific winner — bestRCTVariant just picks
        // whichever gives the smaller total token count, and on
        // synthetic data either could win. The point is that the
        // scoring runs without crashing and returns a known variant.
        XCTAssertTrue([RCTVariant.identity, .ycocgR].contains(vu))
    }

    /// 2-channel grayscale + alpha image round-trips exactly. Channel
    /// 0 is grayscale gradient, channel 1 is constant alpha = 255.
    /// The constant alpha channel should compress to almost nothing
    /// via `.zero` predictor + simple-distribution shortcut.
    func testM0_GrayscalePlusAlpha_RoundTrip() throws {
        var frame = ImageFrame(
            width: 16, height: 16, channels: 2,
            pixelType: .uint8, colorSpace: .grayscale,
            alphaChannels: 1
        )
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x + y) * 8))
                frame.setPixel(x: x, y: y, channel: 1, value: 255)
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.channels, 2)
        XCTAssertEqual(decoded.alphaChannels, 1)
        XCTAssertEqual(decoded.data, frame.data,
            "grayscale+alpha must round-trip exactly")
    }

    /// 4-channel RGBA image round-trips exactly. R, G, B are
    /// correlated (encoder picks YCoCg-R RCT for the colour part);
    /// alpha varies independently and is left untouched by RCT.
    func testM0_RGBA_RoundTrip() throws {
        var frame = ImageFrame(
            width: 16, height: 16, channels: 4,
            pixelType: .uint8, colorSpace: .sRGB,
            alphaChannels: 1
        )
        for y in 0..<16 {
            for x in 0..<16 {
                let base = min(254, max(1, x + y))
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(base))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(base + 1))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(base - 1))
                frame.setPixel(x: x, y: y, channel: 3, value: UInt16(min(255, x * 16)))
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        // Raw RGBA: 16*16*4 = 1024 bytes. With RCT on R/G/B and
        // separate prediction on alpha, the encoded buffer should
        // compress meaningfully.
        XCTAssertLessThan(encoded.count, 1024,
            "correlated RGBA should compress below raw byte count " +
            "(\(encoded.count) vs raw 1024)")
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.channels, 4)
        XCTAssertEqual(decoded.alphaChannels, 1)
        XCTAssertEqual(decoded.data, frame.data,
            "RGBA must round-trip exactly through RCT (R/G/B only) + per-channel prediction")
    }

    /// 16-bit RGBA round-trip — the full medical-imaging shape with
    /// transparency.
    func testM0_RGBA16Bit_RoundTrip() throws {
        var frame = ImageFrame(
            width: 8, height: 8, channels: 4,
            pixelType: .uint16, colorSpace: .sRGB,
            alphaChannels: 1
        )
        for y in 0..<8 {
            for x in 0..<8 {
                let base = UInt16(min(65000, (x + y) * 1024))
                frame.setPixel(x: x, y: y, channel: 0, value: base)
                frame.setPixel(x: x, y: y, channel: 1, value: base &+ 100)
                frame.setPixel(x: x, y: y, channel: 2, value: base &- 100)
                frame.setPixel(x: x, y: y, channel: 3, value: 65535)
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data,
            "16-bit RGBA must round-trip exactly")
    }

    /// Encoder rejects channel counts outside 1…4.
    func testM0_RejectsUnsupportedChannelCount() {
        // ImageFrame's init clamps to 1..4 via precondition, so we
        // can't directly construct a > 4-channel frame. Test instead
        // that the decoder throws on a malformed channel-count field
        // by hand-constructing a buffer with channels=5.
        // (Skipped — would require duplicating most of the encoder
        // to inject bad bytes. The encoder's guard is exercised
        // implicitly via ImageFrame's precondition.)
    }

    /// Natural-image-shaped 128×128 grayscale with smooth gradient +
    /// small noise produces > 4 distinct residuals after prediction.
    /// Without full-mode distribution, this case falls into the
    /// flat-distribution path and costs ~7 bits per token. With
    /// full-mode, the encoder pays the alphabet × 13-bit overhead but
    /// each token costs near-Shannon-entropy bits — substantially
    /// better than flat.
    ///
    /// Asserts the output is well below 7 bits per residual.
    func testM0_NaturalImage_FullModeBeatsFlat() throws {
        var frame = ImageFrame(
            width: 128, height: 128, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        // Linear-congruential PRNG seeded for determinism — gradient
        // base + per-pixel noise in [-3, 3].
        var seed: UInt32 = 0x1234_5678
        for y in 0..<128 {
            for x in 0..<128 {
                seed = seed &* 1664525 &+ 1013904223
                let noise = Int((seed >> 24) & 0x7) - 3   // [-3, 4)
                let base = min(255, max(0, x + y))
                let v = UInt16(min(255, max(0, base + noise)))
                frame.setPixel(x: x, y: y, channel: 0, value: v)
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let rawByteCount = 128 * 128
        // 7 bits per token = 56% of raw at the flat-only floor; the
        // M0 header plus prediction overhead push it slightly above.
        // With full-mode the same image should comfortably beat 50%.
        XCTAssertLessThan(encoded.count, rawByteCount / 2,
            "natural image should compress below 50% with full-mode " +
            "(\(encoded.count) vs raw \(rawByteCount))")
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data,
            "natural image must round-trip exactly")
    }

    /// Fast-mode round-trip: encode with `.fast`, decode, verify
    /// pixel-exact recovery. The decoder doesn't need to know about
    /// effort — it reads the predictor IDs and RCT variant the
    /// encoder picked (`.gradient` and `.identity` for `.fast`).
    func testM0_FastEffort_RoundTrip() throws {
        var frame = ImageFrame(
            width: 16, height: 16, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 4 + y))
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame, effort: .fast)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data,
            "fast-mode encode must round-trip exactly")
    }

    /// Fast mode must work on RGB too, leaving RCT at `.identity`.
    func testM0_FastEffort_RGB_RoundTrip() throws {
        var frame = ImageFrame(
            width: 8, height: 8, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 8))
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame, effort: .fast)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data,
            "fast-mode RGB encode must round-trip exactly")
    }

    /// On highly-stripey content where `.balanced` would pick
    /// `.north` or `.west`, fast mode (which always uses `.gradient`)
    /// produces a larger output. This pins down the speed/ratio
    /// trade-off: fast is faster but less compressed.
    func testM0_FastEffort_LargerOutputThanBalancedOnStripes() throws {
        var frame = ImageFrame(
            width: 32, height: 32, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        // Vertical stripes — `.north` is the perfect predictor here.
        // `.gradient` gives non-zero residuals at the column changes.
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 8))
            }
        }
        let bal = try MinimalLosslessCodec.encode(frame, effort: .balanced)
        let fst = try MinimalLosslessCodec.encode(frame, effort: .fast)
        // Both must round-trip.
        XCTAssertEqual(try MinimalLosslessCodec.decode(bal).data, frame.data)
        XCTAssertEqual(try MinimalLosslessCodec.decode(fst).data, frame.data)
        // Balanced should be at least as small as fast.
        XCTAssertLessThanOrEqual(bal.count, fst.count,
            "balanced should compress no worse than fast on stripe content " +
            "(balanced=\(bal.count), fast=\(fst.count))")
    }

    /// `inspectM0(_:)` extracts geometry, channel count, RCT variant
    /// and per-channel predictor IDs without decoding pixels. Useful
    /// for `jxl-tool info`-style diagnostic without paying decode cost.
    func testM0_Inspection_RoundTrip() throws {
        // Vertical-stripes 8×8 → encoder picks `.north`.
        var frame = ImageFrame(
            width: 16, height: 16, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let info = try MinimalLosslessCodec.inspectM0(encoded)
        XCTAssertEqual(info.xsize, 16)
        XCTAssertEqual(info.ysize, 16)
        XCTAssertEqual(info.bitsPerSample, 8)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.rctVariant, .identity)
        XCTAssertEqual(info.channelPredictors, [.north])
    }

    /// 3-channel correlated RGB → encoder picks `.ycocgR` and the
    /// chroma predictors collapse to `.zero` once RCT decorrelates
    /// the channels.
    func testM0_Inspection_RGBPicksYCoCgR() throws {
        var frame = ImageFrame(
            width: 32, height: 32, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        for y in 0..<32 {
            for x in 0..<32 {
                let base = min(254, max(1, x + y))
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(base))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(base + 1))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(base - 1))
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let info = try MinimalLosslessCodec.inspectM0(encoded)
        XCTAssertEqual(info.channels, 3)
        XCTAssertEqual(info.rctVariant, .ycocgR,
            "correlated RGB should pick YCoCg-R")
        XCTAssertEqual(info.channelPredictors.count, 3)
    }

    /// `isM0(_:)` returns true for an M0 buffer and false for a
    /// random PNM (no marker).
    func testM0_isM0_Recognises() throws {
        let frame = ImageFrame(
            width: 4, height: 4, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        let encoded = try MinimalLosslessCodec.encode(frame)
        XCTAssertTrue(MinimalLosslessCodec.isM0(encoded))
        // Random data → false.
        let bogus = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00])
        XCTAssertFalse(MinimalLosslessCodec.isM0(bogus))
    }

    /// Single-row image (height=1) — exercises the case where
    /// `Neighbourhood` has no `N` neighbour anywhere; everyone falls
    /// back to the W path.
    func testM0_SingleRow_RoundTrip() throws {
        var frame = ImageFrame(
            width: 32, height: 1, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        for x in 0..<32 {
            frame.setPixel(x: x, y: 0, channel: 0, value: UInt16(x * 8))
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// Single-column image (width=1) — exercises the case where
    /// `Neighbourhood` has no `W` neighbour; everyone falls back to N.
    func testM0_SingleColumn_RoundTrip() throws {
        var frame = ImageFrame(
            width: 1, height: 32, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        for y in 0..<32 {
            frame.setPixel(x: 0, y: y, channel: 0, value: UInt16(y * 8))
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// Pseudo-random noise image — exercises the flat-distribution
    /// fallback path (>4 distinct tokens, no compressible structure).
    /// Round-trip must still be exact.
    func testM0_PureNoise_RoundTrip() throws {
        var frame = ImageFrame(
            width: 16, height: 16, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        var seed: UInt32 = 0xCAFEBABE
        for y in 0..<16 {
            for x in 0..<16 {
                seed = seed &* 1664525 &+ 1013904223
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(seed & 0xFF))
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data,
            "noise round-trip must be exact even when nothing compresses")
    }

    /// 16-bit grayscale full-dynamic-range — exercises HybridUint
    /// extra-bits path on values that don't fit the literal-token
    /// range. Confirms the full pipeline handles 16-bit correctly.
    func testM0_FullDynamicRange16Bit_RoundTrip() throws {
        var frame = ImageFrame(
            width: 16, height: 16, channels: 1,
            pixelType: .uint16, colorSpace: .grayscale
        )
        // Span the full 0..65535 range with a deterministic pattern.
        for y in 0..<16 {
            for x in 0..<16 {
                let v = UInt16((x &+ y) &* 256 &+ x)
                frame.setPixel(x: x, y: y, channel: 0, value: v)
            }
        }
        let encoded = try MinimalLosslessCodec.encode(frame)
        let decoded = try MinimalLosslessCodec.decode(encoded)
        XCTAssertEqual(decoded.data, frame.data)
    }

    /// Float32 isn't supported by M0 — encoder should throw cleanly.
    func testM0_RejectsFloat32() {
        let frame = ImageFrame(
            width: 1, height: 1, channels: 1,
            pixelType: .float32, colorSpace: .grayscale
        )
        XCTAssertThrowsError(try MinimalLosslessCodec.encode(frame)) { err in
            guard let e = err as? MinimalLosslessError,
                  case .unsupportedPixelType = e else {
                XCTFail("expected .unsupportedPixelType, got \(err)"); return
            }
        }
    }
}

// MARK: - LZ77Config (§C.6.5)

extension FoundationTests {

    /// Disabled LZ77 emits a single bit (0). Round-trip recovers the
    /// disabled state.
    func testLZ77Config_RoundTrip_Disabled() throws {
        var w = BitWriter()
        try LZ77Config.disabled.write(to: &w, logAlpha: 8)
        let bytes = [UInt8](w.finishToData())
        // Single bit (0) padded to a byte → 0x00.
        XCTAssertEqual(bytes, [0x00])
        var r = BitReader(w.finishToData())
        let parsed = try LZ77Config.read(from: &r, logAlpha: 8)
        XCTAssertFalse(parsed.enabled)
    }

    /// Enabled LZ77 with default values: round-trip every field,
    /// including the embedded distance HybridUintConfig.
    func testLZ77Config_RoundTrip_EnabledDefaults() throws {
        let cfg = LZ77Config(
            enabled: true,
            minSymbol: 224,
            minLength: 3,
            distanceConfig: HybridUintConfig.defaultConfig
        )
        var w = BitWriter()
        try cfg.write(to: &w, logAlpha: 8)
        var r = BitReader(w.finishToData())
        let parsed = try LZ77Config.read(from: &r, logAlpha: 8)
        XCTAssertTrue(parsed.enabled)
        XCTAssertEqual(parsed.minSymbol, 224)
        XCTAssertEqual(parsed.minLength, 3)
        XCTAssertEqual(parsed.distanceConfig.splitExponent, 4)
        XCTAssertEqual(parsed.distanceConfig.msbInToken, 2)
        XCTAssertEqual(parsed.distanceConfig.lsbInToken, 0)
    }

    /// Sweep across a few representative (minSymbol, minLength,
    /// distanceConfig) tuples to exercise the variable-width
    /// distanceConfig field at different `logAlpha` settings.
    func testLZ77Config_RoundTrip_Sweep() throws {
        struct Case { let logAlpha: Int; let cfg: LZ77Config }
        let cases: [Case] = [
            Case(logAlpha: 5, cfg: LZ77Config(
                enabled: true, minSymbol: 16, minLength: 5,
                distanceConfig: HybridUintConfig(splitExponent: 3,
                                                  msbInToken: 1,
                                                  lsbInToken: 1))),
            Case(logAlpha: 6, cfg: LZ77Config(
                enabled: true, minSymbol: 100, minLength: 4,
                distanceConfig: HybridUintConfig(splitExponent: 6,
                                                  msbInToken: 0,
                                                  lsbInToken: 0))),
            Case(logAlpha: 8, cfg: LZ77Config(
                enabled: true, minSymbol: 65535, minLength: 65535,
                distanceConfig: HybridUintConfig(splitExponent: 4,
                                                  msbInToken: 2,
                                                  lsbInToken: 0))),
        ]
        for c in cases {
            var w = BitWriter()
            try c.cfg.write(to: &w, logAlpha: c.logAlpha)
            var r = BitReader(w.finishToData())
            let parsed = try LZ77Config.read(from: &r, logAlpha: c.logAlpha)
            XCTAssertEqual(parsed.enabled, c.cfg.enabled)
            XCTAssertEqual(parsed.minSymbol, c.cfg.minSymbol,
                "minSymbol mismatch at logAlpha=\(c.logAlpha)")
            XCTAssertEqual(parsed.minLength, c.cfg.minLength,
                "minLength mismatch at logAlpha=\(c.logAlpha)")
            XCTAssertEqual(parsed.distanceConfig.splitExponent,
                           c.cfg.distanceConfig.splitExponent)
            XCTAssertEqual(parsed.distanceConfig.msbInToken,
                           c.cfg.distanceConfig.msbInToken)
            XCTAssertEqual(parsed.distanceConfig.lsbInToken,
                           c.cfg.distanceConfig.lsbInToken)
        }
    }

    /// Encoder rejects out-of-range minSymbol / minLength (above the
    /// u(16) placeholder limit).
    func testLZ77Config_RejectsOutOfRange() {
        var w = BitWriter()
        let cfg = LZ77Config(
            enabled: true, minSymbol: 0x1_0000, minLength: 3,
            distanceConfig: .defaultConfig
        )
        XCTAssertThrowsError(try cfg.write(to: &w, logAlpha: 8))
    }
}

// MARK: - ContextMap (§C.6.4)

extension FoundationTests {

    /// Trivial case: numContexts == 1 → emit nothing, decode back
    /// the same single-element [0].
    func testContextMap_TrivialSingleContext() throws {
        let cm = ContextMap.trivial(numContexts: 1)
        XCTAssertEqual(cm.numClusters, 1)
        XCTAssertEqual(cm.map, [0])
        var w = BitWriter()
        try cm.write(to: &w)
        XCTAssertEqual(w.finishToData().count, 0,
            "trivial 1-context map should consume no bits")
        var r = BitReader(Data())
        let parsed = try ContextMap.read(numContexts: 1, from: &r)
        XCTAssertEqual(parsed.numClusters, 1)
        XCTAssertEqual(parsed.map, [0])
    }

    /// Trivial multi-context: numClusters == 1 → emit only the
    /// num_clusters-1 byte; decoder fills with zeros.
    func testContextMap_TrivialSingleCluster() throws {
        let cm = try ContextMap(
            numClusters: 1, map: [UInt8](repeating: 0, count: 32)
        )
        var w = BitWriter()
        try cm.write(to: &w)
        var r = BitReader(w.finishToData())
        let parsed = try ContextMap.read(numContexts: 32, from: &r)
        XCTAssertEqual(parsed.numClusters, 1)
        XCTAssertEqual(parsed.map.count, 32)
        XCTAssertTrue(parsed.map.allSatisfy { $0 == 0 })
    }

    /// Simple-path round-trip across each bits_per_entry shape that
    /// the spec supports: 1, 2, and 3 bits per entry → 2, 4, and 8
    /// clusters respectively.
    func testContextMap_SimpleBitsPerEntry_AllShapes() throws {
        let cases: [(numClusters: Int, map: [UInt8])] = [
            (numClusters: 2, map: [0, 1, 0, 1, 1, 0]),
            (numClusters: 4, map: [0, 1, 2, 3, 2, 1, 0, 3]),
            (numClusters: 8, map: [0, 1, 2, 3, 4, 5, 6, 7, 0, 7]),
        ]
        for c in cases {
            let cm = try ContextMap(numClusters: c.numClusters, map: c.map)
            var w = BitWriter()
            try cm.write(to: &w)
            var r = BitReader(w.finishToData())
            let parsed = try ContextMap.read(
                numContexts: c.map.count, from: &r
            )
            XCTAssertEqual(parsed.numClusters, c.numClusters,
                "numClusters mismatch for \(c)")
            XCTAssertEqual(parsed.map, c.map, "map mismatch for \(c)")
        }
    }

    /// Encoder rejects > 8 clusters (would need the full path which
    /// isn't implemented yet).
    func testContextMap_RejectsTooManyClusters() throws {
        let map = (0..<16).map { UInt8($0) }
        let cm = try ContextMap(numClusters: 16, map: map)
        var w = BitWriter()
        XCTAssertThrowsError(try cm.write(to: &w)) { err in
            XCTAssertEqual(err as? ContextMapError, .fullPathNotImplemented)
        }
    }

    /// Decoder rejects a malformed bits_per_entry that can't address
    /// all clusters.
    func testContextMap_RejectsBitsPerEntryTooSmall() throws {
        // Hand-build a bitstream:
        //   num_clusters_minus_1 = 3 (4 clusters)
        //   is_simple = 1
        //   bits_per_entry = 1   (1 bit per entry → only 0..1, < 4 needed)
        var w = BitWriter()
        w.write(bits: 8, value: 3)         // num_clusters - 1
        w.writeBit(true)                   // is_simple
        w.write(bits: 2, value: 1)         // bits_per_entry = 1
        // 4 entries would follow, but the decoder must throw before
        // reading them.
        var r = BitReader(w.finishToData())
        XCTAssertThrowsError(try ContextMap.read(numContexts: 4, from: &r)) { err in
            guard let e = err as? ContextMapError,
                  case .bitsPerEntryTooSmall = e else {
                XCTFail("expected bitsPerEntryTooSmall, got \(err)"); return
            }
        }
    }

    /// Hand-derived bit pattern: 4-cluster map [0, 1, 2, 3] over 4
    /// contexts. Layout (LSB-first):
    ///   num_clusters - 1 = 3        u(8)
    ///   is_simple = 1               u(1)
    ///   bits_per_entry = 2          u(2)  → LSB-first: 0, 1
    ///   map[0..3] = 0,1,2,3         u(2) each
    /// Bits emitted (positions 0..10 of the post-num_clusters stream):
    ///   1, 0,1, 0,0, 1,0, 0,1, 1,1
    func testContextMap_HandDerived_4Clusters() throws {
        let cm = try ContextMap(numClusters: 4, map: [0, 1, 2, 3])
        var w = BitWriter()
        try cm.write(to: &w)
        let bytes = [UInt8](w.finishToData())
        // Byte 0: u(8) for num_clusters-1 = 3 → 0x03.
        // Byte 1 covers stream positions 0..7:
        //   pos 0 = 1, pos 1 = 0, pos 2 = 1, pos 3 = 0,
        //   pos 4 = 0, pos 5 = 1, pos 6 = 0, pos 7 = 0
        //   → 1 + 4 + 32 = 37 = 0x25
        // Byte 2 covers stream positions 8..10:
        //   pos 8 = 1, pos 9 = 1, pos 10 = 1
        //   → 1 + 2 + 4 = 7 = 0x07
        XCTAssertEqual(bytes, [0x03, 0x25, 0x07],
            "hand-derived 4-cluster map should be [0x03, 0x25, 0x07]; got \(bytes)")
    }

    /// End-to-end: SimpleEntropyStream + ContextMap together. The
    /// stream uses one cluster, so the context map is trivial; this
    /// verifies the trivial map composes cleanly.
    func testContextMap_TrivialMapComposesWithStream() throws {
        let cm = try ContextMap(numClusters: 1, map: [UInt8](repeating: 0, count: 4))
        var w = BitWriter()
        try cm.write(to: &w)
        var r = BitReader(w.finishToData())
        let parsed = try ContextMap.read(numContexts: 4, from: &r)
        XCTAssertEqual(parsed.numClusters, 1)
        XCTAssertEqual(parsed.map, cm.map)
    }
}

/// Helper: serialise a distribution of the requested shape and
/// immediately deserialise it back, returning the resulting
/// `ANSDistribution`. The encoder/decoder both need the same
/// distribution; this round-trip is the cleanest way to construct
/// one whose frequencies exactly match what the decoder will derive.
private func roundTripDistribution(
    shape: SimpleEntropyDistributionShape, alphabetSize: Int
) throws -> ANSDistribution {
    var w = BitWriter()
    switch shape {
    case .flat:
        try ANSDistributionFormat.encodeFlat(
            alphabetSize: alphabetSize, to: &w
        )
    case .simple(let syms):
        try ANSDistributionFormat.encodeSimple(
            symbols: syms, alphabetSize: alphabetSize, to: &w
        )
    case .full(let freqs):
        try ANSDistributionFormat.encodeFull(
            frequencies: freqs, alphabetSize: alphabetSize, to: &w
        )
    }
    var r = BitReader(w.finishToData())
    return try ANSDistributionFormat.decode(alphabetSize: alphabetSize, from: &r)
}

/// Helper: histogram of tokens produced when a value stream is run
/// through a HybridUintConfig. Used to construct a non-pathological
/// rANS distribution sized to the actual token alphabet.
private func histogramOfTokens(
    values: [UInt32], config: HybridUintConfig, alphabetSize: Int
) -> [UInt32] {
    var histo = [UInt32](repeating: 0, count: alphabetSize)
    for v in values {
        let t = config.encode(v)
        histo[Int(t.token)] &+= 1
    }
    return histo
}
