// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import XCTest
@testable import JXLSwift
import Foundation

/// Tests for memory-bounded decoding and memory efficiency.
///
/// Validates that the decoder handles large images efficiently without
/// excessive memory consumption or leaks.
final class MemoryBoundedDecodingTests: XCTestCase {
    
    // MARK: - Helpers
    
    /// Get current process memory usage in bytes.
    private func getMemoryUsage() -> UInt64 {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        guard kerr == KERN_SUCCESS else {
            return 0
        }
        
        return UInt64(info.resident_size)
        #elseif os(Linux)
        // Read from /proc/self/statm on Linux
        guard let contents = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else {
            return 0
        }
        
        let parts = contents.split(separator: " ")
        guard parts.count >= 2, let rss = UInt64(parts[1]) else {
            return 0
        }
        
        // RSS is in pages, typically 4096 bytes
        let pageSize = UInt64(sysconf(Int32(_SC_PAGESIZE)))
        return rss * pageSize
        #else
        return 0
        #endif
    }
    
    /// Create a large test frame filled with gradient pattern.
    private func makeLargeFrame(width: Int, height: Int, channels: Int) -> ImageFrame {
        var frame = ImageFrame(width: width, height: height, channels: channels)
        
        // Fill with a repeating pattern to be compressible
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
    
    /// Calculate memory per megapixel.
    private func memoryPerMegapixel(memoryBytes: UInt64, width: Int, height: Int) -> Double {
        let megapixels = Double(width * height) / 1_000_000.0
        return Double(memoryBytes) / megapixels
    }
    
    // MARK: - Memory Usage Tests
    
    func testDecodeSmallImage_MemoryBounded() throws {
        let frame = makeLargeFrame(width: 64, height: 64, channels: 3)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        
        let memoryBefore = getMemoryUsage()
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        
        let memoryAfter = getMemoryUsage()
        let memoryUsed = memoryAfter > memoryBefore ? memoryAfter - memoryBefore : 0
        
        // Small image should use less than 5 MB
        XCTAssertLessThan(memoryUsed, 5 * 1024 * 1024,
                         "Small image decode used \(memoryUsed / 1024 / 1024) MB, expected < 5 MB")
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
    }
    
    func testDecodeMediumImage_MemoryBounded() throws {
        let frame = makeLargeFrame(width: 256, height: 256, channels: 3)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        
        let memoryBefore = getMemoryUsage()
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        
        let memoryAfter = getMemoryUsage()
        let memoryUsed = memoryAfter > memoryBefore ? memoryAfter - memoryBefore : 0
        
        // Medium image should use less than 15 MB
        XCTAssertLessThan(memoryUsed, 15 * 1024 * 1024,
                         "Medium image decode used \(memoryUsed / 1024 / 1024) MB, expected < 15 MB")
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
    }
    
    func testDecodeLargeImage_MemoryBounded() throws {
        // 1 megapixel image
        let frame = makeLargeFrame(width: 1000, height: 1000, channels: 3)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        
        let memoryBefore = getMemoryUsage()
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        
        let memoryAfter = getMemoryUsage()
        let memoryUsed = memoryAfter > memoryBefore ? memoryAfter - memoryBefore : 0
        
        let memPerMP = memoryPerMegapixel(memoryBytes: memoryUsed, width: frame.width, height: frame.height)
        
        // Should use less than 50 MB per megapixel for reasonable efficiency
        // (3 channels × 2 bytes × 1M pixels = 6 MB minimum, allow overhead)
        XCTAssertLessThan(memPerMP, 50 * 1024 * 1024,
                         "Large image decode used \(memPerMP / 1024 / 1024) MB/MP, expected < 50 MB/MP")
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
    }
    
    func testDecodeVeryLargeImage_MemoryBounded() throws {
        // 4 megapixel image (2K)
        let frame = makeLargeFrame(width: 2048, height: 2048, channels: 3)
        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .lossy(quality: 75),
            effort: .lightning
        ))
        let encoded = try encoder.encode(frame)
        
        let memoryBefore = getMemoryUsage()
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        
        let memoryAfter = getMemoryUsage()
        let memoryUsed = memoryAfter > memoryBefore ? memoryAfter - memoryBefore : 0
        
        let memPerMP = memoryPerMegapixel(memoryBytes: memoryUsed, width: frame.width, height: frame.height)
        
        // Should use less than 60 MB per megapixel
        XCTAssertLessThan(memPerMP, 60 * 1024 * 1024,
                         "Very large image decode used \(memPerMP / 1024 / 1024) MB/MP, expected < 60 MB/MP")
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
    }
    
    // MARK: - Multiple Decode Memory Tests
    
    func testMultipleDecodes_NoMemoryLeak() throws {
        let frame = makeLargeFrame(width: 128, height: 128, channels: 3)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        
        let memoryBefore = getMemoryUsage()
        
        // Decode multiple times
        let decoder = JXLDecoder()
        for _ in 0..<10 {
            _ = try decoder.decode(encoded.data)
        }
        
        let memoryAfter = getMemoryUsage()
        let memoryGrowth = memoryAfter > memoryBefore ? memoryAfter - memoryBefore : 0
        
        // Memory should not grow significantly with multiple decodes
        // Allow 20 MB growth for 10 decodes (2 MB per decode)
        XCTAssertLessThan(memoryGrowth, 20 * 1024 * 1024,
                         "Multiple decodes showed memory growth of \(memoryGrowth / 1024 / 1024) MB, expected < 20 MB")
    }
    
    func testSequentialDecodes_MemoryReleased() throws {
        let frame = makeLargeFrame(width: 256, height: 256, channels: 3)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        
        let memoryBefore = getMemoryUsage()
        
        // Decode in sequence, allowing frames to be released
        for _ in 0..<5 {
            #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            autoreleasepool {
                let decoder = JXLDecoder()
                _ = try? decoder.decode(encoded.data)
            }
            #else
            // No autoreleasepool on Linux, just rely on ARC
            let decoder = JXLDecoder()
            _ = try? decoder.decode(encoded.data)
            #endif
        }
        
        // Force garbage collection (best effort on Linux)
        #if os(Linux)
        // No explicit GC on Linux, rely on ARC
        #else
        // Give ARC time to clean up
        Thread.sleep(forTimeInterval: 0.1)
        #endif
        
        let memoryAfter = getMemoryUsage()
        let memoryGrowth = memoryAfter > memoryBefore ? memoryAfter - memoryBefore : 0
        
        // Memory should be mostly released between decodes
        // Allow 30 MB growth for 5 sequential decodes
        XCTAssertLessThan(memoryGrowth, 30 * 1024 * 1024,
                         "Sequential decodes showed memory growth of \(memoryGrowth / 1024 / 1024) MB, expected < 30 MB")
    }
    
    // MARK: - Pixel Type Memory Tests
    
    func testDecodeUInt8_MemoryEfficient() throws {
        let frame = makeLargeFrame(width: 512, height: 512, channels: 3)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        
        let memoryBefore = getMemoryUsage()
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        
        let memoryAfter = getMemoryUsage()
        let memoryUsed = memoryAfter > memoryBefore ? memoryAfter - memoryBefore : 0
        
        // uint8 should be most memory-efficient
        // 512×512×3 = 786,432 pixels = ~1.5 MB minimum (stored as uint16 internally)
        // Allow 30 MB for overhead
        XCTAssertLessThan(memoryUsed, 30 * 1024 * 1024,
                         "uint8 decode used \(memoryUsed / 1024 / 1024) MB, expected < 30 MB")
        
        XCTAssertEqual(decoded.pixelType, .uint8)
    }
    
    func testDecodeFloat32_MemoryBounded() throws {
        var frame = ImageFrame(width: 256, height: 256, channels: 3, pixelType: .float32)
        
        // Fill with normalized float values
        for c in 0..<3 {
            for y in 0..<256 {
                for x in 0..<256 {
                    let value = UInt16((x % 256 + y % 256 + c * 7) % 256)
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }
        
        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .lossy(quality: 90),
            effort: .lightning
        ))
        let encoded = try encoder.encode(frame)
        
        let memoryBefore = getMemoryUsage()
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        
        let memoryAfter = getMemoryUsage()
        let memoryUsed = memoryAfter > memoryBefore ? memoryAfter - memoryBefore : 0
        
        // float32 uses 4 bytes per sample
        // 256×256×3 = 196,608 samples × 4 = 786 KB minimum
        // Allow 40 MB for overhead
        XCTAssertLessThan(memoryUsed, 40 * 1024 * 1024,
                         "float32 decode used \(memoryUsed / 1024 / 1024) MB, expected < 40 MB")
        
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)
    }
    
    // MARK: - Channel Count Memory Tests
    
    func testDecodeGrayscale_LowerMemory() throws {
        let frame = makeLargeFrame(width: 512, height: 512, channels: 1)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        
        let memoryBefore = getMemoryUsage()
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        
        let memoryAfter = getMemoryUsage()
        let memoryUsed = memoryAfter > memoryBefore ? memoryAfter - memoryBefore : 0
        
        // Grayscale should use ~1/3 the memory of RGB
        XCTAssertLessThan(memoryUsed, 15 * 1024 * 1024,
                         "Grayscale decode used \(memoryUsed / 1024 / 1024) MB, expected < 15 MB")
        
        XCTAssertEqual(decoded.channels, 1)
    }
    
    func testDecodeRGBA_AdditionalMemory() throws {
        let frame = makeLargeFrame(width: 256, height: 256, channels: 4)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        
        let memoryBefore = getMemoryUsage()
        
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        
        let memoryAfter = getMemoryUsage()
        let memoryUsed = memoryAfter > memoryBefore ? memoryAfter - memoryBefore : 0
        
        // RGBA should use ~4/3 the memory of RGB
        XCTAssertLessThan(memoryUsed, 25 * 1024 * 1024,
                         "RGBA decode used \(memoryUsed / 1024 / 1024) MB, expected < 25 MB")
        
        XCTAssertEqual(decoded.channels, 4)
    }
}
