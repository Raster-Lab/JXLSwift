# Changelog

JXLSwift's release history. Two trajectories are recorded here:

- **Pure-Swift trajectory** (v0.5.0 onward, current `main`) — independent JPEG XL implementation in 100 % Swift 6.2 with strict concurrency.
- **libjxl-backed trajectory** (v0.1.0 – v0.4.0) — Swift wrapper over libjxl, preserved on the `libjxl-backend` branch for historical reference.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and the project follows [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.11.0] — in progress (VarDCT lossy encoder)

With the VarDCT *decoder* byte-exact across every real image (any size, all AC strategies, RGBA), v0.11.0 builds the other half — a lossy VarDCT *encoder*. This is a multi-stage effort; the bitstream-serialisation layer follows the DSP core below.

### v0.11.0a — forward-transform core

New `Sources/JXLSwift/Codec/VarDCTEncoder.swift` — the analysis half of the codec, the exact inverse of each proven `JXLDecoder` step:

- **Pipeline.** `ImageFrame` (8-bit RGB/RGBA) → sRGB⁻¹ to linear → `OpsinXYB.forward` → pad to 8×8 → `AccelerateDCT.dct2D` per block (the exact forward partner of the decoder's `idct2D`) → transpose to bitstream coefficient layout → quantise. Output is `VarDCTEncoder.Quantized` — per-channel quantised DC + per-block quantised AC, ready for the (separate) bitstream layer.
- **Inverse-exact details.** Colour-correlation decorrelation matches the decoder's default-CfL fold (`B −= Y`, base correlation B = 1) on both DC and AC; AC quantisation (`coef · qweight · scale · qf`) is the precise reciprocal of the decoder's `AdjustQuantBias / qweight · invQuantAC`. First cut is deliberately minimal — DCT8×8 only, one global quantiser, `dc_extra_precision = 0`.
- **Verified.** `testVarDCTEncoder_ForwardRoundTrip` reconstructs the encoder's output with the decoder's exact dequant + IDCT + inverse-XYB and checks the lossy round-trip of a smooth image stays within `mean < 6`, `max < 40` — a broken DCT layout / CfL / quant blows this past 100. (Caught a real bug mid-build: the first cut used `DCT2D.forward`, a different DCT normalisation than the decoder's `idct2D`; switching to `AccelerateDCT.dct2D` fixed it.)
- **Survey.** A full audit of existing encoder-side primitives (forward DCT, `OpsinXYB.forward`, `ACQuantize`, `ANSEncoder`, the entropy-section / codebook / TOC / GroupHeader writers) confirmed the orchestration layer can call them directly; the only missing writers are the trivial all-default forms of `DequantMatricesDC/AC`, `BlockCtxMap`, and `ColorCorrelation` — built alongside the bitstream layer.
- **374 tests passing, 3 skipped, 0 failures.**

### v0.11.0b — bitstream serialisation: a `djxl`-decodable frame 🎉

New `Sources/JXLSwift/Codec/VarDCTBitstreamWriter.swift` — the serialisation layer that turns `VarDCTEncoder.Quantized` into a complete JPEG XL codestream, written section-for-section as the inverse of `JXLDecoder.decodeVarDCTPartial`.

- **First cut — DC-only.** Every block's AC coefficients are emitted as `nzeros = 0`, so *any* image encodes to a structurally valid lossy frame (blocky — each 8×8 block decodes to its average colour). Real AC coefficient tokens are the next increment.
- **Full frame.** Signature + SizeHeader + ImageMetadata + VarDCT FrameHeader + single-entry TOC; LfGlobal (default `DequantMatricesDC` / `BlockCtxMap` / `ColorCorrelation`, `QuantizerParams`, the global modular tree); the DC group (modular DC sub-image + ACMetadata sub-image, sharing one pooled Huffman codebook reused from the proven `SpecModularEncoder` pattern); HfGlobal (`used_orders = 0`, the AC histogram); the AC group's `nzeros = 0` token stream.
- **Verified against libjxl.** `testVarDCTBitstreamWriter_RoundTrip` encodes a 24×24 image and decodes it with **both** our own decoder **and `djxl 0.11.2`** — djxl accepts the codestream and reconstructs every 8×8 block's average colour to within ±1 of the source. Our encoder now emits genuinely spec-compliant JPEG XL.
- **Scope.** Single-section frames (≤ ~256 px), DCT8×8, RGB. Multi-section and real AC follow.
- **375 tests passing, 3 skipped, 0 failures.**

### v0.11.0c — real AC coefficient encoding

The DC-only stub is replaced with a genuine AC coefficient encoder — the encoder now compresses real detail, not just per-block averages.

- **`generateACTokens`** is the exact inverse of `ACDecoder.decodeBlock`, driven over the AC-group block grid. Per (block, channel), in libjxl's storage iteration order {Y, X, B}: count the non-zero AC coefficients → emit one `nzeros` token at `nonZeroContext(predictedNnz, blockCtx)`, then walk the natural scan order emitting `ZigZag`-packed coefficient tokens at `zeroDensityContext`-routed contexts until the last non-zero. `predictedNnz` replicates the decoder's neighbour-prediction (`ACDecoder.predictNnz`) via per-channel nnz planes.
- **Two-pass entropy.** Pass 1 generates every AC token and pools their HybridUint symbols into one histogram; the AC Huffman codebook is built from it and written in HfGlobal; pass 2 emits the tokens. (A flat image emitting only token 0 keeps the ≥ 2-symbol phantom guard.)
- **Verified.** `testVarDCTBitstreamWriter_RoundTrip` now checks the **per-pixel** round-trip error of a strong within-block gradient — `mean < 4` via both our decoder and `djxl 0.11.2`. A DC-only encode would mean ~7+ on the same image, so the bound proves the AC stream carries real detail. The JXLSwift VarDCT encoder is now a working lossy compressor.
- **375 tests passing, 3 skipped, 0 failures.**

### v0.11.0d — multi-section encode (frames > 256 px)

The encoder was limited to a single 256-px AC group. Frames up to one DC group (≤ 2048 px) now encode as a multi-section codestream.

- **Section split.** When the frame spans more than one 256-px AC group the codestream is written as `LfGlobal + DC-group + HfGlobal + N × AC-group` TOC sections (mirroring `JXLDecoder`'s section indices), each byte-aligned with its size recorded in a multi-entry TOC. Single-group frames keep the contiguous one-section form. The sub-section writers (`writeLfGlobal` / `writeDCGroup` / `writeHfGlobal` / `writeACGroup`) are shared by both paths.
- **Per-group AC tokens.** `generateACTokens` now returns one token stream per AC group, walking each group's block sub-grid; the nnz-prediction planes reset at every group boundary (matching the decoder's per-group `nzeros` state). HfGlobal writes `num_histograms = 1` as a raw 0 in `CeilLog2(numGroups)` bits.
- **Verified.** `testVarDCTBitstreamWriter_MultiSection` encodes a 384×384 frame (2×2 AC groups) and round-trips it through our decoder **and `djxl 0.11.2`** at per-pixel `mean < 4`.
- **376 tests passing, 3 skipped, 0 failures.**

### v0.11.0e — `distance` quality knob

The encoder gains a quality control. `VarDCTEncoder.forward(frame:distance:)` and `VarDCTBitstreamWriter.encode(frame:distance:)` now take a `distance` parameter (default `1.0`).

- **Mapping.** `VarDCTEncoder.globalScale(forDistance:)` maps `distance` to the frame's `global_scale` via `round(5111 / d)`, clamped to `[1, 65535]`. Smaller `distance` → larger `global_scale` → finer quantisation (bigger file, lower error); `distance = 1` reproduces the previous fixed quantiser exactly. This is a deliberately **crude global monotone** knob in the spirit of cjxl's `-d` — not the perceptual butteraugli-driven adaptive quant libjxl uses.
- **Verified.** `testVarDCTBitstreamWriter_DistanceKnob` encodes a 64×64 image at distances `[0.5, 1.0, 2.0, 6.0]`, confirms each is `djxl 0.11.2`-decodable, and asserts monotonicity: the `d = 0.5` file is larger than the `d = 6` file, and the `d = 6` round-trip error clearly exceeds `d = 0.5`.
- **377 tests passing, 3 skipped, 0 failures.**

### v0.11.0f — RGBA encode (alpha extra channel)

The encoder accepted 4-channel frames but silently dropped the alpha. It now carries alpha through to the codestream as a genuine extra channel.

- **Alpha as a modular extra channel.** A 4-channel `ImageFrame` declares one default 8-bit alpha `ExtraChannelInfo` in `ImageMetadata`, sets `num_extra_channels = 1` in the VarDCT FrameHeader, and emits the alpha plane as the LfGlobal `gi` modular sub-image — a default `GroupHeader` followed by gradient-predicted residual tokens sharing the pooled post-tree codebook. This is the exact inverse of `JXLDecoder`'s `gi` global-pass decode (the alpha channel fits the global pass for single-section frames). Alpha is **lossless** — a modular channel carries no quantisation; only the VarDCT RGB is lossy.
- **Verified.** `testVarDCTBitstreamWriter_RGBA` encodes a 32×32 RGBA frame with a per-pixel alpha ramp and round-trips it through our decoder **and `djxl 0.11.2`**: RGB within `mean < 4`, alpha **byte-exact** at every pixel in both decoders.
- **Scope.** Single-section frames (≤ 256 px); RGBA frames spanning more than one AC group throw a clear `unsupported` error (the deferred per-AC-group alpha decode is a follow-up).
- **378 tests passing, 3 skipped, 0 failures.**

### v0.11.0g — VarDCT wired into the public encoder API + CLI

The VarDCT lossy encoder was reachable only through the internal `VarDCTBitstreamWriter`. It is now the codec `JXLEncoder` and `jxl-tool encode` use for lossy modes — the encoder is end-to-end usable.

- **`JXLEncoder.encode(_:)` picks the codec from `options.mode`.** `.lossless` always uses the Modular path. A lossy mode (`.lossy` / `.distance`) routes to `VarDCTBitstreamWriter` at `options.distance`. Previously every mode silently produced lossless Modular output regardless of `mode` — a long-standing latent bug, since the *default* `EncodingOptions()` is `.lossy(quality: 90)`.
- **Graceful fallback.** When VarDCT can't take a frame (non-8-bit, grayscale, or beyond its size limits) the `unsupported` error is caught and the encode falls back to the lossless Modular path, so `encode` always yields a valid codestream rather than failing. Any *other* encoder error propagates.
- **CLI.** `jxl-tool encode` now honours `--lossless` / `--quality`: the default is lossy VarDCT, `--lossless` forces Modular. The summary line reports the mode used.
- **Verified.** `testJXLEncoder_LossyRoutesToVarDCT` confirms a lossy RGB8 encode is a VarDCT frame that round-trips within `mean < 4` and is markedly smaller than the lossless Modular encode of the same frame (which round-trips bit-exact); `testJXLEncoder_LossyGrayscaleFallsBackToModular` confirms the Modular fallback. `testJXLEncoder_DispatchRGB8` now constructs `.lossless` options explicitly, since it tests the Modular dispatch.
- **380 tests passing, 3 skipped, 0 failures.**

### v0.11.0h — multi-section RGBA encode

RGBA encode (v0.11.0f) was limited to single-section frames (≤ 256 px) — larger RGBA frames threw `unsupported`. They now encode, so RGBA reaches the same size ceiling as RGB (one DC group, ≤ 2048 px).

- **Deferred per-AC-group alpha.** When an RGBA frame spans more than one 256-px group its alpha channel is larger than a modular group, so — exactly as the decoder's `extraGiImage` path expects — the LfGlobal `gi` sub-image writes only a `GroupHeader` (the alpha channel decodes nothing in the global pass), and each AC-group TOC section carries its VarDCT AC tokens followed by a modular `GroupHeader` + that group's gradient-predicted alpha sub-rect. Every sub-rect's residuals pool into the shared post-tree codebook.
- **Verified.** `testVarDCTBitstreamWriter_RGBA_MultiSection` encodes a 384×384 RGBA frame (2×2 groups) and round-trips it through our decoder **and `djxl 0.11.2`**: RGB within `mean < 4`, alpha **byte-exact** at every pixel in both decoders.
- **381 tests passing, 3 skipped, 0 failures.**

### v0.11.0i — multi-DC-group encode (frames > 2048 px)

The encoder was capped at one DC group (2048 px). Frames now encode up to an 8192-px cap, split into one DC group per 2048-px tile.

- **DC-group split.** A DC group covers up to 256×256 blocks. The encoder slices the quantised DC plane and the ACMeta planes into per-DC-group sub-regions, gradient-predicts each region on its own group-local neighbourhood, and writes one `DC-group` TOC section per group — so the multi-section codestream is `LfGlobal + DC×numDcGroups + HfGlobal + AC×numGroups` (libjxl's `NumTocEntries` layout). Each group's ACMeta `count` is sized to that group's block total. Frames ≤ 2048 px keep a single DC group; the per-group code path collapses to the previous behaviour.
- **Verified.** `testVarDCTBitstreamWriter_MultiDcGroup` encodes a 2304×2304 frame — a 2×2 grid of DC groups and a 9×9 grid of AC groups, 87 TOC sections — and round-trips it through our decoder **and `djxl 0.11.2`** at per-pixel `mean < 4`.
- **382 tests passing, 3 skipped, 0 failures.**

### v0.11.0j — multi-cluster codebook fix + adaptive 2-cluster AC

Two changes, the first a genuine bug fix surfaced by the second.

- **Fix — `MultiClusterCodebook.write` cluster layout.** The prefix-code writer interleaved `alphabet_size` / Huffman-table pairs per cluster, but the spec layout (and the reader, and libjxl `DecodeHistograms`) is **all alphabet sizes first, then all Huffman tables**. The two layouts coincide for a single cluster, so the bug stayed latent until the first multi-cluster encoder — any codebook with ≥ 2 prefix clusters was written corrupt. `testMultiClusterCodebook_Write_PrefixCode_MultiCluster` pins the fix with 2- and 3-cluster round-trips.
- **Adaptive 2-cluster AC entropy coding.** `VarDCTBitstreamWriter` can now route the AC `nzeros` tokens and the coefficient tokens to two separate Huffman codebooks via a context map — their value distributions differ (small non-zero counts vs zig-zag-packed coefficients). The split needs an explicit context map costing ~`numACContexts` bits in the simple per-entry form, so the encoder **estimates both layouts and keeps the smaller** — the 2-cluster path is chosen only when its token-bit saving clears the map cost (it does on large high-detail frames; small/smooth frames keep the single cluster unchanged). Clustering is a pure lossless recode, so the decoded pixels are identical either way. The gain is modest (≈ 0.05–0.5 % on frames where it activates) — the larger value is that this exercises the multi-cluster encoder path end-to-end, which is what surfaced the codebook bug above.
- **Verified.** `testVarDCTBitstreamWriter_TwoClusterAC` encodes a 1280×1280 high-detail frame (which selects the 2-cluster layout) and confirms `djxl 0.11.2` and our own decoder both decode it and agree.
- **384 tests passing, 3 skipped, 0 failures.**

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

### v0.9.0q–s: encoder primitives + AFV pin-downs

- **`ACQuantize.quantizeBlock`** in `Sources/JXLSwift/VarDCT/ACQuantize.swift` — direct port of libjxl's `enc_group.cc::QuantizeBlockAC`. Encoder-side per-block AC quantization with per-quadrant chroma thresholding. Two pin-down tests verify round-trip with `Dequantize.dequantize` and chroma threshold gating.
- **AFV corner-flip pin-down** — new test verifies the libjxl `srcY = (afvY == 1) ? 3 - iy : iy` corner-flip mapping in `AFV.transformToPixels` against the libjxl source line-for-line.

### v0.9.0t–z: family-API-parity audit + Phase A/B/C alignment with J2KSwift

- **`Documentation/FAMILY-API-PARITY.md`** — 13-divergence audit of JXLSwift ↔ J2KSwift surfaces, with a 3-phase recommended alignment plan.
- **Phase A — non-breaking additions** (v0.9.0u): `JXLImage` typealias for `ImageFrame`; `EncodingOptions` static presets (`.lossless`, `.highQuality`, `.balanced`, `.fast`); `JXLConfiguration` shim with `quality: Double` + `lossless: Bool` matching `J2KConfiguration`; `jxl` CLI alias as a second executable product (both `jxl` and `jxl-tool` now ship); stub subcommands `version`, `compare`, `completions`, `validate` matching `j2k`'s surface.
- **Phase B — parity migrations** (v0.9.0v–y): `JXLEncoder` and `JXLDecoder` converted from `final class` → `public struct: Sendable`. Async overloads on `encode(_:) async throws` / `decode(_:) async throws` / `decodeAll(_:) async throws`. Progress-callback overloads with `JXLEncoderProgressUpdate` / `JXLDecoderProgressUpdate` types matching J2KSwift's shape. CLI canonical name renamed `jxl-tool` → `jxl` in `--help` / `--version`.
- **Phase C — final convergence** (v0.9.0z): `CompressionImage`, `CompressionOutput`, `CompressionEncoder`, `CompressionDecoder`, `CompressionError` protocols defined in JXLSwift. JXLSwift's own types conform. Generic-over-codec helpers compile + run.

### Tests

- **366 tests passing, 3 skipped, 0 failures.** (+13 from v0.9.0d-z: AdjustQuantBias all-branches, GaborishInverse5x5 step-edge, AFV transformToPixels DC-only / all-kinds / corner-flip, ACQuantize round-trip / chroma thresholding, JXLImage typealias, EncodingOptions presets, JXLConfiguration mapping, async overloads round-trip, progress callbacks, generic-over-encoder, generic-over-decoder, CompressionError catch.)

---

## [0.10.0] — in progress (shared package + family-parity polish)

The headline of v0.10.0 is extracting the family-parity protocol surface to a standalone Swift package both libraries depend on, so callers can write codec-agnostic generic code that works across the family today (not just within one library).

### Added

- **`CompressionFamily` shared Swift package** at `/Users/raster/Documents/raster/CompressionFamily/`. JXLSwift and J2KSwift both depend on it via path. Five protocols (`CompressionImage`, `CompressionOutput`, `CompressionEncoder`, `CompressionDecoder`, `CompressionError`) + default `Data: CompressionOutput` conformance. 2 self-contained smoke tests in the package itself.
- **J2KSwift adoption** (cross-repo, commit `56c61ab` in J2KSwift main, awaiting upstream push) — 2 conformance files (`J2KCore` + `J2KCodec`), 5 pin-down tests in J2KCodecTests.
- **`Sources/JXLSwift/ImageMetrics.swift`** — public library API for image-quality metrics (PSNR, MSE, MAE, max error, bit-exact). `ImageMetrics.compute(reference:test:)` over two shape-matched `ImageFrame`s. Used by `jxl compare` (real metrics now, not stub).

### Changed

- `jxl compare ref.pgm test.pgm` (Phase A.5 stub) is now a real metrics command. Text + JSON output. Mirrors `j2k compare`.
- `jxl completions <bash|zsh|fish>` (Phase A.5 stub) now generates real, syntactically-valid completion scripts via swift-argument-parser's `completionScript(for:)`.

### v0.10.0d–f: docs refresh + real `validate` + AFV decoder dispatch

- **`v0.10.0d`** — manager-facing docs (STATUS / CHANGELOG / ROADMAP) refreshed for the v0.9.0 → v0.10.0 transition.
- **`v0.10.0e`** — `jxl validate` is now a real two-tier validator: structural via `JXLDecoder.inspect` (form, dimensions, box types, metadata presence), functional via full `JXLDecoder.decode`. `--no-decode` flag for headers-only mode; `--json` output for tooling.
- **`v0.10.0f`** — AFV decoder dispatch wired into `JXLDecoder`. `QuantWeights.getAFVQuantWeights(...)` ports libjxl's `kQuantModeAFV` quant-matrix builder; `AFV.transformToPixels` is invoked from the per-cell IDCT loop for strategies `afv0` / `afv1` / `afv2` / `afv3`. Correctness anchored to libjxl source — no real-fixture validation at the time of landing.

### v0.10.0g — real-fixture AFV probe vs `djxl`

- **`testVarDCT_AFV_DjxlByteDiffProbe`** sweeps 6 synthetic content patterns (sharp half-and-half X/Y edges, two diagonal edges, dot grid, single horizontal line) across cjxl distances 0.5 / 1.0 / 2.0 / 5.0. Captures the AC-strategy plane our decoder reads via `setenv(JXL_TRACE)` + a temp-file stderr-redirect helper (`captureStrategyCounts`), and reports per-channel byte-diff vs `djxl 0.11.2` whenever AFV blocks (raw strategies 14..17) appear.
- **Findings:** cjxl emits AFV across `diagEdge` / `antiDiag` / `hLine` fixtures at d=1.0..2.0, hitting all 4 variants (afv0/1/2/3). Our decoder completes without throwing — but produces catastrophic byte-diff vs djxl: `max=(R=156, G=244, B=232)` on `hLine d=0.5`. Confirms the v0.10.0f dispatch is wired correctly (no `notImplemented` on AFV blocks) but the math is wrong somewhere in the AFV path. Anchors AFV correctness investigation against real fixtures instead of just libjxl source.
- The capture helper uses a temp file rather than a `Pipe` so that JXL_TRACE volume can't deadlock the writer mid-decode. Test passes; correctness numbers are informational and tighten in a follow-up bite.

### v0.10.0h — fix AFV quant-matrix pair-swap (latent)

- `QuantWeights.getAFVQuantWeights(...)` stored `afv[0]/afv[1]` and `afv[2]/afv[3]` at swapped (x, y) positions vs libjxl's `set_weight(x, y, val)` convention (which writes to flat index `y * 8 + x`). For LIBRARY defaults this was **invisible** — `DefaultQuantBands.afv` has `afv[0]==afv[1]` and `afv[2]==afv[3]` for all three channels, so the resulting quant matrix was bit-identical regardless of swap. The bug surfaces only when the bitstream emits non-default `afv_weights` via the explicit `kQuantModeAFV` mode (future encoder territory).
- Latent bug, fixed for correctness. **Net byte-diff vs djxl on the v0.10.0g probe is unchanged** — confirms the pair-swap was *not* the source of the catastrophic AFV residual. Investigation continues; next candidates are the `ComputeScaledIDCT<4, 4>` / `<4, 8>` backend convention and the per-cell DC-CFL application path inside the AFV overlay.
- Pin-down test extended with unique marker values 100..500 in `afv[0..4]` so a future pair-swap regression would fail.

### v0.10.0i — 🎉 VarDCT pixel byte-equality achieved

The v0.9.0 headline goal — closing the textured-fixture pixel drift vs `djxl 0.11.2` — is **done**. An instrumented libjxl 0.11.2 (`dec_group.cc::DequantBlock` + `TransformToPixels` printf trace) was built and run side-by-side against our decoder on the gradient + SWEEP fixtures. The side-by-side trace exposed **seven** distinct decoder bugs, all now fixed:

1. **AC channel swap.** libjxl decodes AC channels in stream order `{1, 0, 2}` (Y, X, B); our decoder stored the i-th decoded block at iteration index `i`, mislabelling Y as X and vice-versa. Fixed by storing each block at its XYB slot `storageC`. (`JXLDecoder.decodeVarDCT`.)
2. **Spurious ×64 on LIBRARY quant matrices.** `DefaultQuantBands.scaledForBitstream(_:)` multiplied the seed band by 64 — but libjxl's `*= 64` in `DecodeDctParams` applies *only* to bitstream-decoded custom DCT params, never the LIBRARY defaults. djxl's `dequant_matrix[Y][0]` traced to `1/560`, not `1/35840`. All `scaledForBitstream` call sites removed.
3. **IDCT transpose.** libjxl's `ComputeScaledIDCT<R,C>` emits a transposed layout for ROWS≥COLS strategies; our `AccelerateDCT.idct2D` is the un-transposed `IDCTSlow`. Fixed by transposing the coefficient block before the IDCT for the square strategies (`ComputeScaledIDCT(C) = IDCTSlow(Cᵀ)`).
4. **Wrong LLF resample scales.** `kScales2to16` / `kScales4to32` / `kScales2to32` in `LowestFrequenciesFromDC` held the `<FULL, LF>` *downscale* values (`0.901764…`) instead of the `<LF, FULL>` *upscale* values (`1.108937…`). Corrected against libjxl `dct_scales.h::DCTResampleScales`.
5. **LLF block-ordering transpose.** `LowestFrequenciesFromDC.dct16x16` / `dct32x32` / `dct64x64` produced the LF region from a *vanilla* small DCT; libjxl's `ReinterpretingDCT` uses `ComputeScaledDCT<N,N>` (transposed). Fixed by swapping/transposing the LF block.
6. **`scaledDCT4` scaling.** The 1-D scaled DCT-4 applied a uniform `1/4` to all four coefficients; libjxl's convention scales the odd-index coefficients by `√2/4`. (Affected DCT32x32 and the ord-6 asymmetric LLF.)
7. **`AdjustQuantBias` `|q| == 1` bias.** The decoder used the encoder-side `kZeroBiasDefault = 0.5`; libjxl's decoder dequant uses the per-channel `kDefaultQuantBias` (`X≈0.945`, `Y≈0.930`, `B≈0.950`). The `0.95/0.5 = 1.9×` error on every ±1-quantized coefficient was the dominant textured-fixture residual.

The prior investigation's "**2.286× factor**" was a red herring: with the channels swapped, the standalone diagnostic compared cjxl's actual X-channel quantised value (−7) against its prediction for the Y channel (≈−16); `16/7 ≈ 2.286`. No mysterious scaling factor exists.

- **Results vs `djxl 0.11.2`:** gradient 8×8 (`testVarDCT_GradientBlock`) max byte-diff **58 → 1**. SWEEP 64×64 textured: **d=0.5 and d=1.0 byte-exact** (max 1); d=2.0/5.0/10 max 12–14 on a handful of B-channel pixels (mean < 0.7). DCT8x8 / DCT16x16 / DCT32x32 / DCT64x64 fixtures all byte-exact (`g16`/`g32`/`g64` max ≤ 2).
- **Method note:** the instrumented libjxl lives at `/tmp/libjxl-trace` (not committed); the probe points are documented in [Documentation/NEXT-STEP-libjxl-trace.md](Documentation/NEXT-STEP-libjxl-trace.md).

### Tests

- **368 tests passing, 3 skipped, 0 failures.** (`testVarDCT_AdjustQuantBias_AllBranches` updated for the corrected per-channel `|q|==1` bias.)

### v0.10.0j — AFV byte-equality confirmed + IDENTITY ("hornuss") transform

- **AFV is now near-byte-exact.** The v0.10.0g probe's "catastrophic" `max=(R=156,G=244,B=232)` was entirely the three global bugs fixed in `v0.10.0i` (AC channel swap, spurious ×64, `AdjustQuantBias`) — AFV shares that dequant path. Re-running `testVarDCT_AFV_DjxlByteDiffProbe` after `v0.10.0i` shows AFV-using fixtures at **`max=(R=1..3, G=1..3, B=1..3)`** vs `djxl` (several byte-exact). No AFV-specific code change was needed.
- **IDENTITY transform** (`Sources/JXLSwift/VarDCT/IdentityTransform.swift`) — AC strategy 1 ("hornuss" in our enum) previously threw `notImplemented` on any block with non-zero AC. Ported libjxl's `dec_transforms-inl.h::TransformToPixels` `Type::IDENTITY` case (four 4×4 quadrants, each a 2×2-DCT block-DC + 15 spatial residuals — no frequency transform, hence no transpose). Added `QuantWeights.getIdentityQuantWeights` (the `kQuantModeID` 64-position quant matrix) and `DefaultQuantBands.identity`, and an IDENTITY overlay in `JXLDecoder`. The `antiDiag` AFV-probe fixture (which uses 3 hornuss blocks) now decodes **byte-exact** (`max=(R=1,G=1,B=1)`).
- Still unimplemented (decode throws on non-zero AC): `DCT2X2`, `DCT4X4`, `DCT4X8`, `DCT8X4`, `DCT32X8`, `DCT8X32`. libjxl `TransformToPixels` ports for each are the remaining close-out work.
- **368 tests passing, 3 skipped, 0 failures.**

### v0.10.0k — DCT2X2 + DCT4X4 transforms; `used_orders` gap identified

- **DCT2X2 and DCT4X4 transforms** (`Sources/JXLSwift/VarDCT/SmallACTransforms.swift`) — ports of libjxl `dec_transforms-inl.h` (`Type::DCT2X2` via the `IDCT2TopBlock<2/4/8>` cascade; `Type::DCT4X4` via four 4×4 `ComputeScaledIDCT` quadrants). Quant matrices: `QuantWeights.getDCT2QuantWeights` (the `kQuantModeDCT2` 6-weight fan-out) and `getDCT4QuantWeights` (the `kQuantModeDCT4` 4×4-table upsample). Both wired into the single-cell decoder overlay alongside IDENTITY. **DCT2X2 verified byte-exact vs `djxl`** on the `diagEdge` probe fixture (edge-carrying dct2x2 blocks, `used_orders=0`). DCT4X4 ported faithfully + DC-only pin-down (`testVarDCT_SmallACTransforms_DCOnlyIsFlat`); no cjxl fixture was found that selects pure DCT4X4, so its AC path is verified only by composition of verified parts.
- **`used_orders != 0` (`DecodeCoeffOrders`) gap identified.** A 64×64 all-dct2x2 fixture (`checker4`) decoded to garbage. An instrumented djxl trace pinned the cause: that bitstream sets `used_orders = 2` (a custom Lehmer-coded coefficient order for ord 1), and our `ProcessACGlobal` mis-handles the `used_orders != 0` path — desyncing the AC token stream. This is **not** a DCT2X2 bug (the dct2x2 transform decodes byte-exact whenever `used_orders = 0`); it is the pre-existing ⏳ `DecodeCoeffOrders` item, and it affects **every** AC strategy on bitstreams that emit custom coefficient orders. This is the recommended next work.
- Still unimplemented: `DCT4X8`, `DCT8X4`, `DCT32X8`, `DCT8X32` (transform ports remain).
- **369 tests passing, 3 skipped, 0 failures.**

### v0.10.0l — fix single-symbol prefix code (the real `checker4` bug)

- **One-line entropy-decode bug.** `SimplePrefixCodeFormat.decode`'s `count == 1` case (a simple prefix code with a single symbol) returned an all-zero code-length array, **ignoring `symbols[0]`**. `PrefixCodeTable`'s degenerate-code decoder returns the first non-zero-length symbol — so an all-zero array always decodes to **symbol 0**, regardless of which symbol the code actually carries. Fixed by marking `lengths[symbols[0]]` non-zero.
- **This — not `DecodeCoeffOrders` — was the `checker4` bug.** The `v0.10.0k` "`used_orders` gap" diagnosis was wrong. An instrumented-djxl per-token AC trace showed the AC-global is fully bit-synced (the permutation/`DecodeCoeffOrders` path is correct); the failure was that `checker4`'s AC histogram cluster 1 is a single-symbol prefix code on symbol **1** ("every dct2x2 block has exactly one nonzero AC coefficient"), which our decoder mis-decoded as symbol 0 → `nzeros = 0` everywhere → all-zero AC → grey output.
- **`checker4` (64×64, all-dct2x2, `used_orders = 2`) now decodes byte-exact** vs `djxl` (`max = 0`). This also confirms **DCT2X2 with real AC is correct** (`checker4` is 64 dct2x2 blocks). The fix is global — it corrects any prefix-coded entropy stream (Modular or VarDCT) with a single-symbol cluster selecting a symbol other than 0.
- `testSimplePrefixCode_RoundTrip_AllShapes` updated: the `count == 1` shape now pins `lengths[symbols[0]] != 0`, all others 0.
- **369 tests passing, 3 skipped, 0 failures.**

### v0.10.0m — DCT4X8 + DCT8X4 transforms

- **DCT4X8 and DCT8X4 transforms** (`SmallACTransforms.swift`) — ports of libjxl `dec_transforms-inl.h::TransformToPixels` (`Type::DCT4X8` / `Type::DCT8X4`). Each splits the 8×8 cell into two 4×8 / 8×4 halves; each half carries a 1-D-DCT-2-combined DC plus a strided gather of 31 AC coefficients, reconstructed with a `ComputeScaledIDCT<4,8>` / `<8,4>`. New `ScaledIDCT.transform(_:rows:cols:)` helper handles the asymmetric `ComputeScaledIDCT` layout (transpose for ROWS≥COLS). Quant matrix: `QuantWeights.getDCT4X8QuantWeights` (the `kQuantModeDCT4X8` 4×8-table row-axis upsample, shared by both). Wired into the single-cell decoder overlay.
- **Verified byte-exact vs `djxl`** — a random-noise 64×64 fixture (cjxl picks DCT4X8) and a 4-pixel checkerboard (DCT4X8 + DCT8X4) both decode at `max byte-diff = 1`.
- **369 tests passing, 3 skipped, 0 failures.**

### v0.10.0n — 🎉 EPF fixes — VarDCT byte-equality across the full distance range

Two bugs in the EPF (edge-preserving) restoration filter, surfaced by tracing the SWEEP d≥2 residual (the VarDCT *core* decode was already proven byte-exact — the dequantised coefficient block matched `djxl` to 1e-6, so the residual was localised entirely to EPF):

- **EPF2 `sm` missing the ×1.65.** libjxl `stage_epf.cc::EPF2Stage` computes `sm = epf_pass2_sigma_scale × 1.65`; our `applyEPF2` used `pass2SigmaScale` raw. EPF0 and EPF1 had the factor; EPF2 didn't. The 1.65× sad-multiplier error skewed every EPF2 weight. (EPF2 runs at `epf_iters ≥ 2`, i.e. cjxl distance ≥ 2 — which is why d=0.5/1.0 were already byte-exact.)
- **EPF stage order.** libjxl's render pipeline adds the stages 0, 1, 2 and runs them in that order; our code ran EPF1 → EPF2 → EPF0. For `epf_iters = 3` (cjxl distance ≥ ~5) EPF0 must run **first**. Reordered to EPF0 → EPF1 → EPF2.

- **Result:** the 64×64 textured SWEEP fixture is now **byte-exact vs `djxl` at every distance** — d=0.5 / 1.0 / 2.0 / 5.0 / 10 all `max byte-diff = 1`. The v0.9.0 byte-equality goal is met across the full quality range, not just d=1.
- **369 tests passing, 3 skipped, 0 failures.**

### v0.10.0o — per-colour-tile AC chroma-from-luma (frames > 64 px)

The VarDCT decoder applied a **single** YToX / YToB chroma-from-luma slope — `acMetaValues[c].first`, i.e. colour tile (0,0) — to the *whole* frame. JPEG XL stores the AC CfL map at one entry per **64×64-pixel colour tile** (`kColorTileDim`), so this was only correct for frames ≤ 64 px (one tile). Every frame larger than 64 px got the tile-(0,0) multiplier stamped onto all other tiles.

- **Fix.** New `acCFLMul(bx:by:)` helper looks up the YToX/YToB slope at the block's colour tile — `(bx / kColorTileDimInBlocks, by / kColorTileDimInBlocks)`, indexed row-major into ACMeta channels 0/1 — and converts it via `cmapDC.ytoXRatio` / `ytoBRatio`. Wired into all **nine** dequant + IDCT passes (per-cell DCT8, the small-transform overlay, DCT16x16, DCT16x8/8x16, DCT32x16/16x32, DCT32x32, DCT64x32/32x64, DCT64x64, AFV). Matches libjxl `dec_group.cc:273-301`, where `x_cc_mul` / `b_cc_mul` are recomputed per colour tile. DC-CfL is unchanged — it has its own global `cmap.DecodeDC` scalars.
- **Verified vs `djxl 0.11.2`.** A 192×192 textured fixture (3×3 colour tiles, YToB map `[127,16,12,0,127,0,16,1,127]` confirmed byte-identical to an instrumented djxl trace): mean B-error **17.1 → 0.34**. A smooth 192×192 fixture (9 DCT64x64 tiles, no AFV/small transforms) decodes essentially byte-exact — `max=(3,1,2)` at d=1, uniform across all 9 tiles.
- **Known residual.** On textured > 64 px frames, AFV blocks carrying real high-frequency AC still spike — fixed immediately after in `v0.10.0p`.
- **369 tests passing, 3 skipped, 0 failures.**

### v0.10.0p — AFV `IDCT4×4` transpose (high-frequency AFV blocks)

The AFV transform decomposes its 8×8 cell into three sub-blocks — a 4×4 AFV-basis corner, a **4×4 IDCT** corner, and a 4×8 IDCT half. The 4×4 IDCT sub-block is *square*, so libjxl's `ComputeScaledIDCT<4,4>` emits the transposed layout (the ROWS≥COLS convention, same as DCT8/16/32/64) — `ComputeScaledIDCT(C) = IDCTSlow(Cᵀ)`. The decoder's `idct4x4Backend` closure called the un-transposed `AccelerateDCT.idct2D` directly, so the 4×4 IDCT sub-region of every AFV block was reconstructed transposed.

- **Fix.** `idct4x4Backend` now transposes the coefficient block (`transposeSquareInPlace(_:size: 4)`) before `idct2D`, mirroring the square DCT overlays. The 4×8 sub-block (ROWS<COLS) correctly needs no transpose and is unchanged.
- **Why the v0.10.0g/j AFV probes missed it.** The synthetic edge/dot/line probe fixtures put almost no energy in the AFV block's (odd-col, even-row) coefficient positions — the IDCT4×4 sub-region was near-DC, and a transpose of a near-constant block is a no-op. Textured content (`x ^ y`) is the first fixture to load that sub-region; its transposed reconstruction produced a 0/255 chequer that the EPF restoration filter then smeared into ±100 pixel spikes.
- **Result.** The 192×192 textured multi-tile fixture now decodes **byte-exact vs `djxl 0.11.2`** — `max=(1,1,1)` at d=1, `max=(3,1,3)` at d=2 (the same sub-±3 rounding floor as SWEEP/DCT64x64). New pin-down test `testVarDCT_MultiTileAFV_DjxlByteEquality` asserts `max ≤ 5` and would fail at >100 on either the v0.10.0o CfL or v0.10.0p transpose regression. SWEEP + AFV-probe fixtures stay byte-exact.
- **370 tests passing, 3 skipped, 0 failures.**

### v0.10.0q — multi-DC-group decode (frames > ~2048 px)

The VarDCT decoder handled exactly **one DC group** — `JXLDecoder.decodeVarDCT` threw `notImplemented` on any frame wider or taller than a DC group (`dc_group_dim` ≈ 2048 px). Real-world photographs are almost always larger, so this gated the decoder to small fixtures only. The DC-group decode is now a loop over all DC groups.

- **Per-DC-group loop.** libjxl decodes each DC group as an independent `DecodeVarDCTDC` (3 DC channels) + `DecodeAcMetadata` (4 channels) pair, each at its own TOC section (`1 + dc_group`). The decoder now iterates `num_dc_groups`, seeks each section, and stitches every group's `groupDim`-block sub-region (libjxl `frame_dimensions.h::DCGroupRect`) into full-frame DC / YToX-YToB cmap / EPF-sharpness / AC-strategy planes. New `ACStrategyImage.buildMultiGroup` runs the first-block raster walk per DC-group segment (a multi-block transform never crosses a DC-group boundary).
- **Local modular trees.** Multi-DC-group cjxl output commonly sets `has_tree=false` (no global tree); each DC group's DC and ACMeta sub-images then carry their own local tree. New `resolveModularTree` helper reads a local tree inline (`EntropySectionHeader → MultiClusterCodebook → ModularTree → post-tree header → post-tree codebook`) when a GroupHeader's `use_global_tree` is false — previously a hard `notImplemented`.
- **`num_histograms > 1` AC histogram selector.** Large frames split the AC histograms into sets; each AC group's token stream opens with `CeilLog2Nonzero(num_histograms)` bits selecting its set, shifting every AC context by `cur_histogram × NumACContexts` (libjxl `dec_group.cc:656`). The decoder read neither — it assumed `num_histograms == 1` and a zero context offset. Both are now handled.
- **`VarDCTDC` modular stream id** corrected to `1 + dc_group` (was the `ModularDC` formula `1 + num_dc_groups + group`); harmless for single-DC-group fixtures whose tree ignores the group-id property, but wrong in general.
- **Result.** A 2080×2080 textured fixture (4 DC groups, local trees, `num_histograms=4`, 81 AC groups) decodes vs `djxl 0.11.2` at mean `(0.24, 0.24, 0.26)` — uniform across all four DC-group quadrants. New pin-down test `testVarDCT_MultiDCGroup_DjxlByteEquality` (2056×2056, 2×2 DC groups). A residual handful of B-channel pixels drift up to ~20 on large textured frames — fixed next in `v0.10.0r`.
- **371 tests passing, 3 skipped, 0 failures.**

### v0.10.0r — adaptive DC smoothing (large textured frames)

The decoder never applied **adaptive DC smoothing**. libjxl runs `AdaptiveDCSmoothing` (`compressed_dc.cc`) on the dequantised DC plane between DC-group and AC-group decode (`FinalizeDC`), unless the frame sets `kSkipAdaptiveDCSmoothing` (flag bit 7) or `kUseDcFrame` (bit 5). cjxl enables it by default. The DC plane feeds `LowestFrequenciesFromDC`, so an unsmoothed DC shifts the LLF of every multi-block transform — a low-frequency drift that left ~0.04 % of B-channel pixels off by up to ~20 on large textured frames (`big1dc` 2040×512, `dcg2080` 2080×2080). Small fixtures (≤ 192 px) were unaffected: the smoothing kernel's effect there stayed inside the ±1 sRGB rounding floor.

- **Port.** New `AdaptiveDCSmoothing` (`Sources/JXLSwift/VarDCT/AdaptiveDCSmoothing.swift`) — the 3×3 edge-preserving low-pass from libjxl `ComputePixel`: `out = mc + (sm − mc)·factor`, `sm` the weighted 3×3 average (`w0/w1/w2`), `factor = max(0, 3 − 4·gap)`, `gap` the largest normalised centre-vs-smoothed deviation across the 3 channels (seeded 0.5 → `factor ∈ [0,1]`). Borders pass through; a no-op for planes ≤ 2.
- **Wiring.** The decoder now builds the full-frame dequantised + DC-CfL `dcFloat` plane once (libjxl `DequantDC`), smooths it in place (gated on flag bits 7 / 5), and all nine dequant + IDCT sites read the prepared `dcFloat` directly instead of re-dequantising `dcValues` per cell. This also de-duplicates the DC-CfL arithmetic that was inlined nine times.
- **Result.** `big1dc` (2040×512) and `dcg2080` (2080×2080) now decode **byte-exact vs `djxl 0.11.2`** — `max=(1,1,1)`. The multi-DC-group pin-down test's assertion is tightened to `max ≤ 5`. SWEEP / cfl192 / AFV fixtures stay byte-exact.
- **371 tests passing, 3 skipped, 0 failures.**

### v0.10.0s — extra-channel (alpha) decode for VarDCT

The VarDCT decoder threw `notImplemented` on any frame with extra channels — so every RGBA image failed. The colour part of a VarDCT frame is XYB-coded; the extra channels (alpha, depth, …) are **Modular**-coded in the global `gi` sub-image (libjxl `dec_modular.cc::DecodeGlobalInfo`). That sub-image is now decoded.

- **Meta-channels modular decode.** After the global tree, when the frame has extra channels the decoder reads the `gi` GroupHeader, builds the extra-channel modular image (sized per `extra_channel_upsampling`), applies meta-transforms, decodes the channels with the existing `decodeAllChannels`, and undoes the transforms — reusing the Modular machinery (`metaApplyTransforms` / `applyInverseTransforms`) already proven on the lossless path. A single alpha extra channel is interleaved behind the VarDCT-decoded RGB into a 4-channel RGBA `ImageFrame`.
- **Palette `numC == 1` trap fixed.** cjxl routinely applies a 1-channel **Palette** transform to the alpha channel. `metaApplyPalette` walked the palette range with the closed range `(beginC + 1)...endC`, which for `numC == 1` is `1...0` — an invalid range that **traps** at runtime. Changed to the half-open `(beginC + 1)..<(endC + 1)` (empty for `numC == 1`). This also hardens the lossless Modular path against single-channel palettes.
- **Scope.** Extra channels that fit in one modular group (frames ≤ `group_dim`, ~256 px) are decoded in this global pass; larger frames are handled in `v0.10.0t`. A single alpha channel is wired to RGBA output; other extra-channel types still throw.
- **Result.** 64×64 RGBA fixtures decode **byte-exact vs `djxl 0.11.2`** at d=0.5/1.0/3.0 — colour `max=(1,1,1)` (±1 sRGB floor), modular **alpha exact** (`max=0`). New pin-down test `testVarDCT_RGBA_DjxlByteEquality`.
- **372 tests passing, 3 skipped, 0 failures.**

### v0.10.0t — per-AC-group modular extra channels (RGBA > 256 px)

`v0.10.0s` decoded extra channels only when they fit one modular group. Larger frames defer the extra channels to **per-AC-group** modular sections: libjxl `ProcessACGroup` runs the VarDCT AC decode and then `ModularFrameDecoder::DecodeGroup` from the *same* section cursor — the modular extra-channel data follows the VarDCT AC tokens within each AC group's TOC section. That tail is now decoded.

- **Global / per-group split.** The global `gi` pass decodes channels up to the first non-meta channel exceeding `group_dim` (libjxl `ModularDecode`'s `num_chans` loop); the rest are deferred. The deferred channels' full-frame planes are filled in the AC-group loop — each AC group, after its VarDCT AC blocks, reads a local modular GroupHeader and decodes that group's `group_dim`-pixel sub-rect of every deferred channel. The meta-transform inverse runs once, after the loop, on the assembled full image.
- **Palette straddle.** When cjxl palettises a large alpha channel, the palette *table* is a small meta-channel decoded in the global pass while the *index* channel is large and per-group. The decoder decodes both halves into one `ModularImage` and applies the inverse Palette on the assembled whole — reusing `applyInversePalette`.
- **Result.** 300×300 / 320×320 / 600×600 RGBA fixtures — palettised and non-palettised alpha, 2×2 and 3×3 AC-group grids — decode **byte-exact vs `djxl 0.11.2`**: colour `max ≤ 2` (±2 sRGB floor), modular **alpha exact** (`max=0`). New pin-down test `testVarDCT_RGBALarge_DjxlByteEquality` (320×320, palettised, per-group). The earlier rANS-end-position concern was unfounded — the VarDCT AC decode leaves the cursor exactly at the modular tail.
- **373 tests passing, 3 skipped, 0 failures.**

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
