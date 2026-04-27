// Example: Noise Synthesis
//
// Demonstrates adding film grain or synthetic noise to JPEG XL images.
// Noise synthesis improves perceptual quality by masking quantisation
// artefacts and preserving natural texture appearance in photographs.

import Foundation
import JXLSwift

func noiseSynthesisExample() throws {
    print("=== Noise Synthesis Example ===\n")

    let width  = 128
    let height = 128

    // 1. Create a smooth gradient (smooth areas are most sensitive to
    //    quantisation artefacts — noise synthesis helps here most)
    var frame = ImageFrame(width: width, height: height, channels: 3,
                           pixelType: .uint8, colorSpace: .sRGB)
    for y in 0..<height {
        for x in 0..<width {
            let v = UInt16((x + y) * 255 / (width + height - 2))
            frame.setPixel(x: x, y: y, channel: 0, value: v)
            frame.setPixel(x: x, y: y, channel: 1, value: v)
            frame.setPixel(x: x, y: y, channel: 2, value: v)
        }
    }

    // 2. Configure noise synthesis
    let noiseConfig = NoiseConfig(
        enabled: true,
        amplitude: 0.03,         // Subtle noise level (0.0–1.0)
        lumaStrength: 0.8,       // How much luma noise to add
        chromaStrength: 0.3,     // Less chroma noise for natural look
        seed: 42                 // Reproducible noise pattern
    )

    let options = EncodingOptions(
        mode: .lossy(quality: 80),
        noiseConfig: noiseConfig
    )

    let encoder = JXLEncoder(options: options)
    let result = try encoder.encode(frame)

    // 3. Compare with plain lossy encoding
    let plainOptions = EncodingOptions(mode: .lossy(quality: 80))
    let plainEncoder = JXLEncoder(options: plainOptions)
    let plainResult = try plainEncoder.encode(frame)

    print("Plain lossy : \(plainResult.stats.compressedSize) bytes")
    print("With noise  : \(result.stats.compressedSize) bytes")
    print("Noise amplitude : \(noiseConfig.amplitude)")
    print("Luma strength   : \(noiseConfig.lumaStrength)")
    print("Chroma strength : \(noiseConfig.chromaStrength)")
    print("✅ Noise synthesis example complete")
}

// Run the example
do {
    try noiseSynthesisExample()
} catch {
    print("Error: \(error)")
}
