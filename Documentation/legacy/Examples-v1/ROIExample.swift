// Example: Region-of-Interest (ROI) Encoding
//
// Demonstrates selective quality encoding: the specified region is preserved
// at a higher quality than the surrounding area.  Useful for encoding portraits
// (face region), scientific images (measurement zone), and web images where
// the focal point must be sharp.

import Foundation
import JXLSwift

func roiEncodingExample() throws {
    print("=== Region-of-Interest Encoding Example ===\n")

    let width  = 256
    let height = 256

    // 1. Create a test image
    var frame = ImageFrame(width: width, height: height, channels: 3,
                           pixelType: .uint8, colorSpace: .sRGB)
    for y in 0..<height {
        for x in 0..<width {
            frame.setPixel(x: x, y: y, channel: 0,
                           value: UInt16((x * 255) / max(1, width  - 1)))
            frame.setPixel(x: x, y: y, channel: 1,
                           value: UInt16((y * 255) / max(1, height - 1)))
            frame.setPixel(x: x, y: y, channel: 2, value: 128)
        }
    }

    // 2. Define a central ROI (64×64 at the centre of the image)
    let roi = RegionOfInterest(
        x: (width  - 64) / 2,    // Top-left X
        y: (height - 64) / 2,    // Top-left Y
        width:  64,
        height: 64,
        qualityBoost: 20.0,       // +20 quality points inside the ROI
        featherWidth: 8           // Gradual transition at the border
    )

    // 3. Encode with ROI
    let options = EncodingOptions(
        mode: .lossy(quality: 75),    // Base quality outside ROI
        regionOfInterest: roi
    )
    let encoder = JXLEncoder(options: options)
    let roiResult = try encoder.encode(frame)

    // 4. Encode without ROI for comparison
    let noRoiOptions = EncodingOptions(mode: .lossy(quality: 75))
    let noRoiEncoder = JXLEncoder(options: noRoiOptions)
    let noRoiResult = try noRoiEncoder.encode(frame)

    print("Without ROI: \(noRoiResult.stats.compressedSize) bytes")
    print("With ROI   : \(roiResult.stats.compressedSize) bytes  " +
          "(slightly larger due to higher quality in ROI)")
    print("ROI area   : (\(roi.x), \(roi.y))–(\(roi.x + roi.width), " +
          "\(roi.y + roi.height)) with \(Int(roi.qualityBoost))pt quality boost")
    print("✅ ROI encoding complete")
}

// Run the example
do {
    try roiEncodingExample()
} catch {
    print("Error: \(error)")
}
