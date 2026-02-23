// Example: Spline Encoding
//
// Demonstrates detecting and encoding smooth curves, edges, and line art as
// vector splines.  Spline encoding provides resolution-independent quality
// for illustrations, diagrams, and UI screenshots with sharp lines.

import Foundation
import JXLSwift

func splineEncodingExample() throws {
    print("=== Spline Encoding Example ===\n")

    let width  = 128
    let height = 128

    // 1. Create an image with a diagonal line (a simple "line art" image)
    var frame = ImageFrame(width: width, height: height, channels: 3,
                           pixelType: .uint8, colorSpace: .sRGB)
    // White background
    for y in 0..<height {
        for x in 0..<width {
            frame.setPixel(x: x, y: y, channel: 0, value: 255)
            frame.setPixel(x: x, y: y, channel: 1, value: 255)
            frame.setPixel(x: x, y: y, channel: 2, value: 255)
        }
    }
    // Black diagonal line
    for i in 0..<min(width, height) {
        frame.setPixel(x: i, y: i, channel: 0, value: 0)
        frame.setPixel(x: i, y: i, channel: 1, value: 0)
        frame.setPixel(x: i, y: i, channel: 2, value: 0)
    }

    // 2. Configure spline detection and encoding
    let splineConfig = SplineConfig(
        enabled: true,
        quantizationAdjustment: 0,   // No extra quantisation
        minControlPointDistance: 4.0,
        maxSplinesPerFrame: 50,
        edgeThreshold: 0.1,          // Sensitivity to edges
        minEdgeLength: 3.0
    )

    let options = EncodingOptions(
        mode: .lossy(quality: 90),
        splineConfig: splineConfig
    )

    let encoder = JXLEncoder(options: options)
    let result = try encoder.encode(frame)

    // 3. Run the spline detector standalone to see what it found
    let detector = SplineDetector(config: splineConfig)
    let splines = (try? detector.detectSplines(in: frame)) ?? []

    print("Splines detected: \(splines.count)")
    for (i, spline) in splines.enumerated() {
        print("  Spline \(i): \(spline.controlPoints.count) control points")
    }
    print("Compressed: \(result.stats.compressedSize) bytes")
    print("✅ Spline encoding example complete")
}

// Run the example
do {
    try splineEncodingExample()
} catch {
    print("Error: \(error)")
}
