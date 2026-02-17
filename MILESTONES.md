# JXLSwift — Project Milestones

> **JPEG XL (ISO/IEC 18181) Reference Implementation in Native Swift**
>
> A detailed milestone plan for creating a production-quality JPEG XL compression codec optimised for Apple Silicon, with a command line tool and libjxl-comparable output.

---

## Milestone Overview

| # | Milestone | Target | Status |
|---|-----------|--------|--------|
| 0 | Project Foundation & Infrastructure | Weeks 1–2 | ✅ Complete |
| 1 | Core Data Structures & Bitstream I/O | Weeks 2–4 | ✅ Complete |
| 2 | Lossless Compression (Modular Mode) | Weeks 4–7 | ✅ Complete |
| 3 | Lossy Compression (VarDCT Mode) | Weeks 7–11 | ✅ Complete |
| 4 | JPEG XL File Format & Container | Weeks 11–14 | ✅ Complete |
| 5 | Hardware Acceleration — Apple Accelerate | Weeks 14–17 | ✅ Complete |
| 6 | Hardware Acceleration — ARM NEON / SIMD | Weeks 17–20 | ✅ Complete |
| 7 | Hardware Acceleration — Metal GPU | Weeks 20–23 | ✅ Complete |
| 8 | ANS Entropy Coding | Weeks 23–27 | ✅ Complete |
| 9 | Advanced Encoding Features | Weeks 27–31 | ✅ Complete (13/13) |
| 10 | Command Line Tool (jxl-tool) | Weeks 31–34 | ✅ Complete |
| 11 | libjxl Validation & Performance Benchmarking | Weeks 34–38 | 🔶 In Progress |
| 12 | Decoding Support | Weeks 38–44 | ⬜ Not Started |
| 13 | Production Hardening & Release | Weeks 44–48 | ⬜ Not Started |

---

## Milestone 0 — Project Foundation & Infrastructure

**Goal:** Establish the Swift package, CI/CD, project structure, and documentation framework.

### Deliverables

- [x] Swift Package Manager project with `Package.swift`
- [x] Platform targets: macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+
- [x] Swift 6.2 with strict concurrency enabled by default
- [x] Directory structure: `Core/`, `Encoding/`, `Hardware/`, `Format/`
- [x] `.gitignore` for Swift build artifacts
- [x] MIT License
- [x] `README.md` with project overview, installation, and usage examples
- [x] `CONTRIBUTING.md` with development guidelines
- [x] `TECHNICAL.md` with architecture diagrams
- [x] XCTest target configured (`JXLSwiftTests`)

### Acceptance Criteria

- `swift build` succeeds on macOS (ARM64), macOS (x86-64) and Linux (x86-64)
- `swift test` runs with 0 failures
- All `Sendable` conformances compile without warnings under strict concurrency

---

## Milestone 1 — Core Data Structures & Bitstream I/O

**Goal:** Implement the foundational types for image representation, bitstream serialisation, encoding configuration, and CPU/hardware detection.

### Deliverables

- [x] `CPUArchitecture` enum with `#if arch()` compile-time detection
- [x] `HardwareCapabilities` struct (`Sendable`) — NEON, AVX2, Accelerate, Metal, core count
- [x] `ImageFrame` struct — planar pixel storage, `getPixel`/`setPixel`, multi-type support (`uint8`, `uint16`, `float32`)
- [x] `ColorSpace`, `ColorPrimaries`, `TransferFunction`, `PixelType` types
- [x] `BitstreamWriter` — bit, byte, U32, varint, signature, image header writing
- [x] `BitstreamReader` — bit and byte reading (for validation/testing)
- [x] `EncodingOptions` — mode, effort, thread count, hardware flags, presets (`.lossless`, `.fast`, `.highQuality`)
- [x] `CompressionStats` — original size, compressed size, ratio, time, memory
- [x] `EncoderError` — typed errors with `LocalizedError` conformance

### Tests Required

- [x] Architecture detection returns non-unknown value
- [x] `HardwareCapabilities.detect()` returns valid core count
- [x] `ImageFrame` creation, pixel set/get round-trip for all `PixelType` variants
- [x] `BitstreamWriter` signature writing produces `0xFF 0x0A`
- [x] Bit writing: 8 alternating bits → `0xAA`
- [x] Varint encoding: small (< 128) and large (≥ 128) values
- [x] `EncodingOptions` default values and presets
- [x] `CompressionStats.compressionRatio` edge case (zero original size)

### Acceptance Criteria

- All core types compile and are used by the encoder
- `BitstreamWriter` output matches expected byte sequences
- ≥ 95% branch coverage on core types

---

## Milestone 2 — Lossless Compression (Modular Mode)

**Goal:** Implement the Modular mode pipeline for bit-perfect lossless compression following ISO/IEC 18181-1 Part 7.

### Deliverables

- [x] `ModularEncoder` class
- [x] Channel extraction (planar → per-channel `[UInt16]`)
- [x] Median Edge Detector (MED) predictor: `median(N, W, N+W-NW)`
- [x] ZigZag signed-to-unsigned residual mapping
- [x] Run-length + varint entropy coding (simplified)
- [x] Multi-channel decorrelation (RCT — Reversible Colour Transform)
- [x] Squeeze transform (multi-resolution decomposition)
- [x] Context modelling for entropy coding
- [x] MA (Meta-Adaptive) tree-based prediction
- [ ] Full Modular subbitstream framing per ISO/IEC 18181-1 §7

### Tests Required

- [x] Lossless encoding produces non-empty output
- [x] Compression ratio > 1.0 for gradient images
- [ ] Round-trip test: encode → decode → pixel-perfect match (requires decoder)
- [ ] Round-trip test: encode with JXLSwift → decode with libjxl → pixel-perfect match
- [ ] Round-trip test: encode with libjxl → decode with JXLSwift → pixel-perfect match (requires decoder)
- [x] MED predictor unit tests: first pixel, first row, first column, general case
- [x] ZigZag encoding: 0→0, -1→1, 1→2, -2→3, 2→4
- [x] RCT forward and inverse produce pixel-perfect round-trip
- [x] Squeeze transform forward/inverse round-trip
- [x] Edge cases: 1×1 image, single-channel, 16-bit depth, maximum dimensions

### Acceptance Criteria

- Lossless mode compresses ≥ 2× on natural images
- Output bitstream starts with valid JPEG XL signature
- No data loss (verified via future decoder or reference comparison)

---

## Milestone 3 — Lossy Compression (VarDCT Mode)

**Goal:** Implement the VarDCT mode pipeline for high-quality lossy compression following ISO/IEC 18181-1 Part 6.

### Deliverables

- [x] `VarDCTEncoder` class
- [x] RGB → YCbCr colour space conversion (BT.601)
- [x] 8×8 block extraction with edge padding
- [x] 2D Discrete Cosine Transform (scalar reference implementation)
- [x] Frequency-dependent quantisation with distance control
- [x] Zigzag coefficient scanning (8×8)
- [x] DC coefficient + AC run-length encoding
- [x] Quality-to-distance conversion formula
- [ ] Variable block sizes (8×8, 16×16, 32×32, 16×8 etc.)
- [x] XYB colour space (JPEG XL native perceptual space)
- [x] Chroma-from-luma (CfL) prediction
- [x] Adaptive quantisation per block
- [x] DC prediction across blocks
- [ ] Coefficient reordering (natural order per spec)
- [ ] Full VarDCT frame header per ISO/IEC 18181-1 §6

### Tests Required

- [x] Lossy encoding produces non-empty output
- [x] Compression ratio > 1.0 for test images
- [x] DCT round-trip: DCT → IDCT ≈ original (within floating-point tolerance)
- [x] Quantisation: zero distance → no quantisation loss
- [x] Zigzag scan order covers all 64 coefficients exactly once
- [x] Colour space conversion: RGB → YCbCr → RGB round-trip (within tolerance)
- [x] XYB colour space forward/inverse
- [ ] Quality levels: 100 → near-lossless, 50 → high compression, 10 → maximum compression
- [x] Block sizes: non-multiple-of-8 image dimensions handled correctly
- [ ] Performance: 256×256 encoding completes in < 2s

### Acceptance Criteria

- Lossy mode compresses ≥ 8× at quality 90 on photographic images
- Visual quality at quality 90 comparable to JPEG at quality 95
- No crashes or memory errors on any valid input

---

## Milestone 4 — JPEG XL File Format & Container

**Goal:** Implement the JPEG XL codestream and container format per ISO/IEC 18181-2.

### Deliverables

- [x] JPEG XL codestream header (SizeHeader, ImageMetadata, colour encoding)
- [x] Frame header serialisation
- [x] Section/group byte-aligned framing
- [x] ISOBMFF-based container format (.jxl extension)
- [x] Metadata boxes: EXIF, XMP, JUMBF
- [x] ICC colour profile embedding
- [x] Thumbnail box support
- [x] Multi-frame (animation) container framing

### Tests Required

- [ ] Codestream header parses correctly with libjxl
- [ ] Container format validates with `jxlinfo` or equivalent tool
- [x] ICC profile round-trip
- [x] EXIF metadata preserved
- [x] Thumbnail generation and embedding
- [x] File extension and MIME type correctness (`image/jxl`)

### Acceptance Criteria

- Output `.jxl` files open in viewers that support JPEG XL
- libjxl can decode files produced by JXLSwift
- Container metadata survives round-trip through libjxl

---

## Milestone 5 — Hardware Acceleration — Apple Accelerate

**Goal:** Replace scalar implementations with Apple Accelerate (vDSP) for measurable speedups on all Apple platforms.

### Deliverables

- [x] `AccelerateOps` enum with vDSP-based operations
- [x] 2D DCT via `vDSP_DCT_CreateSetup` / `vDSP_DCT_Execute`
- [x] Vector add, subtract, multiply, dot product
- [x] Matrix multiplication via `vDSP_mmul`
- [x] Statistical operations (mean, standard deviation)
- [x] `UInt8 ↔ Float` conversion via `vDSP_vfltu8` / `vDSP_vfixu8`
- [x] Integrate Accelerate DCT into VarDCT pipeline (currently falls back to scalar)
- [x] Accelerate-based colour space conversion
- [x] Accelerate-based quantisation (vectorised divide + round)
- [ ] vImage integration for image resizing/resampling
- [ ] Benchmarks comparing Accelerate vs scalar performance

### Tests Required

- [x] Accelerate DCT matches scalar DCT within `1e-5` tolerance
- [x] Vector operations: `vectorAdd([1,2,3], [4,5,6]) == [5,7,9]`
- [x] Matrix multiply: identity matrix × input = input
- [x] Mean/stddev match known values
- [x] `convertU8ToFloat` → `convertFloatToU8` round-trip
- [ ] Performance: Accelerate DCT ≥ 2× faster than scalar on 256×256 image

### Acceptance Criteria

- Encoding with Accelerate is ≥ 2× faster than scalar-only
- Results are numerically equivalent (within floating-point tolerance)
- Graceful fallback on platforms without Accelerate (`#if canImport(Accelerate)`)

---

## Milestone 6 — Hardware Acceleration — ARM NEON / SIMD

**Goal:** Implement ARM NEON SIMD-optimised code paths for critical inner loops, targeting Apple Silicon.

### Deliverables

- [x] NEON-optimised pixel prediction (4-wide `uint16` processing)
- [x] NEON-optimised MED predictor
- [x] NEON-optimised DCT butterfly operations
- [x] NEON-optimised colour space conversion (RGB ↔ YCbCr, 4 pixels at a time)
- [x] NEON-optimised quantisation (vectorised divide + round)
- [x] NEON-optimised zigzag reordering
- [x] Swift SIMD types (`SIMD4<Float>`, `SIMD8<UInt16>`) for portable vectorisation
- [x] `#if arch(arm64)` guards with scalar fallback in `#else`

### Tests Required

- [x] NEON prediction matches scalar prediction exactly
- [x] NEON DCT matches scalar DCT within tolerance
- [x] NEON colour conversion matches scalar conversion within tolerance
- [x] Edge cases: odd image widths (non-multiple of SIMD width)
- [x] Performance: NEON path ≥ 3× faster than scalar on Apple M1

### Acceptance Criteria

- ARM64 builds use NEON paths automatically
- x86-64 builds use scalar fallbacks automatically
- All NEON code is isolated under `#if arch(arm64)` and removable
- No correctness regressions compared to scalar implementations

---

## Milestone 7 — Hardware Acceleration — Metal GPU

**Goal:** Offload parallelisable encoding stages to the GPU via Metal compute shaders.

### Deliverables

- [x] Metal compute shader for 2D DCT on 8×8 blocks
- [x] Metal compute shader for RGB → YCbCr colour conversion
- [x] Metal compute shader for quantisation
- [x] Metal buffer management for image data transfer (CPU ↔ GPU)
- [x] Async GPU encoding pipeline with double-buffering
- [x] Metal availability check with CPU fallback
- [x] Power/thermal aware scheduling (prefer GPU on plugged-in, CPU on battery)

### Tests Required

- [x] Metal DCT matches CPU DCT within `1e-4` tolerance
- [x] Metal colour conversion matches CPU conversion
- [ ] Large image (4K) encoding produces valid output
- [x] GPU memory is properly released after encoding
- [x] Fallback to CPU on devices without Metal support
- [ ] Performance: GPU path ≥ 5× faster than CPU-only for large images

### Acceptance Criteria

- Metal is used automatically when available and beneficial
- No GPU memory leaks
- Encoding results are equivalent (within tolerance) to CPU-only
- Works on all Apple GPU generations (A-series, M-series)

---

## Milestone 8 — ANS Entropy Coding

**Goal:** Replace simplified run-length/varint encoding with full Asymmetric Numeral Systems (ANS) as specified in ISO/IEC 18181-1 Annex A.

### Deliverables

- [x] rANS (range ANS) encoder
- [x] rANS decoder (for validation)
- [x] Symbol frequency analysis and distribution table generation
- [x] Distribution encoding (compressed and uncompressed modes)
- [x] Multi-context ANS (context-dependent distributions)
- [x] Histogram clustering (merge similar distributions)
- [x] ANS interleaving for parallelism
- [x] LZ77 hybrid mode (for repeated patterns)
- [x] Integration with Modular mode entropy backend
- [x] Integration with VarDCT coefficient encoding

### Tests Required

- [x] ANS encode → decode round-trip for uniform distribution
- [x] ANS encode → decode round-trip for skewed distribution
- [x] ANS encode → decode round-trip for sparse data (mostly zeros)
- [x] Multi-context ANS correctness
- [x] Distribution table serialisation/deserialisation
- [x] LZ77 mode for repetitive data
- [x] Performance: ANS encoding ≥ 80% throughput of simplified encoder
- [x] Compression: ANS achieves ≥ 10% better compression than simplified encoding

### Acceptance Criteria

- ANS output matches libjxl entropy coding within 5% size
- Decodable by libjxl decoder
- No compression ratio regression compared to simplified encoding

---

## Milestone 9 — Advanced Encoding Features

**Goal:** Implement advanced JPEG XL features for production-grade encoding.

### Deliverables

- [x] Progressive encoding (DC → AC refinement passes)
- [x] Responsive encoding (progressive by quality layer) — **Framework Complete**
- [x] Multi-frame / animation support
- [x] Alpha channel encoding (separate or premultiplied) — **Pipeline Complete**
- [x] Extra channels (depth, thermal, spectral) — **Core Implementation Complete**
- [x] HDR support: PQ and HLG transfer functions
- [x] Wide gamut: Display P3, Rec. 2020 colour spaces
- [x] Oriented rendering (EXIF orientation) — **All 8 values supported**
- [x] Crop/region-of-interest encoding — **Complete with feathering support**
- [x] Reference frame encoding (for animation deltas) — **Complete with keyframe-based approach**
- [x] Patches (copy from reference) — **Complete with 4 presets and CLI support**
- [x] Noise synthesis parameters — **Complete with 4 presets, deterministic PRNG, Gaussian noise, CLI support**
- [x] Splines (vector overlay feature) — **Complete with 3 presets and CLI support**

### Tests Required

- [x] Progressive: first pass produces viewable low-resolution image
- [x] Responsive: quality layers configured and validated — **29 comprehensive tests**
- [x] Animation: multi-frame round-trip with correct timing — **24 comprehensive tests**
- [x] Alpha: premultiplied and straight alpha modes — **13 comprehensive tests**
- [x] Extra channels: depth, thermal, spectral encoding — **23 comprehensive tests**
- [x] HDR: PQ and HLG metadata preserved
- [x] Wide gamut: P3 and Rec.2020 primaries encoded correctly
- [x] EXIF orientation: all 8 values preserved through encoding — **15 comprehensive tests**
- [x] Region-of-interest: selected area encoded at high quality with smooth transitions — **42 comprehensive tests**

### Acceptance Criteria

- Progressive files render incrementally in supported viewers
- Animation files play correctly in supported viewers — **Encoding complete, decoder required for validation**
- HDR metadata survives round-trip through libjxl
- ROI encoding produces higher quality in specified regions — **Validated via per-block distance calculations**

---

## Milestone 10 — Command Line Tool (jxl-tool)

**Goal:** Create a full-featured command line tool exposing all JXLSwift functionality.

### Deliverables

- [x] Swift executable target `jxl-tool` in `Package.swift`
- [x] ArgumentParser-based CLI with subcommands
- [x] **`encode`** subcommand — encode image files to JPEG XL
  - Input formats: PNG, JPEG, TIFF, BMP (via platform image I/O)
  - Output: `.jxl` file
  - Options: `--quality`, `--distance`, `--effort`, `--lossless`, `--progressive`
  - Options: `--threads`, `--no-accelerate`, `--no-metal`, `--no-neon`
  - Output: statistics (ratio, time, memory)
- [ ] **`decode`** subcommand — decode JPEG XL to image file (when decoder is ready)
- [x] **`info`** subcommand — display JPEG XL file metadata
  - Image dimensions, bit depth, channels
  - Colour space, ICC profile summary
  - Compression mode, effort level
  - File size, container boxes
- [x] **`benchmark`** subcommand — performance benchmarking
  - Compare encoding speeds across effort levels
  - Compare quality metrics (PSNR, SSIM) across quality settings
  - Compare against libjxl (if installed)
  - JSON and human-readable output
- [x] **`hardware`** subcommand — display detected hardware capabilities
  - CPU architecture, NEON/AVX2 support
  - Accelerate availability
  - Metal GPU availability and device name
  - Core count, memory
- [x] **`batch`** subcommand — batch encode a directory of images
  - Recursive directory traversal
  - Progress reporting
  - Summary report
  - `--overwrite`, `--quiet`, `--verbose` flags
- [x] **`compare`** subcommand — compare JXLSwift output with libjxl
  - Byte-level comparison
  - Quality metric comparison (PSNR, SSIM, Butteraugli)
  - Speed comparison
- [x] Standard UNIX conventions: `--help`, `--version`, `--verbose`, `--quiet`
- [x] Exit codes: 0 success, 1 general error, 2 invalid arguments
- [x] Man page generation

### Tests Required

- [x] CLI parses all arguments correctly
- [x] `encode` produces valid `.jxl` output
- [x] `info` displays correct metadata for known test files
- [x] `hardware` displays non-empty capability information
- [x] `benchmark` completes without errors
- [x] `batch` processes a directory correctly
- [x] Invalid arguments produce meaningful error messages
- [x] `--version` outputs correct version string

### Acceptance Criteria

- `jxl-tool encode input.png -o output.jxl` produces valid JPEG XL
- `jxl-tool info output.jxl` displays correct metadata
- `jxl-tool benchmark` produces reproducible results
- All subcommands have `--help` documentation
- Exit codes follow UNIX conventions

---

## Milestone 11 — libjxl Validation & Performance Benchmarking

**Goal:** Validate JXLSwift output against the reference libjxl C++ implementation and establish performance baselines.

### Deliverables

- [x] Test harness comparing JXLSwift and libjxl output
- [ ] Bitstream compatibility validation (libjxl can decode JXLSwift output)
- [x] Quality metric comparison: PSNR, SSIM, MS-SSIM, Butteraugli
- [ ] Speed comparison: encode time at each effort level
- [ ] Compression ratio comparison at each quality level
- [ ] Memory usage comparison
- [ ] Test image corpus: Kodak, Tecnick, Wikipedia test images
- [x] Automated regression test suite (CI integration)
- [x] Performance regression detection (alerting on > 10% slowdown)
- [x] Benchmark result publishing (JSON, HTML report)

### Tests Required

- [ ] libjxl decodes every JXLSwift-produced file without errors
- [ ] PSNR difference ≤ 1 dB at equivalent quality settings
- [ ] Compression ratio within 20% of libjxl at equivalent settings
- [ ] Encoding speed within 3× of libjxl (expected initial gap, improve over time)
- [ ] No memory leaks detected by Instruments/ASan

### Acceptance Criteria

- 100% of test corpus files decode successfully with libjxl
- Quality metrics are comparable (not necessarily identical)
- Performance baselines documented and tracked in CI

---

## Milestone 12 — Decoding Support

**Goal:** Implement a JPEG XL decoder for full round-trip support.

### Deliverables

- [ ] `JXLDecoder` class — main decoding interface
- [ ] Codestream header parsing
- [ ] Frame header parsing
- [ ] Modular mode decoder (inverse prediction, entropy decoding)
- [ ] VarDCT mode decoder (entropy decoding, dequantisation, IDCT, colour conversion)
- [ ] ANS entropy decoder
- [ ] Progressive decoding (partial image rendering)
- [ ] Container format parsing
- [ ] Metadata extraction (EXIF, XMP, ICC)
- [ ] `decode` subcommand in jxl-tool
- [ ] Output to PNG, TIFF, BMP via platform image I/O

### Tests Required

- [ ] Decode JXLSwift-encoded files: pixel-perfect for lossless, PSNR > 40 dB for lossy
- [ ] Decode libjxl-encoded test files
- [ ] Decode progressive files incrementally
- [ ] Handle corrupted/truncated files gracefully
- [ ] Memory-bounded decoding of large images
- [ ] Performance: decode ≥ 100 MP/s on Apple Silicon

### Acceptance Criteria

- Lossless round-trip: encode → decode is pixel-perfect
- Lossy round-trip: encode → decode matches expected quality
- Can decode files produced by libjxl
- Graceful error handling for invalid input

---

## Milestone 13 — Production Hardening & Release

**Goal:** Prepare the library for production use with comprehensive testing, documentation, and release packaging.

### Deliverables

- [ ] 95%+ unit test coverage on all public and internal APIs
- [ ] Fuzzing test suite (invalid/malformed input handling)
- [ ] Memory safety validation (ASan, TSan, UBSan)
- [ ] API documentation generated with DocC
- [ ] Migration guide from libjxl to JXLSwift
- [ ] Performance tuning guide
- [ ] Release versioning (SemVer) and CHANGELOG.md
- [ ] GitHub Actions CI for macOS (ARM64), macOS (x86-64), Linux
- [ ] Tagged release v1.0.0 with pre-built frameworks
- [ ] CocoaPods and Carthage support (optional)
- [ ] Swift Package Index listing

### Tests Required

- [ ] Fuzz testing with 10,000+ malformed inputs (no crashes)
- [ ] Memory leak testing on large image corpus
- [ ] Thread safety testing under concurrent access
- [ ] API stability testing (no breaking changes from 0.x to 1.0)
- [ ] Documentation coverage: every public symbol documented

### Acceptance Criteria

- No crashes on any valid or invalid input
- No memory leaks on extended operation
- Thread-safe under concurrent encoding
- Complete API documentation
- Stable public API ready for SemVer 1.0.0

---

## Architecture-Specific Code Separation Plan

The project maintains strict separation of architecture-specific code to allow future removal of x86-64 support:

```
Sources/JXLSwift/
├── Core/           ← Architecture-independent (always kept)
├── Encoding/       ← Architecture-independent algorithms
├── Hardware/
│   ├── Accelerate.swift    ← #if canImport(Accelerate) guarded
│   ├── ARM/                ← #if arch(arm64) guarded (future)
│   │   ├── NEONOps.swift
│   │   └── NEONDct.swift
│   └── x86/                ← #if arch(x86_64) guarded (removable)
│       ├── AVXOps.swift
│       └── SSEDct.swift
└── Format/         ← Architecture-independent
```

**Removal process:** Delete the `Hardware/x86/` directory and remove `#elseif arch(x86_64)` branches. The `#else` fallback (scalar) implementations remain as universal fallbacks.

---

## Dependency Policy

| Dependency | Purpose | Required | Notes |
|-----------|---------|----------|-------|
| Foundation | Core types, Data, Date | Yes | Apple platform standard |
| Accelerate | vDSP, vImage | Optional | `#if canImport(Accelerate)` |
| Metal | GPU compute | Optional | `#if canImport(Metal)` |
| ArgumentParser | CLI argument parsing | jxl-tool only | Swift Package dependency |
| XCTest | Unit testing | Tests only | Standard testing framework |
| libjxl | Reference comparison | Benchmarks only | External C++ library |

**Zero runtime C/C++ dependencies** for the core library.

---

## Performance Targets

| Scenario | Target (Apple Silicon M1) | Target (x86-64) |
|----------|--------------------------|-----------------|
| Lossless 256×256 | < 50 ms | < 150 ms |
| Lossy 256×256 (effort 3) | < 30 ms | < 100 ms |
| Lossy 256×256 (effort 7) | < 200 ms | < 700 ms |
| Lossy 1920×1080 (effort 3) | < 200 ms | < 700 ms |
| Lossy 1920×1080 (effort 7) | < 2 s | < 7 s |
| Lossy 4K (effort 3) | < 500 ms | < 2 s |
| Decode 4K | < 100 ms | < 300 ms |
| Memory: 4K image | < 100 MB | < 150 MB |

---

## Quality Targets

| Quality Setting | Target PSNR (dB) | Target SSIM | Target Compression |
|----------------|-------------------|-------------|-------------------|
| 100 (near-lossless) | > 50 | > 0.999 | 2–4× |
| 90 (high quality) | > 40 | > 0.98 | 8–15× |
| 75 (good quality) | > 35 | > 0.95 | 15–30× |
| 50 (acceptable) | > 30 | > 0.90 | 30–60× |
| 25 (low quality) | > 25 | > 0.80 | 60–100× |

---

## Standards Reference

- **ISO/IEC 18181-1:2024** — JPEG XL Core coding system
- **ISO/IEC 18181-2:2024** — JPEG XL File format
- **ISO/IEC 18181-3:2024** — JPEG XL Conformance testing
- **ISO/IEC 18181-4:2024** — JPEG XL Reference software

### Key Specification Sections

| Section | Topic | Milestone |
|---------|-------|-----------|
| §6 | VarDCT mode | M3 |
| §7 | Modular mode | M2 |
| §8 | Entropy coding | M8 |
| §9 | Colour management | M3, M9 |
| §10 | Frame header | M4 |
| §11 | Image header | M4 |
| Annex A | ANS coding | M8 |
| Part 2 | File format | M4 |

---

## Risk Register

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| ANS implementation complexity | High | Medium | Start with simplified entropy coding; iterate toward full ANS |
| Metal GPU memory management | Medium | Medium | Implement robust fallback; test on all GPU generations |
| libjxl compatibility gaps | High | Low | Continuous testing against libjxl; focus on core features first |
| Performance gap vs libjxl | Medium | High | Accept initial gap; optimise iteratively; leverage Apple hardware |
| Swift 6 concurrency strictness | Low | Low | Already enabled; maintain `Sendable` conformance throughout |
| x86-64 maintenance burden | Low | Medium | Keep x86 code minimal; prefer architecture-independent solutions |

---

*Document version: 1.0*
*Created: 2026-02-16*
*Project: JXLSwift (Raster-Lab/JXLSwift)*
*Standard: ISO/IEC 18181-1:2024*
