# Changelog

All notable changes to JXLSwift will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Production hardening and release infrastructure
- CHANGELOG.md for tracking version history
- Comprehensive API documentation with DocC
- Migration guide from libjxl to JXLSwift
- Performance tuning guide
- Fuzzing test suite for malformed input handling
- Memory safety validation (ASan, TSan, UBSan)
- Thread safety tests for concurrent encoding
- Code coverage reporting in CI
- Memory leak detection in CI
- Security scanning in CI

### Changed
- Enhanced CI/CD pipeline for production releases
- Improved error handling for edge cases
- Updated documentation with comprehensive examples

### Fixed
- Edge case handling in decoder for malformed inputs
- Memory efficiency improvements in large image processing
- Thread safety issues in concurrent encoding scenarios

## [0.12.0] - 2026-02-19

### Added
- Complete JPEG XL decoding support
- `JXLDecoder` class with full round-trip capability
- Codestream and frame header parsing
- Modular mode decoder with inverse prediction
- VarDCT mode decoder with IDCT and color conversion
- ANS entropy decoder for symbol decoding
- Progressive decoding with incremental rendering (3-pass: DC-only, low-freq AC, high-freq AC)
- Container format parsing with ISOBMFF support
- Metadata extraction (EXIF, XMP, ICC profiles)
- `decode` subcommand in jxl-tool
- Image export to PNG, TIFF, BMP via platform image I/O
- `ImageExporter` with planar-to-interleaved conversion
- `LibjxlCompatibilityTests` (11 tests) for reference decoder validation
- `MemoryBoundedDecodingTests` (10 tests) for memory efficiency validation
- `DecodePerformanceTests` (19 tests) measuring decode throughput
- `ProgressiveDecodingTests` (10 tests) for incremental rendering

### Performance
- Decode throughput: ≥ 100 MP/s on Apple Silicon
- Memory-efficient decoding of large images (64×64 to 2048×2048)

## [0.11.0] - 2026-02-10

### Added
- libjxl validation and performance benchmarking infrastructure
- Systematic quality comparison (PSNR, SSIM, MS-SSIM, Butteraugli)
- Encoding speed benchmarks across all effort levels
- Compression ratio analysis with bits-per-pixel metrics
- Process-level memory usage tracking
- Synthetic test image corpus (Kodak-like, Tecnick-like, Wikipedia-like)
- JSON and HTML report generation
- Performance regression detection
- Bitstream compatibility validation with libjxl
- Validation test harness with configurable acceptance criteria

### Performance
- Established baseline metrics for future optimization
- Documented performance characteristics across platforms

## [0.10.0] - 2026-02-05

### Added
- `jxl-tool` command-line interface
- `encode` subcommand with quality, effort, and format options
- `info` subcommand for image metadata display
- `benchmark` subcommand for performance testing
- Man page documentation
- Makefile for installation and distribution
- CLI integration tests

### Changed
- Improved user experience with comprehensive help text
- Enhanced error reporting in CLI context

## [0.9.0] - 2026-01-28

### Added
- Advanced encoding features (13 deliverables)
- Extra channel support (depth, thermal, spectral, application-specific)
- Animation encoding with frame timing and loop control
- EXIF orientation support (all 8 rotation/flip values)
- Region-of-Interest (ROI) encoding with quality feathering
- Reference frame encoding for animations
- Patch encoding for repeated rectangular regions
- Noise synthesis for perceptual quality improvement
- Spline encoding for vector overlay rendering
- Responsive encoding with adaptive quality
- Progressive encoding for incremental rendering
- Metal GPU acceleration for async pipeline operations

### Performance
- Significant compression gains on animations and screen content
- GPU-accelerated operations for compatible hardware

## [0.8.0] - 2026-01-20

### Added
- ANS (Asymmetric Numeral Systems) entropy coding
- rANS encoder and decoder
- Adaptive ANS with symbol frequency tracking
- Modular integration with existing pipelines
- VarDCT integration with ANS
- 32 comprehensive ANS tests

### Performance
- Improved compression ratios with entropy coding
- Efficient symbol encoding/decoding

## [0.7.0] - 2026-01-12

### Added
- Metal GPU hardware acceleration
- Async compute pipeline for DCT transforms
- GPU-accelerated quantization
- Metal shader implementations
- Fallback to CPU when GPU unavailable
- 25 Metal compute tests

### Performance
- GPU acceleration on compatible Apple hardware
- Graceful degradation on systems without Metal support

## [0.6.0] - 2026-01-05

### Added
- ARM NEON/SIMD hardware acceleration
- NEON-optimized DCT transforms
- NEON-optimized quantization
- NEON-optimized color conversion
- Architecture-specific code separation
- 30 NEON operation tests

### Performance
- Significant speedup on ARM64 platforms
- Apple Silicon optimization

## [0.5.0] - 2025-12-28

### Added
- Apple Accelerate framework integration
- vDSP-accelerated DCT transforms
- vDSP-accelerated matrix operations
- vDSP-accelerated vector math
- Optional Accelerate usage with `#if canImport(Accelerate)`
- 28 Accelerate operation tests

### Performance
- Hardware-accelerated operations on Apple platforms
- Portable fallback implementations

## [0.4.0] - 2025-12-20

### Added
- JPEG XL file format and container support
- ISOBMFF container with box structure
- Signature and ftyp box writing
- JXL codestream box (jxlc)
- Metadata boxes (Exif, xml, colr)
- Container parsing and validation
- 45 format and container tests

### Changed
- Encoder now outputs valid JPEG XL files
- Container format follows ISO/IEC 18181-2 specification

## [0.3.0] - 2025-12-12

### Added
- Lossy compression (VarDCT mode)
- DCT transform (8×8 blocks)
- Quantization with quality control
- YCbCr color space conversion
- Chroma from Luma (CfL) prediction
- DC prediction
- Quality-to-distance mapping
- VarDCT encoder and decoder
- 89 VarDCT tests

### Performance
- High-quality lossy compression
- Configurable quality levels (0-100)
- Effort levels (1-9) for speed/quality tradeoff

## [0.2.0] - 2025-12-05

### Added
- Lossless compression (Modular mode)
- Median Edge Detector (MED) predictor
- ZigZag signed-to-unsigned residual mapping
- Run-length + varint entropy coding
- Channel extraction for planar data
- Modular encoder and decoder
- 67 Modular mode tests

### Performance
- Bit-perfect lossless compression
- Competitive compression ratios

## [0.1.0] - 2025-11-28

### Added
- Core data structures (`ImageFrame`, `PixelType`, `ColorSpace`)
- Bitstream I/O (`BitstreamWriter`, `BitstreamReader`)
- Encoding configuration (`EncodingOptions`, `CompressionMode`, `EncodingEffort`)
- Hardware detection (`CPUArchitecture`, `HardwareCapabilities`)
- Compression statistics tracking
- Typed error handling (`EncoderError`)
- 95 core structure tests

### Infrastructure
- Swift Package Manager project structure
- Platform targets: macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+
- Swift 6.2 with strict concurrency enabled
- XCTest integration
- GitHub Actions CI for macOS (ARM64, x86-64) and Linux
- MIT License
- Comprehensive documentation (README, CONTRIBUTING, TECHNICAL)

## [0.0.1] - 2025-11-20

### Added
- Initial project foundation
- Directory structure (Core, Encoding, Hardware, Format)
- Basic Swift package configuration
- CI/CD pipeline setup
- Project documentation framework

---

[Unreleased]: https://github.com/Raster-Lab/JXLSwift/compare/v0.12.0...HEAD
[0.12.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.0.1...v0.1.0
[0.0.1]: https://github.com/Raster-Lab/JXLSwift/releases/tag/v0.0.1
