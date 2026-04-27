// Example: Alpha Channel Support
//
// Demonstrates encoding images with transparency (alpha channel) in both
// straight and premultiplied alpha modes.

import Foundation
import JXLSwift

func alphaChannelExample() throws {
    print("=== Alpha Channel Encoding Example ===\n")

    let width  = 128
    let height = 128

    // 1. Create an RGBA frame (4 channels: R, G, B, A)
    var frame = ImageFrame(
        width: width,
        height: height,
        channels: 4,
        pixelType: .uint8,
        colorSpace: .sRGB,
        hasAlpha: true,
        alphaMode: .straight      // Alpha stored separately from colour
    )

    // 2. Fill with a radial gradient, transparent at the edges
    let cx = Float(width)  / 2
    let cy = Float(height) / 2
    let maxRadius = Float(min(width, height)) / 2

    for y in 0..<height {
        for x in 0..<width {
            let dx = Float(x) - cx
            let dy = Float(y) - cy
            let dist = (dx * dx + dy * dy).squareRoot()
            let alpha = max(0, 1 - dist / maxRadius)

            frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 2))     // R
            frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 2))     // G
            frame.setPixel(x: x, y: y, channel: 2, value: 180)               // B
            frame.setPixel(x: x, y: y, channel: 3,
                           value: UInt16(alpha * 255))                         // A
        }
    }

    // 3. Encode losslessly to preserve exact alpha values
    let encoder = JXLEncoder(options: .lossless)
    let result = try encoder.encode(frame)

    print("RGBA lossless: \(result.stats.compressedSize) bytes  " +
          "(\(String(format: "%.2f", result.stats.compressionRatio))×)")

    // 4. Verify round-trip preserves alpha
    let decoder = JXLDecoder()
    let decoded = try decoder.decode(result.data)
    let centreAlpha = decoded.getPixel(x: width / 2, y: height / 2, channel: 3)
    print("Centre alpha after round-trip: \(centreAlpha) (expected 255)")

    // 5. Premultiplied alpha mode (colour already multiplied by alpha)
    var premultFrame = ImageFrame(
        width: 64, height: 64, channels: 4,
        pixelType: .uint8, colorSpace: .sRGB,
        hasAlpha: true, alphaMode: .premultiplied
    )
    // Semi-transparent red pixel in premultiplied form: (128, 0, 0, 128)
    for y in 0..<64 {
        for x in 0..<64 {
            premultFrame.setPixel(x: x, y: y, channel: 0, value: 128)
            premultFrame.setPixel(x: x, y: y, channel: 1, value: 0)
            premultFrame.setPixel(x: x, y: y, channel: 2, value: 0)
            premultFrame.setPixel(x: x, y: y, channel: 3, value: 128)
        }
    }

    let premultResult = try encoder.encode(premultFrame)
    print("Premultiplied alpha: \(premultResult.stats.compressedSize) bytes")
    print("✅ Alpha channel examples complete")
}

// Run the example
do {
    try alphaChannelExample()
} catch {
    print("Error: \(error)")
}
