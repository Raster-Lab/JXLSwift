# Changelog

JXLSwift's release history since the libjxl-backed rewrite. The pre-rewrite history (v0.x — pure-Swift attempt that was rolled back) is preserved at [Documentation/legacy/CHANGELOG-pre-rewrite.md](Documentation/legacy/CHANGELOG-pre-rewrite.md).

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and the project follows [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.4.0] — 2026-04-27

### Added — production hardening

- **Edge-case + fuzz tests** (8 new): empty data, random bytes, truncated bitstream, zero-sized frame, multi-frame mismatched dimensions, malformed DICOM (garbage / too small), encode→decode→encode pixel idempotency.
- **Graceful SIGINT handling** in `jxl-tool batch`: in-flight encodes finish, new dispatch is skipped. Implemented via `DispatchSourceSignal` with a benign-race flag.
- **`jxl-tool --version`** reports both the Swift package version and the linked libjxl version: `jxl-tool 0.4.0  (libjxl 0.11.2)`.
- **GitHub Actions CI** workflow (`.github/workflows/ci.yml`): builds on macOS 15, runs all 21 tests, and exercises the CLI end-to-end on every push.

### Added — codec features

- **Memory-aware parallelism**: `--max-memory-mb` flag in `jxl-tool batch`. New `MemoryBudget` actor gates concurrent encode-task dispatch on a byte budget (defaults to 25 % of physical RAM), with a configurable per-pixel-byte working-set multiplier (`--memory-overhead`, default 4×).
- **DICOM correctness — signed pixels**: `PixelRepresentation = 1` now sign-extends `BitsStored` bits to `Int32` and biases by `2^(bitsStored-1)` so the resulting `ImageFrame` is unsigned. The bias is recorded in `DICOMMetadata.signedBias` for round-tripping.
- **DICOM correctness — Modality LUT**: `RescaleSlope` (0028,1053) and `RescaleIntercept` (0028,1052) are read into `DICOMMetadata`. The transform is **not applied** at read time — that would break lossless round-trips — but it is surfaced for downstream tools.
- **`DICOMReader.readWithMetadata(_:)`** returns `(ImageFrame, DICOMMetadata)` with `seriesInstanceUID`, `studyInstanceUID`, `sliceLocation`, `instanceNumber`, `modality`, `photometricInterpretation`, `bitsStored`, `pixelRepresentation`, `signedBias`, `rescaleSlope`, `rescaleIntercept`.
- **Volume-aware multi-frame batch**: `jxl-tool batch --volume-aware` groups DICOM slices that share a `SeriesInstanceUID`, sorts each group by `InstanceNumber`/`SliceLocation`, and encodes the whole series as one multi-frame `.jxl` named `series_<short-uid>_x<count>.jxl`.

### Fixed

- **Silent 16-bit-to-8-bit downsampling on PGM input**: `loadImageFrame(from:)` was routing `.pgm` through CoreGraphics, which silently downsamples 16-bit greymaps to 8-bit. The CLI now uses the existing `parsePGM` direct parser for `.pgm` files, preserving full bit depth.

---

## [0.3.0] — 2026-04-27

### Added

- **Multi-frame JXL encode/decode**: `JXLEncoder.encode([ImageFrame])` and `JXLDecoder.decodeAll(_:)`. All frames must share dimensions / channels / pixel type; `have_animation` is set on the bitstream and `JxlFrameHeader` is written per frame.
- **16-bit grayscale PNG output**: `jxl-tool decode` preserves 16-bit precision through to the output PNG (CGImage `bitsPerComponent: 16`).
- **JSON manifest output**: `jxl-tool batch --manifest path.json` writes a structured per-file report (input, output, bytesIn/Out, ratio, w/h/channels, frames, bitDepth, encodeTimeS, status).
- **In-process parallel batch ergonomics**: a single long-lived process replaces the per-file shell-loop pattern, eliminating per-file startup cost and intermediate-file I/O.

---

## [0.2.0] — 2026-04-27

### Added — DICOM specialization

- **Native Swift DICOM reader** ([DICOMReader.swift](Sources/JXLSwift/DICOMReader.swift)) handling Implicit/Explicit VR LE and Explicit VR BE transfer syntaxes — the uncompressed monochrome formats that dominate radiology archives. Output: `ImageFrame` at the original bit depth (uint8 for ≤ 8-bit, uint16 for 9-16-bit).
- **DICOM auto-detect in CLI**: `jxl-tool encode --input scan.dcm` works without an external preprocessing step.
- **`magick` PGM fallback** for compressed DICOM transfer syntaxes (JPEG / JPEG-LS / JPEG 2000 / RLE-encapsulated) the native reader doesn't decode.
- **Parallel batch subcommand** with `Swift Concurrency TaskGroup`: `jxl-tool batch path/ --output out/ --parallel 4`. One long-lived process, no per-file startup, no intermediate PNG.

### Verified

- 9 / 9 integration tests pass.
- 16-bit pixel data preserved end-to-end on every uncompressed-monochrome DICOM in the test corpus.

---

## [0.1.0] — 2026-04-27

### Rewrite

The first public version: a thin Swift wrapper around libjxl (Homebrew `jpeg-xl`), via a new `Cjxl` SwiftPM systemLibrary module.

- **Public API**: `ImageFrame`, `EncodingOptions`, `JXLEncoder`, `JXLDecoder`, `EncodedImage`, `CompressionStats`.
- **`jxl-tool` CLI**: `encode`, `decode`, `info` subcommands.
- **Integration tests** ([Tests/JXLSwiftTests/IntegrationTests.swift](Tests/JXLSwiftTests/IntegrationTests.swift)):
  - lossless round-trip pixel-exact
  - lossy quality 90 / distance 1.0 PSNR ≥ 35 dB
  - lossless output strictly smaller than raw input
  - bitstream is decodable by the libjxl reference decoder
  - libjxl-encoded bitstreams are decodable by `JXLDecoder`
  - encoded bitstream carries a JXL signature

### Replaces

This release replaces a pure-Swift implementation that did not produce ISO/IEC 18181-compliant output. The pre-rewrite tree is preserved on the `pre-rewrite-snapshot` branch (commit `f0927ef`).
