// Example: Extra Channels
//
// Demonstrates encoding depth maps, thermal data, and arbitrary application-
// specific channels alongside the main colour image.

import Foundation
import JXLSwift

func extraChannelsExample() throws {
    print("=== Extra Channels Example ===\n")

    let width  = 64
    let height = 64

    // 1. Build the colour image
    var frame = ImageFrame(
        width: width,
        height: height,
        channels: 3,
        pixelType: .uint16,
        colorSpace: .sRGB,
        extraChannels: [
            ExtraChannelInfo.depth(bitsPerSample: 16, name: "Depth"),
            ExtraChannelInfo.thermal(bitsPerSample: 16, name: "Thermal"),
            ExtraChannelInfo.optional(bitsPerSample: 8, name: "Confidence"),
        ]
    )

    // 2. Fill colour channels
    for y in 0..<height {
        for x in 0..<width {
            frame.setPixel(x: x, y: y, channel: 0,
                           value: UInt16((x * 65535) / max(1, width - 1)))
            frame.setPixel(x: x, y: y, channel: 1,
                           value: UInt16((y * 65535) / max(1, height - 1)))
            frame.setPixel(x: x, y: y, channel: 2, value: 32768)
        }
    }

    // 3. Fill depth channel (channel index 0 in extraChannelData)
    for y in 0..<height {
        for x in 0..<width {
            // Simulated depth: closer at the centre
            let dx = Float(x) - Float(width) / 2
            let dy = Float(y) - Float(height) / 2
            let dist = (dx * dx + dy * dy).squareRoot()
            let depth = UInt16(max(0, 65535 - Int(dist * 800)))
            frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 0,
                                       value: depth)
        }
    }

    // 4. Fill thermal channel (simulated temperature 20 °C–40 °C → 0–65535)
    for y in 0..<height {
        for x in 0..<width {
            let tempNorm = Float(y) / Float(max(1, height - 1))
            let thermal = UInt16(tempNorm * 65535)
            frame.setExtraChannelValue(x: x, y: y, extraChannelIndex: 1,
                                       value: thermal)
        }
    }

    // 5. Encode losslessly to preserve all extra channel data
    let encoder = JXLEncoder(options: .lossless)
    let result = try encoder.encode(frame)

    print("Channels  : \(frame.channels) colour + \(frame.extraChannels.count) extra")
    print("Compressed: \(result.stats.compressedSize) bytes")
    print("Ratio     : \(String(format: "%.2f", result.stats.compressionRatio))×")

    // 6. Read back the depth at the image centre
    let cx = width / 2, cy = height / 2
    let centreDepth = frame.getExtraChannelValue(x: cx, y: cy,
                                                  extraChannelIndex: 0)
    print("Centre depth value: \(centreDepth)")
    print("✅ Extra channels example complete")
}

// Run the example
do {
    try extraChannelsExample()
} catch {
    print("Error: \(error)")
}
