# JXLSwift

A native Swift implementation of the JPEG XL (ISO/IEC 18181) compression codec, optimized for Apple Silicon hardware.

## Overview

JXLSwift provides a pure Swift implementation of the JPEG XL image compression standard with hardware-accelerated encoding for Apple Silicon (ARM NEON/SIMD) and Apple Accelerate framework integration. The library is designed for high performance with separate code paths for x86-64 that can be removed if needed.

## Features

- ✅ **Native Swift Implementation** - Pure Swift, no C/C++ dependencies
- 🚀 **Apple Silicon Optimized** - Leverages ARM NEON SIMD instructions
- ⚡ **Apple Accelerate Integration** - Uses vDSP for DCT and matrix operations
- 🎯 **Modular Architecture** - Separate x86-64 code paths for future removal
- 📦 **Two Compression Modes**:
  - **Lossless (Modular Mode)** - Perfect pixel reproduction
  - **Lossy (VarDCT Mode)** - High-quality lossy compression
- 🎨 **Advanced Color Support** - sRGB, linear RGB, grayscale, custom color spaces
- 🔧 **Flexible Configuration** - Quality levels, effort settings, hardware acceleration control

## Requirements

- Swift 6.0 or later
- macOS 13.0+ / iOS 16.0+ / tvOS 16.0+ / watchOS 9.0+ / visionOS 1.0+
- Apple Silicon (ARM64) recommended for optimal performance
- x86-64 supported with fallback implementations

## Installation

### Swift Package Manager

Add JXLSwift to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Raster-Lab/JXLSwift.git", from: "0.1.0")
]
```

## Usage

### Basic Encoding

```swift
import JXLSwift

// Create an image frame
var frame = ImageFrame(
    width: 1920,
    height: 1080,
    channels: 3,
    pixelType: .uint8,
    colorSpace: .sRGB
)

// Fill with image data
for y in 0..<frame.height {
    for x in 0..<frame.width {
        frame.setPixel(x: x, y: y, channel: 0, value: r)  // Red
        frame.setPixel(x: x, y: y, channel: 1, value: g)  // Green
        frame.setPixel(x: x, y: y, channel: 2, value: b)  // Blue
    }
}

// Create encoder
let encoder = JXLEncoder()

// Encode image
let result = try encoder.encode(frame)

// Access compressed data
let compressedData = result.data
print("Compression ratio: \(result.stats.compressionRatio)x")
print("Encoding time: \(result.stats.encodingTime)s")
```

### Lossless Encoding

```swift
let encoder = JXLEncoder(options: .lossless)
let result = try encoder.encode(frame)
```

### High-Quality Lossy Encoding

```swift
let encoder = JXLEncoder(options: .highQuality)
let result = try encoder.encode(frame)
```

### Fast Encoding

```swift
let encoder = JXLEncoder(options: .fast)
let result = try encoder.encode(frame)
```

### Custom Configuration

```swift
let options = EncodingOptions(
    mode: .lossy(quality: 92),
    effort: .kitten,              // Highest quality
    progressive: true,
    useHardwareAcceleration: true,
    useAccelerate: true,
    useMetal: true,
    numThreads: 0                 // Auto-detect
)

let encoder = JXLEncoder(options: options)
let result = try encoder.encode(frame)
```

### Hardware Capabilities Detection

```swift
let caps = HardwareCapabilities.shared

print("Running on: \(CPUArchitecture.current)")
print("ARM NEON: \(caps.hasNEON)")
print("Apple Accelerate: \(caps.hasAccelerate)")
print("Metal: \(caps.hasMetal)")
print("CPU cores: \(caps.coreCount)")
```

## Architecture

The library is organized into several modules:

```
Sources/JXLSwift/
├── Core/              # Fundamental data structures
│   ├── Architecture.swift     # CPU detection & capabilities
│   ├── ImageFrame.swift       # Image representation
│   ├── Bitstream.swift        # Bitstream I/O
│   └── EncodingOptions.swift  # Configuration
├── Encoding/          # Compression pipeline
│   ├── Encoder.swift          # Main encoder interface
│   ├── ModularEncoder.swift   # Lossless compression
│   └── VarDCTEncoder.swift    # Lossy compression
├── Hardware/          # Platform optimizations
│   └── Accelerate.swift       # Apple Silicon acceleration
└── Format/            # File format support (future)

Sources/JXLTool/
├── JXLTool.swift              # CLI entry point
├── Encode.swift               # Encode subcommand
├── Info.swift                  # Info subcommand
├── Hardware.swift              # Hardware subcommand
└── Benchmark.swift             # Benchmark subcommand
```

## Performance

JXLSwift is optimized for Apple Silicon:

- **ARM NEON SIMD** - Vectorized operations for pixel processing
- **Apple Accelerate** - vDSP DCT transforms and matrix operations
- **Metal GPU** - Parallel processing support (planned)

Benchmarks on Apple M1 (256x256 image):
- Fast mode: ~0.7s per frame
- High quality: ~2-3s per frame

## Compression Modes

### Modular Mode (Lossless)
- Perfect pixel-by-pixel reproduction
- Uses predictive coding + entropy encoding
- Ideal for archival, medical imaging, scientific data

### VarDCT Mode (Lossy)
- High-quality lossy compression
- Uses DCT transforms, quantization, and entropy coding
- Ideal for photographs, web delivery, general use

## Effort Levels

Encoding effort controls the quality/speed tradeoff:

1. **Lightning** - Fastest (minimal compression)
2. **Thunder**
3. **Falcon** - Fast preset
4. **Cheetah**
5. **Hare**
6. **Wombat**
7. **Squirrel** - Default (balanced)
8. **Kitten** - High quality preset
9. **Tortoise** - Maximum compression (slowest)

## Quality Settings

For lossy encoding, quality ranges from 0-100:
- **90-100**: Excellent quality, minimal artifacts
- **80-89**: Very good quality, some compression
- **70-79**: Good quality, noticeable compression
- **60-69**: Acceptable quality, visible artifacts
- **Below 60**: Low quality, significant artifacts

## Platform-Specific Code

The library maintains separate code paths for different architectures:

```swift
#if arch(arm64)
    // Apple Silicon / ARM optimizations
    return applyDCTNEON(block: block)
#elseif arch(x86_64)
    // x86-64 fallback implementation
    return applyDCTScalar(block: block)
#endif
```

This design allows easy removal of x86-64 code in the future if desired.

## Command Line Tool

JXLSwift includes a command line tool `jxl-tool` for encoding and inspecting JPEG XL files:

```bash
# Encode a test image
swift run jxl-tool encode --quality 90 --effort 7 -o output.jxl

# Lossless encoding
swift run jxl-tool encode --lossless -o output.jxl

# Display hardware capabilities
swift run jxl-tool hardware

# Inspect a JPEG XL file
swift run jxl-tool info output.jxl

# Run performance benchmarks
swift run jxl-tool benchmark --width 512 --height 512
```

## Roadmap

See [MILESTONES.md](MILESTONES.md) for the detailed project milestone plan.

- [x] Core compression pipeline
- [x] Lossless (Modular) mode
- [x] Lossy (VarDCT) mode
- [x] Apple Silicon optimization
- [x] Accelerate framework integration
- [x] Command line tool (jxl-tool)
- [ ] Full ANS entropy coding
- [ ] Metal GPU acceleration
- [ ] Progressive encoding
- [ ] JPEG XL file format (.jxl)
- [ ] Metadata support (EXIF, XMP)
- [ ] Animation support
- [ ] Decoding support
- [ ] libjxl validation & benchmarking

## Standards Compliance

This implementation follows the JPEG XL specification:
- ISO/IEC 18181-1:2024 - Core coding system
- Focus on compression (encoding) only

## License

MIT License - See LICENSE file for details

## Contributing

Contributions welcome! Please ensure:
- Code follows Swift style guidelines
- Tests pass on both ARM64 and x86-64
- Performance-critical code has benchmarks
- Hardware-specific code is properly isolated

## References

- [JPEG XL Official Site](https://jpeg.org/jpegxl/)
- [ISO/IEC 18181 Standard](https://www.iso.org/standard/85066.html)
- [JPEG XL White Paper](https://ds.jpeg.org/whitepapers/jpeg-xl-whitepaper.pdf)

## Acknowledgments

This is a reference implementation created for educational and research purposes. For production use, consider the official [libjxl](https://github.com/libjxl/libjxl) C++ implementation.