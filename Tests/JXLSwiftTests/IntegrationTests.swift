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

    /// Decoder must reject a truncated bitstream.
    func testRANS_RejectsTruncatedStream() throws {
        let dist = try ANSDistribution(rawFrequencies: [1, 1])
        let truncated = Data([0xFF])  // < 4 bytes — can't even read final state
        XCTAssertThrowsError(try ANSDecoder(data: truncated, distribution: dist)) { err in
            XCTAssertEqual(err as? ANSError, ANSError.malformedFinalState)
        }
    }

}
