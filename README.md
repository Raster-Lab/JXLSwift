# JXLSwift

A native Swift implementation of the JPEG XL (ISO/IEC 18181) compression codec, optimized for Apple Silicon hardware.

## Overview

JXLSwift provides a pure Swift implementation of the JPEG XL image compression standard with hardware-accelerated encoding for Apple Silicon (ARM NEON/SIMD) and Apple Accelerate framework integration. The library is designed for high performance with separate code paths for x86-64 that can be removed if needed.

## Features

- ✅ **Native Swift Implementation** - Pure Swift, no C/C++ dependencies
- 🚀 **Apple Silicon Optimized** - Leverages ARM NEON SIMD via portable Swift SIMD types
- ⚡ **Apple Accelerate Integration** - Uses vDSP for DCT and matrix operations
- 🎯 **Modular Architecture** - Separate x86-64 code paths for future removal
- 📦 **Two Compression Modes**:
  - **Lossless (Modular Mode)** - Perfect pixel reproduction
  - **Lossy (VarDCT Mode)** - High-quality lossy compression
- 🎨 **Advanced Color Support**:
  - Standard: sRGB, linear RGB, grayscale
  - Wide Gamut: Display P3, Rec. 2020
  - HDR Transfer Functions: PQ (HDR10), HLG
  - Alpha Channels: Straight and premultiplied modes
- 📊 **Extra Channels** - Depth maps, thermal data, spectral bands, and application-specific channels
- 🎬 **Animation Support** - Multi-frame encoding with frame timing and loop control
- 🔄 **EXIF Orientation** - Full support for all 8 EXIF orientation values (rotation/flip metadata)
- 🎯 **Region-of-Interest (ROI)** - Selective quality encoding with configurable feathering for smooth transitions
- 🎞️ **Reference Frame Encoding** - Delta encoding for animations with configurable keyframe intervals to reduce file size for video-like content
- 🔧 **Flexible Configuration** - Quality levels, effort settings, hardware acceleration control
- 📄 **JPEG XL Container Format** - ISOBMFF container with metadata boxes (EXIF, XMP, ICC)
- 🌊 **Progressive Encoding** - Incremental rendering for faster perceived loading

## Requirements

- Swift 6.2 or later
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

### Command Line Tool Installation

To install the `jxl-tool` command-line tool:

```bash
# Build and install to /usr/local (requires sudo)
sudo make install

# Or install to a custom location
make PREFIX=~/.local install

# Install man pages (requires sudo for system-wide installation)
sudo make install-man
```

The Makefile provides several targets:
- `make build` - Build the project in release mode
- `make test` - Run all tests
- `make man` - Generate man pages
- `make install` - Install jxl-tool binary
- `make install-man` - Install man pages
- `make uninstall` - Remove installed files
- `make clean` - Clean build artifacts
- `make help` - Show help message

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
let stats = result.stats
print("Compressed: \(stats.originalSize) → \(stats.compressedSize) bytes")
print("Ratio: \(stats.compressionRatio)x in \(stats.encodingTime)s")
```

### Alpha Channel Support

```swift
// Create RGBA frame with alpha channel
var rgbaFrame = ImageFrame(
    width: 1920,
    height: 1080,
    channels: 4,  // RGBA
    pixelType: .uint8,
    colorSpace: .sRGB,
    hasAlpha: true,
    alphaMode: .straight  // or .premultiplied
)

// Set pixels including alpha channel
for y in 0..<rgbaFrame.height {
    for x in 0..<rgbaFrame.width {
        rgbaFrame.setPixel(x: x, y: y, channel: 0, value: r)      // Red
        rgbaFrame.setPixel(x: x, y: y, channel: 1, value: g)      // Green
        rgbaFrame.setPixel(x: x, y: y, channel: 2, value: b)      // Blue
        rgbaFrame.setPixel(x: x, y: y, channel: 3, value: alpha)  // Alpha
    }
}

// Encode with alpha - works with both lossless and lossy modes
let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90)))
let result = try encoder.encode(rgbaFrame)
```

### Lossless Compression

```swift
// Lossless (Modular) mode - bit-perfect preservation
let options = EncodingOptions(mode: .lossless)
let encoder = JXLEncoder(options: options)
let result = try encoder.encode(frame)
```

### Lossy Compression

```swift
let encoder = JXLEncoder(options: .lossless)
let result = try encoder.encode(frame)
```

### High-Quality Lossy Encoding

```swift
let encoder = JXLEncoder(options: .highQuality)
let result = try encoder.encode(frame)
```

### Encoding Effort Levels

```swift
// Fast encoding (effort level 1: lightning)
let fastOptions = EncodingOptions(
    mode: .lossy(quality: 90),
    effort: .lightning
)

// Balanced encoding (effort level 7: squirrel - default)
let balancedOptions = EncodingOptions(
    mode: .lossy(quality: 90),
    effort: .squirrel
)

// Best compression (effort level 9: tortoise)
let bestOptions = EncodingOptions(
    mode: .lossy(quality: 90),
    effort: .tortoise
)
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
    numThreads: 0,                // Auto-detect
    useANS: true                  // Use rANS entropy coding
)

let encoder = JXLEncoder(options: options)
let result = try encoder.encode(frame)
```

### Progressive Encoding

Progressive encoding allows images to be rendered incrementally as data arrives, showing a low-resolution preview first that gradually refines to full quality. This is particularly useful for web delivery and streaming scenarios.

```swift
// Enable progressive encoding
let progressiveOptions = EncodingOptions(
    mode: .lossy(quality: 90),
    effort: .squirrel,
    progressive: true  // Enable multi-pass encoding
)

let encoder = JXLEncoder(options: progressiveOptions)
let result = try encoder.encode(frame)
```

#### How Progressive Encoding Works

Progressive encoding splits DCT coefficients into multiple passes:
1. **Pass 0 (DC-only)**: Encodes only DC coefficients, providing a low-resolution 8×8 preview
2. **Pass 1 (Low-frequency AC)**: Adds low-frequency details (coefficients 1-15)
3. **Pass 2 (High-frequency AC)**: Adds high-frequency details (coefficients 16-63)

This allows decoders to render a usable image after receiving just the first pass, then progressively refine it as more data arrives.

#### Trade-offs

- **Pros**: Faster perceived loading, better user experience for slow connections
- **Cons**: Slightly larger file size (typically 5-15% overhead) due to pass structure
- **Best for**: Web delivery, progressive image loading, streaming scenarios
- **Avoid for**: Archival storage where file size is critical

### Responsive Encoding

Responsive encoding provides quality-layered progressive delivery, allowing images to be decoded at progressively higher quality levels. Unlike progressive encoding (which splits by frequency), responsive encoding splits by quantization quality, making it ideal for adaptive streaming and bandwidth-constrained environments.

```swift
// Enable responsive encoding with 3 quality layers
let responsiveOptions = EncodingOptions(
    mode: .lossy(quality: 90),
    responsiveEncoding: true,
    responsiveConfig: .threeLayers  // Preview → Medium → Full quality
)

let encoder = JXLEncoder(options: responsiveOptions)
let result = try encoder.encode(frame)
```

#### How Responsive Encoding Works

Responsive encoding generates multiple quality layers with different distance (quantization) values:
- **Layer 0 (Preview)**: High distance (~6× base) - fast loading, low quality preview
- **Layer 1+ (Refinement)**: Progressively lower distances - incremental quality improvements
- **Final Layer**: Base distance - target quality

For quality 90 (distance ~1.0):
- Layer 0: distance 6.0 (quick preview)
- Layer 1: distance 2.45 (medium quality)
- Layer 2: distance 1.0 (full quality)

#### Configuration Options

```swift
// Use preset layer counts
ResponsiveConfig.twoLayers    // Fast: preview + full
ResponsiveConfig.threeLayers  // Balanced: preview + medium + full (default)
ResponsiveConfig.fourLayers   // Maximum refinement

// Custom layer count (2-8 layers)
let config = ResponsiveConfig(layerCount: 4)

// Custom distance values for precise control
let customConfig = ResponsiveConfig(
    layerCount: 3,
    layerDistances: [8.0, 4.0, 1.5]  // Must be descending order
)
```

#### Combining Progressive and Responsive

You can combine both encoding modes for maximum flexibility:

```swift
let options = EncodingOptions(
    mode: .lossy(quality: 95),
    progressive: true,        // Frequency-based passes (DC, low-freq, high-freq)
    responsiveEncoding: true, // Quality-based layers
    responsiveConfig: .threeLayers
)
```

#### Trade-offs

- **Pros**: Adaptive quality delivery, better UX on variable bandwidth, graceful degradation
- **Cons**: Minimal overhead (<3%), requires decoder support for multi-layer decoding
- **Best for**: Responsive web design, adaptive streaming, bandwidth-sensitive applications
- **Current status**: Framework complete, full bitstream encoding requires decoder support

#### CLI Usage

```bash
# Enable responsive encoding with default 3 layers
jxl-tool encode --responsive input.png -o output.jxl

# Specify custom layer count
jxl-tool encode --responsive --quality-layers 4 input.png -o output.jxl

# Combine with progressive
jxl-tool encode --responsive --progressive -q 95 input.png -o output.jxl
```

### EXIF Orientation Support

JXLSwift fully supports EXIF orientation metadata, allowing proper handling of rotated and flipped images from cameras and smartphones. The orientation is preserved in the JPEG XL file and can be used by viewers to display images correctly without modifying pixel data.

```swift
// Create a frame with specific orientation
let frame = ImageFrame(
    width: 1920,
    height: 1080,
    channels: 3,
    orientation: 6  // 90° clockwise rotation
)

// Encode with orientation metadata
let encoder = JXLEncoder()
let result = try encoder.encode(frame)
```

#### EXIF Orientation Values

| Value | Transform | Description |
|-------|-----------|-------------|
| 1 | None | Normal (no rotation) |
| 2 | Flip horizontal | Mirror image |
| 3 | Rotate 180° | Upside-down |
| 4 | Flip vertical | Vertical mirror |
| 5 | Rotate 270° + flip H | Transpose |
| 6 | Rotate 90° CW | 90° clockwise |
| 7 | Rotate 90° + flip H | Transverse |
| 8 | Rotate 270° CW | 270° clockwise |

#### Extracting Orientation from EXIF Data

```swift
import JXLSwift

// Parse orientation from EXIF data
let exifData = Data(...) // Raw EXIF from JPEG/PNG/TIFF
let orientation = EXIFOrientation.extractOrientation(from: exifData)

// Create frame with extracted orientation
let frame = ImageFrame(
    width: width,
    height: height,
    channels: 3,
    orientation: orientation
)
```

#### Command Line Tool

```bash
# Encode with specific orientation
swift run jxl-tool encode --orientation 6 --width 1920 --height 1080 -o output.jxl

# Orientation is preserved in the encoded file
swift run jxl-tool info output.jxl
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

### HDR and Wide Gamut Support

```swift
// Display P3 (wide gamut)
var displayP3Frame = ImageFrame(
    width: 1920,
    height: 1080,
    channels: 3,
    pixelType: .uint16,
    colorSpace: .displayP3,  // Display P3 with sRGB transfer function
    bitsPerSample: 10
)

// HDR10 (Rec. 2020 with PQ transfer function)
var hdr10Frame = ImageFrame(
    width: 3840,
    height: 2160,
    channels: 3,
    pixelType: .float32,  // HDR typically uses float
    colorSpace: .rec2020PQ,  // Rec. 2020 primaries with PQ (Perceptual Quantizer)
    bitsPerSample: 16
)

// HLG HDR (Rec. 2020 with HLG transfer function)
var hlgFrame = ImageFrame(
    width: 3840,
    height: 2160,
    channels: 3,
    pixelType: .uint16,
    colorSpace: .rec2020HLG,  // Rec. 2020 primaries with HLG (Hybrid Log-Gamma)
    bitsPerSample: 10
)
```

### Alpha Channel Support

```swift
// RGBA with straight (unassociated) alpha
var rgbaFrame = ImageFrame(
    width: 1920,
    height: 1080,
    channels: 4,  // RGB + Alpha
    pixelType: .uint8,
    colorSpace: .sRGB,
    hasAlpha: true,
    alphaMode: .straight  // RGB values independent of alpha
)

// Set pixel with alpha
rgbaFrame.setPixel(x: 100, y: 100, channel: 0, value: 255)  // R
rgbaFrame.setPixel(x: 100, y: 100, channel: 1, value: 128)  // G
rgbaFrame.setPixel(x: 100, y: 100, channel: 2, value: 64)   // B
rgbaFrame.setPixel(x: 100, y: 100, channel: 3, value: 128)  // A (50% transparent)

// RGBA with premultiplied alpha
var premultFrame = ImageFrame(
    width: 1920,
    height: 1080,
    channels: 4,
    pixelType: .uint16,
    colorSpace: .displayP3,
    hasAlpha: true,
    alphaMode: .premultiplied  // RGB already multiplied by alpha
)
```

### Multi-Frame Animation Support

JXLSwift supports encoding animated JPEG XL files with multiple frames, frame timing, and loop controls. This is ideal for animated images, sequences, and video-like content.

```swift
// Create animation frames
var frames: [ImageFrame] = []
for i in 0..<30 {
    var frame = ImageFrame(width: 512, height: 512, channels: 3)
    // Populate frame with animation data...
    frames.append(frame)
}

// Configure animation settings
let animConfig = AnimationConfig(
    fps: 30,              // 30 frames per second
    loopCount: 0          // 0 = infinite loop
)

// Create encoder with animation config
let options = EncodingOptions(
    mode: .lossy(quality: 90),
    effort: .falcon,
    animationConfig: animConfig
)

let encoder = JXLEncoder(options: options)

// Encode all frames as animation
let result = try encoder.encode(frames)
```

#### Animation Configuration Options

```swift
// Different frame rates
let fps24 = AnimationConfig.fps24  // Cinematic 24 FPS
let fps30 = AnimationConfig.fps30  // Standard 30 FPS
let fps60 = AnimationConfig.fps60  // Smooth 60 FPS

// Finite loop count
let loopThrice = AnimationConfig(fps: 30, loopCount: 3)

// Custom frame durations (in ticks, 1000 ticks per second)
let customDurations = AnimationConfig(
    fps: 30,
    frameDurations: [100, 200, 150, 300]  // Different duration per frame
)
```

#### Animation Features

- **Frame Rate Control**: Set FPS from 1 to any desired rate
- **Loop Control**: Infinite loop or specific repeat count
- **Custom Timing**: Different duration for each frame
- **All Pixel Types**: Supports uint8, uint16, and float32
- **Alpha Channel**: Full RGBA animation support
- **Progressive**: Combine with progressive encoding for streaming
- **HDR/Wide Gamut**: Animate HDR or wide color gamut content

#### Animation Trade-offs

- **Pros**: Native format support, better compression than GIF/APNG
- **Cons**: Larger than single frame, decoder support varies
- **Best for**: Web animations, UI sequences, short video clips
- **Avoid for**: Long videos (use proper video codecs)

## Architecture

The library is organized into several modules:

```
Sources/JXLSwift/
├── Core/              # Fundamental data structures
│   ├── Architecture.swift     # CPU detection & capabilities
│   ├── ImageFrame.swift       # Image representation
│   ├── PixelBuffer.swift      # Tiled pixel buffer access
│   ├── Bitstream.swift        # Bitstream I/O
│   └── EncodingOptions.swift  # Configuration
├── Encoding/          # Compression pipeline
│   ├── Encoder.swift          # Main encoder interface
│   ├── ModularEncoder.swift   # Lossless compression
│   ├── VarDCTEncoder.swift    # Lossy compression
│   └── ANSEncoder.swift       # rANS entropy coding (ISO/IEC 18181-1 Annex A)
├── Hardware/          # Platform optimizations
│   ├── Accelerate.swift       # Apple Accelerate framework (vDSP)
│   ├── NEONOps.swift          # ARM NEON SIMD via Swift SIMD types
│   └── DispatchBackend.swift  # Runtime backend selection
└── Format/            # JPEG XL file format (ISO/IEC 18181-2)
    ├── CodestreamHeader.swift # SizeHeader, ImageMetadata, ColourEncoding
    ├── FrameHeader.swift      # Frame header, section/group framing
    └── JXLContainer.swift     # ISOBMFF container, metadata boxes

Sources/JXLTool/
├── JXLTool.swift              # CLI entry point
├── Encode.swift               # Encode subcommand
├── Info.swift                  # Info subcommand
├── Hardware.swift              # Hardware subcommand
├── Benchmark.swift            # Benchmark subcommand
├── Batch.swift                # Batch subcommand
├── Compare.swift              # Compare subcommand
└── Utilities.swift            # Shared CLI helpers
```

## Performance

JXLSwift is optimized for Apple Silicon:

- **ARM NEON SIMD** - Vectorized DCT, colour conversion, quantisation, prediction, RCT, and squeeze transforms via Swift SIMD types (both Modular and VarDCT pipelines)
- **Apple Accelerate** - vDSP DCT transforms and matrix operations
- **Metal GPU** - Parallel block processing with compute shaders for DCT, color conversion, and quantization (batch operations with async pipeline)

Benchmarks on Apple M1 (256x256 image):
- Fast mode: ~0.7s per frame
- High quality: ~2-3s per frame

**Metal GPU Acceleration:**
- Automatically enabled on Apple platforms when available
- Async pipeline with double-buffering overlaps CPU and GPU work for improved throughput
- Best suited for batch processing of multiple images or large images (32+ blocks)
- Falls back to CPU (Accelerate/NEON/scalar) for small workloads
- Control via `EncodingOptions.useMetal` flag

## Compression Modes

### Modular Mode (Lossless)
- Perfect pixel-by-pixel reproduction
- Uses predictive coding + entropy encoding
- NEON-accelerated MED prediction, RCT, and squeeze transforms on ARM64
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

### Region-of-Interest (ROI) Encoding

Region-of-Interest encoding allows you to encode a specific rectangular area at higher quality than the rest of the image. This is particularly useful for:
- Reducing file size by compressing less important areas more aggressively
- Highlighting specific parts of an image (faces, subjects, etc.)
- Creating focal point encoding for attention guidance

```swift
// Define a region of interest (center 200×200 region)
let roi = RegionOfInterest(
    x: 100,         // Top-left X coordinate
    y: 100,         // Top-left Y coordinate
    width: 200,     // Width of the ROI
    height: 200,    // Height of the ROI
    qualityBoost: 15.0,   // Quality improvement (0-50)
    featherWidth: 16      // Transition width in pixels
)

let options = EncodingOptions(
    mode: .lossy(quality: 80),  // Base quality for non-ROI areas
    effort: .squirrel,
    regionOfInterest: roi
)

let encoder = JXLEncoder(options: options)
let result = try encoder.encode(frame)
```

#### How ROI Encoding Works

ROI encoding varies the quantization distance on a per-block basis:
1. **Inside ROI**: Lower distance = higher quality (e.g., quality boost of 10 ≈ 0.91× distance multiplier)
2. **Outside ROI**: Normal distance = base quality
3. **Feather Zone**: Smooth transition using cosine interpolation for seamless quality gradients

#### ROI Configuration Options

- **qualityBoost** (0-50, default 10): Quality improvement for ROI region
  - 10 = approximately 10% higher quality
  - 20 = approximately 16.7% higher quality
  - 50 = approximately 33.3% higher quality (maximum)
- **featherWidth** (pixels, default 16): Width of smooth transition at ROI edges
  - 0 = hard edge (abrupt quality change)
  - 8-16 = subtle transition (recommended)
  - 32+ = very gradual transition

#### CLI Example

```bash
# Encode with ROI in center region
swift run jxl-tool encode --width 512 --height 512 \\
    --roi 128,128,256,256 \\
    --roi-quality-boost 20 \\
    --roi-feather 16 \\
    -o output.jxl

# Corner ROI with sharp edges
swift run jxl-tool encode --width 800 --height 600 \\
    --roi 0,0,200,200 \\
    --roi-quality-boost 15 \\
    --roi-feather 0 \\
    -o corner_roi.jxl
```

#### Trade-offs

- **Pros**: Smaller file size, maintains detail where it matters, guides viewer attention
- **Cons**: Potential visible quality boundaries (mitigated by feathering)
- **Best for**: Portrait photography, product shots, documents with focal areas
- **Note**: Only applies to lossy (VarDCT) encoding; ignored for lossless mode

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

# Batch encode a directory
swift run jxl-tool batch /path/to/images --recursive -o /path/to/output

# Display hardware capabilities
swift run jxl-tool hardware

# Inspect a JPEG XL file
swift run jxl-tool info output.jxl

# Compare two JPEG XL files
swift run jxl-tool compare file1.jxl file2.jxl

# Run performance benchmarks
swift run jxl-tool benchmark --width 512 --height 512

# Compare ANS vs simplified entropy encoding
swift run jxl-tool benchmark --compare-entropy

# Compare hardware acceleration vs scalar
swift run jxl-tool benchmark --compare-hardware

# Compare Metal GPU vs CPU acceleration
swift run jxl-tool benchmark --compare-metal
```

### Man Pages

After installation, comprehensive man pages are available:

```bash
man jxl-tool               # Main tool overview
man jxl-tool-encode        # Encode subcommand
man jxl-tool-benchmark     # Benchmark subcommand
# ... and more
```

### Exit Codes

The tool follows standard UNIX exit code conventions:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (runtime failure) |
| 2 | Invalid arguments |

## Roadmap

See [MILESTONES.md](MILESTONES.md) for the detailed project milestone plan.

- [x] Core compression pipeline
- [x] Lossless (Modular) mode — MED, RCT, Squeeze, MA tree, context modeling
- [x] Lossy (VarDCT) mode — DCT, XYB, CfL, adaptive quantization, DC prediction
- [x] Apple Silicon optimization
- [x] Accelerate framework integration — vDSP DCT, vectorized color/quantization
- [x] ARM NEON SIMD acceleration — portable Swift SIMD types, DCT, colour conversion, quantisation, MED prediction, RCT, squeeze (Modular + VarDCT)
- [x] Metal GPU acceleration — compute shaders for DCT, color conversion, quantization (batch operations)
- [x] Command line tool (jxl-tool) — encode, info, hardware, benchmark, batch, compare
- [x] JPEG XL file format (.jxl) — ISOBMFF container, codestream/frame headers
- [x] Metadata support (EXIF, XMP, ICC profiles)
- [x] Animation container framing (frame index, multi-frame)
- [x] ANS entropy coding — rANS encoder/decoder, multi-context, distribution tables, histogram clustering, ANS interleaving, LZ77 hybrid mode, integrated with Modular + VarDCT
- [x] Man pages for jxl-tool and all subcommands
- [x] Makefile for build, test, and installation
- [x] **Advanced features** — HDR support (PQ, HLG), wide gamut (Display P3, Rec. 2020), alpha channels (straight, premultiplied), EXIF orientation (all 8 values), extra channels (depth, thermal, spectral)
- [x] **Metal GPU async pipeline with double-buffering** — overlapping CPU and GPU work for improved performance
- [x] Progressive encoding — frequency-based multi-pass (DC, low-freq AC, high-freq AC)
- [x] Responsive encoding — quality-layered progressive delivery (2-8 layers)
- [x] Multi-frame animation encoding — frame timing, loop control, custom durations
- [x] EXIF orientation support — reading, encoding, and CLI integration
- [x] Region-of-Interest (ROI) encoding — selective quality with configurable feathering
- [x] Reference frame encoding — delta encoding for animations with configurable keyframe intervals
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