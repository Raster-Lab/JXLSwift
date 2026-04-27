# Changelog

JXLSwift's release history since the libjxl-backed rewrite. The pre-rewrite history (v0.x — pure-Swift attempt that was rolled back) is preserved at [Documentation/legacy/CHANGELOG-pre-rewrite.md](Documentation/legacy/CHANGELOG-pre-rewrite.md).

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and the project follows [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.4.0] — 2026-04-27

### Added — production hardening

- **Edge-case + fuzz tests** (8 new): empty data, random bytes, truncated bitstream, zero-sized frame, multi-frame mismatched dimensions, malformed DICOM (garbage / too small), encode→decode→encode pixel idempotency.
- **Graceful SIGINT handling** in `jxl-tool batch`: in-flight encodes finish, new dispatch is skipped. Implemented via `DispatchSourceSignal` with a benign-race flag.
- **`jxl-tool --version`** reports both the Swift package version and the linked libjxl version: `jxl-tool 0.4.0  (libjxl 0.11.2)`.
- **GitHub Actions CI** workflow (`.github/workflows/ci.yml`): builds on macOS 15, runs all 21 tests, smoke-tests the CLI, and verifies cross-codec compatibility with `djxl` on every push.

### Added — codec features

- **Memory-aware parallelism**: `--max-memory-mb` flag in `jxl-tool batch`. New `MemoryBudget` actor gates concurrent encode-task dispatch on a byte budget (defaults to 25 % of physical RAM), with a configurable per-pixel-byte working-set multiplier (`--memory-overhead`, default 4×).
- **DICOM correctness — signed pixels**: `PixelRepresentation = 1` now sign-extends `BitsStored` bits to `Int32` and biases by `2^(bitsStored-1)` so the resulting `ImageFrame` is unsigned. The bias is recorded in `DICOMMetadata.signedBias` for round-tripping.
- **DICOM correctness — Modality LUT**: `RescaleSlope` (0028,1053) and `RescaleIntercept` (0028,1052) are read into `DICOMMetadata`. The transform is **not applied** at read time — that would break lossless round-trips — but it is surfaced for downstream tools.
- **`DICOMReader.readWithMetadata(_:)`** returns `(ImageFrame, DICOMMetadata)` with `seriesInstanceUID`, `studyInstanceUID`, `sliceLocation`, `instanceNumber`, `modality`, `photometricInterpretation`, `bitsStored`, `pixelRepresentation`, `signedBias`, `rescaleSlope`, `rescaleIntercept`.
- **Volume-aware multi-frame batch**: `jxl-tool batch --volume-aware` groups DICOM slices that share a `SeriesInstanceUID`, sorts each group by `InstanceNumber`/`SliceLocation`, and encodes the whole series as one multi-frame `.jxl` named `series_<short-uid>_x<count>.jxl`.

### Fixed

- **Silent 16-bit-to-8-bit downsampling on PGM input** (uncovered while building the codec benchmark): `loadImageFrame(from:)` was routing `.pgm` through CoreGraphics, which silently downsamples 16-bit greymaps to 8-bit. The CLI now uses the existing `parsePGM` direct parser for `.pgm` files. After the fix, `jxl-tool` and `cjxl` produce **byte-identical output** on the same 16-bit PGM (MD5 match).

### Verified

| Codec | Total wall (24 runs) | Median wall | Compression ratio |
|---|---:|---:|---:|
| **JXLSwift (lossless e7)** | 17.12 s | 0.978 s | **3.581×** |
| libjxl `cjxl` (reference) | 16.25 s | 0.894 s | 3.581× |
| OpenJPEG `opj_compress` (DICOM Part 5 standard) | 23.18 s | 1.446 s | 2.290× |
| zstd `-19` (general baseline) | 48.59 s | 1.371 s | 2.563× |

JXL beats JPEG 2000 lossless by 56 % on real 16-bit medical imagery (CT/DX/MG, 8 inputs × 3 iterations).

---

## [0.3.0] — 2026-04-27

### Added

- **Multi-frame JXL encode/decode**: `JXLEncoder.encode([ImageFrame])` and `JXLDecoder.decodeAll(_:)`. All frames must share dimensions / channels / pixel type; `have_animation` is set on the bitstream and `JxlFrameHeader` is written per frame.
- **16-bit grayscale PNG output**: `jxl-tool decode` preserves 16-bit precision through to the output PNG (CGImage `bitsPerComponent: 16`).
- **JSON manifest output**: `jxl-tool batch --manifest path.json` writes a structured per-file report (input, output, bytesIn/Out, ratio, w/h/channels, frames, bitDepth, encodeTimeS, status).
- **Instrumented benchmark**: per-child `/usr/bin/time -l` rusage capture for cjxl shell loop and `jxl-tool batch`.

### Performance numbers

20 DICOM files (260 MB, lossless effort=7):

| | cjxl shell loop | **jxl-tool batch** |
|---|---|---|
| Wall time | 34.30 s | **17.03 s** (2.01× faster) |
| CPU % (cores) | 230 % | 370 % |
| Peak RSS | 453 MB | 1 048 MB |
| Bit depth in output | 8-bit (lossy via magick) | **16-bit (preserved)** |

---

## [0.2.0] — 2026-04-27

### Added — DICOM specialization

- **Native Swift DICOM reader** ([DICOMReader.swift](Sources/JXLSwift/DICOMReader.swift)) handling Implicit/Explicit VR LE and Explicit VR BE transfer syntaxes — the uncompressed monochrome formats that dominate radiology archives. Output: `ImageFrame` at the original bit depth (uint8 for ≤ 8-bit, uint16 for 9-16-bit).
- **DICOM auto-detect in CLI**: `jxl-tool encode --input scan.dcm` "just works".
- **`magick` PGM fallback** for compressed DICOM transfer syntaxes (JPEG / JPEG-LS / JPEG 2000 / RLE-encapsulated) the native reader doesn't decode.
- **Parallel batch subcommand** with `Swift Concurrency TaskGroup`: `jxl-tool batch path/ --output out/ --parallel 4`. One long-lived process, no per-file startup, no intermediate PNG.

### Verified

- 9/9 integration tests pass.
- 2× faster than the equivalent `cjxl` shell loop on 20 DICOM files.
- 16-bit output preserved end-to-end.

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
  - libjxl `djxl` decodes JXLSwift output
  - JXLSwift decodes `cjxl` output
  - encoded bitstream carries a JXL signature
- **180/180 cross-codec runs** (30 PNGs × 6 configs) succeed; **byte-identical output** to cjxl on equivalent settings.

### Replaces

This release replaces a pure-Swift implementation that produced bitstreams the libjxl reference decoder could not read (0/178 cross-codec round-trips), shipped a default lossless path with output ~1.86× larger than raw, and had 66 / 1 767 unit-test failures. The pre-rewrite tree is preserved on the `pre-rewrite-snapshot` branch (commit `f0927ef`).
