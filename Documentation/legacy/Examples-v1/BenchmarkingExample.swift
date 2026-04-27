// Example: Benchmarking and Quality Metrics
//
// Demonstrates measuring encoding performance, comparing quality at different
// effort levels, and using PSNR/SSIM quality metrics to evaluate lossy
// compression fidelity.

import Foundation
import JXLSwift

/// Build a synthetic test image
private func testImage(width: Int, height: Int) -> ImageFrame {
    var frame = ImageFrame(width: width, height: height, channels: 3,
                           pixelType: .uint8, colorSpace: .sRGB)
    for y in 0..<height {
        for x in 0..<width {
            frame.setPixel(x: x, y: y, channel: 0,
                           value: UInt16((x * 255) / max(1, width  - 1)))
            frame.setPixel(x: x, y: y, channel: 1,
                           value: UInt16((y * 255) / max(1, height - 1)))
            frame.setPixel(x: x, y: y, channel: 2,
                           value: UInt16((x ^ y) % 256))
        }
    }
    return frame
}

func benchmarkEncodingEfforts() throws {
    print("=== Encoding Effort Benchmark ===\n")

    let frame = testImage(width: 256, height: 256)

    let efforts: [(label: String, effort: EncodingEffort)] = [
        ("lightning", .lightning),
        ("cheetah",   .cheetah),
        ("squirrel",  .squirrel),
        ("kitten",    .kitten),
        ("tortoise",  .tortoise),
    ]

    print(String(format: "%-12s %-14s %-8s",
                 "Effort", "Compressed", "Time(s)"))
    print(String(repeating: "─", count: 38))

    for item in efforts {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            effort: item.effort
        )
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)

        print(String(format: "%-12s %-14d %-8.3f",
                     item.label,
                     result.stats.compressedSize,
                     result.stats.encodingTime))
    }
}

func qualityMetricsExample() throws {
    print("\n=== Quality Metrics (PSNR / SSIM) ===\n")

    let original = testImage(width: 128, height: 128)

    let qualities: [Float] = [60, 75, 90, 95]

    print(String(format: "%-10s %-14s %-10s %-10s",
                 "Quality", "Compressed", "PSNR(dB)", "SSIM"))
    print(String(repeating: "─", count: 48))

    let decoder = JXLDecoder()

    for quality in qualities {
        let options = EncodingOptions(mode: .lossy(quality: quality))
        let encoder = JXLEncoder(options: options)
        let encoded = try encoder.encode(original)

        // Decode and measure quality
        let decoded  = try decoder.decode(encoded.data)
        let metrics  = try QualityMetrics.compare(original: original,
                                                  reconstructed: decoded)

        print(String(format: "%-10.0f %-14d %-10.2f %-10.4f",
                     quality,
                     encoded.stats.compressedSize,
                     metrics.psnr,
                     metrics.ssim))
    }

    print("\n✅ Benchmarking example complete")
}

// Run the examples
do {
    try benchmarkEncodingEfforts()
    try qualityMetricsExample()
} catch {
    print("Error: \(error)")
}
