// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import XCTest
@testable import JXLSwift
import Foundation

/// Milestone 11 validation tests: libjxl compatibility, quality comparison,
/// compression ratio, encoding speed, and memory stability.
///
/// All tests that invoke libjxl tools (cjxl/djxl) skip gracefully when those
/// tools are not installed; they are intended to run in environments where
/// libjxl is available (e.g., CI with `apt-get install libjxl-tools`).
final class LibjxlValidationTests: XCTestCase {

    // MARK: - Helpers

    private func findInPath(_ name: String) -> String? {
        let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathVar.split(separator: ":").map(String.init) {
            let fullPath = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    private func isCjxlAvailable() -> Bool { findInPath("cjxl") != nil }
    private func isDjxlAvailable() -> Bool { findInPath("djxl") != nil }

    /// Write a PPM file from an RGB uint8 ImageFrame.
    private func writePPM(_ frame: ImageFrame, to url: URL) throws {
        var data = Data("P6\n\(frame.width) \(frame.height)\n255\n".utf8)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                for c in 0..<min(frame.channels, 3) {
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

    /// Run cjxl to encode a PPM to JXL. Returns encoded bytes.
    private func runCjxl(input: URL, output: URL, quality: Int? = nil, lossless: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: findInPath("cjxl") ?? "cjxl")
        var args = [input.path, output.path]
        if lossless { args.append("--distance=0") }
        else if let q = quality { args.append("--quality=\(q)") }
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "LibjxlValidationTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cjxl failed"])
        }
    }

    /// Run djxl to decode a JXL to PPM. Returns the exit status (0 = success).
    @discardableResult
    private func runDjxl(input: URL, output: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: findInPath("djxl") ?? "djxl")
        process.arguments = [input.path, output.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Encode a PPM with cjxl, then encode the same image with JXLSwift, return both
    /// compressed sizes as (libjxl: Int, jxlswift: Int).
    private func encodeWithBoth(
        frame: ImageFrame,
        quality: Int
    ) throws -> (libjxlBytes: Int, jxlswiftBytes: Int) {
        let tmp = FileManager.default.temporaryDirectory
        let ppmURL = tmp.appendingPathComponent("val_\(UUID().uuidString).ppm")
        let jxlURL = tmp.appendingPathComponent("val_\(UUID().uuidString).jxl")
        defer {
            try? FileManager.default.removeItem(at: ppmURL)
            try? FileManager.default.removeItem(at: jxlURL)
        }

        try writePPM(frame, to: ppmURL)
        try runCjxl(input: ppmURL, output: jxlURL, quality: quality)
        let libjxlBytes = try Data(contentsOf: jxlURL).count

        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: Float(quality)), effort: .squirrel))
        let result = try encoder.encode(frame)
        return (libjxlBytes, result.data.count)
    }

    /// Make a synthetic RGB gradient frame (uint8).
    private func makeTestFrame(width: Int, height: Int, channels: Int = 3) -> ImageFrame {
        var frame = ImageFrame(width: width, height: height, channels: channels, pixelType: .uint8)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    let v = UInt16((x + y * 3 + c * 7) % 256)
                    frame.setPixel(x: x, y: y, channel: c, value: v)
                }
            }
        }
        return frame
    }

    /// Compute PSNR between two uint8 frames. Returns .infinity for identical frames.
    private func psnr(_ a: ImageFrame, _ b: ImageFrame) -> Double {
        guard a.width == b.width, a.height == b.height, a.channels == b.channels else { return 0 }
        var mse = 0.0
        let n = Double(a.width * a.height * a.channels)
        for c in 0..<a.channels {
            for y in 0..<a.height {
                for x in 0..<a.width {
                    let d = Double(a.getPixel(x: x, y: y, channel: c)) -
                            Double(b.getPixel(x: x, y: y, channel: c))
                    mse += d * d / n
                }
            }
        }
        if mse < 1e-10 { return .infinity }
        return 20.0 * log10(255.0 / sqrt(mse))
    }

    // MARK: - Test 1: libjxl decodes every JXLSwift-produced file without errors

    /// Verify that djxl can decode every configuration of JXLSwift output without error.
    ///
    /// Covers: lossless, quality 50 / 75 / 90, 1 channel (grayscale), 3 channels (RGB),
    /// various image sizes. Skips if djxl is not installed.
    func testLibjxlDecodesAllJXLSwiftFiles_MultipleConfigs_AllSucceed() throws {
        guard isDjxlAvailable() else {
            throw XCTSkip("djxl not available — install libjxl-tools to enable this test")
        }

        struct Config {
            let width: Int, height: Int, channels: Int, options: EncodingOptions, label: String
        }
        let configs: [Config] = [
            Config(width: 8,  height: 8,  channels: 3, options: .lossless,               label: "8x8-RGB-lossless"),
            Config(width: 16, height: 16, channels: 3, options: .lossless,               label: "16x16-RGB-lossless"),
            Config(width: 32, height: 32, channels: 3, options: .lossless,               label: "32x32-RGB-lossless"),
            Config(width: 16, height: 16, channels: 1, options: .lossless,               label: "16x16-grey-lossless"),
            Config(width: 16, height: 16, channels: 3,
                   options: EncodingOptions(mode: .lossy(quality: 90), effort: .squirrel), label: "16x16-RGB-q90"),
            Config(width: 16, height: 16, channels: 3,
                   options: EncodingOptions(mode: .lossy(quality: 75), effort: .squirrel), label: "16x16-RGB-q75"),
            Config(width: 16, height: 16, channels: 3,
                   options: EncodingOptions(mode: .lossy(quality: 50), effort: .squirrel), label: "16x16-RGB-q50"),
            Config(width: 32, height: 24, channels: 3,
                   options: EncodingOptions(mode: .lossy(quality: 80), effort: .falcon),   label: "32x24-RGB-q80"),
        ]

        let tmp = FileManager.default.temporaryDirectory

        for cfg in configs {
            let frame = makeTestFrame(width: cfg.width, height: cfg.height, channels: cfg.channels)
            let encoder = JXLEncoder(options: cfg.options)
            let result = try encoder.encode(frame)

            let jxlURL = tmp.appendingPathComponent("m11_\(cfg.label)_\(UUID().uuidString).jxl")
            let outURL = tmp.appendingPathComponent("m11_\(cfg.label)_\(UUID().uuidString).ppm")
            defer {
                try? FileManager.default.removeItem(at: jxlURL)
                try? FileManager.default.removeItem(at: outURL)
            }

            try result.data.write(to: jxlURL)
            let status = try runDjxl(input: jxlURL, output: outURL)
            XCTAssertEqual(status, 0,
                "djxl failed to decode JXLSwift output for config '\(cfg.label)' (exit \(status))")
        }
    }

    // MARK: - Test 2: PSNR difference ≤ 1 dB at equivalent quality settings

    /// Verify that JXLSwift achieves PSNR within 1 dB of libjxl at equivalent quality.
    ///
    /// Encodes the same reference image with both cjxl and JXLSwift at quality 90,
    /// decodes both outputs with the JXLSwift decoder, computes PSNR against the
    /// original, and asserts the difference is ≤ 1 dB.
    ///
    /// Skips if cjxl is not installed.
    func testPSNRComparison_JXLSwiftVsLibjxl_QualityEquivalence() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available — install libjxl-tools to enable this test")
        }

        let original = makeTestFrame(width: 32, height: 32, channels: 3)
        let quality = 90
        let tmp = FileManager.default.temporaryDirectory

        // --- Encode & decode with libjxl ---
        let ppmURL  = tmp.appendingPathComponent("psnr_orig_\(UUID().uuidString).ppm")
        let jxlCURL = tmp.appendingPathComponent("psnr_cjxl_\(UUID().uuidString).jxl")
        defer {
            try? FileManager.default.removeItem(at: ppmURL)
            try? FileManager.default.removeItem(at: jxlCURL)
        }

        try writePPM(original, to: ppmURL)
        try runCjxl(input: ppmURL, output: jxlCURL, quality: quality)

        let libjxlEncoded = try Data(contentsOf: jxlCURL)
        let decoder = JXLDecoder()
        let libjxlDecoded = try decoder.decode(libjxlEncoded)
        let psnrLibjxl = psnr(original, libjxlDecoded)

        // --- Encode & decode with JXLSwift ---
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: Float(quality)), effort: .squirrel))
        let jxlswiftEncoded = try encoder.encode(original)
        let jxlswiftDecoded = try decoder.decode(jxlswiftEncoded.data)
        let psnrJXLSwift = psnr(original, jxlswiftDecoded)

        // Both should achieve reasonable quality
        XCTAssertGreaterThan(psnrLibjxl, 35.0,
            "libjxl decode at quality=\(quality) should achieve PSNR > 35 dB, got \(psnrLibjxl)")
        XCTAssertGreaterThan(psnrJXLSwift, 35.0,
            "JXLSwift decode at quality=\(quality) should achieve PSNR > 35 dB, got \(psnrJXLSwift)")

        // PSNR difference should be within 1 dB (milestone requirement)
        let diff = abs(psnrLibjxl - psnrJXLSwift)
        XCTAssertLessThanOrEqual(diff, 1.0,
            "PSNR difference (\(diff) dB) exceeds 1 dB: libjxl=\(psnrLibjxl) dB, JXLSwift=\(psnrJXLSwift) dB")
    }

    // MARK: - Test 3: Compression ratio within 20% of libjxl at equivalent settings

    /// Verify that JXLSwift compression ratio is within 20% of libjxl at quality 90.
    ///
    /// Encodes the same test corpus images with both cjxl and JXLSwift, then compares
    /// the average compression ratio. Skips if cjxl is not installed.
    func testCompressionRatioComparison_JXLSwiftVsLibjxl_Within20Percent() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available — install libjxl-tools to enable this test")
        }

        let quality = 90
        let frames = [
            makeTestFrame(width: 32, height: 32, channels: 3),
            makeTestFrame(width: 16, height: 32, channels: 3),
            makeTestFrame(width: 48, height: 16, channels: 3),
        ]

        var libjxlRatios: [Double] = []
        var jxlswiftRatios: [Double] = []

        for frame in frames {
            let originalSize = Double(frame.data.count)
            let (libjxlBytes, jxlswiftBytes) = try encodeWithBoth(frame: frame, quality: quality)
            libjxlRatios.append(originalSize / Double(libjxlBytes))
            jxlswiftRatios.append(originalSize / Double(jxlswiftBytes))
        }

        let avgLibjxl   = libjxlRatios.reduce(0, +) / Double(libjxlRatios.count)
        let avgJXLSwift = jxlswiftRatios.reduce(0, +) / Double(jxlswiftRatios.count)

        XCTAssertGreaterThan(avgLibjxl, 1.0,
            "libjxl average compression ratio should exceed 1.0, got \(avgLibjxl)")
        XCTAssertGreaterThan(avgJXLSwift, 1.0,
            "JXLSwift average compression ratio should exceed 1.0, got \(avgJXLSwift)")

        // Ratio difference should be within 20% of libjxl ratio
        let relativeDiff = abs(avgJXLSwift - avgLibjxl) / avgLibjxl
        XCTAssertLessThanOrEqual(relativeDiff, 0.20,
            "Compression ratio difference (\(String(format: "%.1f", relativeDiff * 100))%) exceeds 20%: " +
            "libjxl avg=\(avgLibjxl), JXLSwift avg=\(avgJXLSwift)")
    }

    // MARK: - Test 4: Encoding speed within 3× of libjxl

    /// Verify that JXLSwift encoding speed is within 3× of libjxl at comparable settings.
    ///
    /// Measures JXLSwift and cjxl encoding time on a 64×64 image over several iterations.
    /// Skips if cjxl is not installed. This is an aspirational target for an initial
    /// implementation; the 3× bound may be relaxed in future milestones.
    func testEncodingSpeedComparison_JXLSwiftVsLibjxl_Within3x() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available — install libjxl-tools to enable this test")
        }

        let frame = makeTestFrame(width: 64, height: 64, channels: 3)
        let quality = 90
        let iterations = 3

        // --- Measure JXLSwift encoding time ---
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: Float(quality)), effort: .squirrel))
        var jxlswiftTimes: [Double] = []
        for _ in 0..<iterations {
            let start = ProcessInfo.processInfo.systemUptime
            _ = try encoder.encode(frame)
            jxlswiftTimes.append(ProcessInfo.processInfo.systemUptime - start)
        }
        let avgJXLSwift = jxlswiftTimes.reduce(0, +) / Double(iterations)

        // --- Measure cjxl encoding time ---
        let tmp = FileManager.default.temporaryDirectory
        let ppmURL = tmp.appendingPathComponent("speed_\(UUID().uuidString).ppm")
        defer { try? FileManager.default.removeItem(at: ppmURL) }
        try writePPM(frame, to: ppmURL)

        var libjxlTimes: [Double] = []
        for i in 0..<iterations {
            let jxlURL = tmp.appendingPathComponent("speed_out_\(i)_\(UUID().uuidString).jxl")
            defer { try? FileManager.default.removeItem(at: jxlURL) }
            let start = ProcessInfo.processInfo.systemUptime
            try runCjxl(input: ppmURL, output: jxlURL, quality: quality)
            libjxlTimes.append(ProcessInfo.processInfo.systemUptime - start)
        }
        let avgLibjxl = libjxlTimes.reduce(0, +) / Double(iterations)

        XCTAssertGreaterThan(avgLibjxl, 0, "libjxl encoding time should be positive")
        XCTAssertGreaterThan(avgJXLSwift, 0, "JXLSwift encoding time should be positive")

        // JXLSwift should be within 3× of cjxl wall-clock time
        let ratio = avgJXLSwift / avgLibjxl
        XCTAssertLessThanOrEqual(ratio, 3.0,
            "JXLSwift is \(String(format: "%.2f", ratio))× slower than libjxl (limit: 3×); " +
            "JXLSwift avg=\(String(format: "%.1f", avgJXLSwift * 1000)) ms, " +
            "libjxl avg=\(String(format: "%.1f", avgLibjxl * 1000)) ms")
    }

    // MARK: - Test 5: No memory leaks

    /// Verify that repeated encoding and decoding does not produce unbounded memory growth.
    ///
    /// Runs 50 encode+decode iterations and checks that resident memory after the run
    /// is within 5 MB of the baseline (memory growth from allocator fragmentation is
    /// normal; we only flag a large sustained leak).
    func testNoMemoryLeaks_RepeatedEncoding_MemoryStable() throws {
        let frame = makeTestFrame(width: 64, height: 64, channels: 3)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90), effort: .falcon))
        let decoder = JXLDecoder()

        // Warm up the allocator before measuring
        for _ in 0..<5 {
            let r = try encoder.encode(frame)
            _ = try decoder.decode(r.data)
        }

        let memBefore = ComparisonBenchmark.currentProcessMemory()

        for _ in 0..<50 {
            let r = try encoder.encode(frame)
            _ = try decoder.decode(r.data)
        }

        let memAfter = ComparisonBenchmark.currentProcessMemory()

        // Allow up to 5 MB growth from normal allocator/cache churn
        let growthBytes = max(0, memAfter - memBefore)
        let limitBytes = 5 * 1024 * 1024
        XCTAssertLessThanOrEqual(growthBytes, limitBytes,
            "Memory grew by \(growthBytes / 1024) KB after 50 encode+decode cycles " +
            "(limit: \(limitBytes / 1024) KB); possible leak detected")
    }
}
