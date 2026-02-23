# Changelog

All notable changes to JXLSwift will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-02-23

### Added

#### Documentation & Examples Refresh (Milestone 20)
- 16 new example scripts in `Examples/` covering every major feature:
  `LosslessEncoding`, `LossyEncoding`, `DecodingExample`,
  `AnimationExample`, `AlphaChannelExample`, `ExtraChannelsExample`,
  `HDRExample`, `ROIExample`, `PatchEncodingExample`,
  `NoiseSynthesisExample`, `SplineEncodingExample`,
  `HardwareDetectionExample`, `DICOMWorkflowExample`,
  `BatchProcessingExample`, `BenchmarkingExample`
- `ExamplesTests.swift` — 18 tests verifying example logic compiles and runs
- `Examples/README.md` refreshed with descriptions of all 16 examples
- `TECHNICAL.md` comprehensively refreshed with current architecture tree,
  compression pipeline diagrams, hardware acceleration section, and test
  coverage summary
- `CONTRIBUTING.md` updated: Areas for Contribution reflects completed work;
  testing section points to `make coverage` / `make coverage-html`
- `CHANGELOG.md` now includes entries for Milestones 14–19 (previously missing)

#### J2KSwift API Consistency (Milestone 19)
- `RasterImageEncoder`, `RasterImageDecoder`, and `RasterImageCodec` shared protocols
  in `Sources/JXLSwift/Core/CodecProtocols.swift`
- `JXLEncoder` conforms via `encode(frame:)` / `encode(frames:)`
- `JXLDecoder` conforms via `decode(data:)`
- 17 tests in `J2KSwiftConsistencyTests.swift`
- `Documentation/J2KSWIFT_MIGRATION.md` migration guide for cross-library developers
- Cross-library usage section added to README

#### Internationalisation & Spelling Support (Milestone 18)
- British English throughout all source code comments, help text, and error messages
- Dual-spelling CLI options on the `encode` subcommand:
  `--colour-space` / `--color-space`, `--optimise` / `--optimize`
- `ColourPrimaries` type alias alongside `ColorPrimaries` in `BritishSpelling.swift`
- `scripts/check-spelling.sh` spelling consistency checker (with `--fix` mode)
- British English style guide section added to `CONTRIBUTING.md`
- 18 tests in `InternationalisationTests.swift`
- CI spelling-check job

#### DICOM Awareness (Milestone 17)
- `PixelType.int16` for signed 16-bit Hounsfield units
- `getPixelSigned` / `setPixelSigned` / `getPixelFloat` / `setPixelFloat` accessors
- `PhotometricInterpretation` enum (MONOCHROME1, MONOCHROME2, RGB, YCbCr)
- `WindowLevel` struct with built-in CT presets (bone, lung, abdomen, brain, liver)
- `MedicalImageMetadata` pass-through struct
- `MedicalImageValidator` with dimension / bit-depth / channel checks
- `MedicalImageSeries` for CT / MR stacks
- Convenience initialisers: `ImageFrame.medical12bit`, `medical16bit`, `medicalSigned16bit`
- `EncodingOptions.medicalLossless` preset
- 30 tests in `DICOMTests.swift`
- `Documentation/DICOM_INTEGRATION.md` integration guide

#### Vulkan GPU Compute (Milestone 16)
- `VulkanOps.swift` — Vulkan device, queue, buffer management
- `VulkanCompute.swift` — DCT, colour conversion, quantisation, async pipeline
- `Shaders.comp` — GLSL compute shaders (SPIR-V via glslc)
- `GPUCompute.swift` — cross-platform abstraction routing Metal ↔ Vulkan
- `DispatchBackend.vulkan` case (7 backends total)
- `HardwareCapabilities.hasVulkan` / `vulkanDeviceName`
- Vulkan dispatch path in `VarDCTEncoder`
- 25 tests in `VulkanComputeTests.swift`

#### Intel x86-64 SIMD Optimisation (Milestone 15)
- `SSEOps.swift` — SSE2 4-wide SIMD operations (DCT, colour conversion, quantisation,
  MED prediction, RCT, Squeeze) via `SIMD4<Float>`
- `AVXOps.swift` — AVX2 8-wide operations (wider DCT, colour conversion) via `SIMD8<Float>`
- Runtime AVX2 detection in `Architecture.swift`
- `#if arch(x86_64)` dispatch in `VarDCTEncoder` and `ModularEncoder` with scalar fallback
- 58 tests in `SSEOpsTests.swift`

#### ISO/IEC 18181-3 Conformance Testing (Milestone 14)
- `ConformanceTestSuite.swift` — `ConformanceRunner` with 17 synthetic test vectors
  covering 9 categories: bitstream structure, image header, frame header, container
  format, lossless round-trip, lossy round-trip, progressive encoding, animation,
  and bidirectional libjxl interoperability
- `ConformanceReport` with per-category pass/fail results
- 37 tests in `ConformanceTests.swift`
- CI `conformance` job in `.github/workflows/ci.yml`

## [1.0.0] - 2026-02-19

🎉 **Initial stable release of JXLSwift!**

This release marks the first production-ready version of JXLSwift, a native Swift implementation of the JPEG XL (ISO/IEC 18181) compression codec optimized for Apple Silicon.

### Highlights

- ✅ **Complete JPEG XL Implementation** - Full encoding and decoding support for both lossless (Modular) and lossy (VarDCT) modes
- 🚀 **Apple Silicon Optimized** - Hardware acceleration via ARM NEON, Apple Accelerate, and Metal GPU compute
- 📦 **Production Ready** - Comprehensive testing (1200+ tests), 95%+ code coverage, memory safety validation
- 📚 **Well Documented** - Complete API documentation (DocC), migration guides, performance tuning guides
- 🔧 **Command Line Tool** - Full-featured `jxl-tool` for encoding, decoding, and benchmarking

### Added

#### Production Hardening & Release Infrastructure (Milestone 13)
- CHANGELOG.md for tracking version history
- VERSION file with semantic versioning
- Comprehensive API documentation with DocC
- Migration guide from libjxl to JXLSwift (13K words)
- Performance tuning guide (18K words)
- Code coverage verification infrastructure with automated reporting
- Fuzzing test suite (51 tests) for malformed input handling
- Thread safety tests (51 tests) for concurrent encoding/decoding
- Memory safety validation (ASan, TSan, UBSan in CI)
- Security scanning with CodeQL
- Code coverage reporting in CI pipeline
- `scripts/generate-coverage-report.sh` for automated coverage analysis
- `Documentation/COVERAGE.md` with coverage guidelines
- Makefile targets: `make coverage`, `make coverage-html`

#### Decoding Support (Milestone 12)
- Complete JPEG XL decoding support
- `JXLDecoder` class with full round-trip capability
- Codestream and frame header parsing
- Modular mode decoder with inverse MED prediction
- VarDCT mode decoder with IDCT and YCbCr→RGB conversion
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

#### Benchmarking & Validation (Milestone 11)
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

#### Command Line Tool (Milestone 10)
- `jxl-tool` command-line interface
- `encode` subcommand with quality, effort, and format options
- `decode` subcommand for image decoding
- `info` subcommand for image metadata display
- `benchmark` subcommand for performance testing
- Man page documentation
- Makefile for installation and distribution
- CLI integration tests

#### Advanced Encoding Features (Milestone 9)
- Extra channel support (depth, thermal, spectral, application-specific)
- Animation encoding with frame timing and loop control
- EXIF orientation support (all 8 rotation/flip values)
- Region-of-Interest (ROI) encoding with quality feathering
- Reference frame encoding for animations
- Patch encoding for repeated rectangular regions
- Noise synthesis for perceptual quality improvement
- Spline encoding for vector overlay rendering
- Quality metrics (PSNR, SSIM, MS-SSIM, Butteraugli)
- Validation harness for automated testing
- Bitstream compatibility validation
- Benchmark report generation (JSON, HTML)
- Speed, compression, and memory comparison tools

#### ANS Entropy Coding (Milestone 8)
- Full ANS (Asymmetric Numeral Systems) encoder/decoder
- Adaptive symbol distribution with streaming
- Context modeling for improved compression
- rANS (range ANS) variant for precise probability modeling
- Bitstream compatibility with JPEG XL specification

#### Hardware Acceleration (Milestones 5-7)
- Apple Accelerate integration for vDSP operations
- ARM NEON SIMD optimization using Swift SIMD types
- Metal GPU compute shaders for parallel DCT
- Multi-threaded encoding with hardware detection
- CPU architecture detection (ARM64, x86-64)
- Hardware capability detection (NEON, AVX2, Metal, core count)
- Platform-specific code paths with scalar fallbacks

#### JPEG XL Container Format (Milestone 4)
- ISOBMFF container format support
- Metadata box encoding/decoding (EXIF, XMP, ICC)
- Frame index for animation support
- Container parsing and validation

#### Lossy Compression (Milestone 3)
- VarDCT (Variable-DCT) mode for lossy compression
- DCT transforms (8×8, 16×16, 32×32 blocks)
- Chroma from Luma (CfL) prediction
- Adaptive quantization based on perceptual distance
- YCbCr color space conversion
- Quality-to-distance mapping (0-100 scale)
- Configurable effort levels (fastest, fast, default, thorough)

#### Lossless Compression (Milestone 2)
- Modular mode for bit-perfect lossless compression
- Median Edge Detector (MED) predictor
- ZigZag signed-to-unsigned residual mapping
- Run-length + varint entropy coding
- Support for all pixel types (uint8, uint16, float32)

#### Core Infrastructure (Milestones 0-1)
- `ImageFrame` for planar pixel storage
- `BitstreamWriter`/`BitstreamReader` for I/O
- `EncodingOptions` with presets (`.lossless`, `.fast`, `.highQuality`)
- `CompressionStats` for performance metrics
- `EncoderError` with typed error handling
- `ColorSpace`, `ColorPrimaries`, `TransferFunction` support
- Wide gamut and HDR support (Display P3, Rec. 2020, PQ, HLG)
- Swift Package Manager integration
- Comprehensive test suite (1200+ tests)
- GitHub Actions CI/CD pipeline

### Performance

- **Encoding:** Fast lossless compression optimized for Apple Silicon
- **Decoding:** ≥ 100 MP/s throughput on Apple Silicon
- **Memory:** Efficient memory usage for large images (validated up to 2048×2048)
- **Concurrency:** Thread-safe concurrent encoding with configurable thread count

### Compatibility

- **Platforms:** macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+
- **Swift:** 6.2+ with strict concurrency enabled
- **Architecture:** ARM64 (Apple Silicon), x86-64
- **Dependencies:** Zero runtime C/C++ dependencies
- **Standards:** Follows JPEG XL (ISO/IEC 18181) specification

### Documentation

- API documentation generated with DocC
- Migration guide from libjxl to JXLSwift
- Performance tuning guide with optimization tips
- Coverage verification guide with 95%+ target
- Man pages for command-line tool
- Comprehensive README with examples
- Technical architecture documentation

### Changed
- Enhanced CI/CD pipeline for production releases
- Improved error handling for edge cases
- Updated documentation with comprehensive examples
- Optimized memory usage in large image processing

### Fixed
- Edge case handling in decoder for malformed inputs
- Thread safety issues in concurrent encoding scenarios
- Memory efficiency improvements in large image processing
- Platform-specific build issues on Linux

### Security
- CodeQL security scanning in CI
- Memory safety validation (ASan, TSan, UBSan)
- Fuzzing tests for malformed input handling (no crashes)
- Zero crashes on any valid or invalid input

---

**Migration from 0.x to 1.0.0:**

The 1.0.0 release is API-stable and ready for production use. If you're upgrading from 0.x versions, please review the [Migration Guide](Documentation/MIGRATION.md) for any necessary changes.

**Next Steps:**

- Follow SemVer 2.0.0 for all future releases
- Maintain API stability for 1.x versions
- Deprecation policy: 1 minor version notice before removal

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

[Unreleased]: https://github.com/Raster-Lab/JXLSwift/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/Raster-Lab/JXLSwift/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Raster-Lab/JXLSwift/compare/v0.12.0...v1.0.0
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
