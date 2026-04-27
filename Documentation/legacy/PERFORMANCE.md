# Performance Tuning Guide for JXLSwift

This guide provides strategies and best practices for optimizing JPEG XL encoding and decoding performance with JXLSwift.

## Table of Contents

1. [Understanding Performance Factors](#understanding-performance-factors)
2. [Hardware Acceleration](#hardware-acceleration)
3. [Encoding Options](#encoding-options)
4. [Memory Optimization](#memory-optimization)
5. [Concurrency and Parallelism](#concurrency-and-parallelism)
6. [Platform-Specific Optimizations](#platform-specific-optimizations)
7. [Benchmarking and Profiling](#benchmarking-and-profiling)
8. [Common Pitfalls](#common-pitfalls)
9. [Best Practices](#best-practices)

---

## Understanding Performance Factors

JPEG XL encoding performance depends on several factors:

### Compression Mode
- **Lossless (Modular)**: Slower, guarantees bit-perfect reproduction
- **Lossy (VarDCT)**: Faster at lower quality settings, slower at high quality

### Encoding Effort
- **Effort 1-3**: Fast encoding, moderate compression
- **Effort 4-6**: Balanced speed/compression
- **Effort 7-9**: Slow encoding, best compression

### Image Characteristics
- **Size**: Larger images take more time (scales roughly linearly)
- **Complexity**: High-frequency content (textures, noise) is slower to encode
- **Channel count**: More channels = more processing time
- **Pixel type**: `float32` is slower than `uint8` due to conversion overhead

### Hardware
- **CPU**: Single-core performance matters for scalar operations
- **SIMD**: ARM NEON (Apple Silicon) and x86 SIMD accelerate key operations
- **Accelerate**: Apple's vDSP framework provides optimized math operations
- **Metal GPU**: Offloads DCT and quantization to GPU (when available)

---

## Hardware Acceleration

JXLSwift automatically detects and uses available hardware acceleration. You can control this behavior:

### Automatic Detection (Recommended)

```swift
let encoder = JXLEncoder()  // Uses all available acceleration
let result = try encoder.encode(frame)
```

### Manual Control

```swift
let options = EncodingOptions(
    mode: .lossy(quality: 90),
    effort: .balanced,
    useAccelerate: true,   // Use Apple Accelerate (vDSP)
    useMetal: true,        // Use Metal GPU
    useNEON: true          // Use ARM NEON (Apple Silicon)
)
let encoder = JXLEncoder(options: options)
```

### Hardware Detection

```swift
import JXLSwift

let capabilities = HardwareCapabilities.detect()
print("CPU: \(capabilities.cpuArchitecture)")
print("Cores: \(capabilities.coreCount)")
print("NEON: \(capabilities.hasNEON)")
print("Accelerate: \(capabilities.hasAccelerate)")
print("Metal: \(capabilities.hasMetal)")
```

### Apple Silicon (M1/M2/M3)

**Best Configuration:**
```swift
let options = EncodingOptions(
    mode: .lossy(quality: 90),
    effort: .balanced,
    useAccelerate: true,  // vDSP for DCT
    useMetal: true,       // GPU for large images
    useNEON: true         // ARM NEON SIMD
)
```

**Expected Performance (M1):**
- Lossy 1920×1080, effort 3: ~200 ms
- Lossy 1920×1080, effort 7: ~2 seconds
- Lossless 256×256: ~50 ms

### Intel x86-64

**Best Configuration:**
```swift
let options = EncodingOptions(
    mode: .lossy(quality: 90),
    effort: .balanced,
    useAccelerate: true   // vDSP still helps
)
// NEON not available, uses scalar fallback
```

**Expected Performance (Intel i7):**
- Lossy 1920×1080, effort 3: ~700 ms
- Lossy 1920×1080, effort 7: ~7 seconds
- Lossless 256×256: ~150 ms

### Metal GPU Considerations

Metal GPU acceleration is most effective for:
- **Large images** (1920×1080 and above)
- **High effort levels** (7-9)
- **Batch processing** (encoding multiple images)

Metal may be slower for:
- **Small images** (< 512×512) due to GPU setup overhead
- **Low effort levels** (1-3) where CPU is already fast
- **Single-frame encoding** (GPU warmup cost)

**Tip:** Disable Metal for small images:
```swift
let options = EncodingOptions(
    mode: .lossy(quality: 90),
    useMetal: frame.width * frame.height > 500_000  // > ~500K pixels
)
```

---

## Encoding Options

### Quality vs. Speed Tradeoff

| Quality | Distance | Speed | Use Case |
|---------|----------|-------|----------|
| 100 | ~0.1 | Slowest | Near-lossless archival |
| 95 | ~0.5 | Very slow | High-quality photography |
| 90 | ~1.0 | Slow | Professional work |
| 75 | ~2.5 | Moderate | General purpose |
| 50 | ~5.0 | Fast | Web images, thumbnails |
| 25 | ~10.0 | Very fast | Low-quality preview |

### Effort Levels

| Effort | Preset | Encoding Time | Compression | Recommended Use |
|--------|--------|---------------|-------------|-----------------|
| 1 | `.fastest` | 1× | 100% | Real-time preview |
| 3 | `.fast` | 3× | 95% | Interactive tools |
| 5 | `.balanced` | 10× | 90% | **Default** |
| 7 | `.high` | 30× | 85% | Offline processing |
| 9 | `.maximum` | 100× | 80% | Archival, distribution |

**Recommendation:** Use `.balanced` (effort 5) for most cases. Use `.fast` for interactive applications. Use `.high` or `.maximum` only for final output.

### Presets

```swift
// Fast encoding
let fastOptions = EncodingOptions.fast
// - Mode: lossy(quality: 75)
// - Effort: .fast (3)
// - All acceleration enabled

// High quality
let hqOptions = EncodingOptions.highQuality
// - Mode: lossy(quality: 95)
// - Effort: .high (7)
// - All acceleration enabled

// Lossless
let losslessOptions = EncodingOptions.lossless
// - Mode: .lossless
// - Effort: .balanced (5)
```

---

## Memory Optimization

### Image Frame Pixel Types

Choose the appropriate pixel type for your data:

```swift
// uint8: 0-255 (1 byte/channel)
let frame8 = ImageFrame(width: w, height: h, channels: 3, pixelType: .uint8)

// uint16: 0-65535 (2 bytes/channel)
let frame16 = ImageFrame(width: w, height: h, channels: 3, pixelType: .uint16)

// float32: 0.0-1.0 (4 bytes/channel)
let frame32 = ImageFrame(width: w, height: h, channels: 3, pixelType: .float32)
```

**Memory Usage:**
- 1920×1080 RGB uint8: ~6.2 MB
- 1920×1080 RGB uint16: ~12.4 MB
- 1920×1080 RGB float32: ~24.7 MB

**Recommendation:** Use `uint8` for standard images, `uint16` for high-bit-depth, `float32` only for HDR.

### Planar vs. Interleaved

JXLSwift uses **planar** storage internally (separate arrays per channel). If your source data is interleaved (RGBRGBRGB...), avoid unnecessary conversions:

```swift
// Avoid: Converting interleaved → planar → interleaved
let interleavedData: [UInt8] = loadImage()
var frame = ImageFrame(width: w, height: h, channels: 3)
// This is inefficient:
for i in 0..<interleavedData.count {
    let channel = i % 3
    let pixelIndex = i / 3
    let x = pixelIndex % w
    let y = pixelIndex / w
    frame.setPixel(x: x, y: y, channel: channel, value: interleavedData[i])
}

// Better: Load directly into planar format
var frame = ImageFrame(width: w, height: h, channels: 3)
for c in 0..<3 {
    for y in 0..<h {
        for x in 0..<w {
            let idx = (y * w + x) * 3 + c
            frame.setPixel(x: x, y: y, channel: c, value: interleavedData[idx])
        }
    }
}

// Best: Use ImageFrame.init with planar data if available
```

### Reusing Frames

If encoding multiple images with the same dimensions, reuse the frame:

```swift
var frame = ImageFrame(width: 1920, height: 1080, channels: 3)
let encoder = JXLEncoder()

for imageData in imageBatch {
    // Reuse frame, just update pixels
    loadPixels(into: &frame, from: imageData)
    let result = try encoder.encode(frame)
    save(result.data)
}
```

### Memory-Bounded Decoding

For large images, use progressive decoding to limit memory:

```swift
let decoder = JXLDecoder()
try decoder.decodeProgressive(largeJXLData) { pass, frame in
    if pass == 0 {
        // DC-only pass: 8× downsampled
        // Memory usage: ~1/64 of full image
        displayPreview(frame)
    }
    return pass < 2  // Stop after low-frequency pass
}
```

---

## Concurrency and Parallelism

### Thread Count

Control the number of encoding threads:

```swift
let options = EncodingOptions(
    mode: .lossy(quality: 90),
    threadCount: 4  // Use 4 threads
)

// Or use automatic detection (recommended)
let autoOptions = EncodingOptions(
    mode: .lossy(quality: 90),
    threadCount: 0  // 0 = auto-detect (uses all available cores)
)
```

**Recommendation:**
- **Single image**: Use all cores (`threadCount: 0`)
- **Batch processing**: Use fewer threads per image to avoid oversubscription

### Batch Encoding

For encoding multiple images, use Swift concurrency:

```swift
import JXLSwift

func encodeBatch(_ frames: [ImageFrame]) async throws -> [EncodedImage] {
    try await withThrowingTaskGroup(of: (Int, EncodedImage).self) { group in
        for (index, frame) in frames.enumerated() {
            group.addTask {
                let encoder = JXLEncoder(options: .fast)
                let result = try encoder.encode(frame)
                return (index, result)
            }
        }
        
        var results = [EncodedImage?](repeating: nil, count: frames.count)
        for try await (index, result) in group {
            results[index] = result
        }
        return results.compactMap { $0 }
    }
}

// Usage
let frames: [ImageFrame] = loadImages()
let encoded = try await encodeBatch(frames)
```

### Dispatch Queues (Legacy)

For older code using Dispatch:

```swift
let queue = DispatchQueue(label: "com.example.jxl", attributes: .concurrent)
let group = DispatchGroup()

for frame in frames {
    queue.async(group: group) {
        let encoder = JXLEncoder(options: .fast)
        let result = try? encoder.encode(frame)
        // Handle result
    }
}

group.wait()
```

---

## Platform-Specific Optimizations

### macOS (Desktop)

```swift
let options = EncodingOptions(
    mode: .lossy(quality: 90),
    effort: .balanced,
    useAccelerate: true,
    useMetal: true,
    threadCount: 0  // Use all cores
)
```

**Considerations:**
- Desktop Macs have powerful CPUs and GPUs
- Use higher effort levels for better quality
- Metal GPU acceleration is very effective

### iOS / iPadOS (Mobile)

```swift
let options = EncodingOptions(
    mode: .lossy(quality: 75),
    effort: .fast,
    useAccelerate: true,
    useMetal: UIDevice.current.userInterfaceIdiom == .pad,  // iPad only
    threadCount: 2  // Limit threads for battery life
)
```

**Considerations:**
- Battery life matters: use lower effort
- Thermal throttling: limit thread count
- Memory is limited: use `uint8` pixel type
- Metal on iPhone may not be worth the overhead

### watchOS (Wearable)

```swift
let options = EncodingOptions(
    mode: .lossy(quality: 50),
    effort: .fastest,
    useAccelerate: true,
    useMetal: false,  // No Metal on watchOS
    threadCount: 1    // Single thread
)
```

**Considerations:**
- Extremely limited resources
- Use lowest acceptable quality
- Encode on iPhone/Mac, transfer compressed
- Consider pre-compressed content

### tvOS (Set-Top Box)

```swift
let options = EncodingOptions(
    mode: .lossy(quality: 90),
    effort: .balanced,
    useAccelerate: true,
    useMetal: true,
    threadCount: 0
)
```

**Considerations:**
- Powerful hardware, similar to desktop
- 4K/HDR content is common
- GPU acceleration recommended

---

## Benchmarking and Profiling

### Built-In Statistics

```swift
let encoder = JXLEncoder(options: .balanced)
let result = try encoder.encode(frame)

print("Original: \(result.stats.originalSize) bytes")
print("Compressed: \(result.stats.compressedSize) bytes")
print("Ratio: \(result.stats.compressionRatio)×")
print("Time: \(result.stats.encodingTime) seconds")
print("Memory: \(result.stats.peakMemoryUsage) bytes")
```

### Performance Testing

Use XCTest's `measure` for benchmarking:

```swift
import XCTest
import JXLSwift

class PerformanceTests: XCTestCase {
    func testEncodingSpeed() {
        let frame = ImageFrame(width: 1920, height: 1080, channels: 3)
        let encoder = JXLEncoder(options: .balanced)
        
        measure {
            _ = try? encoder.encode(frame)
        }
    }
}
```

### Profiling with Instruments

1. Build in Release mode: `swift build -c release`
2. Open in Xcode and profile with Instruments
3. Use these instruments:
   - **Time Profiler**: Identify hot code paths
   - **Allocations**: Track memory usage
   - **System Trace**: See thread activity
   - **Metal System Trace**: GPU usage

### Key Metrics

Monitor these metrics for performance tuning:

- **Megapixels per second (MP/s)**: Throughput measure
  ```swift
  let mp = Double(frame.width * frame.height) / 1_000_000.0
  let mps = mp / result.stats.encodingTime
  print("Throughput: \(mps) MP/s")
  ```

- **Compression ratio**: Space savings
  ```swift
  print("Ratio: \(result.stats.compressionRatio)×")
  ```

- **Bits per pixel (bpp)**: Compression efficiency
  ```swift
  let bpp = Double(result.stats.compressedSize * 8) / Double(frame.width * frame.height)
  print("BPP: \(bpp)")
  ```

---

## Common Pitfalls

### 1. Using High Effort for Interactive Applications

❌ **Bad:**
```swift
let encoder = JXLEncoder(options: .maximum)  // Effort 9, very slow
let result = try encoder.encode(frame)
// User waits 30+ seconds
```

✅ **Good:**
```swift
let encoder = JXLEncoder(options: .fast)  // Effort 3, interactive
let result = try encoder.encode(frame)
// User waits < 1 second
```

### 2. Enabling Metal for Small Images

❌ **Bad:**
```swift
let smallFrame = ImageFrame(width: 64, height: 64, channels: 3)
let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90), useMetal: true))
// GPU setup overhead exceeds encoding time
```

✅ **Good:**
```swift
let smallFrame = ImageFrame(width: 64, height: 64, channels: 3)
let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90), useMetal: false))
// Use CPU for small images
```

### 3. Not Reusing Encoders

❌ **Bad:**
```swift
for frame in frames {
    let encoder = JXLEncoder()  // Creates new encoder each time
    let result = try encoder.encode(frame)
}
```

✅ **Good:**
```swift
let encoder = JXLEncoder()  // Create once
for frame in frames {
    let result = try encoder.encode(frame)  // Reuse
}
```

### 4. Oversubscribing Threads

❌ **Bad:**
```swift
for frame in frames {
    DispatchQueue.global().async {
        let encoder = JXLEncoder(options: EncodingOptions(threadCount: 0))  // Uses all cores
        // 10 frames × 8 cores = 80 threads!
    }
}
```

✅ **Good:**
```swift
for frame in frames {
    DispatchQueue.global().async {
        let encoder = JXLEncoder(options: EncodingOptions(threadCount: 1))  // 1 thread per task
    }
}
```

### 5. Using float32 Unnecessarily

❌ **Bad:**
```swift
let frame = ImageFrame(width: w, height: h, channels: 3, pixelType: .float32)
// Uses 4× memory of uint8
```

✅ **Good:**
```swift
let frame = ImageFrame(width: w, height: h, channels: 3, pixelType: .uint8)
// Use float32 only for HDR content
```

---

## Best Practices

### 1. Choose the Right Preset

```swift
// Interactive applications (preview, thumbnails)
let encoder = JXLEncoder(options: .fast)

// General-purpose encoding
let encoder = JXLEncoder(options: .balanced)

// Final output, archival
let encoder = JXLEncoder(options: .highQuality)

// Lossless archival
let encoder = JXLEncoder(options: .lossless)
```

### 2. Profile Before Optimizing

Always measure before and after optimization:

```swift
let start = Date()
let result = try encoder.encode(frame)
let duration = Date().timeIntervalSince(start)
print("Encoding took \(duration)s")
```

### 3. Use Appropriate Quality

Don't use higher quality than needed:

- **Quality 100**: Near-lossless, massive files
- **Quality 90-95**: Professional photography
- **Quality 75-85**: General purpose
- **Quality 50-75**: Web images
- **Quality < 50**: Thumbnails, previews

### 4. Leverage Hardware Acceleration

Let JXLSwift choose the best acceleration:

```swift
let encoder = JXLEncoder()  // Auto-detects and uses available acceleration
```

Or control explicitly when needed:

```swift
let options = EncodingOptions(
    mode: .lossy(quality: 90),
    useAccelerate: true,
    useMetal: frame.width * frame.height > 500_000
)
```

### 5. Batch Processing

Process multiple images efficiently:

```swift
func encodeImages(_ frames: [ImageFrame]) async throws -> [EncodedImage] {
    try await withThrowingTaskGroup(of: EncodedImage.self) { group in
        for frame in frames {
            group.addTask {
                let encoder = JXLEncoder(options: .fast)
                return try encoder.encode(frame)
            }
        }
        return try await group.reduce(into: []) { $0.append($1) }
    }
}
```

### 6. Monitor Memory Usage

For large images or batch processing:

```swift
let result = try encoder.encode(frame)
print("Peak memory: \(result.stats.peakMemoryUsage / 1_000_000) MB")

if result.stats.peakMemoryUsage > 500_000_000 {  // > 500 MB
    print("Warning: High memory usage")
}
```

---

## Performance Checklist

- [ ] Use appropriate quality setting (75-90 for most cases)
- [ ] Use `.fast` or `.balanced` effort for interactive applications
- [ ] Enable hardware acceleration (Accelerate, NEON, Metal)
- [ ] Choose the right pixel type (`uint8` vs `uint16` vs `float32`)
- [ ] Reuse encoder instances when encoding multiple images
- [ ] Use progressive decoding for large images
- [ ] Limit thread count for batch processing
- [ ] Profile with Instruments before optimizing
- [ ] Monitor memory usage for large images
- [ ] Test on target hardware (iPhone, iPad, Mac)

---

## Troubleshooting

### Slow Encoding on Apple Silicon

**Check:**
1. Is Accelerate enabled? `options.useAccelerate = true`
2. Is NEON enabled? `options.useNEON = true`
3. Are you using Release build? `swift build -c release`
4. Is effort too high? Try `.fast` or `.balanced`

### High Memory Usage

**Solutions:**
1. Use `uint8` instead of `float32`
2. Use progressive decoding
3. Process images in batches with limited concurrency
4. Monitor `result.stats.peakMemoryUsage`

### Poor GPU Performance

**Causes:**
1. Image too small (< 512×512)
2. GPU setup overhead
3. Metal not available on this platform

**Solution:**
```swift
let useMetal = frame.width * frame.height > 500_000
let options = EncodingOptions(mode: .lossy(quality: 90), useMetal: useMetal)
```

---

## Conclusion

JXLSwift provides multiple tuning options for optimal performance. Follow these guidelines:

1. **Start with defaults**: Use `.balanced` preset
2. **Profile your workload**: Measure before optimizing
3. **Choose appropriate quality**: Don't over-quality
4. **Leverage hardware**: Enable Accelerate, NEON, Metal
5. **Manage concurrency**: Avoid thread oversubscription
6. **Monitor resources**: Track time and memory usage

For most applications, the default settings provide excellent performance. Fine-tune only when measurements indicate a need for optimization.
