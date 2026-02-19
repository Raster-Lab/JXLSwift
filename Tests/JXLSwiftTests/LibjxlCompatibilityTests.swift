// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import XCTest
@testable import JXLSwift
import Foundation

/// Tests for decoding libjxl-encoded files with JXLSwift decoder.
///
/// These tests verify bitstream compatibility by encoding test images with
/// the reference libjxl implementation (cjxl) and decoding them with JXLSwift.
/// Tests are conditional and skip gracefully when libjxl tools are not installed.
final class LibjxlCompatibilityTests: XCTestCase {
    
    // MARK: - Setup & Helpers
    
    /// Check if cjxl is available on the system.
    private func isCjxlAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["cjxl"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    /// Check if djxl is available on the system.
    private func isDjxlAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["djxl"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    /// Write a PPM (Portable Pixmap) image file for use with cjxl.
    /// PPM is a simple uncompressed format that cjxl can read.
    private func writePPM(
        frame: ImageFrame,
        to url: URL
    ) throws {
        guard frame.pixelType == .uint8 else {
            throw NSError(domain: "LibjxlCompatibilityTests", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "PPM output requires uint8 pixel type"])
        }
        
        let ppm = "P6\n\(frame.width) \(frame.height)\n255\n"
        var data = Data(ppm.utf8)
        
        // Write pixels in RGB interleaved format
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                for c in 0..<min(frame.channels, 3) {
                    let value = UInt8(frame.getPixel(x: x, y: y, channel: c))
                    data.append(value)
                }
                // If grayscale, duplicate to RGB
                if frame.channels == 1 {
                    let value = UInt8(frame.getPixel(x: x, y: y, channel: 0))
                    data.append(value)
                    data.append(value)
                }
            }
        }
        
        try data.write(to: url)
    }
    
    /// Encode a frame with cjxl (libjxl encoder).
    private func encodeWithCjxl(
        frame: ImageFrame,
        quality: Int? = nil,
        lossless: Bool = false
    ) throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory
        let ppmPath = tempDir.appendingPathComponent("test_\(UUID().uuidString).ppm")
        let jxlPath = tempDir.appendingPathComponent("test_\(UUID().uuidString).jxl")
        
        defer {
            try? FileManager.default.removeItem(at: ppmPath)
            try? FileManager.default.removeItem(at: jxlPath)
        }
        
        // Write PPM input file
        try writePPM(frame: frame, to: ppmPath)
        
        // Run cjxl
        let process = Process()
        let cjxl = findInPath("cjxl") ?? "cjxl"
        process.executableURL = URL(fileURLWithPath: cjxl)
        
        var arguments = [ppmPath.path, jxlPath.path]
        if lossless {
            arguments.append("--distance=0")
        } else if let q = quality {
            arguments.append("--quality=\(q)")
        }
        
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let errorPipe = process.standardError as! Pipe
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "LibjxlCompatibilityTests", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "cjxl failed: \(errorStr)"])
        }
        
        return try Data(contentsOf: jxlPath)
    }
    
    /// Find an executable in the system PATH.
    private func findInPath(_ name: String) -> String? {
        let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = pathVar.split(separator: ":").map(String.init)
        
        for dir in paths {
            let fullPath = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }
    
    /// Calculate PSNR between two frames.
    private func calculatePSNR(_ a: ImageFrame, _ b: ImageFrame) -> Double {
        guard a.width == b.width && a.height == b.height && a.channels == b.channels else {
            return 0.0
        }
        
        var mse = 0.0
        let pixelCount = Double(a.width * a.height * a.channels)
        
        for c in 0..<a.channels {
            for y in 0..<a.height {
                for x in 0..<a.width {
                    let av = Double(a.getPixel(x: x, y: y, channel: c))
                    let bv = Double(b.getPixel(x: x, y: y, channel: c))
                    let diff = av - bv
                    mse += (diff * diff) / pixelCount
                }
            }
        }
        
        if mse < 1e-10 {
            return Double.infinity  // Pixel-perfect match
        }
        
        let maxValue = 255.0
        return 20.0 * log10(maxValue / sqrt(mse))
    }
    
    /// Create a test frame with a gradient pattern.
    private func makeGradientFrame(width: Int, height: Int, channels: Int) -> ImageFrame {
        var frame = ImageFrame(width: width, height: height, channels: channels, pixelType: .uint8)
        for c in 0..<channels {
            for y in 0..<height {
                for x in 0..<width {
                    let value = UInt16((x + y * width + c * 7) % 256)
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }
        return frame
    }
    
    // MARK: - Lossless Round-Trip Tests
    
    func testDecodeCjxlLossless_8x8_RGB() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available - install libjxl to enable this test")
        }
        
        let frame = makeGradientFrame(width: 8, height: 8, channels: 3)
        let encoded = try encodeWithCjxl(frame: frame, lossless: true)
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        
        // Lossless should be pixel-perfect
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
        XCTAssertEqual(decoded.channels, frame.channels)
        
        let psnr = calculatePSNR(frame, decoded)
        XCTAssertTrue(psnr.isInfinite || psnr > 100.0, 
                     "Lossless decode should be pixel-perfect, got PSNR=\(psnr)")
    }
    
    func testDecodeCjxlLossless_16x16_RGB() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available - install libjxl to enable this test")
        }
        
        let frame = makeGradientFrame(width: 16, height: 16, channels: 3)
        let encoded = try encodeWithCjxl(frame: frame, lossless: true)
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
        XCTAssertEqual(decoded.channels, frame.channels)
        
        let psnr = calculatePSNR(frame, decoded)
        XCTAssertTrue(psnr.isInfinite || psnr > 100.0,
                     "Lossless decode should be pixel-perfect, got PSNR=\(psnr)")
    }
    
    func testDecodeCjxlLossless_32x32_RGB() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available - install libjxl to enable this test")
        }
        
        let frame = makeGradientFrame(width: 32, height: 32, channels: 3)
        let encoded = try encodeWithCjxl(frame: frame, lossless: true)
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
        XCTAssertEqual(decoded.channels, frame.channels)
        
        let psnr = calculatePSNR(frame, decoded)
        XCTAssertTrue(psnr.isInfinite || psnr > 100.0,
                     "Lossless decode should be pixel-perfect, got PSNR=\(psnr)")
    }
    
    func testDecodeCjxlLossless_Grayscale() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available - install libjxl to enable this test")
        }
        
        let frame = makeGradientFrame(width: 16, height: 16, channels: 1)
        let encoded = try encodeWithCjxl(frame: frame, lossless: true)
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
        // Note: cjxl might convert grayscale to RGB
        XCTAssertTrue(decoded.channels == 1 || decoded.channels == 3)
        
        // For grayscale→RGB conversion, check only first channel
        let psnr = calculatePSNR(frame, decoded)
        XCTAssertTrue(psnr.isInfinite || psnr > 100.0,
                     "Lossless decode should be pixel-perfect, got PSNR=\(psnr)")
    }
    
    // MARK: - Lossy Round-Trip Tests
    
    func testDecodeCjxlLossy_Quality90_RGB() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available - install libjxl to enable this test")
        }
        
        let frame = makeGradientFrame(width: 32, height: 32, channels: 3)
        let encoded = try encodeWithCjxl(frame: frame, quality: 90)
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
        XCTAssertEqual(decoded.channels, frame.channels)
        
        let psnr = calculatePSNR(frame, decoded)
        XCTAssertGreaterThan(psnr, 40.0, 
                            "Lossy quality=90 should achieve PSNR > 40 dB, got \(psnr)")
    }
    
    func testDecodeCjxlLossy_Quality75_RGB() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available - install libjxl to enable this test")
        }
        
        let frame = makeGradientFrame(width: 32, height: 32, channels: 3)
        let encoded = try encodeWithCjxl(frame: frame, quality: 75)
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
        XCTAssertEqual(decoded.channels, frame.channels)
        
        let psnr = calculatePSNR(frame, decoded)
        XCTAssertGreaterThan(psnr, 35.0,
                            "Lossy quality=75 should achieve PSNR > 35 dB, got \(psnr)")
    }
    
    func testDecodeCjxlLossy_Quality50_RGB() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available - install libjxl to enable this test")
        }
        
        let frame = makeGradientFrame(width: 32, height: 32, channels: 3)
        let encoded = try encodeWithCjxl(frame: frame, quality: 50)
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
        XCTAssertEqual(decoded.channels, frame.channels)
        
        let psnr = calculatePSNR(frame, decoded)
        XCTAssertGreaterThan(psnr, 30.0,
                            "Lossy quality=50 should achieve PSNR > 30 dB, got \(psnr)")
    }
    
    // MARK: - Various Image Sizes
    
    func testDecodeCjxl_NonMultipleOf8() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available - install libjxl to enable this test")
        }
        
        let frame = makeGradientFrame(width: 17, height: 23, channels: 3)
        let encoded = try encodeWithCjxl(frame: frame, lossless: true)
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
    }
    
    func testDecodeCjxl_LargeImage() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available - install libjxl to enable this test")
        }
        
        let frame = makeGradientFrame(width: 256, height: 256, channels: 3)
        let encoded = try encodeWithCjxl(frame: frame, quality: 80)
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded)
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
        XCTAssertEqual(decoded.channels, frame.channels)
        
        let psnr = calculatePSNR(frame, decoded)
        XCTAssertGreaterThan(psnr, 35.0, "Large image decode should maintain quality")
    }
    
    // MARK: - Bidirectional Compatibility
    
    func testBidirectionalCompatibility_JXLSwiftEncodeLibjxlDecode() throws {
        guard isDjxlAvailable() else {
            throw XCTSkip("djxl not available - install libjxl to enable this test")
        }
        
        // Encode with JXLSwift
        let frame = makeGradientFrame(width: 32, height: 32, channels: 3)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        
        // Decode with libjxl (djxl)
        let tempDir = FileManager.default.temporaryDirectory
        let jxlPath = tempDir.appendingPathComponent("test_\(UUID().uuidString).jxl")
        let ppmPath = tempDir.appendingPathComponent("test_\(UUID().uuidString).ppm")
        
        defer {
            try? FileManager.default.removeItem(at: jxlPath)
            try? FileManager.default.removeItem(at: ppmPath)
        }
        
        try encoded.data.write(to: jxlPath)
        
        let process = Process()
        let djxl = findInPath("djxl") ?? "djxl"
        process.executableURL = URL(fileURLWithPath: djxl)
        process.arguments = [jxlPath.path, ppmPath.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        XCTAssertEqual(process.terminationStatus, 0, 
                      "libjxl should successfully decode JXLSwift-encoded file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ppmPath.path),
                     "Decoded output file should exist")
    }
    
    func testBidirectionalCompatibility_LibjxlEncodeJXLSwiftDecode() throws {
        guard isCjxlAvailable() else {
            throw XCTSkip("cjxl not available - install libjxl to enable this test")
        }
        
        // Encode with libjxl
        let frame = makeGradientFrame(width: 32, height: 32, channels: 3)
        let encoded = try encodeWithCjxl(frame: frame, lossless: true)
        
        // Decode with JXLSwift
        let decoder = JXLDecoder()
        XCTAssertNoThrow(try decoder.decode(encoded),
                        "JXLSwift should successfully decode libjxl-encoded file")
        
        let decoded = try decoder.decode(encoded)
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
    }
}
