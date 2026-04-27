// Example: JXL Decoding
//
// Demonstrates decoding a JPEG XL codestream back to an ImageFrame, including
// container extraction, header inspection, progressive decoding, and metadata
// extraction.

import Foundation
import JXLSwift

func decodingExample() throws {
    print("=== JXL Decoding Example ===\n")

    // 1. Produce a small encoded image to decode
    var frame = ImageFrame(width: 128, height: 128, channels: 3,
                           pixelType: .uint8, colorSpace: .sRGB)
    for y in 0..<frame.height {
        for x in 0..<frame.width {
            frame.setPixel(x: x, y: y, channel: 0,
                           value: UInt16((x * 255) / (frame.width - 1)))
            frame.setPixel(x: x, y: y, channel: 1,
                           value: UInt16((y * 255) / (frame.height - 1)))
            frame.setPixel(x: x, y: y, channel: 2, value: 128)
        }
    }

    let encoder = JXLEncoder(options: .lossless)
    let encoded = try encoder.encode(frame)
    let jxlData = encoded.data
    print("Encoded \(jxlData.count) bytes")

    // 2. Basic decode
    let decoder = JXLDecoder()
    let decoded = try decoder.decode(jxlData)
    print("Decoded: \(decoded.width)×\(decoded.height), " +
          "\(decoded.channels) channels, pixelType: \(decoded.pixelType)")

    // 3. Parse the image header (without full decode)
    let codestream = try decoder.extractCodestream(jxlData)
    let header = try decoder.parseImageHeader(codestream)
    print("\nImage header:")
    print("  \(header.width)×\(header.height), " +
          "\(header.channels) channels, \(header.bitsPerSample) bpp")
    print("  hasAlpha: \(header.hasAlpha)")

    // 4. Access individual pixels
    let r = decoded.getPixel(x: 64, y: 64, channel: 0)
    let g = decoded.getPixel(x: 64, y: 64, channel: 1)
    let b = decoded.getPixel(x: 64, y: 64, channel: 2)
    print("\nCentre pixel: R=\(r), G=\(g), B=\(b)")

    print("\n✅ Decoding complete")
}

func progressiveDecodingExample() throws {
    print("\n=== Progressive Decoding Example ===\n")

    // Encode with progressive flag enabled
    var frame = ImageFrame(width: 64, height: 64, channels: 3,
                           pixelType: .uint8, colorSpace: .sRGB)
    for y in 0..<frame.height {
        for x in 0..<frame.width {
            frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 3))
            frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 3))
            frame.setPixel(x: x, y: y, channel: 2, value: 100)
        }
    }

    let options = EncodingOptions(mode: .lossy(quality: 90), progressive: true)
    let encoder = JXLEncoder(options: options)
    let encoded = try encoder.encode(frame)

    // Decode progressively — callback receives each pass
    let decoder = JXLDecoder()
    try decoder.decodeProgressive(encoded.data) { pass, passFrame in
        print("Pass \(pass): \(passFrame.width)×\(passFrame.height) received")
        // In a real app, update the UI here for incremental display
    }

    print("✅ Progressive decoding complete")
}

// Run the examples
do {
    try decodingExample()
    try progressiveDecodingExample()
} catch {
    print("Error: \(error)")
}
