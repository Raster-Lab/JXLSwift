// Example: Animation Encoding
//
// Demonstrates multi-frame animation support in JXLSwift, including frame
// timing, loop control, reference frame delta-encoding, and patch copying.

import Foundation
import JXLSwift

func animationExample() throws {
    print("=== Animation Encoding Example ===\n")

    let width  = 64
    let height = 64

    // 1. Build three animation frames (a simple colour cycle)
    var frames: [ImageFrame] = []
    let colours: [(UInt16, UInt16, UInt16)] = [
        (220, 50, 50),   // Frame 0 – warm red
        (50, 200, 80),   // Frame 1 – fresh green
        (50, 100, 220),  // Frame 2 – cool blue
    ]

    for (r, g, b) in colours {
        var f = ImageFrame(width: width, height: height, channels: 3,
                           pixelType: .uint8, colorSpace: .sRGB)
        for y in 0..<height {
            for x in 0..<width {
                f.setPixel(x: x, y: y, channel: 0, value: r)
                f.setPixel(x: x, y: y, channel: 1, value: g)
                f.setPixel(x: x, y: y, channel: 2, value: b)
            }
        }
        frames.append(f)
    }

    // 2. Configure animation at 10 fps, loop forever
    let animConfig = AnimationConfig(
        fps: 10,
        loopCount: 0   // 0 = loop forever
    )

    let options = EncodingOptions(
        mode: .lossy(quality: 90),
        animationConfig: animConfig
    )

    let encoder = JXLEncoder(options: options)
    let result = try encoder.encode(frames)

    print("Frames    : \(frames.count)")
    print("Compressed: \(result.stats.compressedSize) bytes")
    print("Ratio     : \(String(format: "%.2f", result.stats.compressionRatio))×")
}

func referenceFrameExample() throws {
    print("\n=== Reference Frame + Patch Encoding ===\n")

    let width  = 128
    let height = 128

    // Create a "background" that stays mostly constant and a moving element
    var frames: [ImageFrame] = []
    for frameIndex in 0..<5 {
        var f = ImageFrame(width: width, height: height, channels: 3,
                           pixelType: .uint8, colorSpace: .sRGB)
        // Static grey background
        for y in 0..<height {
            for x in 0..<width {
                f.setPixel(x: x, y: y, channel: 0, value: 180)
                f.setPixel(x: x, y: y, channel: 1, value: 180)
                f.setPixel(x: x, y: y, channel: 2, value: 180)
            }
        }
        // Moving red square
        let sqX = frameIndex * 16
        for y in 20..<40 {
            for x in sqX..<(sqX + 20) where x < width {
                f.setPixel(x: x, y: y, channel: 0, value: 220)
                f.setPixel(x: x, y: y, channel: 1, value: 40)
                f.setPixel(x: x, y: y, channel: 2, value: 40)
            }
        }
        frames.append(f)
    }

    let options = EncodingOptions(
        mode: .lossy(quality: 90),
        animationConfig: .fps24,
        referenceFrameConfig: .balanced,  // Delta encode against keyframes
        patchConfig: .screenContent        // Copy repeated background regions
    )

    let encoder = JXLEncoder(options: options)
    let result = try encoder.encode(frames)

    print("Frames    : \(frames.count)")
    print("Compressed: \(result.stats.compressedSize) bytes")
    print("✅ Animation with reference frames and patches encoded")
}

// Run the examples
do {
    try animationExample()
    try referenceFrameExample()
} catch {
    print("Error: \(error)")
}
