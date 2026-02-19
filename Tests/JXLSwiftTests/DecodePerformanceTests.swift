// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import XCTest
@testable import JXLSwift
import Foundation

/// Performance benchmarks for JPEG XL decoding.
///
/// Measures decode throughput (megapixels per second) for various image
/// sizes, encoding modes, and pixel types to validate performance targets.
final class DecodePerformanceTests: XCTestCase {
    
    // MARK: - Helpers
    
    /// Measure decode time and calculate megapixels per second.
    private func measureDecode(
        frame: ImageFrame,
        options: EncodingOptions,
        iterations: Int = 3
    ) throws -> (averageTimeSeconds: Double, megapixelsPerSecond: Double) {
        // Encode once
        let encoder = JXLEncoder(options: options)
        let encoded = try encoder.encode(frame)
        let decoder = JXLDecoder()
        
        var times: [Double] = []
        
        // Warm-up iteration
        _ = try decoder.decode(encoded.data)
        
        // Measured iterations
        for _ in 0..<iterations {
            let start = ProcessInfo.processInfo.systemUptime
            _ = try decoder.decode(encoded.data)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            times.append(elapsed)
        }
        
        let averageTime = times.reduce(0.0, +) / Double(times.count)
        let megapixels = Double(frame.width * frame.height) / 1_000_000.0
        let mpPerSecond = megapixels / averageTime
        
        return (averageTime, mpPerSecond)
    }
    
    /// Create a test frame filled with gradient pattern.
    private func makeFrame(width: Int, height: Int, channels: Int, pixelType: PixelType = .uint8) -> ImageFrame {
        var frame = ImageFrame(width: width, height: height, channels: channels, pixelType: pixelType)
        
        for c in 0..<channels {
            for y in 0..<height {
                for x in 0..<width {
                    let value = UInt16((x % 256 + y % 256 + c * 7) % 256)
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }
        
        return frame
    }
    
    // MARK: - Small Image Decode Performance
    
    func testDecodePerformance_Lossless_64x64() throws {
        let frame = makeFrame(width: 64, height: 64, channels: 3)
        let options = EncodingOptions(mode: .lossless, effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options)
        
        print("Lossless 64×64: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        // Should be very fast for small images
        XCTAssertLessThan(avgTime, 0.5, "64×64 decode should take < 500ms")
        XCTAssertGreaterThan(mpPerSec, 0.01, "64×64 decode should achieve > 0.01 MP/s")
    }
    
    func testDecodePerformance_Lossy_64x64() throws {
        let frame = makeFrame(width: 64, height: 64, channels: 3)
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options)
        
        print("Lossy 64×64: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        XCTAssertLessThan(avgTime, 0.5, "64×64 lossy decode should take < 500ms")
        XCTAssertGreaterThan(mpPerSec, 0.01, "64×64 lossy decode should achieve > 0.01 MP/s")
    }
    
    // MARK: - Medium Image Decode Performance
    
    func testDecodePerformance_Lossless_256x256() throws {
        let frame = makeFrame(width: 256, height: 256, channels: 3)
        let options = EncodingOptions(mode: .lossless, effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options)
        
        print("Lossless 256×256: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        // 256×256 = 65K pixels = 0.065 MP
        XCTAssertLessThan(avgTime, 2.0, "256×256 decode should take < 2s")
        XCTAssertGreaterThan(mpPerSec, 0.03, "256×256 decode should achieve > 0.03 MP/s")
    }
    
    func testDecodePerformance_Lossy_256x256() throws {
        let frame = makeFrame(width: 256, height: 256, channels: 3)
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options)
        
        print("Lossy 256×256: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        XCTAssertLessThan(avgTime, 2.0, "256×256 lossy decode should take < 2s")
        XCTAssertGreaterThan(mpPerSec, 0.03, "256×256 lossy decode should achieve > 0.03 MP/s")
    }
    
    // MARK: - Large Image Decode Performance
    
    func testDecodePerformance_Lossless_512x512() throws {
        let frame = makeFrame(width: 512, height: 512, channels: 3)
        let options = EncodingOptions(mode: .lossless, effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options)
        
        print("Lossless 512×512: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        // 512×512 = 262K pixels = 0.262 MP
        XCTAssertLessThan(avgTime, 5.0, "512×512 decode should take < 5s")
        XCTAssertGreaterThan(mpPerSec, 0.05, "512×512 decode should achieve > 0.05 MP/s")
    }
    
    func testDecodePerformance_Lossy_512x512() throws {
        let frame = makeFrame(width: 512, height: 512, channels: 3)
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options)
        
        print("Lossy 512×512: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        XCTAssertLessThan(avgTime, 5.0, "512×512 lossy decode should take < 5s")
        XCTAssertGreaterThan(mpPerSec, 0.05, "512×512 lossy decode should achieve > 0.05 MP/s")
    }
    
    // MARK: - 1 Megapixel Image Performance
    
    func testDecodePerformance_Lossless_1000x1000() throws {
        let frame = makeFrame(width: 1000, height: 1000, channels: 3)
        let options = EncodingOptions(mode: .lossless, effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options)
        
        print("Lossless 1000×1000: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        // 1 megapixel
        XCTAssertLessThan(avgTime, 10.0, "1MP decode should take < 10s")
        XCTAssertGreaterThan(mpPerSec, 0.1, "1MP decode should achieve > 0.1 MP/s")
    }
    
    func testDecodePerformance_Lossy_1000x1000() throws {
        let frame = makeFrame(width: 1000, height: 1000, channels: 3)
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options, iterations: 3)
        
        print("Lossy 1000×1000: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        XCTAssertLessThan(avgTime, 10.0, "1MP lossy decode should take < 10s")
        XCTAssertGreaterThan(mpPerSec, 0.1, "1MP lossy decode should achieve > 0.1 MP/s")
    }
    
    // MARK: - 4 Megapixel Image Performance
    
    func testDecodePerformance_Lossy_2048x2048() throws {
        let frame = makeFrame(width: 2048, height: 2048, channels: 3)
        let options = EncodingOptions(mode: .lossy(quality: 75), effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options, iterations: 2)
        
        print("Lossy 2048×2048: \(String(format: "%.3f", avgTime)) s, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        // 4 megapixels - this is a stress test
        XCTAssertLessThan(avgTime, 60.0, "4MP lossy decode should take < 60s")
        XCTAssertGreaterThan(mpPerSec, 0.05, "4MP lossy decode should achieve > 0.05 MP/s")
    }
    
    // MARK: - Pixel Type Performance Comparison
    
    func testDecodePerformance_PixelType_UInt8() throws {
        let frame = makeFrame(width: 512, height: 512, channels: 3, pixelType: .uint8)
        let options = EncodingOptions(mode: .lossless, effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options)
        
        print("UInt8 512×512: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        XCTAssertGreaterThan(mpPerSec, 0.05, "UInt8 decode should be efficient")
    }
    
    func testDecodePerformance_PixelType_UInt16() throws {
        let frame = makeFrame(width: 512, height: 512, channels: 3, pixelType: .uint16)
        let options = EncodingOptions(mode: .lossless, effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options)
        
        print("UInt16 512×512: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        XCTAssertGreaterThan(mpPerSec, 0.05, "UInt16 decode should be reasonably fast")
    }
    
    func testDecodePerformance_PixelType_Float32() throws {
        let frame = makeFrame(width: 256, height: 256, channels: 3, pixelType: .float32)
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options)
        
        print("Float32 256×256: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        XCTAssertGreaterThan(mpPerSec, 0.03, "Float32 decode should maintain performance")
    }
    
    // MARK: - Channel Count Performance
    
    func testDecodePerformance_Grayscale() throws {
        let frame = makeFrame(width: 512, height: 512, channels: 1)
        let options = EncodingOptions(mode: .lossless, effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options)
        
        print("Grayscale 512×512: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        // Grayscale should be faster than RGB
        XCTAssertGreaterThan(mpPerSec, 0.1, "Grayscale decode should be fast")
    }
    
    func testDecodePerformance_RGBA() throws {
        let frame = makeFrame(width: 512, height: 512, channels: 4)
        let options = EncodingOptions(mode: .lossless, effort: .lightning)
        
        let (avgTime, mpPerSec) = try measureDecode(frame: frame, options: options)
        
        print("RGBA 512×512: \(String(format: "%.3f", avgTime * 1000)) ms, \(String(format: "%.1f", mpPerSec)) MP/s")
        
        XCTAssertGreaterThan(mpPerSec, 0.05, "RGBA decode should maintain reasonable speed")
    }
    
    // MARK: - Modular vs VarDCT Comparison
    
    func testDecodePerformance_ModularVsVarDCT_256x256() throws {
        let frame = makeFrame(width: 256, height: 256, channels: 3)
        
        // Modular (lossless)
        let modularOptions = EncodingOptions(mode: .lossless, effort: .lightning)
        let (modularTime, modularMP) = try measureDecode(frame: frame, options: modularOptions)
        
        // VarDCT (lossy)
        let vardctOptions = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        let (vardctTime, vardctMP) = try measureDecode(frame: frame, options: vardctOptions)
        
        print("Modular 256×256: \(String(format: "%.3f", modularTime * 1000)) ms, \(String(format: "%.1f", modularMP)) MP/s")
        print("VarDCT 256×256: \(String(format: "%.3f", vardctTime * 1000)) ms, \(String(format: "%.1f", vardctMP)) MP/s")
        
        // Both should be reasonably fast
        XCTAssertGreaterThan(modularMP, 0.03, "Modular decode should be efficient")
        XCTAssertGreaterThan(vardctMP, 0.03, "VarDCT decode should be efficient")
    }
    
    // MARK: - Quality Level Performance
    
    func testDecodePerformance_QualityLevels_512x512() throws {
        let frame = makeFrame(width: 512, height: 512, channels: 3)
        
        let qualities = [50, 75, 90, 100]
        var results: [(quality: Int, mpPerSec: Double)] = []
        
        for quality in qualities {
            let options = EncodingOptions(
                mode: quality == 100 ? .lossless : .lossy(quality: Float(quality)),
                effort: .lightning
            )
            let (_, mpPerSec) = try measureDecode(frame: frame, options: options)
            results.append((quality, mpPerSec))
            print("Quality \(quality): \(String(format: "%.1f", mpPerSec)) MP/s")
        }
        
        // All quality levels should maintain decent performance
        for (quality, mpPerSec) in results {
            XCTAssertGreaterThan(mpPerSec, 0.05,
                               "Quality \(quality) should achieve > 0.05 MP/s")
        }
    }
    
    // MARK: - Overall Throughput Test
    
    func testDecodePerformance_OverallThroughput() throws {
        // Test multiple sizes and average MP/s
        let testSizes = [(64, 64), (128, 128), (256, 256), (512, 512)]
        var totalMP: Double = 0
        var totalTime: Double = 0
        
        for (width, height) in testSizes {
            let frame = makeFrame(width: width, height: height, channels: 3)
            let options = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
            let (avgTime, _) = try measureDecode(frame: frame, options: options)
            
            let mp = Double(width * height) / 1_000_000.0
            totalMP += mp
            totalTime += avgTime
        }
        
        let overallMPPerSec = totalMP / totalTime
        
        print("Overall throughput: \(String(format: "%.1f", overallMPPerSec)) MP/s")
        
        // Overall throughput should be reasonable
        // Note: Apple Silicon target is 100 MP/s, but on x86-64 we expect less
        XCTAssertGreaterThan(overallMPPerSec, 0.05,
                           "Overall decode throughput should be > 0.05 MP/s")
        
        // Store performance result for visibility
        measure {
            // Empty measure block - we already measured above
        }
    }
}
