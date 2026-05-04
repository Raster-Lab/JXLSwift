# Changelog

JXLSwift's release history. Two trajectories are recorded here:

- **Pure-Swift trajectory** (v0.5.0 onward, current `main`) — independent JPEG XL implementation in 100 % Swift 6.2 with strict concurrency.
- **libjxl-backed trajectory** (v0.1.0 – v0.4.0) — Swift wrapper over libjxl, preserved on the `libjxl-backend` branch for historical reference.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and the project follows [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.9.0] — in progress (pixel byte-equality push)

The headline goal of v0.9.0 is closing the residual textured-fixture pixel drift between our pure-Swift VarDCT decoder and `djxl 0.11.2` reference output. All v0.9.0 sub-bites are tracked in [Documentation/v0.9.0-pixel-accuracy-investigation.md](Documentation/v0.9.0-pixel-accuracy-investigation.md).

### Added

- **AFV foundation** (`Sources/JXLSwift/VarDCT/AFV.swift`) — 16×16 frozen basis matrix `k4x4AFVBasis` (libjxl `dec_transforms-inl.h::AFVIDCT4x4`) + `AFV.idct4x4` primitive. Two pin-down tests cover DC mode (constant 0.25) and orthonormality (`<basis_i, basis_j> = δ_ij`). Per-AFV-kind overlay (DC decomposition + corner placement + IDCT4x4/4x8 dispatch) is foundation-ready, deferred to a follow-up bite.
- **`AdjustQuantBias`** (`Sources/JXLSwift/VarDCT/AdjustQuantBias.swift`) — per-coefficient AC dequant bias from libjxl `quantizer-inl.h::AdjustQuantBias`. Pin-down test covers every branch (`q == 0 → 0`, `|q| == 1 → ±0.5`, `|q| ≥ 2 → q − 0.145/q`) and custom bias parameters. Wired into all 7 AC dequant call sites (DCT8/16/32/64 + DCT8x16/16x32/32x64).
- **`testVarDCT_UniformBlock_DjxlByteDiff`** — three uniform-colour 8×8 blocks (red, grey, blue-tinted) cjxl-d=1 encoded, decoded, compared per-pixel against djxl. **Result: ±1 byte per channel on every sample** → DC dequant + DC-CFL + OpsinXYB inverse + sRGB OETF pipeline confirmed correct in isolation.
- **`testVarDCT_GradientBlock_DjxlByteDiff`** — three single-axis gradient 8×8 blocks (horizontal-R, vertical-R, diagonal-R). Diagnostic localises the residual drift to the dequant→IDCT bridge (or channel mapping in the AC path).
- **`Documentation/v0.9.0-pixel-accuracy-investigation.md`** — comprehensive investigation log with confirmed-correct components (IDCT, OpsinXYB matrix, kInvDCQuant indexing, CFL pipeline / formula / constants, per-cell QF stamping, AC `prev` flag, channel iteration order), open suspects, and a ranked next-bite list.

### Investigated and ruled out

- **CFL slopes** — `cmapDC.ytoXRatio(slope:)` formula matches libjxl byte-exact.
- **`AdjustQuantBias` magnitude** — neutral on byte-diffs (±0.03 mean per channel).
- **`kInvDCQuant` indexing** — XYB-c indexing (X=0, Y=1, B=2 → 4096, 512, 256) is correct.
- **`Interpolate` / `GetQuantWeights` arithmetic** — byte-identical to libjxl source.
- **Inverse-Gaborish 5×5** — encoder applies a sharpening kernel before DCT; tiny effect (~5 %), wrong direction. Not the residual source.
- **Encoder OpsinXYB scaling** — `intensity_target / 255 = 1.0` for default fixtures.
- **`FindBestDequantMatrices`** — LIBRARY-default matrices for default cparams.
- **Phase R filters** (Gaborish + EPF) — `JXL_SKIP_PHASE_R=1` accounts for only ~4 of the 16-byte gap.

### v0.9.0l mathematical insight (root cause partially confirmed)

libjxl's `ComputeScaledDCT(P) = M·P^T·M^T = vanilla(P^T)` for ROWS≥COLS strategies — bitstream stores TRANSPOSED layout. Verified via runtime `JXL_TRACE_AC=1 col0` dump matching first-principles prediction. Drop-`×64` + transpose for DCT8x8 alone reduces gradient max R: 58 → 17 (3.4× improvement). But interacts with a SECOND missing factor; full fix regresses SWEEP. Reverted; preserved in `transposeSquareInPlace` helper for follow-on bite.

### v0.9.0m–p: standalone numerical reference + foundation primitives

- **`scripts/diagnostics/libjxl_reference_idct.cc`** — self-contained C++ test ports libjxl's reference IDCT/DCT, exact OpsinXYB, exact encoder quantization. **Quantifies residual: 2.286× discrepancy** between libjxl's documented arithmetic and what cjxl actually emits.
- **`Gaborish.applyInverse5x5`** in `Sources/JXLSwift/VarDCT/Gaborish.swift` — full Swift port of libjxl `enc_gaborish.cc::GaborishInverse` (butteraugli-calibrated 5×5 sharpening kernel).
- **`AFV.transformToPixels`** — full overlay port of libjxl `AFVTransformToPixels`. Decomposes 8×8 cell into 4×4 AFV corner + 4×4 IDCT corner + 4×8 IDCT half. Two pin-down tests cover all 4 AFV-kind variants.
- **4 build warnings cleanup** — removed dead `bridge8x16` / `bridge16x32` constants, tightened `var temp` → `let temp`. Build is now warning-free.

### Tests

- **353 tests passing, 3 skipped, 0 failures.** (+3 from v0.9.0d-p: AdjustQuantBias all-branches, GaborishInverse5x5 step-edge, AFV transformToPixels.)

---

## [0.8.0] — 2026 — Multi-AC-strategy + UMA backend

### Added

- **Per-strategy IDCT** for DCT8x8, DCT16x16, DCT8x16/16x8, DCT32x16/16x32, DCT32x32, DCT64x64, DCT64x32/32x64. Every AC strategy used by the SWEEP test fixtures (cjxl distance 0.5 / 1.0 / 2.0 / 5.0 / 10) decodes end-to-end.
- **`AccelerateDCT`** — Apple Silicon UMA-friendly DCT/IDCT backend via `vDSP_mmul`. Per-N matrix cache, square + asymmetric overloads, falls through to the scalar `LibjxlIDCT` reference on non-Apple platforms. **~4.5× IDCT speedup measured on 8×8 DCT** (5000 iters: scalar 14.6 ms, UMA 3.2 ms). Wired into all 15 IDCT call sites in the decoder.
- **`LibjxlIDCT`** / **`LibjxlDCT`** — matrix-vector port of libjxl `dct_for_test.h::IDCTSlow` / `DCTSlow`, replacing the orthonormal `DCT2D` plus per-coefficient bridge factor across every IDCT overlay.
- **`ACStrategyImage`** — per-cell strategy plane decoded from ACMeta channel 2.
- **`CoeffOrders.naturalCoeffOrder`** — port of libjxl `CoeffOrderAndLut` for all 13 ords.
- **`CoeffOrders.decodeLehmerCode`** — Fenwick OST tree decoder for per-channel coefficient-order permutations.
- **`LowestFrequenciesFromDC`** extensions — `dct16x16`, `ord4Pair`, `ord6Block`, `ord8Block`, `dct32x32`, `dct64x64`.
- **`DefaultQuantBands`** — DCT16x16, DCT32x32, DCT8x16, DCT16x32, DCT32x64, DCT64x64 quant matrix bands.
- **EPF0** — 12-neighbour 5×5-plus bilateral filter (the third EPF stage).

### Fixed

- **Inverted `prev` flag** in AC decode/encode — was `(u == 0)` should be `(u != 0)`. Masked for single-cluster fixtures but broke d=0.5 SWEEP.
- **Per-cell QF stamping** — multi-block first-block QFs are now stamped onto all covered cells.
- **Per-channel `x_dm_multiplier` / `b_dm_multiplier`** in AC dequant.
- **Channel iteration order** in AC decode — corrected to libjxl storage `{1, 0, 2}`. Was a latent Y/X swap masked by single-cluster fixtures.

### Tests

- 345 tests passing.

### Known residual

- Textured-fixture pixel drift: max byte-diff per channel **25–115** vs djxl on cjxl-d=0.5..10 SWEEP. Localised to DC handling / CFL slopes / LIBRARY-mode quant matrix scaling / inverse OpsinXYB chain — deferred to v0.9.0.

---

## [0.7.x] — 2026 — Multi-block, multi-AC-group, EPF kernels

### Added (v0.7.0)

- 8×8 / 16×16 / 32×32 fixtures + 300×300 multi-AC-group solid-grey fixture round-trip.
- Per-block QF, coefficient-level CFL, per-block predicted_nzeros.
- EPF1 (5×5 plus-bilateral), EPF2 (3×3 plus).
- Multi-AC-group decode: TOC-driven section seeking between DC global / DC group / AC global / per-AC-group sections, with fresh rANS state per AC group.

### Added (v0.7.1)

- **`CoeffOrders.skipUnusedPermutations`** — advances the bitstream past the per-pass Lehmer-coded coefficient-order block when `used_orders != 0`.
- **Multi-cluster `blockCtx` routing** — AC decode computes proper `block_ctx = bctx.context(dcIdx, qf, ord, c)` so multi-cluster AC histograms (e.g., numClusters=9 for 384×384 cjxl-d=1) route to the correct ANS distribution.

---

## [0.5.0 / 0.6.0] — 2026 — VarDCT decode + restoration filters

### Added (v0.5.0)

- **VarDCT decode for the cjxl-d=1 8×8 fixture** — full pipeline: AC token stream → dequant DC + AC → 8×8 IDCT → CFL → inverse OpsinXYB → sRGB OETF → 8-bit RGB output. Per-channel RGB means **(133, 120, 124)** vs djxl reference **(114, 113, 114)** (within ±20 — Phase R restoration filters close the residual).
- **`testVarDCT_8x8Fixture_PixelsMatchDjxlMean`** — cross-validation against `djxl`.
- **First "JPEG XL VarDCT decoded in 100 % Swift" milestone.**

### Added (v0.6.0)

- **Gaborish 3×3 separable smoothing** wired into `decodeVarDCTPartial` after color correlation, before `OpsinXYB.inverse`. Default weights match libjxl: `1.1 × 0.104699568` / `1.1 × 0.055680538`.
- **EPF framework** — `EPF.computeInvSigma` mirrors libjxl's `epf.cc::ComputeSigma`. EPF1 + EPF2 kernels land. EPF0 deferred until a real fixture forces it (uncommon).

---

## [Pre-0.5] — Pure-Swift foundation (Phases F, H, E, M)

The pre-VarDCT pure-Swift work — Phases F (Foundation: bitstream + container + signature + SizeHeader), H (Image headers: BitDepth, ColorEncoding, ExtraChannelInfo, ImageMetadata), E (Entropy: HybridUint, prefix codes, rANS, ANS distributions, context maps, LZ77 header), M0 (project-internal lossless vertical slice with gradient prediction), and Modular subcodec (RCT inverse, Squeeze inverse, weighted predictor, MA-tree decoder) landed in this period. **Byte-equality with cjxl/djxl achieved** for single-group, single-pass Modular lossless inputs (3072 individual pixel assertions all pass on a 32×32 RGB cjxl-emitted file). Detail: see [ROADMAP.md § Phase F / H / E / M](ROADMAP.md).

---

## libjxl-backed trajectory (v0.1.0 – v0.4.0) — historical

**Branch:** `libjxl-backend`. The Swift-wrapper-over-libjxl trajectory that preceded the pure-Swift restart. Preserved for reference; not a supported runtime path on `main`.

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
