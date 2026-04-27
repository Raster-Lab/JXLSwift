// Example: Lossy JXL Encoding
//
// Demonstrates lossy compression using JXLSwift's VarDCT mode across a range
// of quality settings.  VarDCT is JPEG XL's DCT-based lossy codec; it
// outperforms JPEG at equivalent visual quality.

import Foundation
import JXLSwift

func lossyEncodingExample() throws {
    print("=== Lossy JXL Encoding Example ===\n")

    // 1. Create a 512×512 RGB image frame
    var frame = ImageFrame(
        width: 512,
        height: 512,
        channels: 3,
        pixelType: .uint8,
        colorSpace: .sRGB
    )

    // 2. Fill with a gradient to give the compressor something to work with
    for y in 0..<frame.height {
        for x in 0..<frame.width {
            let r = UInt16((x * 255) / (frame.width - 1))
            let g = UInt16((y * 255) / (frame.height - 1))
            let b = UInt16(128)
            frame.setPixel(x: x, y: y, channel: 0, value: r)
            frame.setPixel(x: x, y: y, channel: 1, value: g)
            frame.setPixel(x: x, y: y, channel: 2, value: b)
        }
    }

    // 3. Compare several quality levels
    let qualities: [Float] = [50, 75, 90, 95]

    print(String(format: "%-10s %-16s %-10s %-10s",
                 "Quality", "Compressed", "Ratio", "Time"))
    print(String(repeating: "─", count: 50))

    for quality in qualities {
        let options = EncodingOptions(
            mode: .lossy(quality: quality),
            effort: .squirrel           // Default balanced effort
        )
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)

        print(String(format: "%-10.0f %-16d %-10.2f %-10.3f",
                     quality,
                     result.stats.compressedSize,
                     result.stats.compressionRatio,
                     result.stats.encodingTime))
    }

    // 4. Encode with the high-quality preset (convenience shorthand)
    print("\n--- High-quality preset ---")
    let hqEncoder = JXLEncoder(options: .highQuality)
    let hqResult = try hqEncoder.encode(frame)
    print("Compressed: \(hqResult.stats.compressedSize) bytes  " +
          "(\(String(format: "%.2f", hqResult.stats.compressionRatio))×)")

    // 5. Encode with ANS entropy coding for better compression at slow effort
    print("\n--- ANS entropy coding (effort: tortoise) ---")
    let ansOptions = EncodingOptions(
        mode: .lossy(quality: 90),
        effort: .tortoise,
        useANS: true
    )
    let ansEncoder = JXLEncoder(options: ansOptions)
    let ansResult = try ansEncoder.encode(frame)
    print("Compressed: \(ansResult.stats.compressedSize) bytes  " +
          "(\(String(format: "%.2f", ansResult.stats.compressionRatio))×)")
}

// Run the example
do {
    try lossyEncodingExample()
} catch {
    print("Error: \(error)")
}
