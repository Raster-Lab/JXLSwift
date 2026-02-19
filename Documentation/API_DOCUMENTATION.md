# API Documentation

JXLSwift uses Swift-DocC for generating API documentation from inline documentation comments.

## Generating Documentation

### Prerequisites

- Xcode 14+ (for macOS)
- Swift 6.2+ with Swift-DocC plugin

### Quick Start

Generate and preview the documentation:

```bash
make docc-preview
```

This will start a local server and open the documentation in your browser.

### Build Documentation Archive

To generate a DocC archive for distribution:

```bash
make docc
```

The documentation will be generated in `Documentation/API/`.

### Build Static HTML Documentation

To generate static HTML documentation for hosting:

```bash
make docc-html
```

The HTML documentation will be generated in `Documentation/API/` and can be hosted on any static web server.

## Documentation Structure

The API documentation is automatically generated from inline documentation comments in the source code:

- **Core Types**: `ImageFrame`, `EncodingOptions`, `CompressionStats`, `HardwareCapabilities`
- **Encoding**: `JXLEncoder`, `ModularEncoder`, `VarDCTEncoder`
- **Decoding**: `JXLDecoder`, `ModularDecoder`, `VarDCTDecoder`
- **Format**: `JXLContainer`, `ImageHeader`, `FrameHeader`
- **Hardware**: `AccelerateOps`, `NEONOps`, `MetalEncoder`

## Documentation Standards

All public APIs follow these documentation guidelines:

1. **Summary**: A brief description of the type, method, or property (one sentence)
2. **Discussion**: Detailed explanation of behavior, usage, and edge cases
3. **Parameters**: Description of each parameter including type and constraints
4. **Returns**: Description of return value and possible states
5. **Throws**: Description of error conditions
6. **Examples**: Code snippets demonstrating typical usage

Example:

```swift
/// Encode an image frame to JPEG XL format.
///
/// This method performs the full encoding pipeline: validates the input frame,
/// applies color space conversion if needed, runs the selected compression mode
/// (lossless Modular or lossy VarDCT), and returns the compressed bitstream.
///
/// - Parameter frame: The image frame to encode. Must have valid dimensions
///   (1-262144 pixels) and 1-4 channels.
/// - Returns: Encoded image data with compression statistics
/// - Throws: `EncoderError` if encoding fails due to invalid input or encoding errors
///
/// Example:
/// ```swift
/// let encoder = JXLEncoder(options: .highQuality)
/// var frame = ImageFrame(width: 256, height: 256, channels: 3)
/// // ... fill frame with pixel data ...
/// let result = try encoder.encode(frame)
/// print("Compression ratio: \(result.stats.compressionRatio)x")
/// ```
public func encode(_ frame: ImageFrame) throws -> EncodedImage
```

## CI Integration

Documentation generation is integrated into the CI pipeline:

1. **Build-time validation**: Documentation warnings are reported during build
2. **Symbol coverage**: All public symbols must be documented
3. **Link validation**: Internal links between documentation pages are verified

## Viewing Documentation

### In Xcode

1. Open the Package in Xcode
2. Select Product → Build Documentation
3. Open the Documentation window (⌘⇧0)

### In Browser

Run `make docc-preview` to view the documentation in your default browser.

### Online

The documentation can be hosted on GitHub Pages or any static hosting service using the output from `make docc-html`.

## Contributing

When adding new public APIs, ensure they are fully documented following the standards above. The CI will fail if:

- Public APIs lack documentation comments
- Parameter names in documentation don't match the actual parameter names
- Internal links reference non-existent symbols

## Known Issues

- The `docc` command-line tool may not be available in all CI environments. For these environments, documentation generation is skipped gracefully.
- Symbol graph generation requires the Swift package to build successfully.

## Resources

- [Swift-DocC Documentation](https://www.swift.org/documentation/docc/)
- [Apple's DocC Guide](https://developer.apple.com/documentation/docc)
- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
