// Integration tests against LocalDatasets/medical-dicom-organized.
//
// These tests are skipped when the dataset isn't present (CI runners,
// freshly-cloned trees) so the suite stays green in those environments.
// On a developer machine with the symlinked dataset, they exercise:
//   • lossless round-trip pixel-exact on real medical-imagery-derived PNGs
//   • lossy compression at q=90/q=95 produces PSNR ≥ 35 dB
//   • cross-codec compatibility: libjxl's `djxl` decodes JXLSwift output
//   • cross-codec compatibility: JXLSwift decodes libjxl's `cjxl` output
//   • compression contract: lossless output is strictly smaller than raw

import XCTest
@testable import JXLSwift
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

final class IntegrationTests: XCTestCase {

    // MARK: - Dataset discovery

    /// Cached, lazily resolved on first use.
    static let datasetSamples: [URL] = locateDatasetSamples()

    /// Locate a handful of representative PNGs to drive the matrix.
    /// Strategy: prefer pre-converted PNGs at /tmp/jxl-it/png; fall back
    /// to converting a few DICOM files on the fly via ImageMagick if
    /// available. If neither path exists, return empty (all tests skip).
    private static func locateDatasetSamples() -> [URL] {
        let pngDir = URL(fileURLWithPath: "/tmp/jxl-it/png")
        if let entries = try? FileManager.default.contentsOfDirectory(at: pngDir,
                                  includingPropertiesForKeys: nil) {
            let pngs = entries.filter { $0.pathExtension.lowercased() == "png" }
                              .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            if !pngs.isEmpty { return Array(pngs.prefix(12)) }
        }
        return []
    }

    private func skipIfNoDataset() throws {
        try XCTSkipIf(IntegrationTests.datasetSamples.isEmpty,
                      "LocalDataset PNGs not present at /tmp/jxl-it/png — skipping")
    }

    // MARK: - Helpers

    #if canImport(ImageIO)
    private func loadGrayscalePNG(_ url: URL) -> ImageFrame? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        let ok = bytes.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var frame = ImageFrame(
            width: w, height: h, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale
        )
        frame.data = bytes
        return frame
    }
    #endif

    private func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        precondition(a.count == b.count)
        var sse: Double = 0
        for i in 0..<a.count {
            let d = Double(a[i]) - Double(b[i])
            sse += d * d
        }
        if sse == 0 { return .infinity }
        return 10.0 * log10(255.0 * 255.0 / (sse / Double(a.count)))
    }

    @discardableResult
    private func runProcess(_ launchPath: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return (-1, "launch failed: \(error)") }
        p.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: errData, encoding: .utf8) ?? "")
    }

    private func haveLibjxl() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/cjxl")
        && FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/djxl")
    }

    // MARK: - Lossless round-trip

    /// Lossless encode → decode must reproduce the input exactly.
    /// Run on every dataset sample.
    func testLosslessRoundTrip_PixelExact_AllSamples() throws {
        try skipIfNoDataset()
        #if !canImport(ImageIO)
        try XCTSkipIf(true, "ImageIO not available")
        #else
        for url in IntegrationTests.datasetSamples {
            guard let original = loadGrayscalePNG(url) else {
                XCTFail("could not load \(url.lastPathComponent)"); continue
            }
            let encoded = try JXLEncoder(options: EncodingOptions(
                mode: .lossless, effort: .squirrel
            )).encode(original)
            XCTAssertGreaterThan(encoded.data.count, 0,
                                 "encoder produced empty bitstream for \(url.lastPathComponent)")
            let decoded = try JXLDecoder().decode(encoded.data)
            XCTAssertEqual(decoded.width, original.width, "\(url.lastPathComponent): width")
            XCTAssertEqual(decoded.height, original.height, "\(url.lastPathComponent): height")
            XCTAssertEqual(decoded.data, original.data,
                           "\(url.lastPathComponent): lossless round-trip not pixel-exact")
        }
        #endif
    }

    /// The lossless contract: output must be strictly smaller than the raw
    /// input (which would be `width * height * channels * bytesPerSample`).
    /// JXLSwift v1 produced output ≥ 1.85× the input — the rewrite must not.
    func testLosslessOutputIsSmallerThanRawInput() throws {
        try skipIfNoDataset()
        #if !canImport(ImageIO)
        try XCTSkipIf(true, "ImageIO not available")
        #else
        for url in IntegrationTests.datasetSamples.prefix(3) {
            guard let original = loadGrayscalePNG(url) else { continue }
            let encoded = try JXLEncoder(options: EncodingOptions(
                mode: .lossless, effort: .squirrel
            )).encode(original)
            let raw = original.data.count
            XCTAssertLessThan(encoded.data.count, raw,
                "\(url.lastPathComponent): lossless output (\(encoded.data.count)) ≥ raw (\(raw))")
        }
        #endif
    }

    // MARK: - Lossy quality

    func testLossyQuality90_PSNR_AtLeast35dB() throws {
        try skipIfNoDataset()
        #if !canImport(ImageIO)
        try XCTSkipIf(true, "ImageIO not available")
        #else
        for url in IntegrationTests.datasetSamples.prefix(3) {
            guard let original = loadGrayscalePNG(url) else { continue }
            let encoded = try JXLEncoder(options: EncodingOptions(
                mode: .lossy(quality: 90), effort: .squirrel
            )).encode(original)
            let decoded = try JXLDecoder().decode(encoded.data)
            let p = psnr(original.data, decoded.data)
            XCTAssertGreaterThan(p, 35,
                "\(url.lastPathComponent): PSNR \(p) dB at q=90 below 35 dB threshold")
        }
        #endif
    }

    func testLossyDistance1_PSNR_AtLeast35dB() throws {
        try skipIfNoDataset()
        #if !canImport(ImageIO)
        try XCTSkipIf(true, "ImageIO not available")
        #else
        for url in IntegrationTests.datasetSamples.prefix(3) {
            guard let original = loadGrayscalePNG(url) else { continue }
            let encoded = try JXLEncoder(options: EncodingOptions(
                mode: .distance(1.0), effort: .squirrel
            )).encode(original)
            let decoded = try JXLDecoder().decode(encoded.data)
            let p = psnr(original.data, decoded.data)
            XCTAssertGreaterThan(p, 35,
                "\(url.lastPathComponent): PSNR \(p) dB at distance=1.0 below 35 dB threshold")
        }
        #endif
    }

    // MARK: - Cross-codec compatibility

    /// JXLSwift-encoded files must be decodable by libjxl's `djxl`.
    /// (The defining v1 defect was that this never worked.)
    func testJXLSwiftToLibjxl_LosslessIsDecodable() throws {
        try skipIfNoDataset()
        try XCTSkipIf(!haveLibjxl(), "libjxl djxl not in /opt/homebrew/bin")
        #if !canImport(ImageIO)
        try XCTSkipIf(true, "ImageIO not available")
        #else
        let url = IntegrationTests.datasetSamples[0]
        guard let original = loadGrayscalePNG(url) else { return XCTFail("load") }
        let encoded = try JXLEncoder(options: EncodingOptions(
            mode: .lossless, effort: .squirrel
        )).encode(original)
        let jxlPath = "/tmp/jxlswift-cross-codec.jxl"
        try encoded.data.write(to: URL(fileURLWithPath: jxlPath))
        let outPath = "/tmp/jxlswift-cross-codec.djxl.png"
        let (rc, err) = runProcess("/opt/homebrew/bin/djxl", [jxlPath, outPath])
        XCTAssertEqual(rc, 0, "djxl rejected JXLSwift output: \(err)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outPath),
                      "djxl produced no output PNG")
        #endif
    }

    /// JXLSwift must decode libjxl's cjxl output.
    func testLibjxlToJXLSwift_LosslessIsDecodable() throws {
        try skipIfNoDataset()
        try XCTSkipIf(!haveLibjxl(), "libjxl cjxl not in /opt/homebrew/bin")
        let pngURL = IntegrationTests.datasetSamples[0]
        let jxlPath = "/tmp/libjxl-cross-codec.jxl"
        let (rc, err) = runProcess("/opt/homebrew/bin/cjxl",
                                   [pngURL.path, jxlPath, "-d", "0", "-e", "5"])
        XCTAssertEqual(rc, 0, "cjxl failed: \(err)")
        let encoded = try Data(contentsOf: URL(fileURLWithPath: jxlPath))
        XCTAssertNoThrow(try JXLDecoder().decode(encoded),
                         "JXLSwift could not decode libjxl-encoded output")
    }

    // MARK: - Sanity: encoded bitstream has the JXL signature

    // MARK: - DICOM (specialized: cjxl can't read this format directly)

    private static let dicomSamples: [URL] = locateDICOMSamples()

    private static func locateDICOMSamples() -> [URL] {
        let dcmRoot = URL(fileURLWithPath: "LocalDatasets/medical-dicom-organized")
        guard FileManager.default.fileExists(atPath: dcmRoot.path) else { return [] }
        let modalities = ["dx", "ct", "mg", "mr"]
        var found: [URL] = []
        for m in modalities {
            let dir = dcmRoot.appendingPathComponent(m)
            if let en = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let u as URL in en where u.pathExtension == "dcm" {
                    found.append(u)
                    if found.count >= 6 { return found }
                }
            }
        }
        return found
    }

    /// DICOM specialised path: read uncompressed monochrome `.dcm` directly,
    /// preserving the native bit depth (typically 12 bits stored in 16). This
    /// is something cjxl cannot do — it only ingests PNG/JPEG/PFM/PPM/PGM.
    func testDICOMReader_PreservesNativeBitDepth() throws {
        try XCTSkipIf(IntegrationTests.dicomSamples.isEmpty,
                      "LocalDatasets/medical-dicom-organized not present — skipping")
        for url in IntegrationTests.dicomSamples {
            let frame: ImageFrame
            do { frame = try DICOMReader.read(url) }
            catch DICOMError.unsupportedTransferSyntax {
                // Compressed DICOM — out of scope for the native reader.
                continue
            } catch {
                XCTFail("DICOM read failed for \(url.lastPathComponent): \(error)")
                continue
            }
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertEqual(frame.channels, 1, "DICOM is monochrome")
            XCTAssertEqual(frame.colorSpace, .grayscale)
            // The whole point of the specialised path: any "12-bit Stored in 16"
            // input must come back as uint16, not be silently truncated to uint8.
            // CT/DX/MR/MG in this dataset are all 12-bit.
            XCTAssertEqual(frame.pixelType, .uint16,
                "\(url.lastPathComponent): expected uint16 (12-bit DICOM in 16-bit container), got \(frame.pixelType)")
        }
    }

    /// End-to-end: read a DICOM, encode lossless, decode back, compare bytes.
    /// Confirms the encoder accepts uint16 input and the decoder returns
    /// the same uint16 buffer.
    func testDICOM_LosslessRoundTrip_16Bit() throws {
        try XCTSkipIf(IntegrationTests.dicomSamples.isEmpty, "no DICOM samples")
        guard let url = IntegrationTests.dicomSamples.first(where: {
            (try? DICOMReader.read($0)) != nil
        }) else {
            try XCTSkipIf(true, "no uncompressed DICOM in sample set")
            return
        }
        let original = try DICOMReader.read(url)
        XCTAssertEqual(original.pixelType, .uint16)
        let encoded = try JXLEncoder(options: EncodingOptions(
            mode: .lossless, effort: .squirrel
        )).encode(original)
        let decoded = try JXLDecoder().decode(encoded.data)
        XCTAssertEqual(decoded.width, original.width)
        XCTAssertEqual(decoded.height, original.height)
        XCTAssertEqual(decoded.pixelType, .uint16,
            "decoded output must keep uint16 — bit depth must round-trip")
        XCTAssertEqual(decoded.data, original.data,
            "16-bit DICOM lossless round-trip must be pixel-exact")
    }

    // MARK: - Multi-frame

    /// Encode a synthetic 3D volume as a multi-frame JXL and verify all
    /// frames round-trip pixel-exact.
    func testMultiFrameEncodeDecode_RoundTripsAllFrames() throws {
        var frames: [ImageFrame] = []
        for z in 0..<10 {
            var f = ImageFrame(width: 32, height: 32, channels: 1,
                               pixelType: .uint8, colorSpace: .grayscale)
            for y in 0..<32 {
                for x in 0..<32 {
                    f.setPixel(x: x, y: y, channel: 0,
                               value: UInt16((x * 5 + y * 3 + z * 11) % 256))
                }
            }
            frames.append(f)
        }
        let encoded = try JXLEncoder(options: EncodingOptions(
            mode: .lossless, effort: .squirrel
        )).encode(frames)
        XCTAssertGreaterThan(encoded.data.count, 0)
        let decoded = try JXLDecoder().decodeAll(encoded.data)
        XCTAssertEqual(decoded.count, frames.count, "frame count must round-trip")
        for (i, df) in decoded.enumerated() {
            XCTAssertEqual(df.data, frames[i].data,
                "frame \(i) lossless round-trip not pixel-exact")
        }
    }

    // MARK: - DICOM correctness (Phase 3a)

    /// Build a minimal Implicit-VR-LE DICOM byte stream in memory, used
    /// by the signed-pixel test below. Only sets the tags relevant to the
    /// reader's correctness checks.
    private func makeImplicitVRDICOM(
        width: Int, height: Int,
        bitsAllocated: Int = 16, bitsStored: Int = 12,
        pixelRepresentation: Int = 0,
        rescaleSlope: Double? = nil,
        rescaleIntercept: Double? = nil,
        photometric: String = "MONOCHROME2",
        pixelData: [UInt16]
    ) -> Data {
        // 128-byte preamble + 'DICM'
        var data = Data(count: 132)
        data[128] = 0x44; data[129] = 0x49; data[130] = 0x43; data[131] = 0x4D

        // File Meta Info — Explicit VR LE.
        // (0002,0000) UL group length (we'll fill at the end)
        // (0002,0010) UI TransferSyntaxUID = "1.2.840.10008.1.2" (Implicit VR LE)
        var meta = Data()
        func appendExplicit(_ group: UInt16, _ element: UInt16, vr: String, value: Data) {
            var d = Data()
            d.append(UInt8(group & 0xFF)); d.append(UInt8(group >> 8))
            d.append(UInt8(element & 0xFF)); d.append(UInt8(element >> 8))
            d.append(contentsOf: vr.utf8)
            // Short-VR length = 2 bytes for everything we use here.
            let len = UInt16(value.count)
            d.append(UInt8(len & 0xFF)); d.append(UInt8(len >> 8))
            d.append(value)
            meta.append(d)
        }
        var ts = "1.2.840.10008.1.2".data(using: .ascii)!
        if ts.count % 2 != 0 { ts.append(0) }
        appendExplicit(0x0002, 0x0010, vr: "UI", value: ts)

        // Group length placeholder; refine below.
        var gl: UInt32 = UInt32(meta.count)
        var glBytes = Data()
        for i in 0..<4 { glBytes.append(UInt8((gl >> (i * 8)) & 0xFF)) }

        var glElem = Data()
        glElem.append(UInt8(0x02)); glElem.append(UInt8(0x00))   // group 0002
        glElem.append(UInt8(0x00)); glElem.append(UInt8(0x00))   // element 0000
        glElem.append(contentsOf: "UL".utf8)
        glElem.append(UInt8(0x04)); glElem.append(UInt8(0x00))   // length 4
        glElem.append(glBytes)

        data.append(glElem)
        data.append(meta)

        // Implicit VR LE dataset: tag(4) length(4) value
        func appendImplicit(_ group: UInt16, _ element: UInt16, value: Data) {
            data.append(UInt8(group & 0xFF)); data.append(UInt8(group >> 8))
            data.append(UInt8(element & 0xFF)); data.append(UInt8(element >> 8))
            let l = UInt32(value.count)
            for i in 0..<4 { data.append(UInt8((l >> (i * 8)) & 0xFF)) }
            data.append(value)
        }
        func u16le(_ v: UInt16) -> Data {
            Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
        }
        func dsString(_ v: Double) -> Data {
            var s = String(format: "%.4f", v)
            // DS values must be even-length, ASCII.
            if s.count % 2 != 0 { s.append(" ") }
            return s.data(using: .ascii)!
        }

        appendImplicit(0x0028, 0x0002, value: u16le(1))                                  // SamplesPerPixel
        var pmi = photometric
        if pmi.count % 2 != 0 { pmi.append(" ") }
        appendImplicit(0x0028, 0x0004, value: pmi.data(using: .ascii)!)                   // Photometric
        appendImplicit(0x0028, 0x0010, value: u16le(UInt16(height)))                      // Rows
        appendImplicit(0x0028, 0x0011, value: u16le(UInt16(width)))                       // Columns
        appendImplicit(0x0028, 0x0100, value: u16le(UInt16(bitsAllocated)))               // BitsAllocated
        appendImplicit(0x0028, 0x0101, value: u16le(UInt16(bitsStored)))                  // BitsStored
        appendImplicit(0x0028, 0x0103, value: u16le(UInt16(pixelRepresentation)))         // PixelRepresentation
        if let s = rescaleSlope { appendImplicit(0x0028, 0x1053, value: dsString(s)) }
        if let i = rescaleIntercept { appendImplicit(0x0028, 0x1052, value: dsString(i)) }

        // Pixel Data (7FE0,0010) — uint16 LE
        var pixels = Data()
        for v in pixelData {
            pixels.append(UInt8(v & 0xFF))
            pixels.append(UInt8((v >> 8) & 0xFF))
        }
        appendImplicit(0x7FE0, 0x0010, value: pixels)

        return data
    }

    /// Phase 3a: signed-pixel DICOM (PixelRepresentation=1) must be biased
    /// to unsigned before being handed to libjxl. The reader does that and
    /// records the bias in `DICOMMetadata.signedBias`.
    func testDICOMReader_SignedPixels_BiasedToUnsigned() throws {
        let w = 4, h = 1
        // 12-bit signed: range [-2048, 2047]. Pixels chosen at the boundaries.
        let signedValues: [Int16] = [-2048, -1, 0, 2047]
        // Two's-complement of `bitsStored` bits, packed in 16-bit container
        // sign-extended to all 16 bits (DICOM spec §C.7.6.3).
        let stored: [UInt16] = signedValues.map {
            UInt16(bitPattern: $0)
        }
        let dcm = makeImplicitVRDICOM(
            width: w, height: h,
            bitsAllocated: 16, bitsStored: 12, pixelRepresentation: 1,
            pixelData: stored
        )
        let (frame, meta) = try DICOMReader.parseWithMetadata(dcm)
        XCTAssertEqual(meta.pixelRepresentation, 1)
        XCTAssertEqual(meta.signedBias, 1 << 11) // 2048
        // After bias, [-2048, -1, 0, 2047] becomes [0, 2047, 2048, 4095].
        XCTAssertEqual(frame.getPixel(x: 0, y: 0, channel: 0), 0)
        XCTAssertEqual(frame.getPixel(x: 1, y: 0, channel: 0), 2047)
        XCTAssertEqual(frame.getPixel(x: 2, y: 0, channel: 0), 2048)
        XCTAssertEqual(frame.getPixel(x: 3, y: 0, channel: 0), 4095)
    }

    /// Phase 3a: RescaleSlope/Intercept (Modality LUT) extraction from a
    /// synthetic CT-style DICOM. The reader does NOT apply the LUT — that
    /// would alter pixel values and break lossless encoding — but it
    /// surfaces the constants so callers can interpret stored values
    /// correctly.
    func testDICOMReader_RescaleSlopeIntercept_Extracted() throws {
        let dcm = makeImplicitVRDICOM(
            width: 4, height: 1,
            bitsAllocated: 16, bitsStored: 12,
            rescaleSlope: 1.0, rescaleIntercept: -1024.0,
            pixelData: [0, 1024, 2048, 4095]
        )
        let (_, meta) = try DICOMReader.parseWithMetadata(dcm)
        XCTAssertEqual(meta.rescaleSlope, 1.0)
        XCTAssertEqual(meta.rescaleIntercept, -1024.0)
    }

    /// 16-bit multi-frame round-trip on a synthetic in-memory volume.
    /// Confirms the encoder and decoder both handle uint16 multi-frame
    /// bitstreams (the use case the multi-frame path was designed for).
    func testMultiFrameRoundTrip_16Bit() throws {
        let w = 24, h = 24, slices = 6
        var frames: [ImageFrame] = []
        for z in 0..<slices {
            var f = ImageFrame(width: w, height: h, channels: 1,
                               pixelType: .uint16, colorSpace: .grayscale)
            for y in 0..<h {
                for x in 0..<w {
                    let v = UInt16((x + y * 5 + z * 31) % 4096)
                    f.setPixel(x: x, y: y, channel: 0, value: v)
                }
            }
            frames.append(f)
        }
        let encoded = try JXLEncoder(options: EncodingOptions(
            mode: .lossless, effort: .squirrel
        )).encode(frames)
        let decoded = try JXLDecoder().decodeAll(encoded.data)
        XCTAssertEqual(decoded.count, slices)
        for (i, df) in decoded.enumerated() {
            XCTAssertEqual(df.pixelType, .uint16, "decoded slice must keep 16-bit")
            XCTAssertEqual(df.data, frames[i].data,
                "slice \(i) lossless round-trip not pixel-exact")
        }
    }

    // MARK: - Hardening: edge cases + adversarial input

    /// Decoder must reject (cleanly) an empty buffer, not crash.
    func testDecoder_RejectsEmptyData() {
        XCTAssertThrowsError(try JXLDecoder().decode(Data())) { err in
            // Any DecoderError is acceptable; the contract is "throws, doesn't crash".
            XCTAssertNotNil(err as? DecoderError)
        }
    }

    /// Decoder must reject random bytes (not start with the JXL signature).
    func testDecoder_RejectsRandomBytes() {
        var data = Data(count: 1024)
        data.withUnsafeMutableBytes { ptr in
            for i in 0..<ptr.count {
                ptr[i] = UInt8(truncatingIfNeeded: i &* 31 ^ 0xAA)
            }
        }
        XCTAssertThrowsError(try JXLDecoder().decode(data))
    }

    /// Decoder must reject a truncated valid JXL bitstream.
    func testDecoder_RejectsTruncatedBitstream() throws {
        // Make a real .jxl, then chop it at half length.
        var f = ImageFrame(width: 16, height: 16, channels: 1,
                           pixelType: .uint8, colorSpace: .grayscale)
        for y in 0..<16 { for x in 0..<16 { f.setPixel(x: x, y: y, channel: 0, value: UInt16((x + y) * 8)) } }
        let encoded = try JXLEncoder(options: EncodingOptions(mode: .lossless, effort: .falcon))
            .encode(f)
        let truncated = encoded.data.prefix(encoded.data.count / 2)
        XCTAssertThrowsError(try JXLDecoder().decode(Data(truncated)))
    }

    /// Encoder must reject a frame whose declared geometry is impossible
    /// without crashing the libjxl bridge.
    func testEncoder_RejectsZeroSizedFrame() {
        // ImageFrame init has a precondition that catches this at the
        // boundary; we verify the precondition with XCTAssertThrowsAssertion-
        // style "would-trap" via a separate path: build a degenerate frame
        // by hand and confirm the encode throws cleanly.
        // We can't construct ImageFrame(width:0,...) without trapping in init,
        // so we instead test that the encoder throws on a frame with size
        // exceeding what libjxl will accept by simulating only a handful of
        // bytes of data — the data-size validator should catch this.
        var bad = ImageFrame(width: 4, height: 4, channels: 1,
                             pixelType: .uint8, colorSpace: .grayscale)
        // Wipe the data array so the bytesPerRow * height invariant breaks.
        bad.data = []
        XCTAssertThrowsError(try JXLEncoder().encode(bad))
    }

    /// Multi-frame encode must reject a heterogeneous frame list with a
    /// clear error rather than emitting a malformed bitstream.
    func testEncoder_MultiFrame_RejectsMismatchedDimensions() {
        var a = ImageFrame(width: 8, height: 8, channels: 1, pixelType: .uint8, colorSpace: .grayscale)
        var b = ImageFrame(width: 16, height: 8, channels: 1, pixelType: .uint8, colorSpace: .grayscale)
        for i in 0..<a.data.count { a.data[i] = UInt8(i % 256) }
        for i in 0..<b.data.count { b.data[i] = UInt8(i % 256) }
        XCTAssertThrowsError(try JXLEncoder().encode([a, b])) { err in
            XCTAssertNotNil(err as? EncoderError)
        }
    }

    /// DICOMReader must reject obvious garbage (not a DICOM file).
    func testDICOMReader_RejectsGarbage() {
        var noise = Data(count: 256)
        noise.withUnsafeMutableBytes { p in for i in 0..<p.count { p[i] = UInt8(i ^ 0x55) } }
        XCTAssertThrowsError(try DICOMReader.parse(noise)) { err in
            XCTAssertNotNil(err as? DICOMError)
        }
    }

    /// DICOMReader must reject a file that's too small to contain a valid header.
    func testDICOMReader_RejectsFileTooSmall() {
        let tiny = Data(repeating: 0, count: 64)
        XCTAssertThrowsError(try DICOMReader.parse(tiny))
    }

    /// Encode → decode → encode → decode must preserve pixels exactly
    /// across multiple lossless passes. (Bitstream bytes can differ between
    /// passes because libjxl's effort heuristics aren't byte-deterministic;
    /// the lossless contract is on pixel values, not bitstream structure.)
    func testIdempotent_LosslessTwoPasses_PreservesPixels() throws {
        var f = ImageFrame(width: 64, height: 48, channels: 1,
                           pixelType: .uint16, colorSpace: .grayscale)
        for y in 0..<48 {
            for x in 0..<64 {
                f.setPixel(x: x, y: y, channel: 0, value: UInt16((x * 257 + y * 17) % 4096))
            }
        }
        let opts = EncodingOptions(mode: .lossless, effort: .squirrel)
        let first = try JXLEncoder(options: opts).encode(f)
        let pass1 = try JXLDecoder().decode(first.data)
        let second = try JXLEncoder(options: opts).encode(pass1)
        let pass2 = try JXLDecoder().decode(second.data)
        XCTAssertEqual(pass1.data, f.data, "first round-trip must be pixel-exact")
        XCTAssertEqual(pass2.data, f.data, "second round-trip must also be pixel-exact")
    }

    func testEncodedBitstreamHasJXLSignature() throws {
        try skipIfNoDataset()
        #if !canImport(ImageIO)
        try XCTSkipIf(true, "ImageIO not available")
        #else
        let url = IntegrationTests.datasetSamples[0]
        guard let original = loadGrayscalePNG(url) else { return XCTFail("load") }
        let encoded = try JXLEncoder(options: EncodingOptions(mode: .lossless, effort: .falcon)).encode(original)
        let bytes = [UInt8](encoded.data.prefix(12))
        // JXL container signature is `\0\0\0\x0CJXL \r\n\x87\n` for ISOBMFF
        // wrapped output, or 0xFF 0x0A for raw codestream.
        let isoSig: [UInt8] = [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
        let isContainer = (bytes == isoSig)
        let isRaw = (bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0x0A)
        XCTAssertTrue(isContainer || isRaw,
                      "encoded bitstream lacks JXL signature; first bytes = \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        #endif
    }
}
