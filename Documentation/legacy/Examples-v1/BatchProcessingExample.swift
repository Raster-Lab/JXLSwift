// Example: Batch Processing
//
// Demonstrates encoding multiple images in a loop and collecting statistics,
// simulating a batch-processing pipeline (e.g. photo archive conversion,
// web asset optimisation).

import Foundation
import JXLSwift

/// Simulates loading an image from disk by building a synthetic frame.
private func syntheticImage(width: Int, height: Int, seed: Int) -> ImageFrame {
    var frame = ImageFrame(width: width, height: height, channels: 3,
                           pixelType: .uint8, colorSpace: .sRGB)
    for y in 0..<height {
        for x in 0..<width {
            frame.setPixel(x: x, y: y, channel: 0,
                           value: UInt16((x + seed) % 256))
            frame.setPixel(x: x, y: y, channel: 1,
                           value: UInt16((y + seed) % 256))
            frame.setPixel(x: x, y: y, channel: 2,
                           value: UInt16((x ^ y ^ seed) % 256))
        }
    }
    return frame
}

func batchProcessingExample() throws {
    print("=== Batch Processing Example ===\n")

    // 1. Simulate a catalogue of images to convert
    let catalogue: [(name: String, width: Int, height: Int)] = [
        ("thumbnail",  128,  128),
        ("banner",     800,  200),
        ("portrait",   400,  600),
        ("landscape",  600,  400),
        ("square",     256,  256),
    ]

    let options = EncodingOptions(
        mode: .lossy(quality: 85),
        effort: .squirrel,
        useHardwareAcceleration: true,
        numThreads: 0       // 0 = auto-detect CPU cores
    )
    let encoder = JXLEncoder(options: options)

    // 2. Encode each image and collect statistics
    var totalOriginalBytes  = 0
    var totalCompressedBytes = 0
    var totalTime: Double    = 0

    print(String(format: "%-14s %-10s %-14s %-14s %-8s",
                 "Name", "Size", "Original", "Compressed", "Ratio"))
    print(String(repeating: "─", count: 64))

    for item in catalogue {
        let frame = syntheticImage(width: item.width, height: item.height,
                                   seed: item.name.hashValue)
        let result = try encoder.encode(frame)

        totalOriginalBytes   += result.stats.originalSize
        totalCompressedBytes += result.stats.compressedSize
        totalTime            += result.stats.encodingTime

        print(String(format: "%-14s %-10s %-14d %-14d %-8.2f",
                     item.name,
                     "\(item.width)×\(item.height)",
                     result.stats.originalSize,
                     result.stats.compressedSize,
                     result.stats.compressionRatio))
    }

    // 3. Print summary
    let overallRatio = totalOriginalBytes > 0
        ? Double(totalOriginalBytes) / Double(totalCompressedBytes) : 0
    print(String(repeating: "─", count: 64))
    print(String(format: "Total                       %-14d %-14d %-8.2f",
                 totalOriginalBytes, totalCompressedBytes, overallRatio))
    print(String(format: "\nProcessed %d images in %.3fs (%.1f img/s)",
                 catalogue.count, totalTime,
                 Double(catalogue.count) / max(totalTime, 0.001)))

    print("\n✅ Batch processing complete")
}

// Run the example
do {
    try batchProcessingExample()
} catch {
    print("Error: \(error)")
}
