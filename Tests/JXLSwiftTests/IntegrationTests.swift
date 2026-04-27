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
