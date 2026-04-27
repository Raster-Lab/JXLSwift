// Example: Basic JXL Encoding
//
// This example demonstrates basic usage of JXLSwift to encode an image

import Foundation
import JXLSwift

func basicEncodingExample() throws {
    print("=== Basic JXL Encoding Example ===\n")
    
    // 1. Create an image frame
    print("Creating 512x512 RGB image...")
    var frame = ImageFrame(
        width: 512,
        height: 512,
        channels: 3,
        pixelType: .uint8,
        colorSpace: .sRGB
    )
    
    // 2. Fill with a gradient pattern
    print("Filling with gradient pattern...")
    for y in 0..<frame.height {
        for x in 0..<frame.width {
            let r = UInt16((x * 255) / frame.width)
            let g = UInt16((y * 255) / frame.height)
            let b = UInt16(128)
            
            frame.setPixel(x: x, y: y, channel: 0, value: r)
            frame.setPixel(x: x, y: y, channel: 1, value: g)
            frame.setPixel(x: x, y: y, channel: 2, value: b)
        }
    }
    
    // 3. Create encoder with default settings
    print("Encoding with default settings...")
    let encoder = JXLEncoder()
    
    // 4. Encode the image
    let result = try encoder.encode(frame)
    
    // 5. Display results
    print("\n=== Encoding Results ===")
    print("Original size: \(result.stats.originalSize) bytes")
    print("Compressed size: \(result.stats.compressedSize) bytes")
    print("Compression ratio: \(String(format: "%.2f", result.stats.compressionRatio))x")
    print("Encoding time: \(String(format: "%.3f", result.stats.encodingTime))s")
    print("Data starts with: \(result.data.prefix(10).map { String(format: "%02X", $0) }.joined(separator: " "))")
}

// Run the example
do {
    try basicEncodingExample()
} catch {
    print("Error: \(error)")
}
