# JXLSwift — Technical Overview

> Native Swift implementation of ISO/IEC 18181 (JPEG XL) optimised for Apple Silicon.

---

## Architecture

```
Sources/JXLSwift/
├── Core/                        # Foundational types (architecture-independent)
│   ├── Architecture.swift       # CPUArchitecture, HardwareCapabilities detection
│   ├── ImageFrame.swift         # Image data structures, colour spaces, pixel types
│   ├── PixelBuffer.swift        # Tiled pixel-buffer with random-access API
│   ├── Bitstream.swift          # BitstreamWriter / BitstreamReader
│   ├── EncodingOptions.swift    # CompressionMode, EncodingEffort, animation, ROI,
│   │                            #   patches, noise, splines, reference frames,
│   │                            #   responsive config
│   ├── CodecProtocols.swift     # RasterImageEncoder / RasterImageDecoder / RasterImageCodec
│   ├── BritishSpelling.swift    # ColourPrimaries type alias
│   ├── QualityMetrics.swift     # PSNR, SSIM, MS-SSIM, Butteraugli
│   ├── ValidationHarness.swift  # Encoding validation test harness
│   ├── BitstreamValidator.swift # Structural bitstream validation + libjxl hooks
│   ├── BenchmarkReport.swift    # JSON / HTML report generation, regression detection
│   ├── ComparisonBenchmark.swift# Speed, compression, memory comparisons; test corpus
│   ├── ConformanceTestSuite.swift# ISO/IEC 18181-3 conformance test runner (17 vectors)
│   ├── NoiseSynthesis.swift     # NoiseConfig, film-grain synthesis parameters
│   ├── Spline.swift             # Spline, SplineConfig, SplineDetector
│   ├── Patch.swift              # Patch detection and reference-frame copying
│   └── MedicalImagingSupport.swift # MedicalImageValidator, MedicalImageSeries,
│                                #   DICOM-compatible initialisers, WindowLevel presets
│
├── Encoding/                    # Compression pipeline
│   ├── Encoder.swift            # JXLEncoder — single/multi-frame encoding, animation
│   ├── Decoder.swift            # JXLDecoder — codestream + container decode, metadata
│   ├── ModularEncoder.swift     # Lossless Modular mode (MED, RCT, Squeeze, MA tree)
│   ├── ModularDecoder.swift     # Inverse Modular decode (round-trip support)
│   ├── VarDCTEncoder.swift      # Lossy VarDCT mode (DCT, quantisation, CfL, XYB)
│   ├── VarDCTDecoder.swift      # Inverse VarDCT decode (IDCT, YCbCr->RGB)
│   └── ANSEncoder.swift         # rANS entropy coding (ISO/IEC 18181-1 Annex A)
│
├── Export/                      # Image format export
│   └── ImageExporter.swift      # PNG, TIFF, BMP via CoreGraphics / ImageIO
│
├── Hardware/                    # Platform-specific acceleration
│   ├── Accelerate.swift         # vDSP DCT, matrix ops; vImage Lanczos resampling
│   ├── NEONOps.swift            # ARM NEON SIMD (portable Swift SIMD types)
│   ├── NEONDct.swift            # NEON-optimised DCT kernel
│   ├── DispatchBackend.swift    # Runtime backend enum
│   ├── GPUCompute.swift         # Cross-platform GPU abstraction (Metal or Vulkan)
│   ├── Metal/                   # Apple GPU — #if canImport(Metal)
│   │   ├── MetalOps.swift       # Device / buffer management
│   │   ├── MetalCompute.swift   # DCT, colour conversion, quantisation; async pipeline
│   │   └── Shaders.metal        # MSL compute shaders
│   ├── x86/                     # Intel SIMD — #if arch(x86_64)
│   │   ├── SSEOps.swift         # SSE2 4-wide ops (DCT, colour conversion, quantisation)
│   │   └── AVXOps.swift         # AVX2 8-wide ops (wider DCT, colour conversion)
│   └── Vulkan/                  # Linux / Windows GPU — #if canImport(Vulkan)
│       ├── VulkanOps.swift      # Vulkan device / queue / buffer management
│       ├── VulkanCompute.swift  # Vulkan compute (DCT, colour conversion, async pipeline)
│       └── Shaders.comp         # GLSL compute shaders (compiled to SPIR-V with glslc)
│
└── Format/                      # ISO/IEC 18181-2 file format
    ├── CodestreamHeader.swift   # SizeHeader, ImageMetadata, ColourEncoding
    ├── FrameHeader.swift        # Frame header, section / group framing
    └── JXLContainer.swift       # ISOBMFF container, EXIF / XMP / ICC boxes

Sources/JXLTool/
├── JXLTool.swift               # CLI entry point (swift-argument-parser)
├── Encode.swift                # encode subcommand (dual British/American options)
├── Decode.swift                # decode subcommand
├── Info.swift                   # info subcommand
├── Hardware.swift               # hardware subcommand
├── Benchmark.swift             # benchmark subcommand
├── Batch.swift                 # batch subcommand
├── Compare.swift               # compare subcommand
├── Validate.swift              # validate subcommand
└── Utilities.swift             # Shared CLI helpers
```

---

## Compression Pipelines

### Lossless — Modular Mode

```
Input
  +-> Channel Extraction
        +-> Reversible Colour Transform (RCT)    [NEON / SSE / scalar]
              +-> MA (Meta-Adaptive) Tree context modelling
                    +-> MED Predictor             [NEON / SSE / scalar]
                          +-> Residuals (ZigZag signed->unsigned)
                                +-> Entropy Coding (ANS or RLE+varint)
                                      +-> Subbitstream framing (Section 7)
                                            +-> Output
```

Features:
- Median Edge Detector (MED) predictor
- Reversible Colour Transform (RCT)
- Squeeze transform for subsampled channels
- MA tree for context-adaptive symbol distribution
- rANS entropy coding (ISO/IEC 18181-1 Annex A)
- Subbitstream framing with global + per-channel sections

### Lossy — VarDCT Mode

```
Input
  +-> Optional XYB colour space conversion        [Accel / NEON / SSE / AVX / Metal / Vulkan]
        +-> Variable block-size DCT                [Accel / NEON / SSE / AVX / Metal / Vulkan]
              |  (8x8, 16x16, 32x32, 16x8, 8x16 ...)
              +-> Chroma-from-Luma (CfL) prediction
                    +-> Frequency-dependent quantisation
                          +-> Natural-order coefficient scanning
                                +-> DC prediction
                                      +-> Entropy Coding (ANS or RLE)
                                            +-> VarDCT frame header
                                                  +-> Output
```

Features:
- XYB perceptual colour space (JPEG XL native)
- Variable block sizes with content-adaptive selection
- Chroma-from-Luma coefficient prediction
- Frequency-dependent quantisation matrices
- Natural-order coefficient scanning (spec-compliant)
- Progressive encoding (DC + low-freq AC + high-freq AC)
- Responsive encoding (quality-layered delivery)
- Adaptive quantisation for perceptual quality

---

## Hardware Acceleration

### ARM64 (Apple Silicon / ARM servers)

```swift
#if arch(arm64)
    // Swift SIMD4<Float> / SIMD8<Float> portable NEON operations
    // Vectorised: DCT, colour conversion, quantisation, MED prediction,
    //             RCT, Squeeze, and buffer operations
#endif
```

### Apple Accelerate Framework

```swift
#if canImport(Accelerate)
    // vDSP: DCT-II/III transforms, vector multiply-add, matrix operations
    // vImage: Lanczos resampling via vImageScale_Planar8
    // Automatic CPU dispatch (uses AMX coprocessor on M-series chips)
#endif
```

### Intel SSE2 / AVX2

```swift
#if arch(x86_64)
    // SSEOps: 4-wide Float SIMD (DCT, colour conversion, quantisation)
    // AVXOps: 8-wide Float SIMD (wider DCT, colour conversion)
    // Runtime AVX2 guard: HardwareCapabilities.shared.hasAVX2
#endif
```

### Metal GPU (Apple platforms)

```swift
#if canImport(Metal)
    // Async double-buffered pipeline (CPU / GPU overlap)
    // Compute pipelines: DCT, colour conversion, quantisation
    // Controlled via EncodingOptions.useMetal
#endif
```

### Vulkan GPU (Linux / Windows)

```swift
#if canImport(Vulkan)
    // VulkanCompute mirrors the Metal API
    // GLSL shaders -> SPIR-V with glslc
    // GPUCompute routes to Metal on Apple, Vulkan elsewhere
#endif
```

### Runtime Backend Priority

```
Metal  ->  Vulkan  ->  Accelerate  ->  AVX2  ->  NEON  ->  Scalar
```

---

## Data Flow

```
User Application
       |
       v
+------------------+
|   JXLEncoder     |<--- EncodingOptions (mode, effort, ROI, animation, ...)
+------------------+
       |
       +--- lossless? ------------------------------------------+
       |                                                          |
       v                                                          v
+--------------+                                    +-----------------+
| VarDCTEncoder|                                    | ModularEncoder  |
|  + ANS       |                                    |  + ANS          |
+--------------+                                    +-----------------+
       |                                                          |
       +----------------------------+-----------------------------+
                                    |
                                    v
                         +------------------+
                         | BitstreamWriter  |
                         +------------------+
                                    |
                                    v
                             Compressed Data
                        (codestream or ISOBMFF container)
```

---

## Quality / Speed Trade-off

```
Effort   Name         Speed        Compression
--------------------------------------------------
1        Lightning    ██████████   ██
2        Thunder      █████████    ███
3        Falcon       ████████     ████
4        Cheetah      ███████      █████
5        Hare         ██████       ██████
6        Wombat       █████        ███████
7        Squirrel     ████         ████████  <- default
8        Kitten       ███          █████████
9        Tortoise     ██           ██████████
```

---

## Memory Layout

### Image Frame (Planar)

```
Planar layout — one contiguous region per channel:
  data = [ C0_00 C0_01 ... C0_nm ][ C1_00 C1_01 ... C1_nm ][ C2_00 ... ]
  index = channel * (width * height * bytesPerSample)
        + y      * (width * bytesPerSample)
        + x      * bytesPerSample
```

### DCT Blocks

```
8x8 blocks extracted from padded planar channel:
  +----+----+----+
  | B0 | B1 | B2 |   x ->
  +----+----+----+
  | B3 | B4 | B5 |   y down
  +----+----+----+
Coefficients in natural order per ISO/IEC 18181-1 Annex C.6
```

---

## Compression Performance (Apple M1, indicative)

| Mode                  | Ratio   | Speed           |
|-----------------------|---------|-----------------|
| Lossless (Modular)    | 2–4x    | ~0.3 s / MP     |
| Lossy q90 (VarDCT)   | 8–15x   | ~0.7 s / 256^2  |
| Lossy q75 (VarDCT)   | 15–30x  | ~0.5 s / 256^2  |

---

## Standards Compliance

| Standard               | Description                        | Status        |
|------------------------|------------------------------------|---------------|
| ISO/IEC 18181-1:2024   | Core coding system                 | Implemented   |
| ISO/IEC 18181-2:2021   | File format (ISOBMFF container)    | Implemented   |
| ISO/IEC 18181-3:2024   | Conformance testing                | 17 test vectors |

---

## Test Coverage Summary

- Architecture detection (CPUArchitecture, HardwareCapabilities)
- Image frame operations (uint8 / uint16 / float32 / int16 pixel types)
- Bitstream I/O (BitstreamWriter, BitstreamReader)
- Lossless Modular round-trip encode/decode
- Lossy VarDCT round-trip encode/decode
- ANS entropy coding (encode / decode / histogram clustering)
- Animation encoding (multi-frame, reference frames, patches)
- Progressive encoding / decoding (3-pass)
- Responsive encoding (quality layers)
- Extra channels (depth, thermal, optional)
- Alpha channels (straight, premultiplied)
- HDR / wide gamut (PQ, HLG, Display P3, Rec. 2020)
- EXIF orientation (all 8 values)
- Region-of-Interest encoding
- Noise synthesis
- Spline encoding
- Patch encoding
- DICOM-compatible medical imaging
- Quality metrics (PSNR, SSIM, MS-SSIM, Butteraugli)
- Container format (ISOBMFF, metadata boxes)
- Hardware acceleration (NEON, Accelerate, SSE/AVX, Metal, Vulkan)
- ISO/IEC 18181-3 conformance testing (17 vectors)
- Fuzzing (51 malformed-input tests)
- Thread safety (51 concurrent-operation tests)
- Memory safety (ASan, TSan, UBSan in CI)
- Security scanning (CodeQL)
