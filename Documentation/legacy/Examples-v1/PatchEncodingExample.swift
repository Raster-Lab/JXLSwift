// Example: Patch Encoding
//
// Demonstrates patch encoding — copying repeated rectangular regions from
// reference frames rather than re-encoding them.  This achieves massive
// compression gains for screen recordings, slideshows, and animations with
// static UI elements.

import Foundation
import JXLSwift

func patchEncodingExample() throws {
    print("=== Patch Encoding Example ===\n")

    let width  = 256
    let height = 256

    // 1. Build a multi-frame animation with a large static background and a
    //    small moving element — ideal for patch encoding.
    var frames: [ImageFrame] = []

    for frameIndex in 0..<8 {
        var f = ImageFrame(width: width, height: height, channels: 3,
                           pixelType: .uint8, colorSpace: .sRGB)

        // Static gradient background (same in every frame)
        for y in 0..<height {
            for x in 0..<width {
                f.setPixel(x: x, y: y, channel: 0, value: UInt16(x / 2))
                f.setPixel(x: x, y: y, channel: 1, value: UInt16(y / 2))
                f.setPixel(x: x, y: y, channel: 2, value: 64)
            }
        }

        // Moving green rectangle (the only part that changes)
        let rectX = (frameIndex * 24) % (width - 32)
        for y in 100..<132 {
            for x in rectX..<(rectX + 32) {
                f.setPixel(x: x, y: y, channel: 0, value: 30)
                f.setPixel(x: x, y: y, channel: 1, value: 200)
                f.setPixel(x: x, y: y, channel: 2, value: 60)
            }
        }
        frames.append(f)
    }

    // 2. Encode with reference frames only (no patches)
    let refOnlyOptions = EncodingOptions(
        mode: .lossy(quality: 85),
        animationConfig: .fps30,
        referenceFrameConfig: .balanced
    )
    let refOnlyResult = try JXLEncoder(options: refOnlyOptions).encode(frames)

    // 3. Encode with reference frames + screen-content patches
    let patchOptions = EncodingOptions(
        mode: .lossy(quality: 85),
        animationConfig: .fps30,
        referenceFrameConfig: .balanced,
        patchConfig: .screenContent     // Optimised for UI/screen content
    )
    let patchResult = try JXLEncoder(options: patchOptions).encode(frames)

    print("Reference frames only : \(refOnlyResult.stats.compressedSize) bytes")
    print("With patch encoding   : \(patchResult.stats.compressedSize) bytes")
    let saving = refOnlyResult.stats.compressedSize - patchResult.stats.compressedSize
    if saving > 0 {
        let pct = Double(saving) * 100.0 / Double(refOnlyResult.stats.compressedSize)
        print(String(format: "Saving from patches   : %d bytes (%.1f%%)", saving, pct))
    }
    print("✅ Patch encoding example complete")
}

// Run the example
do {
    try patchEncodingExample()
} catch {
    print("Error: \(error)")
}
