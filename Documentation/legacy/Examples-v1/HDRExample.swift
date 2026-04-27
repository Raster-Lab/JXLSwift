// Example: HDR and Wide-Gamut Encoding
//
// Demonstrates encoding High Dynamic Range images using Rec. 2020 colour
// primaries with PQ (HDR10) and HLG transfer functions, and wide-gamut images
// using Display P3.

import Foundation
import JXLSwift

func hdrEncodingExample() throws {
    print("=== HDR and Wide-Gamut Encoding Example ===\n")

    let width  = 128
    let height = 128

    // 1. HDR10 (Rec. 2020 + PQ) — float32 pixels, values 0.0–1.0 (mapped to 0–10 000 nits)
    var hdr10Frame = ImageFrame(
        width: width,
        height: height,
        channels: 3,
        pixelType: .float32,
        colorSpace: .rec2020PQ     // Rec. 2020 primaries, PQ (SMPTE ST 2084) transfer
    )

    // Fill with a high-dynamic-range gradient
    for y in 0..<height {
        for x in 0..<width {
            // float32 pixels use a normalised 0.0–1.0 range
            let r = Float(x) / Float(max(1, width  - 1))
            let g = Float(y) / Float(max(1, height - 1))
            let b: Float = 0.5
            // setPixel stores float32 via UInt16 bit-pattern representation;
            // for float32 frames use the Float-specific setter
            hdr10Frame.setPixelFloat(x: x, y: y, channel: 0, value: r)
            hdr10Frame.setPixelFloat(x: x, y: y, channel: 1, value: g)
            hdr10Frame.setPixelFloat(x: x, y: y, channel: 2, value: b)
        }
    }

    let encoder = JXLEncoder(options: EncodingOptions(
        mode: .lossy(quality: 92),
        effort: .squirrel
    ))
    let hdr10Result = try encoder.encode(hdr10Frame)
    print("HDR10 (PQ) : \(hdr10Result.stats.compressedSize) bytes  " +
          "(\(String(format: "%.2f", hdr10Result.stats.compressionRatio))×)")

    // 2. HLG (Rec. 2020 + HLG) — compatible with SDR displays
    var hlgFrame = ImageFrame(
        width: width,
        height: height,
        channels: 3,
        pixelType: .float32,
        colorSpace: .rec2020HLG    // Rec. 2020 primaries, HLG transfer
    )
    for y in 0..<height {
        for x in 0..<width {
            let v = Float(x + y) / Float(max(1, width + height - 2))
            hlgFrame.setPixelFloat(x: x, y: y, channel: 0, value: v)
            hlgFrame.setPixelFloat(x: x, y: y, channel: 1, value: v * 0.8)
            hlgFrame.setPixelFloat(x: x, y: y, channel: 2, value: v * 0.6)
        }
    }
    let hlgResult = try encoder.encode(hlgFrame)
    print("HLG        : \(hlgResult.stats.compressedSize) bytes  " +
          "(\(String(format: "%.2f", hlgResult.stats.compressionRatio))×)")

    // 3. Display P3 — common on modern Apple devices
    var p3Frame = ImageFrame(
        width: width,
        height: height,
        channels: 3,
        pixelType: .uint16,
        colorSpace: .displayP3     // P3 primaries, sRGB transfer
    )
    for y in 0..<height {
        for x in 0..<width {
            p3Frame.setPixel(x: x, y: y, channel: 0,
                              value: UInt16((x * 65535) / max(1, width  - 1)))
            p3Frame.setPixel(x: x, y: y, channel: 1,
                              value: UInt16((y * 65535) / max(1, height - 1)))
            p3Frame.setPixel(x: x, y: y, channel: 2, value: 32768)
        }
    }
    let p3Result = try encoder.encode(p3Frame)
    print("Display P3 : \(p3Result.stats.compressedSize) bytes  " +
          "(\(String(format: "%.2f", p3Result.stats.compressionRatio))×)")

    print("\n✅ HDR / wide-gamut encoding complete")
}

// Run the example
do {
    try hdrEncodingExample()
} catch {
    print("Error: \(error)")
}
