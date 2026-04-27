# JXLSwift 1.0.0 Release Notes

🎉 **We're excited to announce the first stable release of JXLSwift!**

JXLSwift 1.0.0 is a production-ready, native Swift implementation of the JPEG XL (ISO/IEC 18181) compression codec, optimized for Apple Silicon hardware.

## What is JXLSwift?

JXLSwift provides a pure Swift implementation of the JPEG XL image compression standard with zero C/C++ runtime dependencies. It delivers hardware-accelerated encoding and decoding for both lossless (Modular) and lossy (VarDCT) compression modes, with full support for modern color spaces, HDR, animation, and advanced features.

## Highlights

### ✨ Complete JPEG XL Implementation
- **Encoding:** Lossless (Modular mode) and lossy (VarDCT mode) compression
- **Decoding:** Full round-trip decoding with progressive rendering support
- **Container Format:** ISOBMFF container with EXIF, XMP, and ICC profile metadata
- **Advanced Features:** Animation, ROI encoding, reference frames, patch encoding, noise synthesis, spline overlays

### 🚀 Performance
- **Apple Silicon Optimized:** ARM NEON SIMD and Apple Accelerate integration
- **Metal GPU Support:** Hardware-accelerated DCT transforms
- **Multi-threaded:** Configurable thread count for parallel encoding
- **Fast Decoding:** ≥ 100 MP/s throughput on Apple Silicon

### 📦 Production Ready
- **1200+ Tests:** Comprehensive test coverage including fuzzing, thread safety, and performance benchmarks
- **95%+ Code Coverage:** Verified with automated coverage reporting
- **Memory Safety:** Validated with ASan, TSan, and UBSan sanitizers
- **Security Scanning:** CodeQL integration for vulnerability detection
- **Zero Crashes:** Handles all valid and invalid inputs gracefully

### 🔧 Developer Experience
- **Command Line Tool:** `jxl-tool` for encoding, decoding, and benchmarking
- **API Documentation:** Complete DocC-generated documentation
- **Migration Guide:** 13K-word guide for transitioning from libjxl
- **Performance Guide:** 18K-word optimization and tuning reference
- **Easy Installation:** Swift Package Manager integration

## Installation

### Swift Package Manager

Add JXLSwift to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Raster-Lab/JXLSwift.git", from: "1.0.0")
]
```

### Command Line Tool

Install the `jxl-tool` command-line interface:

```bash
# macOS or Linux
sudo make install

# Custom installation directory
make PREFIX=~/.local install
```

## Quick Start

### Encoding

```swift
import JXLSwift

// Create an image frame
var frame = ImageFrame(width: 1920, height: 1080, channels: 3)

// Fill with pixel data
for y in 0..<frame.height {
    for x in 0..<frame.width {
        frame.setPixel(x: x, y: y, channel: 0, value: r)
        frame.setPixel(x: x, y: y, channel: 1, value: g)
        frame.setPixel(x: x, y: y, channel: 2, value: b)
    }
}

// Encode
let encoder = JXLEncoder(options: .highQuality)
let result = try encoder.encode(frame)

// Save to file
try result.data.write(to: URL(fileURLWithPath: "output.jxl"))
```

### Decoding

```swift
import JXLSwift

// Read JPEG XL file
let data = try Data(contentsOf: URL(fileURLWithPath: "input.jxl"))

// Decode
let decoder = JXLDecoder()
let frame = try decoder.decode(data)

// Access pixels
let red = frame.getPixel(x: 0, y: 0, channel: 0)
let green = frame.getPixel(x: 0, y: 0, channel: 1)
let blue = frame.getPixel(x: 0, y: 0, channel: 2)
```

### Command Line

```bash
# Encode an image
jxl-tool encode input.png --output output.jxl --quality 90

# Decode an image
jxl-tool decode input.jxl --output output.png

# Show image info
jxl-tool info image.jxl

# Run benchmarks
jxl-tool benchmark --input test.png --quality 90 --effort 7
```

## Platform Support

- **macOS:** 13.0+ (ARM64, x86-64)
- **iOS:** 16.0+
- **tvOS:** 16.0+
- **watchOS:** 9.0+
- **visionOS:** 1.0+
- **Linux:** x86-64 (tested on Ubuntu)

## Documentation

- **API Reference:** [Documentation/API/](Documentation/API/)
- **Migration Guide:** [Documentation/MIGRATION.md](Documentation/MIGRATION.md)
- **Performance Guide:** [Documentation/PERFORMANCE.md](Documentation/PERFORMANCE.md)
- **Coverage Guide:** [Documentation/COVERAGE.md](Documentation/COVERAGE.md)
- **Man Pages:** `man jxl-tool` (after installation)

## What's Next?

JXLSwift 1.0.0 represents a stable, production-ready foundation for JPEG XL encoding and decoding on Apple platforms. Future releases will maintain API stability following Semantic Versioning 2.0.0.

### Roadmap

- **1.x releases:** Bug fixes, performance improvements, and backwards-compatible enhancements
- **2.0:** Planned major version with potential API refinements based on community feedback

## Acknowledgments

JXLSwift implements the JPEG XL (ISO/IEC 18181) standard and draws inspiration from the reference [libjxl](https://github.com/libjxl/libjxl) implementation while providing a pure Swift, dependency-free alternative optimized for Apple platforms.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License - See [LICENSE](LICENSE) for details.

---

**Full Changelog:** https://github.com/Raster-Lab/JXLSwift/blob/main/CHANGELOG.md

**Report Issues:** https://github.com/Raster-Lab/JXLSwift/issues

**Discussions:** https://github.com/Raster-Lab/JXLSwift/discussions
