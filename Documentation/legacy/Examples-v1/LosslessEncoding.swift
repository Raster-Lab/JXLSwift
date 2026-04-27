// Example: Lossless JXL Encoding
//
// Demonstrates bit-perfect lossless compression using JXLSwift's Modular mode.
// Lossless mode guarantees that every pixel is reproduced exactly after
// decoding — ideal for archival, medical imaging, and scientific data.

import Foundation
import JXLSwift

func losslessEncodingExample() throws {
    print("=== Lossless JXL Encoding Example ===\n")

    // 1. Create a 256×256 RGB image frame with uint8 pixel type
    var frame = ImageFrame(
        width: 256,
        height: 256,
        channels: 3,
        pixelType: .uint8,
        colorSpace: .sRGB
    )

    // 2. Fill with a test pattern (sharp edges benefit most from lossless mode)
    for y in 0..<frame.height {
        for x in 0..<frame.width {
            // Checkerboard pattern — high-frequency content
            let isLight = ((x / 32) + (y / 32)) % 2 == 0
            let value: UInt16 = isLight ? 240 : 16
            frame.setPixel(x: x, y: y, channel: 0, value: value)
            frame.setPixel(x: x, y: y, channel: 1, value: value)
            frame.setPixel(x: x, y: y, channel: 2, value: value)
        }
    }

    // 3. Configure lossless encoding using the convenience preset
    let options = EncodingOptions.lossless
    let encoder = JXLEncoder(options: options)

    // 4. Encode
    let result = try encoder.encode(frame)

    print("Original size  : \(result.stats.originalSize) bytes")
    print("Compressed size: \(result.stats.compressedSize) bytes")
    print("Compression    : \(String(format: "%.2f", result.stats.compressionRatio))×")
    print("Encoding time  : \(String(format: "%.3f", result.stats.encodingTime))s")

    // 5. Verify round-trip (decode and compare every pixel)
    let decoder = JXLDecoder()
    let decoded = try decoder.decode(result.data)

    var pixelMismatches = 0
    for y in 0..<frame.height {
        for x in 0..<frame.width {
            for c in 0..<frame.channels {
                if frame.getPixel(x: x, y: y, channel: c) !=
                   decoded.getPixel(x: x, y: y, channel: c) {
                    pixelMismatches += 1
                }
            }
        }
    }
    print("\nRound-trip pixel mismatches: \(pixelMismatches) (must be 0 for lossless)")
    assert(pixelMismatches == 0, "Lossless round-trip failed")
    print("✅ Lossless round-trip verified")
}

// Run the example
do {
    try losslessEncodingExample()
} catch {
    print("Error: \(error)")
}
