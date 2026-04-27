// Minimal end-to-end example: encode an in-memory frame, then decode it.
//
// Build & run:
//   swift run jxl-tool encode --input some.png --output some.jxl --lossless
//   swift run jxl-tool decode --input some.jxl --output some.png

import Foundation
import JXLSwift

// Build a tiny synthetic 64×64 grayscale gradient.
var frame = ImageFrame(width: 64, height: 64, channels: 1,
                       pixelType: .uint8, colorSpace: .grayscale)
for y in 0..<frame.height {
    for x in 0..<frame.width {
        frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x * y) % 256))
    }
}

// Lossless encode at squirrel effort.
let encoded = try JXLEncoder(options: EncodingOptions(
    mode: .lossless, effort: .squirrel
)).encode(frame)
print("encoded \(encoded.data.count) bytes (ratio \(String(format: "%.2f", encoded.stats.compressionRatio))×)")

// Decode and verify.
let decoded = try JXLDecoder().decode(encoded.data)
assert(decoded.width == 64 && decoded.height == 64)
assert(decoded.data == frame.data, "round-trip not pixel-exact")
print("ok: decoded \(decoded.width)×\(decoded.height), \(decoded.channels)ch, pixel-exact match")
