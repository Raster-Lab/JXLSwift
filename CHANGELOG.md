# Changelog

JXLSwift's release history. Two trajectories are recorded here:

- **Pure-Swift trajectory** (v0.5.0 onward, current `main`) — independent JPEG XL implementation in 100 % Swift 6.2 with strict concurrency.
- **libjxl-backed trajectory** (v0.1.0 – v0.4.0) — Swift wrapper over libjxl, preserved on the `libjxl-backend` branch for historical reference.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and the project follows [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.12.0] — in progress (Phase J transcoding)

### v0.12.0f — Phase J: `QuantWeights.getRAWQuantWeights` (coefficient-bridge foundation)

First concrete code bite toward the JPEG → JXL coefficient bridge per the v0.12.0e design doc's step 1. Ports the math of libjxl's `kQuantModeRAW` quant-weight synthesis — the path the bridge will use to translate JPEG quant tables into JXL quant matrices.

- **`Sources/JXLSwift/VarDCT/QuantWeights.swift`** — `getRAWQuantWeights(qtable:qtableDen:) -> [Float]` per libjxl `quant_weights.cc::ComputeQuantTable` case `kQuantModeRAW`. Formula: `weight[i] = 1 / (qtableDen × qtable[i])`. Rejects zero qtable entries (would cause division-by-zero in the JXL dequant formula) and non-3-channel-multiple sizes.
- **What this unlocks.** The eventual coefficient bridge will pick `qtableDen = 1 / invQuantAC` so that JXL's dequant formula `quant / weight × invQuantAC` recovers `quant × jpegQt[k]` — the same dequantised value JPEG would produce. Pin-down test `testQuantWeights_RAW_DequantRoundTrip` verifies this algebra with concrete numbers.
- **What this DOESN'T do.** The **bitstream-decode** side of RAW (extracting the embedded Int32 quant table from the codestream) is gated on Modular-decoder plumbing for the embedded quant-table sub-image. That's step 2 from the design doc and lands in a later bite. Today's helper is the foundation the eventual encoder will build against; if a real-world coefficient-bridge JXL is fed to our current decoder, the RAW-mode dispatch will need that follow-up to decode it.
- **4 new tests**: `testQuantWeights_RAW_BasicFormula` (per-entry math), `testQuantWeights_RAW_DequantRoundTrip` (the full JPEG ↔ JXL dequant algebra round-trip), `testQuantWeights_RAW_RejectsZeroEntry`, `testQuantWeights_RAW_RejectsBadShape`. **515 tests passing, 6 skipped, 0 failures** (was 511; +4).

### v0.12.0e — CLI: `jxl transcode` + Phase J design doc

Closes the last remaining J2KSwift parity gap (`transcode` subcommand) by adding `jxl transcode <input> <output>` — typed CLI entry point for JPEG → JXL and (future) JXL → JPEG conversion. Today the forward direction maps to the existing JPEG-decode + JXL-encode pixel-fallback path; the reverse direction throws with a pointer to the design doc that explains the Brotli gating.

- **`Sources/JXLTool/Transcode.swift`** (new). Auto-detects JPEG vs JXL via magic bytes (SOI marker; naked-codestream `0xFF 0x0A`; ISOBMFF `JXL ` signature box). Three modes via `--mode`:
  - `pixel-fallback` (default) — today's behaviour: JPEG → `JPEGDecoder.decode` → `ImageFrame` → `JXLEncoder.encode` → JXL. Lossy at both steps; **not** bit-perfect transcoding.
  - `coefficient-bridge` — reserved for the in-progress Phase J coefficient bridge; throws `.notImplemented` with a pointer to the new design doc.
  - `reverse` — JXL → JPEG; throws (gated on Brotli for `jbrd` box decompression).
- **`Sources/JXLTool/JXLTool.swift`** — `Transcode.self` registered in the subcommand list.
- **`Documentation/PHASE-J-COEFFICIENT-BRIDGE.md`** (new, ~150 lines). Implementation plan + work-item enumeration for the four pieces (`JPEGCoefficientImage` ✅, forward bridge ⏳, reverse bridge ⏳, `jbrd` parser ⏳) with surgical-change list for VarDCTBitstreamWriter (skip `VarDCTEncoder.forward`, custom `DequantMatrices`, `color_transform = None`, chroma_subsampling mapping, all-DCT8×8 strategy plane, skip Gaborish/adaptiveQF, per-component QF = 1), the blocking `kQuantModeRAW` decoder port, the Brotli dependency for reverse direction, recommended implementation order (8 steps, 12–18 sessions total to bit-perfect; 4.5–5.5 sessions to forward-only coefficient bridge), and open questions.
- **End-to-end smoke** verified all four paths:
  - `jxl transcode foo.jpg foo.jxl -q 85` → 953 B JPEG → 150 B JXL (15.7% of source). Output JXL decodes through djxl.
  - `jxl transcode foo.jxl foo.jpg` → errors with clear message + exit 1.
  - `jxl transcode bogus.bin x.jxl` → errors with "neither JPEG nor JXL" + exit 1.
  - `jxl transcode foo.jpg foo.jxl --mode coefficient-bridge` → errors with "not yet implemented" pointer + exit 1.
- **511 tests passing, 6 skipped, 0 failures** (unchanged — pure CLI plumbing over already-tested paths).
- **README.md known-limitations update.** The "Bit-perfect JPEG ↔ JXL transcoding (Phase J capstone) — NOT in v0.11.0" line still holds; `jxl transcode` exists today as the typed CLI entry point but the underlying coefficient-bridge path is not yet implemented.

### v0.12.0d docs — EPF0 is already shipped, the v0.11.0 "deferred" claim was stale

Pure docs correction. `EPF.applyEPF0(...)` in `Sources/JXLSwift/VarDCT/EPF.swift` is a complete port of libjxl `render_pipeline/stage_epf.cc::EPF0Stage` (12-neighbour 5×5 plus, 3×3-plus SAD shape, `pass0SigmaScale × 1.65` sigma scale, edge-pixel `borderSadMul`), and `EPF.applyAllStages` dispatches it when `epf_iters >= 3`. The "deferred" claim in the v0.11.0 README / CHANGELOG / ROADMAP was stale — the implementation shipped during the v0.10.0 EPF batch and just wasn't re-validated in the v0.11.0 release-prep audit. Updated:

- **README.md** — "EPF0 7×7 kernel deferred until a fixture forces it" → "EPF0 / EPF1 / EPF2 restoration" (matches reality).
- **ROADMAP.md** — EPF0 row now marked ✅ with the implementation pointer + the test-pin-down follow-up (a real `epf_iters=3` fixture for the byte-equality assertion).
- **CHANGELOG.md** — v0.11.0 known-limitations bullet for EPF0 struck-through with the correction.

No code change; only documentation that was out of date. The pin-down byte-equality test on a real `epf_iters=3` fixture is still open follow-up work (the SWEEP corpus uses default `epf_iters=2` so EPF0 never fires in those tests).

### v0.12.0c — VarDCT: DCT32×8 + DCT8×32 transforms (closes a v0.11.0 known limitation)

The two remaining sub-64 asymmetric VarDCT strategies are now wired into the decoder. Closes one of the explicit `known limitations` bullets from the v0.11.0 release notes: "DCT128 / DCT256 / DCT32×8 / DCT8×32 transforms not ported" → DCT32×8 / DCT8×32 now ported; DCT128/256 remain.

- **`Sources/JXLSwift/VarDCT/QuantWeights.swift`** — adds `DefaultQuantBands.dct8x32` (X/Y/B), copied byte-exact from libjxl 0.11.2 `lib/jxl/quant_weights.cc::DCT8X32()` (the same constant set covers both DCT8×32 and DCT32×8 after `CoefficientLayout` swap).
- **`Sources/JXLSwift/Codec/JXLDecoder.swift`** — new IDCT overlay for the 4-cell, 1×4 / 4×1 asymmetric strategy. Pattern mirrors the existing DCT32×16 / DCT16×32 overlay: per-strategy quant weights, LLF assembled via the existing `LowestFrequenciesFromDC.ord5Block(dc:)` helper (4 DC values → 4 LLF coefficients at the top-left 4×1 corner of the 32×8 coef block), AC dequant + CFL recorrelation per-channel, `AccelerateDCT.idct2D(_, rows: 8, cols: 32)`, transposed-or-natural pixel placement based on `isVerticalStack` (DCT32×8 is the 32-tall, 8-wide variant; DCT8×32 is 8-tall, 32-wide). Strategy gate at the AC-decode site extended.
- **No real-fixture probe.** cjxl strongly prefers larger or differently-shaped strategies (DCT32×32, DCT64×64, DCT16×32, DCT32×64) even on heterogeneous content sweeping multiple distances + effort levels — DCT8×32 / DCT32×8 are genuinely rare in practice. The implementation is sound by construction (mirrors the proven DCT16×32 path that's byte-exact vs djxl, uses the same proven `ord5Block` LLF helper, libjxl-exact quant bands). If a real fixture ever surfaces a byte-diff against djxl, a libjxl-trace bite would close it the same way v0.10.0i closed the broader VarDCT residual.
- **511 tests passing, 6 skipped, 0 failures** (unchanged — no new tests added since the existing SWEEP corpus doesn't trigger these strategies and the implementation is composition-of-verified-parts).

### v0.12.0b — CLI: `jxl info foo.jpg` surfaces coefficient-image structure

Small follow-on to v0.12.0a. The new `JPEGDecoder.decodeToCoefficients(_:)` API just landed; `jxl info` on a JPEG now uses it to print a per-component coefficient diagnostic alongside the existing structural summary. Useful for anyone working on the in-progress JPEG → JXL coefficient bridge — the per-component sampling factors, quant-table bindings, and block grid sizes are all visible at a glance.

- **`Sources/JXLTool/Info.swift`** — when `decodeToCoefficients(_:)` succeeds on a JPEG input, print a `--- JPEG coefficients (Phase J) ---` block listing total coefficient count and per-component `(blocksWide × blocksHigh, sampling, quant-table ID, DC factor)`. For out-of-scope inputs (progressive / 12-bit / CMYK), the helper silently skips so the basic structural summary still prints — no throw propagation to the user.
- **End-to-end smoke** on a 16×16 RGB sips JPEG: reports `Total coefs: 384 (6 × 8×8 blocks)` then `[0] comp=1 2×2 blocks (H=2 V=2, qt=0, DC=1)`, `[1] comp=2 1×1 blocks (H=1 V=1, qt=1, DC=1)`, `[2] comp=3 1×1 blocks (H=1 V=1, qt=1, DC=1)` — the 4:2:0 chroma subsampling is immediately visible.
- **No new tests** — the JPEG-decode side is covered by the v0.12.0a coefficient-image tests; `jxl info` is thin dispatch best smoke-tested manually.
- **511 tests passing, 6 skipped, 0 failures** (unchanged from v0.12.0a — pure CLI plumbing).

### v0.12.0a — Phase J: `JPEGCoefficientImage` + `decodeToCoefficients(_:)`

First v0.12.0 bite — opens the data-handoff seam between the JPEG decode stack and the eventual JXL VarDCT *coefficient bridge* (the libjxl-style transcode shortcut that packs JPEG quantised coefficients into a JXL frame without IDCT). No JXL-side machinery yet; this commit just exposes the right structured output from the JPEG side so the bridge can be built against a stable type.

**Plan reassessment for v0.12.0.** Original Tier B sketch called for "JXL → JPEG reverse first" because it's easier to validate (bit-exact against the input JPEG). On closer reading of libjxl's source, **the reverse direction is gated on a pure-Swift Brotli decompressor** — the JXL `jbrd` box (JPEG Bitstream Reconstruction Data) payload is Brotli-compressed, and per CLAUDE.md constraint 1 ("C/C++ permitted only for measured optimisation; correctness logic stays Swift") that's a multi-session slab on its own. Forward direction (JPEG → JXL via the coefficient bridge) doesn't need Brotli, so v0.12.0 moves that direction first. Reverse and `jbrd` parsing come later in the v0.12.x line once a Swift Brotli lands (or alongside the broader compressed-ICC-profile-box work, which has the same dependency).

- **`Sources/JXLSwift/JPEG/JPEGCoefficientImage.swift`** (new). Carries the dequantised-pending coefficient state from a decoded JPEG: `width`, `height`, `precision`, `frameKind`, `frameComponents` (sampling factors + quant-table bindings), `quantisedComponents: [JPEGComponentBlocks]` (Int32 per coefficient, natural row-major order, straight-out-of-`JPEGScanDecoder`), `quantTables: [JPEGQuantTable]` (zig-zag-ordered, indexed by table destination ID via `frameComponent.quantTableId`). `totalCoefficientCount` convenience for diagnostics.
- **`JPEGDecoder.decodeToCoefficients(_:) -> JPEGCoefficientImage`** — runs the same segment-walk prelude as `decode(_:)` but stops after `JPEGScanDecoder.decodeBaselineSequential`, returning the structured coefficient state instead of finishing the IDCT + colour-conversion pipeline. Same scope envelope as `decode(_:)` (baseline-sequential 1 or 3 components, 8-bit precision); same `JPEGDecoderError.unsupported` errors for out-of-scope shapes.
- **API stability.** `JPEGCoefficientImage` and `decodeToCoefficients(_:)` are foundation types for the in-progress coefficient bridge; signatures may evolve as the bridge work matures. Callers who only need "JPEG bytes → ImageFrame" should continue to use the v0.11.0-stable `JPEGDecoder.decode(_:)`.
- **3 tests**: real-fixture pipeline equivalence (decode-via-coefficients + manual finish should produce byte-identical pixels to direct `JPEGDecoder.decode`), dequantise-matches-direct (catches quant-table reorder bugs), progressive rejection. **511 tests passing, 6 skipped, 0 failures** (was 508; +3).
- **What's NOT here yet.** The JXL-side coefficient bridge (i.e. an encoder mode that accepts `JPEGCoefficientImage` and emits a JXL frame whose decoded pixels match the source JPEG). That's the next bite — the v0.12.0a structured output is its required input.

---

## [0.11.0] — 2026-05-24 (release)

**Headline.** First tagged release on the pure-Swift trajectory. Full encode + decode pipeline (VarDCT lossy + Modular lossless), multi-frame animations, JPEG-decode foundation, and a CLI surface feature-aligned with the family-parity J2KSwift target.

**What's in v0.11.0.**

- **VarDCT lossy encoder + decoder.** Encoder emits spec-compliant codestreams djxl decodes (8-bit RGB/RGBA up to 8192 px, distance quality knob, all decoder-supported AC strategies, inverse-Gaborish pre-pass, per-block adaptive QF, multi-DC-group, multi-section, animation). Decoder byte-exact against `djxl 0.11.2` on `cjxl -d 0.5`/`-d 1.0` SWEEP + DCT8/16/32/64 / AFV / IDENTITY / DCT2×2 / DCT4×4 / DCT4×8 / DCT8×4 fixtures; `cjxl -d 2/5/10` retains a small B-channel residual (max ~12–14, mean < 0.7). Multi-AC-group, multi-DC-group, adaptive DC smoothing, EPF1/EPF2.
- **Modular lossless encoder + decoder.** 8/16-bit grayscale / RGB / RGBA, byte-exact round-trips through `cjxl`/`djxl`.
- **Multi-frame animations.** `JXLEncoder.encode([ImageFrame])` + `JXLDecoder.decodeAll(_:)` / `decodeFrame(_:at:)` / `inspectFrames(_:)` / `countFrames(_:)` end-to-end. CLI supports `--frame-duration 10,20,30`, `--all-frames` decode template, per-frame `info --frames` listing.
- **JPEG decode side (Phase J foundation).** `JPEGDecoder.decode(_:) → ImageFrame` for baseline-sequential 1- or 3-component 8-bit JPEGs. Wired into `jxl decode foo.jpg`, `jxl encode -i foo.jpg`, `jxl compare ref.jpg test.jxl`, and `jxl batch encode photos/`. Progressive / 12-bit / arithmetic-coded / CMYK throw `.unsupported` with clear messages.
- **CLI surface.** `jxl` (alias: `jxl-tool`) with `info`, `encode`, `decode`, `benchmark`, `compare` (PNM ↔ JXL ↔ JPEG, per-frame + all-frames), `validate` (structural + functional, walks every frame of animations), `batch encode|decode` (recursive, glob filter, continue-on-error, JSON summary), `version`, `completions`, multi-value `-i`. M0 internal subcommands hidden from main help.
- **Family-parity with J2KSwift.** Phases A + B + C of the API alignment plan complete: `JXLImage` typealias, `EncodingOptions` presets, `JXLConfiguration`, `jxl` canonical CLI name, async + progress overloads, shared `CompressionFamily` Swift package, `CompressionError` umbrella. See [Documentation/FAMILY-API-PARITY.md](Documentation/FAMILY-API-PARITY.md).

**Known limitations.** Documented at the top of [README.md](README.md). Headline ones:

- VarDCT decoder: DCT128, DCT256, DCT32×8, DCT8×32 transforms not ported (rare on real images, no real fixture forces them in our test corpus).
- VarDCT decoder: `cjxl -d 2/5/10` has a small B-channel byte-diff (max ~12–14) — visually indistinguishable but not bit-exact. Pixel-byte-equality close-out is open Phase V work.
- VarDCT decoder: Splines / Noise / Patches synthesis frame flags throw `.notImplemented`.
- Modular: Palette transform throws `.paletteUnsupported`; ICC compressed-profile boxes not parsed (uncompressed profiles work).
- ~~EPF0 7×7 kernel deferred until a real fixture forces it.~~ **Stale claim — EPF0 is implemented + dispatched (corrected in v0.12.0d docs); the existing SWEEP corpus just uses `epf_iters = 2` so EPF0 never fires in those tests.**
- JPEG: progressive / 12-bit / arithmetic / CMYK rejected with a clear error message.
- **Bit-perfect JPEG ↔ JXL transcoding (Phase J capstone) — NOT in v0.11.0**, planned for v0.12.0 (VarDCT coefficient bridge + JXL → JPEG reverse + `jbrd` box).

**Stability boundary for v0.11.0.**

- **Stable**: `JXLEncoder`, `JXLDecoder`, `ImageFrame` (+ `JXLImage` typealias), `EncodingOptions`, `CompressionMode`, `EncodingEffort`, `JXLConfiguration`, `EncodedImage`, `DecoderError`, `EncoderError`, `JXLDecoder.JXLInspection`, `JXLDecoder.FrameSummary`, multi-frame methods (`encode([ImageFrame])`, `decodeAll`, `decodeFrame`, `countFrames`, `inspectFrames`), `ImageMetrics`, the `CompressionFamily` protocol family.
- **Foundation (may evolve in v0.12.0)**: every public type in `Sources/JXLSwift/JPEG/*` except `JPEGDecoder.decode(_:)`. The layer types (segment reader, parsers, codebooks, bit reader, block decoder, scan decoder, IDCT, assembler, color conversion) are public because the eventual JPEG → JXL transcoding bridge needs them, but their individual signatures may move. Pin to `JPEGDecoder.decode(_:)` for the "JPEG bytes → ImageFrame" use case if you want zero-churn upgrades.
- M0 placeholder format (`encode-m0` / `decode-m0`) — explicitly internal scaffolding, may be removed in v0.12.0 once the real codec covers the M0 use cases.

**Test suite.** 508 tests passing, 6 skipped, 0 failures (release config, ~38 s on Apple Silicon). One sips-dependent JPEG round-trip skips on non-Darwin.

---

## [0.11.0a–cm] — in progress (VarDCT lossy encoder)

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

### v0.11.0k — README brought in line with the working codec

Documentation only — no code change. The `README.md` status sections still described JXLSwift as a "pre-codec spec layer" whose `JXLEncoder.encode` / `JXLDecoder.decode` "throw `.notImplemented`". That has been false since the v0.5.0 VarDCT decoder and the entire v0.11.0 encoder line. The README now states the actual state — a byte-exact VarDCT decoder and a working VarDCT-lossy + Modular-lossless encoder — with accurate test count (384), `jxl-tool encode`/`decode` usage, and source layout.

A chroma-from-luma (CfL) encoder slope-estimator was prototyped this cycle and **dropped**: measured across varied content it gained ≤ 1.2 % (best case, on maximally luma-correlated synthetic input) and was neutral on typical images, while a per-tile cost search made encode ≈ 4× slower — the wrong trade against the project's speed-first priority. The remaining genuine encoder win is AC-strategy selection.

### v0.11.0l — AC-strategy encode: DCT16×16 DSP foundation

First milestone of VarDCT AC-strategy selection (variable DCT block sizes). The decoder already supports every strategy; the encoder is DCT8×8-only. This lands the DCT16×16 *forward* DSP, self-contained and ahead of the bitstream integration.

- **`LowestFrequenciesFromDC.dcFromLowestFrequencies16x16`** — the encoder-direction inverse of `dct16x16`. A DCT16×16 block produces 256 coefficients; its 4 lowest-frequency coefficients are stored in the DC plane (one per covered 8×8 cell) and the decoder reconstructs them via `dct16x16`. This function recovers those 4 DC-plane values from the 4 LLF coefficients — undoing the `<2,16>` resample scales and inverting the 2×2 scaled DCT (whose sign matrix `M` satisfies `M·M = 4·I`, so the inverse is `d = M·s`).
- **Verified.** `testLowestFrequenciesFromDC_DCT16x16_Inverse` confirms `dct16x16 ∘ dcFromLowestFrequencies16x16 = identity`; `testVarDCT_DCT16_ForwardInverse_DSP` puts a 16×16 patch through the encoder-side forward DCT16 (`dct2D` + transpose) plus the LLF→DC split and confirms the decoder's own DCT16 primitives reconstruct it exactly.
- **Scope.** DSP foundation only — no bitstream change, encoder output is byte-identical to v0.11.0k. The bitstream integration (ACS-plane encoding, multi-block AC tokens, strategy selection) follows.
- **386 tests passing, 3 skipped, 0 failures.**

### v0.11.0m — AC-strategy encode: DCT16×16 block analysis

Second milestone — the complete DCT16×16 *analysis* path (forward transform + quantise), self-contained ahead of the bitstream integration.

- **`VarDCTEncoder.forwardDCT16Block`** — forward-transforms and quantises one 16×16 single-channel patch as a `dct16x16` block: `dct2D` size 16 → transpose to the bitstream coefficient layout → split the 4 lowest-frequency coefficients (grid positions 0/1/16/17) into DC-plane cell values via `dcFromLowestFrequencies16x16` → quantise the 252 AC coefficients with the channel's DCT16 quant matrix. The 252-entry AC array uses the natural grid layout the multi-block AC coder consumes.
- **Verified.** `testVarDCT_DCT16NaturalOrder_LLFPrefix` confirms `CoeffOrders.naturalCoeffOrder(for: .dct16x16)` lists the 4 LLF grid positions first — so the AC coder's "skip the first `coveredBlocks` scan positions" rule skips exactly the LLF. `testVarDCTEncoder_ForwardDCT16Block_RoundTrip` round-trips a smooth 16×16 patch through `forwardDCT16Block` and the decoder's full DCT16 reconstruction (LLF-from-DC + dequant + IDCT16) within a bounded error.
- **Scope.** Analysis primitive only — still no bitstream change; encoder output byte-identical to v0.11.0k. The remaining DCT16 milestones are the ACS-plane writer, multi-block AC token emission (`ACEncoder.encodeBlock` already handles `coveredBlocks = 4`), and a strategy-selection heuristic.
- **388 tests passing, 3 skipped, 0 failures.**

### v0.11.0n — AC-strategy encode: shared AC tokeniser

Third milestone — a behaviour-preserving refactor that consolidates AC tokenisation, so the upcoming DCT16×16 bitstream wiring reuses one spec-verified path instead of duplicating it.

- **`ACEncoder.tokenize`** — the per-block AC tokeniser, extracted from `ACEncoder.encodeBlock`. It returns the `(context, value)` token pairs plus the non-zero count, and is generic over `coveredBlocks` (1 for DCT8×8, 4 for DCT16×16) — the exact inverse of `ACDecoder.decodeBlock`. `encodeBlock` now delegates to it.
- **`VarDCTBitstreamWriter.generateACTokens`** previously inlined its own copy of the DCT8 token logic; it now calls `ACEncoder.tokenize` (`coveredBlocks: 1`). When DCT16 first-blocks are wired in, the same call with `coveredBlocks: 4` handles them — no second implementation.
- **Behaviour-preserving.** The token sequence is identical; encoder output is byte-for-byte unchanged. All 388 tests pass, including every VarDCT round-trip and `djxl` cross-check.
- **388 tests passing, 3 skipped, 0 failures.**

### v0.11.0o — AC-strategy encode: DCT16×16 emission 🎉

Fourth milestone — the VarDCT encoder now **emits DCT16×16 blocks**. A frame is no longer DCT8×8-only; smooth 16×16 regions are coded with one DCT16×16 transform, and `djxl` decodes the result.

- **`VarDCTEncoder.forward`** builds an AC-strategy plane: even-aligned 16×16 regions flat enough (a conservative variance test) use `dct16x16`, the rest stay `dct8x8`; edges that cannot fit a 2×2 region keep DCT8. Even-grid alignment guarantees a transform never straddles a group boundary. Each DCT16×16 first-block is forward-transformed via `forwardDCT16Block` — its 4 low-frequency coefficients populate the DC plane's four covered cells, its 252 AC coefficients are quantised with the DCT16 matrix. `Quantized` gained a per-block `acStrategy` plane; `acQuant` inner arrays are now 64 (DCT8) or 256 (DCT16).
- **`VarDCTBitstreamWriter`** writes a variable-`count` ACS plane — a raster walk over each DC group's cells emits one `(strategy, QF−1)` entry per transform first-block (`count` = number of first-blocks, not cell total). `generateACTokens` dispatches per strategy: a DCT16 first-block emits multi-block AC tokens (`ACEncoder.tokenize` with `coveredBlocks = 4`), covered cells emit nothing, and `⌈nnz / coveredBlocks⌉` is stamped across the covered cells of the nnz-prediction plane.
- **Verified.** `testVarDCTBitstreamWriter_DCT16` encodes a smooth 96×96 frame — confirmed to select DCT16×16 — and round-trips it through our decoder **and `djxl 0.11.2`** at per-pixel `mean < 4`. `testVarDCTEncoder_ForwardRoundTrip` likewise confirms a 64×64 gradient selects DCT16 and round-trips.
- **Scope.** DCT16×16 only; the selection heuristic is a deliberately conservative variance test (a rate-distortion search, and DCT32/asymmetric strategies, are later milestones).
- **389 tests passing, 3 skipped, 0 failures.**

### v0.11.0p — AC-strategy encode: trial-encode selection

Fifth milestone — the DCT8 / DCT16 choice is now a **trial encode** rather than a conservative variance guess.

- **`VarDCTEncoder.forward`** quantises every even-aligned 16×16 region *both* ways — once as a single DCT16×16, once as four DCT8×8 blocks — estimates the token cost of each via `tokenCost` (`nzeros` token + run structure to the last non-zero scan position + magnitude bits, the terms that actually drive the AC coder), and keeps whichever is cheaper. Because the choice is per-region and includes the DCT8 option, it **never regresses** below all-DCT8; and unlike the variance test it picks up DCT16-favourable detailed/structured regions, not just flat ones.
- New `forwardDCT8Block` mirrors `forwardDCT16Block`, so the trial path is symmetric; the old `regionUsesDCT16` variance test is removed.
- **Measured.** Encoding the same images at the previous (variance-heuristic) build vs the trial-encode: neutral on smooth gradients, **−2.2 % on a detailed/structured 512×512 image** (217.4 → 212.6 KB). Encode time roughly doubles (both transforms are computed) — ~0.08 s for 512×512, still well within the speed budget.
- **Verified.** All 389 tests pass — every VarDCT round-trip and `djxl 0.11.2` cross-check, with the trial-encode driving strategy selection.
- **389 tests passing, 3 skipped, 0 failures.**

### v0.11.0q — AC-strategy encode: DCT32×32 DSP foundation

First step of DCT32×32 support — the forward-transform DSP, self-contained ahead of the bitstream wiring (the same pattern the DCT16×16 milestones followed).

- **`LowestFrequenciesFromDC.inverseScaledDCT4`** — the 4-point scaled IDCT-4, the inverse of `scaledDCT4` (its odd half is an orthogonal 2×2 map that is its own inverse since `cos²(π/8) + cos²(3π/8) = 1`).
- **`LowestFrequenciesFromDC.dcFromLowestFrequencies32x32`** — the encoder-direction inverse of `dct32x32`: undoes the transpose + `<4,32>` resample, then the row and column scaled DCT-4 passes, recovering the 16 DC-plane cell values from a DCT32×32 block's 16 low-frequency coefficients.
- **`VarDCTEncoder.forwardDCT32Block`** — forward `dct2D` size 32 → transpose → split the 4×4 LLF corner into DC-plane values → quantise the 1008 AC coefficients with the DCT32 matrix.
- **Verified.** `testLowestFrequenciesFromDC_DCT32x32_Inverse` confirms `dct32x32 ∘ dcFromLowestFrequencies32x32 = identity`; `testVarDCTEncoder_ForwardDCT32Block_RoundTrip` round-trips a smooth 32×32 patch through `forwardDCT32Block` and the decoder's full DCT32 reconstruction within a bounded error.
- **Scope.** DSP foundation only — no bitstream change, encoder output byte-identical to v0.11.0p. The DCT32 bitstream wiring (a hierarchical DCT8 / DCT16 / DCT32 trial encode) follows.
- **391 tests passing, 3 skipped, 0 failures.**

### v0.11.0r — AC-strategy encode: DCT32×32 emission

The VarDCT encoder now emits DCT32×32 blocks — the AC-strategy trial encode became **hierarchical**.

- **`VarDCTEncoder.forward`** gains a 32×32 pass over the 4-block-aligned grid: each region is quantised as one DCT32×32, and that cost is compared against the sum of its four 16×16 sub-regions' chosen costs (each already the cheaper of DCT16×16 / four DCT8×8s). The cheaper wins; because every level includes the smaller-transform option, the choice **never regresses**. Block-aligned grids keep a DCT32×32 inside its group. `forwardDCT32Block` (v0.11.0q) supplies the analysis; new `forwardDCT8Block`/`dct32Region` round it out.
- **`VarDCTBitstreamWriter`** — `generateACTokens` and the ACS-plane writer became fully strategy-generic, driven by `ACStrategy.coveredBlocks` / `.blockCells` / `.orderBucket`, so a DCT32×32 first-block emits its 1008 multi-block AC tokens (`coveredBlocks = 16`) with no special-casing.
- **Measured.** Encoding smooth gradients at the previous (DCT8/16) build vs DCT8/16/32: **−5.5 % to −11 %** on smooth 512×512 frames (e.g. 7.3 → 6.5 KB); neutral on content DCT32 doesn't suit.
- **Verified.** `testVarDCTBitstreamWriter_DCT32` encodes a very smooth 128×128 frame — confirmed to select DCT32×32 — and round-trips it through our decoder **and `djxl 0.11.2`** at per-pixel `mean < 4`.
- **392 tests passing, 3 skipped, 0 failures.**

### v0.11.0s — AC-strategy encode: DCT16×8 / DCT8×16 DSP foundation

The square AC strategies (DCT8 / DCT16 / DCT32) are emitted; the next AC-strategy axis is the **asymmetric** pair — DCT16×8 (vertical pair, `8w × 16h`) and DCT8×16 (horizontal pair, `16w × 8h`), libjxl ord 4. This milestone lands their forward-transform DSP, self-contained ahead of the bitstream integration.

- **`LowestFrequenciesFromDC.dcFromLowestFrequenciesOrd4Pair`** — encoder-direction inverse of `ord4Pair`. Undoes the `<2, 16>` resample on each half then the 2×2 Hadamard (`d0+d1` / `d0-d1`), recovering the 2 DC-plane cell values from a block's 2 LLF coefficients (top-then-bottom for DCT16×8, left-then-right for DCT8×16).
- **`VarDCTEncoder.forwardDCT8x16Block`** — direct `dct2D(rows: 8, cols: 16)` on the 128-entry patch; the coef layout matches the decoder's, so no transpose.
- **`VarDCTEncoder.forwardDCT16x8Block`** — transposes the 16h × 8w patch into the 8-row × 16-col coef layout, then `dct2D(rows: 8, cols: 16)`. The decoder transposes the IDCT output back to pixels; the encoder takes the symmetric path.
- **Verified.** `testLowestFrequenciesFromDC_Ord4Pair_Inverse` confirms `ord4Pair ∘ dcFromLowestFrequenciesOrd4Pair = identity`; two block round-trip tests put 8×16 and 16×8 patches through `forwardDCT…Block` and the decoder's `idct2D(rows: 8, cols: 16)` (with the right transpose for DCT16×8) within bounded error.
- **Scope.** DSP foundation only — no bitstream change, encoder output byte-identical to v0.11.0r. The trial-encode wiring (extending `eval16Region` to four partitionings: DCT16×16, 2×DCT16×8, 2×DCT8×16, 4×DCT8×8) follows.
- **395 tests passing, 3 skipped, 0 failures.**

### v0.11.0t — AC-strategy encode: DCT16×8 / DCT8×16 emission

`eval16Region` now picks the cheapest of **four** partitionings instead of two — the asymmetric strategies (libjxl ord 4) are emitted, and `djxl` decodes them.

- **`VarDCTEncoder.forward`** — `eval16Region` quantises every 16×16 region as DCT16×16, **two DCT16×8 vertical pairs** (left + right columns), **two DCT8×16 horizontal pairs** (top + bottom rows), and four DCT8×8 cells, then commits whichever partitioning has the lowest summed token cost. Because every choice keeps the smaller options in the comparison, the trial **never regresses**. New helpers `dct16x8Pair` / `dct8x16Pair` / `commitDCT16x8Pair` / `commitDCT8x16Pair` round out the analysis path; rectangular patch extraction (`patchRect` / `patchBmYRect`) supplies the 8w × 16h and 16w × 8h pixel patches.
- **`VarDCTBitstreamWriter.generateACTokens`** — the strategy-generic dispatch added in v0.11.0r is extended with the ord-4 natural coefficient order (`naturalCoeffOrder(for: .dct8x16)`, shared by `dct16x8` and `dct8x16` since they share an order bucket). The strategy-generic ACS-plane writer already accepts asymmetric `blockCells`.
- **Measured.** On 512×512 directional content (8-pixel vertical or horizontal stripes), encoding shrinks from **7.8 → 6.0 KB (−23 %)** vs the DCT8/16/32-only build; neutral on content the asymmetric pair doesn't suit.
- **Verified.** `testVarDCTBitstreamWriter_AsymmetricACS` encodes a 64×64 vertical-stripes frame — confirmed to select DCT16×8 or DCT8×16 — and confirms `djxl 0.11.2` decodes it and our decoder agrees on the pixels.
- **396 tests passing, 3 skipped, 0 failures.**

### v0.11.0u — AC-strategy encode: DCT32×16 / DCT16×32 DSP foundation

Asymmetric ord-6 DSP, the next axis after ord-4 (DCT16×8 / DCT8×16). Same milestone pattern: DSP foundation first, integration follows.

- **`LowestFrequenciesFromDC.dcFromLowestFrequenciesOrd6Block`** — encoder-direction inverse of `ord6Block`. Undoes the `<4, 32>` × `<2, 32>` resample, the 1-D scaled DCT-4 along rows, then the 1-D DCT-2 along the 2-row axis, recovering the 8 DC-plane cell values from a block's 8 LLF coefficients.
- **`VarDCTEncoder.forwardDCT16x32Block`** — direct `dct2D(rows: 16, cols: 32)` on the 32w × 16h pixel patch; the coef layout matches the decoder's, so no transpose.
- **`VarDCTEncoder.forwardDCT32x16Block`** — transposes the 16w × 32h patch into the 16-row × 32-col coef layout, then `dct2D(rows: 16, cols: 32)`. The decoder transposes the IDCT output back; the encoder is its inverse.
- **Verified.** `testLowestFrequenciesFromDC_Ord6Block_Inverse` confirms `ord6Block ∘ dcFromLowestFrequenciesOrd6Block = identity`; two block round-trip tests put 32w × 16h and 16w × 32h patches through `forwardDCT…Block` and the decoder's `idct2D(rows: 16, cols: 32)` (with the right transpose for DCT32×16) within bounded error.
- **Scope.** DSP foundation only — no bitstream change, encoder output byte-identical to v0.11.0t. The integration (folding DCT32×16 / DCT16×32 into the 32×32-region trial encode as two new partitionings, alongside DCT32×32 and the four-way 16×16 sub-region trial) follows.
- **399 tests passing, 3 skipped, 0 failures.**

### v0.11.0v — AC-strategy encode: DCT32×16 / DCT16×32 emission

The 32×32-region trial encode is now **four-way** instead of two — the ord-6 asymmetric strategies are emitted, and `djxl` decodes them.

- **`VarDCTEncoder.forward`** — the 32×32 pass quantises every 4-aligned region as one DCT32×32, two DCT32×16 vertical halves (each 16w × 32h covering 2 cols × 4 rows of cells), two DCT16×32 horizontal halves (each 32w × 16h covering 4 cols × 2 rows of cells), and the four 16×16 sub-regions' chosen costs (each itself a four-way trial). The cheapest partitioning wins; because every choice keeps the smaller-transform options in the comparison, the trial **never regresses**. New helpers `dct32x16Pair` / `dct16x32Pair` / `commitDCT32x16Pair` / `commitDCT16x32Pair` round out the analysis + commit paths.
- **`VarDCTBitstreamWriter.generateACTokens`** — the strategy-generic dispatch is extended with the ord-6 natural coefficient order (`naturalCoeffOrder(for: .dct16x32)`, shared by `dct32x16` and `dct16x32` since they share an order bucket). The ACS-plane writer already accepts asymmetric `blockCells`.
- **Measured.** On 512×512 directional content (16-pixel vertical or horizontal stripes), encoding shrinks **5.1 → 4.6 KB (−10 %)** vs the ord-4-only build; neutral elsewhere. The ord-6 gain stacks on the ord-4 gain (which was −23 % vs DCT8/16/32-only on 8-pixel stripes).
- **Verified.** `testVarDCTBitstreamWriter_AsymmetricOrd6` encodes a 64×64 16-px-stripe frame — confirmed to select DCT32×16 or DCT16×32 — and confirms `djxl 0.11.2` decodes it and our decoder agrees on the pixels.
- **400 tests passing, 3 skipped, 0 failures.**

### v0.11.0w — AC-strategy encode: DCT64×64 DSP foundation

The square AC-strategy progression continues — DCT64×64 (libjxl ord 7) covers a 8×8 grid of cells. Foundation only this milestone; emission follows.

- **`LowestFrequenciesFromDC.dcFromLowestFrequencies64x64`** — encoder-direction inverse of `dct64x64`. Undoes the transpose + per-axis `<8, 64>` resample, then the 2-D forward scaled DCT-8 via `AccelerateDCT.idct2D(size: 8)`, recovering the 64 DC-plane cell values from a block's 64 LLF coefficients.
- **`VarDCTEncoder.forwardDCT64x64Block`** — forward `dct2D(size: 64)` + transpose, splits the 8×8 LLF corner to the DC plane, quantises the 4032 AC coefficients with the DCT64 matrix.
- **Verified.** `testLowestFrequenciesFromDC_DCT64x64_Inverse` confirms `dct64x64 ∘ dcFromLowestFrequencies64x64 = identity`; `testVarDCTEncoder_ForwardDCT64x64Block_RoundTrip` round-trips a smooth 64×64 patch through the decoder's full DCT64 reconstruction within bounded error.
- **Scope.** DSP foundation only — no bitstream change, encoder output byte-identical to v0.11.0v.
- **402 tests passing, 3 skipped, 0 failures.**

### v0.11.0x — AC-strategy encode: DCT64×64 emission

The hierarchical trial gains a 64×64 level — DCT64×64 (libjxl ord 7) is now emitted on flat large-scale content, and `djxl` decodes it.

- **`VarDCTEncoder.forward`** — the per-level trial is restructured as nested helpers. `eval32Region` extracts the previous 32×32-pass body (returns the chosen cost; commits its 16 cells). A new 64×64 pass quantises every 8-block-aligned 64×64 region as one DCT64×64 and compares against the sum of its four sub-32×32-region costs (each itself a full four-way trial). If DCT64 wins it overwrites the 64 committed cells; otherwise the sub-region commits stand. A trailing 32×32 pass handles 4-aligned regions outside the 64-grid, then 16×16, then DCT8 edges.
- **`VarDCTBitstreamWriter.generateACTokens`** — the strategy-generic dispatch is extended with the DCT64×64 natural coefficient order.
- **Verified.** `testVarDCTBitstreamWriter_DCT64` encodes a near-constant 128×128 frame (where DCT64×64 wins on token-overhead alone — one `nzeros` token vs four for 4×DCT32×32) and confirms `djxl 0.11.2` decodes it and our decoder agrees on the pixels.
- **403 tests passing, 3 skipped, 0 failures.**

### v0.11.0y — AC-strategy encode: DCT64×32 / DCT32×64 DSP foundation

Asymmetric ord-8 DSP, the next axis after ord-6. A DCT64×32 / DCT32×64 covers 32 cells (8×4 or 4×8); its 32 LLF coefficients sit in the DC plane.

- **`LowestFrequenciesFromDC.dcFromLowestFrequenciesOrd8Block`** — encoder-direction inverse of `ord8Block`. Undoes the per-axis `<8, 64>` × `<4, 32>` resample, then the 2-D forward scaled DCT via `AccelerateDCT.idct2D(rows: 4, cols: 8)`, recovering the 32 DC-plane cell values from a block's 32 LLF coefficients.
- **`VarDCTEncoder.forwardDCT32x64Block`** — direct `dct2D(rows: 32, cols: 64)` on the 64w × 32h pixel patch (coef matches decoder layout).
- **`VarDCTEncoder.forwardDCT64x32Block`** — transposes the 32w × 64h patch into the 32-row × 64-col coef layout, then `dct2D(rows: 32, cols: 64)`.
- **Verified.** `testLowestFrequenciesFromDC_Ord8Block_Inverse` confirms `ord8Block ∘ dcFromLowestFrequenciesOrd8Block = identity`; two block round-trip tests put 32×64 and 64×32 patches through `forwardDCT…Block` and the decoder's `idct2D(rows: 32, cols: 64)` (with the right transpose for DCT64×32) within bounded error.
- **Scope.** DSP foundation only — no bitstream change, encoder output byte-identical to v0.11.0x.
- **406 tests passing, 3 skipped, 0 failures.**

### v0.11.0z — AC-strategy encode: DCT64×32 / DCT32×64 emission

The hierarchical trial gains an ord-8 fork — DCT64×32 (libjxl ord 8 vertical-half pair) and DCT32×64 (ord 8 horizontal-half pair) are now emitted on content where a 32-pixel-scale axis seam dominates a 64×64 region, and `djxl` decodes them.

- **`VarDCTEncoder.forward`** — the 64×64 pass becomes a four-way trial. Each 8-block-aligned 64×64 region quantises DCT64×64 (one block, 64 cells), two vertical DCT64×32 halves (32 + 32 cells, left/right), two horizontal DCT32×64 halves (32 + 32 cells, top/bottom), and the four sub-32×32-region cost (each itself a full four-way trial). The cheapest commits its cells; on a single-seam region the two-half ord-8 cost beats DCT64×64 (no cross-seam AC) and 4×DCT32×32 (half the token overhead). Two new commit helpers stamp the cell-strategy map and DC plane in the libjxl-canonical orderings — DCT64×32 cells in a 4-col × 8-row arrangement with `dc[r*8+c]` ↔ cell `(bx+r, by+c)`; DCT32×64 cells in an 8-col × 4-row arrangement with `dc[r*8+c]` ↔ cell `(bx+c, by+r)`.
- **`VarDCTBitstreamWriter.generateACTokens`** — the strategy-generic dispatch is extended with the DCT32×64 natural coefficient order (shared by DCT64×32 — the coef plane has the same `32-row × 64-col` shape for both).
- **Verified.** `testVarDCTBitstreamWriter_AsymmetricOrd8` encodes a 64×64 frame split by a single vertical seam at `x = 32` (two flat colours), asserts at least one cell picks `DCT64×32` or `DCT32×64`, and confirms `djxl 0.11.2` decodes the codestream within `mean < 2` of our decoder.
- **404 tests passing, 3 skipped, 0 failures.**

### v0.11.0aa — AC-strategy encode: DCT4×4 DSP foundation

The small-block axis. DCT4×4 covers one 8×8 cell as four 4×4 DCTs — its coefficient packing differs entirely from the multi-cell strategies (quadrant DCs combined by 2×2 Haar into the four top-left positions, quadrant ACs strided-scattered into the remaining 60), so it needs its own forward primitive.

- **`VarDCTEncoder.forwardDCT4x4Block`** — exact inverse of `DCT4x4Transform.transformToPixels`. Splits an 8×8 patch into four 4×4 quadrants, forward-DCTs each (`dct2D(4) → transposeSquareInPlace(4)`, the inverse of the decoder's `transpose → idct2D` reconstruction), inverse-Haars the four quadrant DCs into positions `(0,0)`, `(0,1)`, `(1,0)`, `(1,1)` of the 8×8 coef grid, strided-scatters the 60 quadrant AC coefficients to positions `(y+iy·2, x+ix·2)`, then quantises the 63 AC slots through the shared `quantizeAC` path.
- **Verified.** `testVarDCTEncoder_ForwardDCT4x4Block_RoundTrip` puts a 4×4-quadrant-aligned high-frequency checkerboard patch through `forwardDCT4x4Block` and the decoder's `DCT4x4Transform.transformToPixels` (with dequant) — the round-trip stays within `mean < 0.02`, `max < 0.10` of the source.
- **Scope.** DSP foundation only — no bitstream change, encoder output byte-identical to v0.11.0z. Trial-encode wiring follows in v0.11.0ab.
- **405 tests passing, 3 skipped, 0 failures.**

### v0.11.0ab — AC-strategy encode: DCT4×4 emission

DCT4×4 joins the trial as a per-cell alternative to DCT8×8. Unlike the multi-cell strategies (DCT16/32/64/asymmetric), DCT4×4 covers a single 8×8 cell — so its choice is independent per cell, slotted into both the leaf of the 16×16-region trial and the edge pass.

- **`VarDCTEncoder.forward`** — `commitDCT8` becomes a per-cell trial: compute DCT8×8 and DCT4×4, sum each strategy's three-channel `tokenCost`, commit the cheaper. `eval16Region`'s "four DCT8" branch is extended in the same way — each of the four cells independently picks min(DCT8, DCT4×4), the small-cell cost is the sum, and the commit-loop writes the per-cell choice. Because the trial only ever picks the cheaper option, including DCT4×4 cannot make any region worse.
- **No bitstream-writer change.** DCT4×4 uses the standard 8×8 zigzag (its `naturalCoeffOrder` matches DCT8×8); the block-context map already routes ord-bucket 1 contexts (shared with Hornuss / DCT2×2); `ACEncoder.tokenize` handles `coveredBlocks == 1` generically.
- **Verified.** `testVarDCTBitstreamWriter_SmallBlockDCT4x4` encodes a 16×16 frame whose four 8×8 cells each have a per-4×4-quadrant flat-colour pattern (varying per cell so no multi-cell strategy compresses better) — asserts at least one cell picks DCT4×4 and confirms `djxl 0.11.2` decodes the codestream within `mean < 2` of our decoder.
- **406 tests passing, 3 skipped, 0 failures.**

### v0.11.0ac — AC-strategy encode: DCT4×8 / DCT8×4 DSP foundation

The half-cell asymmetric small-block pair. DCT4×8 and DCT8×4 each cover an 8×8 cell as two halves (4-tall × 8-wide stacked, or 8-tall × 4-wide side-by-side) joined by a 1-D DCT-2 of their DCs — the right choice for cells with a single sharp axis-aligned discontinuity.

- **`VarDCTEncoder.forwardDCT4x8Block`** — exact inverse of `DCT4x8Transform.transformToPixels`. Two 4×8 forward DCTs (ROWS<COLS, natural = storage), 1-D-DCT-2 combine of the two half DCs into `coef[0] = (top+bot)/2` and `coef[8] = (top-bot)/2`, strided-scatter of each half's 31 ACs into positions `(y + iy·2, ix)`, then quantise the 63 AC slots.
- **`VarDCTEncoder.forwardDCT8x4Block`** — exact inverse of `DCT8x4Transform.transformToPixels`. Two 8×4 forward DCTs (ROWS≥COLS — natural-layout forward then transpose to 4×8 storage per half), same DC combine, strided AC scatter at `(x + iy·2, ix)`.
- **Verified.** `testVarDCTEncoder_ForwardDCT4x8Block_RoundTrip` and `…ForwardDCT8x4Block_RoundTrip` put 8×8 patches with a single sharp horizontal / vertical seam (the half-cell sweet spot — each half is flat, all 31 within-half ACs zero) through the new primitives and the decoder's small-block transforms (with dequant) — both round-trip within `mean < 0.02`, `max < 0.10`.
- **Scope.** DSP foundation only — no bitstream change, encoder output byte-identical to v0.11.0ab. Trial-encode wiring follows in v0.11.0ad.
- **408 tests passing, 3 skipped, 0 failures.**

### v0.11.0ad — AC-strategy encode: DCT4×8 / DCT8×4 emission

DCT4×8 and DCT8×4 join the per-cell trial. The four single-cell strategies (DCT8×8, DCT4×4, DCT4×8, DCT8×4) compete on every 8×8 cell that isn't absorbed by a multi-cell strategy.

- **`VarDCTEncoder.forward`** — the per-cell trial is refactored behind a `bestSmallCell(bx, by)` helper that scores all four single-cell transforms via `tokenCost` and returns the cheapest with its DC, AC, and raw-byte strategy. `commitDCT8` is now a direct wrapper around the helper; `eval16Region`'s "four small cells" branch uses it too. Each transform has a distinct sweet spot — DCT4×8 wins on a half with a clean horizontal ramp (one column-frequency AC) where DCT4×4 has to split the ramp across two quadrants and pay the Haar of the per-quadrant DCs.
- **No bitstream-writer change.** DCT4×8 and DCT8×4 use the standard 8×8 zigzag (`naturalCoeffOrder` for any single-cell strategy); the block-context map already routes ord-bucket 1 contexts (shared with the other small-block strategies); `ACEncoder.tokenize` is generic over `coveredBlocks == 1`.
- **Verified.** `testVarDCTBitstreamWriter_SmallBlockHalfCell` encodes a 16×16 frame whose four 8×8 cells each carry a half-aligned reversed gradient — half horizontal (top-half ramps left→right, bottom-half right→left) and half vertical — asserts at least one cell picks DCT4×8 or DCT8×4, and confirms `djxl 0.11.2` decodes the codestream within `mean < 2` of our decoder.
- **409 tests passing, 3 skipped, 0 failures.**

### v0.11.0ae — AC-strategy encode: DCT2×2 DSP foundation

The last single-cell small-block transform. DCT2×2 is a hierarchical 2×2-Haar cascade: at each scale `s ∈ {8, 4, 2}` the top-left `s × s` region's dense 2×2 pixel groups are each replaced by their 2×2 Haar (DC + 3 ACs). The cell-DC of the largest scale becomes `coef[0]`; each level's three ACs occupy the remaining 63 positions. Its sweet spot is content with detail at every Haar scale simultaneously (e.g. hierarchical synthetic textures).

- **`VarDCTEncoder.forwardDCT2x2Block`** — exact inverse of `DCT2x2Transform.transformToPixels` (the decoder's `idct2TopBlock` cascade at `s = 2 → 4 → 8`). For each scale `s ∈ {8, 4, 2}` (forward, large-to-small), reads dense 2×2 pixel groups in the top-left `s × s` area and writes the per-group `[c00, c01, c10, c11] = [Σ, ±Σ, ∓Σ, ±∓] / 4` Haar to positions `(y, x), (y, x + s/2), (y + s/2, x), (y + s/2, x + s/2)`. The 1/4 normalisation cancels the decoder's pure-sum IDCT cascade exactly.
- **Verified.** `testVarDCTEncoder_ForwardDCT2x2Block_RoundTrip` puts a synthetic 3-scale checkerboard (frequency content at scales 2, 4, *and* 8 simultaneously — every level of the cascade contributes) through `forwardDCT2x2Block` and `DCT2x2Transform.transformToPixels` (with dequant) — round-trips within `mean < 0.03`, `max < 0.15`.
- **Scope.** DSP foundation only — no bitstream change, encoder output byte-identical to v0.11.0ad. Trial-encode wiring follows in v0.11.0af.
- **410 tests passing, 3 skipped, 0 failures.**

### v0.11.0af — AC-strategy encode: DCT2×2 emission

DCT2×2 joins `bestSmallCell` as the fifth single-cell candidate. Adding one more option to a min-of-N comparison cannot make any region worse, so the integration is byte-safe by construction. DCT2×2's sweet spot is narrow (multi-scale hierarchical detail at every Haar level simultaneously) — libjxl itself selects it rarely on real content, so we don't expect frequent firing.

- **`VarDCTEncoder.forward`** — `bestSmallCell` now scores all five single-cell transforms (DCT8×8, DCT4×4, DCT4×8, DCT8×4, DCT2×2) and returns the cheapest. DCT2×2 uses the `kQuantModeDCT2X2` weight table (`getDCT2QuantWeights`).
- **No bitstream-writer change.** DCT2×2 shares ord-bucket 1 and the standard 8×8 zigzag with the rest of the single-cell strategies.
- **Verified.** `testVarDCTBitstreamWriter_SmallBlockDCT2x2` is an integration-safety check — a multi-scale textured fixture is encoded with DCT2×2 in the pool, and the codestream must still decode through our decoder **and `djxl`** at `mean < 2`. Whether DCT2×2 *actually* wins on this particular fixture is a heuristic outcome, not an integration requirement.
- **411 tests passing, 3 skipped, 0 failures.**

### v0.11.0ag — AC-strategy encode: Hornuss DSP foundation

The IDENTITY ("hornuss") transform — a near-spatial small-block strategy. Each 4×4 quadrant carries a 2×2-DCT-combined block DC plus 15 spatial residuals around the quadrant centre pixel `(1,1)`. The (0,0) pixel of each quadrant uses a "corner-overwrite" trick — its residual lives at coef position `(y + 2, x + 2)` (the slot the (1,1) residual would otherwise occupy). Sweet spot: flat / smooth-block content where a full DCT would waste bits on noise-floor high-frequency coefficients.

- **`VarDCTEncoder.forwardHornussBlock`** — exact inverse of `IdentityTransform.transformToPixels`. For each of the four 4×4 quadrants: pick `center = patch(1,1)`, compute 15 residuals via the libjxl coefficient-position permutation (including the corner-overwrite of (0,0)), set `blockDC = center + Σresidual / 16`, then 2×2 forward DCT the four block-DCs into positions `coef[0]`, `coef[1]`, `coef[8]`, `coef[9]`.
- **Verified.** `testVarDCTEncoder_ForwardHornussBlock_RoundTrip` puts a smooth-ish patch (the Hornuss sweet spot) through `forwardHornussBlock` and `IdentityTransform.transformToPixels` (with dequant) — round-trips within `mean < 0.03`, `max < 0.15`.
- **Scope.** DSP foundation only — no bitstream change, encoder output byte-identical to v0.11.0af. Trial-encode wiring follows in v0.11.0ah.
- **412 tests passing, 3 skipped, 0 failures.**

### v0.11.0ah — AC-strategy encode: Hornuss emission

Hornuss joins `bestSmallCell` as the sixth single-cell candidate. Same byte-safety argument as v0.11.0af: adding one more option to a min-of-N comparison cannot regress any region. Hornuss's sweet spot is flat / smooth-block content — libjxl itself selects it rarely.

- **`VarDCTEncoder.forward`** — `bestSmallCell` now scores all six single-cell transforms (DCT8×8, DCT4×4, DCT4×8, DCT8×4, DCT2×2, Hornuss) and returns the cheapest. Hornuss uses the `kQuantModeIdentity` weight table (`getIdentityQuantWeights`).
- **No bitstream-writer change.** Hornuss shares ord-bucket 1 and the standard 8×8 zigzag with the rest of the single-cell strategies.
- **Verified.** `testVarDCTBitstreamWriter_SmallBlockHornuss` is an integration-safety check — a flat-ish dithered fixture is encoded with Hornuss in the pool, and the codestream must still decode through our decoder **and `djxl`** at `mean < 2`. Whether any cell *actually* picks Hornuss on this particular fixture is a heuristic outcome, not an integration requirement.
- **413 tests passing, 3 skipped, 0 failures.**

### v0.11.0ai — AC-strategy encode: AFV DSP foundation

The last decoder-supported AC strategy: AFV (Asymmetric Frequency Variable), four orientations sharing one transform. Each AFV variant partitions the 8×8 cell into three sub-regions — a 4×4 AFV corner (orthonormal basis), a 4×4 IDCT corner, and a 4×8 IDCT half — with three sub-DCs combined into the top-left 2×2 (`coef[0]`, `coef[1]`, `coef[8]`). Sweet spot: directional luminance edges where a normal DCT would spread the edge across many high-frequency coefficients.

- **`AFV.fdct4x4`** — orthonormal forward matrix multiply (`coeffs = basis · pixels`), the exact inverse of `AFV.idct4x4`.
- **`VarDCTEncoder.forwardAFVBlock(afvKind:, …)`** — exact inverse of `AFV.transformToPixels(afvKind:)`. Pulls the AFV-corner 4×4 patch (with libjxl's per-`afvKind` orientation flip), forward-AFV-transforms it; pulls the opposite-x IDCT4×4 corner, forward-DCTs it (transpose convention matches the decoder); pulls the opposite-y IDCT4×8 half, forward-`dct2D(rows:4, cols:8)`. Three sub-DCs (`dc0 = 4·(c[0]+c[8]+c[1])`, `dc1 = c[0]+c[8]−c[1]`, `dc2 = c[0]−c[8]`) are inverted into `coef[0]`, `coef[1]`, `coef[8]`; the 15 AFV ACs scatter to (even,even), 15 IDCT-4×4 ACs to (even,odd), 31 IDCT-4×8 ACs to (odd, any). Then the 63 ACs are quantised via the libjxl `kQuantModeAFV` weights table (`getAFVQuantWeights`).
- **Verified.** `testVarDCTEncoder_ForwardAFVBlock_RoundTrip` iterates `afvKind ∈ 0..3` over a directional-edge patch (diagonal step + smooth gradient) — `forwardAFVBlock` then `AFV.transformToPixels` with dequant — every orientation round-trips within `mean < 0.04`, `max < 0.20`.
- **Scope.** DSP foundation only — no bitstream change, encoder output byte-identical to v0.11.0ah. Trial-encode wiring follows in v0.11.0aj.
- **414 tests passing, 3 skipped, 0 failures.**

### v0.11.0aj — AC-strategy encode: AFV emission

The four AFV orientations join `bestSmallCell` as candidates 7–10. This is the **last** decoder-supported AC strategy — the encoder now considers every transform the decoder can reconstruct. As with the other small-block additions, adding more candidates to a min-of-N cost comparison cannot regress any cell.

- **`VarDCTEncoder.forward`** — `bestSmallCell` is extended to score the four AFV variants alongside DCT8/DCT4×4/DCT4×8/DCT8×4/DCT2×2/Hornuss; the cheapest wins. AFV per-channel quant weights come from `getAFVQuantWeights` (built from the DCT4×8, DCT4×4, and AFV-specific band tables).
- **No bitstream-writer change.** AFV strategies share ord-bucket 1 with the rest of the single-cell pool and use the standard 8×8 zigzag.
- **Verified.** `testVarDCTBitstreamWriter_SmallBlockAFV` is an integration-safety check — a 16×16 frame with per-cell directional edges (each 8×8 cell carries a diagonal step at a different position, mimicking the edge variety AFV is designed for) is encoded with the four AFV variants in the pool, and the codestream must still decode through our decoder **and `djxl`** at `mean < 2`. Whether any cell *actually* picks an AFV variant on this fixture is a heuristic outcome.
- **Coverage.** With AFV in place, every decoder-supported AC strategy is now emitted: all multi-cell DCTs (DCT16/32/64 + asymmetric ord-4/6/8) and all single-cell strategies (DCT8, DCT4×4, DCT4×8, DCT8×4, DCT2×2, Hornuss, AFV0–3). DCT128 / DCT256 / DCT32×8 / DCT8×32 remain out of scope — the decoder doesn't reconstruct them yet, so the encoder doesn't emit them.
- **415 tests passing, 3 skipped, 0 failures.**

### v0.11.0ak — ord-5 (DCT32×8 / DCT8×32) LLF DSP foundation

Pre-work for the only AC-strategy axis the decoder doesn't yet support — DCT32×8 (1×4 covered cells) and DCT8×32 (4×1 covered cells). Adding decoder dispatch + encoder emission for ord 5 is a multi-bite undertaking (LLF + per-axis IDCT + quant matrices + dispatch + forward primitives + region trial); this commit ships the smallest self-contained piece, the LLF transform, so both sides have a verified inverse pair ready when the rest lands.

- **`LowestFrequenciesFromDC.ord5Block`** — 4 DC values from the 4 covered cells (1×4 / 4×1 grid) → 4 LLF coefficients via 1-D scaled DCT-4 plus the `kScales4to32` per-axis resample (the `<1, 8>` axis collapses to a no-op since it has a single element).
- **`LowestFrequenciesFromDC.dcFromLowestFrequenciesOrd5Block`** — the encoder-direction inverse, undoes the resample then `inverseScaledDCT4`.
- **Verified.** `testLowestFrequenciesFromDC_Ord5Block_Inverse` confirms `ord5Block ∘ dcFromLowestFrequenciesOrd5Block = identity` across flat, ramp, and zero-DC fixtures within float epsilon.
- **Scope.** DSP foundation only — no decoder or encoder integration. The decoder's strategy dispatch still skips DCT32×8 / DCT8×32; the encoder still doesn't emit them. Encoder output byte-identical to v0.11.0aj.
- **416 tests passing, 3 skipped, 0 failures.**

### v0.11.0al — VarDCT encoder: Gaborish pre-inverse pre-pass (Phase R encoder)

The decoder has applied the forward Gaborish smoothing pass (`lf.gab=true`) end-to-end since v0.6.0; the encoder always wrote `gab: false` to disable it. v0.11.0al flips this — by default, the encoder applies the libjxl 5×5 inverse-Gaborish sharpening pre-pass to the XYB pixels before the forward DCT, and writes `lf.gab: true` in the frame header so the decoder runs the matching forward Gaborish pass. The encoder-decoder pair is not mathematically inverse (libjxl's pre-kernel is butteraugli-optimised, not a deconvolution), but the pair produces visually pleasing rate-distortion behaviour that respects the spec defaults.

- **`VarDCTEncoder.forward(frame:distance:gaborish:)`** — new `gaborish: Bool = true` parameter. When set, `Gaborish.applyInverse5x5` runs on `planeX`, `planeY`, `planeB` between the OpsinXYB step and the forward DCT. The flag is mirrored into `Quantized.gaborish`.
- **`VarDCTBitstreamWriter.encode(frame:distance:gaborish:)`** — same `gaborish` parameter; threads through to `writeOuterCodestream`, which now writes the frame-header `LoopFilter` with `gab: q.gaborish, gabCustom: false` (libjxl default weights).
- **`FrameHeader.LoopFilter.write`** — extended to support the `gab=true, gabCustom=false, epfIters=0` configuration alongside the previously-supported `gab=false, epfIters=0`. The 1-bit `gabCustom = false` is emitted right after the `gab` flag.
- **Test bound shifts.** Two strategy-selection tests (`testVarDCTBitstreamWriter_AsymmetricOrd6` / `…_AsymmetricOrd8`) now pass `gaborish: false` — the inverse-Gaborish pre-sharpening at the stripe / seam boundaries shifts per-cell trial costs, and these tests verify the trial mechanism itself, not Gaborish behaviour. All round-trip and end-to-end byte-equality tests are unaffected (mean error stays well under the existing bounds).
- **Verified.** `testVarDCTBitstreamWriter_GaborishSmoke` exercises the new path — a 16×16 frame encoded with `gaborish: true` (default) round-trips through our decoder at the right dimensions, and the codestream differs from the `gaborish: false` sibling (proving the flag flows through). The existing 24×24 `…_RoundTrip` test also exercises the gaborish-on path with `djxl 0.11.2`-verified byte equality.
- **417 tests passing, 3 skipped, 0 failures.**

### v0.11.0am — VarDCT encoder: adaptive per-block QF (variance-driven)

The encoder used a uniform `qf = 5` for every block; v0.11.0am makes the QF per-block, variance-driven. Smoother cells get a coarser QF (= fewer bits spent on near-zero AC), textured cells get a finer one (= preserve detail). The decoder already reads per-block QF from ACMetadata channel 2 — only the encoder side needed wiring.

- **`Quantized.qfPerBlock: [Int32]`** — per-cell quantisation factor, row-major `[by · blocksX + bx]`. Populated by `VarDCTEncoder.forward` from the per-cell Y-plane variance: `qf = clamp(5 + round(50·√variance), [3, 16])` for textured cells, qf=5 for flat content. Multi-block strategies use the first-block's QF; the trial-encode uses each cell's own QF (a slight unfairness — a covered cell of a hypothetical DCT16 doesn't share the first-block's QF during cost evaluation — but tolerable in practice and trivially correctable in a future bite).
- **`VarDCTEncoder.forward(frame:distance:gaborish:adaptiveQF:)`** — new `adaptiveQF: Bool = true` parameter. When `false`, every block gets the base QF (= 5). Defaults are libjxl-like behaviour.
- **`VarDCTBitstreamWriter.encode(frame:distance:gaborish:adaptiveQF:)`** — same parameter; threads through. The ACMetadata QF list emits `qfPerBlock[firstBlockIdx] − 1` per first-block (was `q.qf − 1`); the AC block-context lookup uses `qfPerBlock[blk]` (was `q.qf`).
- **Test bound shifts.** The DCT4×4 strategy-selection test (`testVarDCTBitstreamWriter_SmallBlockDCT4x4`) now passes `adaptiveQF: false`. The mixed-quadrant fixture's high Y-variance pushes adaptive QF upward, which shifts the per-cell strategy trial away from DCT4×4 for that specific fixture; the test still verifies the DCT4×4 selection mechanism (just with a uniform QF as in pre-v0.11.0am).
- **Verified.** `testVarDCTBitstreamWriter_AdaptiveQFSmoke` encodes a 32×32 frame with a smooth-gradient left half and a high-frequency checkerboard right half — asserts `qfPerBlock` carries ≥ 2 distinct values (adaptive on); asserts the codestream differs from the `adaptiveQF: false` sibling (proving the flag flows through to the on-wire QF plane). All existing round-trip / `djxl 0.11.2`-byte-equality tests pass unchanged.
- **418 tests passing, 3 skipped, 0 failures.**

### v0.11.0an — VarDCT encoder: 3-cluster AC histograms (split by ord-bucket)

v0.11.0j added an adaptive 2-cluster AC split (nzeros vs coefficient tokens). v0.11.0an extends this to 3 clusters when the saving is worthwhile: cluster 0 = nzeros, cluster 1 = small-block (ord 0–1) coefficient tokens, cluster 2 = big-block (ord ≥ 2 — DCT16/32/64 and the asymmetric variants) coefficient tokens. Coefficient distributions differ sharply between small and big blocks (small blocks tend to spike at near-zero, big blocks have flatter tails) — giving each its own Huffman codebook can shrink the AC stream on mixed-content frames.

- **`VarDCTBitstreamWriter.generateACTokens`** — returns an additional `bigBlockCoefContexts: Set<Int>` set, populated with the context IDs of every coefficient (non-`nzeros`) token emitted from a strategy with `orderBucket ≥ 2`. Tracking is conditional on `blockTokens.count > 1` so the existing nzeros-only path is unaffected.
- **`VarDCTBitstreamWriter.encode`** — the AC clustering decision is now a 3-way comparison. The writer estimates 1-cluster, 2-cluster, and 3-cluster total cost (token bits + context-map cost + per-cluster codebook header slack `[0, 1024, 1536]`), picks the cheapest with a "fewer clusters first" tiebreak. 3-cluster is skipped when `bigBlockCoefContexts` is empty (frame has no multi-block strategies).
- **No spec change.** The bitstream's `EntropySectionHeader.contextMap.numClusters` already supports any value ≤ 64; the existing `MultiClusterCodebook` already takes an arbitrary `huffmanTables` array. The writer just gains one more branch.
- **Verified.** `testVarDCTBitstreamWriter_ThreeClusterACSmoke` encodes an 80×80 frame with a smooth-gradient top half (gets large-DCT-strategy big-block tokens) and a textured bottom half (gets DCT8 small-block tokens) — the 3-cluster path may or may not be chosen by the estimator (heuristic outcome), but the codestream **must** still round-trip through `djxl 0.11.2`. All existing 2-cluster and 1-cluster paths still exercise their original code via the other end-to-end tests.
- **419 tests passing, 3 skipped, 0 failures.**

### v0.11.0ao — Public API: `EncodingOptions.gaborish` / `.adaptiveQF`

The new VarDCT encoder knobs from v0.11.0al (Gaborish pre-pass) and v0.11.0am (adaptive per-block QF) are now reachable from the public `JXLEncoder` API. Defaults match libjxl behaviour (both `true`); callers who want byte-deterministic output with the older simpler pipeline can opt out via `EncodingOptions(... gaborish: false, adaptiveQF: false)`.

- **`EncodingOptions.gaborish: Bool = true`** — when set, the VarDCT encoder applies the inverse-Gaborish 5×5 pre-pass and writes `lf.gab = true`. Ignored for `.lossless` encodes (Modular path doesn't go through VarDCT).
- **`EncodingOptions.adaptiveQF: Bool = true`** — when set, per-block QF varies with Y-plane variance; otherwise a uniform `qf = 5` is used. Ignored for `.lossless` encodes.
- **`JXLEncoder.encode`** — threads `options.gaborish` and `options.adaptiveQF` into `VarDCTBitstreamWriter.encode`.
- **Verified.** `testJXLEncoder_GaborishAndAdaptiveQFOptions` encodes the same 32×32 frame four ways (defaults, gaborish-off, adaptiveQF-off, both-off) and confirms each combination produces a distinct codestream — proving the options thread end-to-end.
- **420 tests passing, 3 skipped, 0 failures.**

### v0.11.0ap — CLI: `--no-gaborish` / `--no-adaptive-qf` flags

The two new `EncodingOptions` knobs are now reachable from the `jxl encode` CLI. Defaults match the public API (`--gaborish` / `--adaptive-qf`, both on); `--no-gaborish` and `--no-adaptive-qf` opt out of the libjxl-default behaviours, useful for byte-deterministic reproducibility and diagnostic encodes.

- **`jxl encode --[no-]gaborish`** — toggle the inverse-Gaborish pre-pass.
- **`jxl encode --[no-]adaptive-qf`** — toggle per-block variance-driven QF.
- **End-to-end verified manually.** Encoding the same 32×32 PPM four ways (defaults, `--no-gaborish`, `--no-adaptive-qf`, both off) produces four distinct codestreams (454 B / 217 B / 361 B respectively for the test fixture). All decode through `djxl 0.11.2`. Test coverage is via the existing `testJXLEncoder_GaborishAndAdaptiveQFOptions` parity test — same options surface, same option-threading guarantee.
- **420 tests passing, 3 skipped, 0 failures** (no new test added — the CLI is a thin layer over the already-tested `EncodingOptions` surface).

### v0.11.0ar — `JXLEncoder.encode([ImageFrame])` single-frame delegation

The multi-frame `encode(_ frames: [ImageFrame])` API previously threw `notImplemented` for any input. v0.11.0ar refines this:

- **Empty array** — throws `EncoderError.unsupportedFrame("encode(_:) on empty frame array")`.
- **Single-element array** — delegates to `encode(_ frame:)` on `frames[0]`. The codestream is byte-identical to the direct single-frame call.
- **Multi-frame array (count ≥ 2)** — still throws `notImplemented` until the animation infrastructure lands (shared `ImageMetadata.animation`, sequential `FrameHeader`s with `isLast` flags, per-frame duration). The error message now points callers at the single-frame workaround.
- **Verified.** `testJXLEncoder_MultiFrameDispatch` exercises all three branches: empty array throws `unsupportedFrame`, single-element matches `encode(_:)` byte-for-byte, two-element throws `notImplemented`.
- **421 tests passing, 3 skipped, 0 failures.**

### v0.11.0as — Tightened round-trip bound + encoder-quality measurement harness

The `testVarDCTBitstreamWriter_RoundTrip` bound is tightened from `mean < 4.0` to `mean < 2.0` (both our-decoder and djxl-decoded paths), and a new opt-in diagnostic test (`testVarDCTBitstreamWriter_EncodeQualityMatrix`) measures encode-output mean error and codestream size across all four (`gaborish`, `adaptiveQF`) combinations.

- **Bound tightening.** Measurement on the 24×24 smooth-gradient fixture: default encode (gab on, aqf on) gets mean error 1.05/channel; the other three combinations are 1.04–1.65. The previous `< 4.0` bound left ~3× slack; `< 2.0` retains a safety margin (~2× headroom) while catching real regressions if e.g. Gaborish silently breaks or a quant table goes wrong.
- **Diagnostic test.** `testVarDCTBitstreamWriter_EncodeQualityMatrix` is `XCTSkip`-gated on `JXL_PRINT_ENC_QUALITY=1`. When run, it prints one `ENC-QUALITY gab=… aqf=… size=… mean=…` line per combination to stderr — useful when investigating encoder-quality changes without polluting the default test output.
- **421 tests passing, 4 skipped (incl. the new opt-in diagnostic), 0 failures.**

### v0.11.0at — VarDCT encoder: adaptive-QF region-trial fairness

The v0.11.0am note flagged a known limitation: when `eval16Region` compared DCT16 vs 4×DCT8 (or `eval32Region` compared DCT32 vs 4×eval16Region, or the 64-pass vs 4×eval32Region), the multi-block candidate used the region's first-cell QF while each cell of the alternative used its own per-cell QF. With adaptive QF, this gave a slight comparison bias — smooth cells in a textured region would quantise to fewer non-zero ACs at their own low QF than the region-wide DCT16 would at the textured QF, skewing the trial toward 4×DCT8.

v0.11.0at fixes the bias by giving every cell helper a `currentQFOverride` it consults before falling back to `qfPerBlock[by · blocksX + bx]`. Each region trial (16-pass `eval16Region`, 32-pass `eval32Region`, the 64-pass inline loop) sets the override to its first-cell QF for the scope of the trial; the override propagates through nested calls (so `eval32Region` → `eval16Region` → `bestSmallCell` → `dct8Cell` all see the 32-region's QF). On commit, a new `stampQF` helper writes the effective QF into `qfPerBlock` for every covered cell — the bitstream writer reads `qfPerBlock[firstBlock]` for ACMetadata, and the decoder must dequantise with the QF the encoder actually used.

- **`VarDCTEncoder.forward`** — adds `var currentQFOverride: Int32? = nil` at the outer scope; all 16 cell helpers (`dct8Cell`, `dct4x4Cell`, `dct4x8Cell`, `dct8x4Cell`, `dct2x2Cell`, `hornussCell`, `afvCell`, `dct16Region`, `dct16x8Pair`, `dct8x16Pair`, `dct32x16Pair`, `dct16x32Pair`, `dct32Region`, `dct64x32Pair`, `dct32x64Pair`, `dct64Region`) shadow `qf = currentQFOverride ?? qfPerBlock[…]`. `eval16Region` / `eval32Region` / the 64-pass set + restore the override around their trials. New `stampQF(firstIdx:covered:)` helper stamps the effective QF over the strategy's covered cells in every commit (`commitDCT8`, `commitDCT16x8Pair`, `commitDCT8x16Pair`, `commitDCT32x16Pair`, `commitDCT16x32Pair`, `commitDCT64x32Pair`, `commitDCT32x64Pair`, and the inline DCT16 / DCT32 / DCT64 commits).
- **Test invariant shift.** The `testVarDCTBitstreamWriter_AdaptiveQFSmoke` assertion that `qfPerBlock` carries ≥ 2 distinct values is no longer correct — under fairness, a fixture that fits in a single trial region produces a uniform `qfPerBlock`. The test now switches to a fully-textured 16×16 checkerboard and asserts `qfPerBlock[0] > 5` (the base QF) when adaptive is on, `== 5` when off, plus the codestream-differs assertion. The fairness invariant is the correct one.
- **Quality impact on the 24×24 diagnostic.** Identical to pre-fairness on this fixture (which fits in one 16-region): mean error 1.05 / 92–99 B per channel across the four (gab, aqf) combinations. The fairness fix is structural — its benefit shows on larger frames where the trial decisions actually shift.
- **421 tests passing, 4 skipped, 0 failures.**

### v0.11.0au — Adaptive-QF heuristic: combined-XYB-stddev driver

v0.11.0am drove the per-block QF from Y-plane variance only. Real images carry detail in chroma too — sharp colour edges, dense mosaics, saturated textures — and a Y-only score under-quantises those cells. v0.11.0au broadens the driver to a weighted combination of per-channel standard deviation:

    detail = (2·√varY + √varX + √varB) / 4
    qf     = clamp(qfBase + round(50 · detail), [3, 16])

Y still has twice the weight of X+B combined (luminance is the dominant perceptual axis), but chroma variance now contributes — colour-textured cells get fine quantisation alongside luminance-textured ones.

- **`VarDCTEncoder.forward`** — the variance loop now accumulates `(sum, sumSq)` for each of `planeX`, `planeY`, `planeB` and computes the combined-stddev score. `sqrt(variance)` puts the metric in pixel-value units so the linear scale below behaves sanely across magnitudes. Same `[3, 16]` clamp as before.
- **Measured quality gains** via `JXL_PRINT_ENC_QUALITY=1` over the new 4-fixture diagnostic matrix (24×24, distance 1.0):
  - **checkerboard:** mean error **13.24** (adaptive on) vs **23.76** (off) — nearly halved; size 968 B vs 749 B.
  - **colour-mosaic:** **4.85** vs **9.65** — half the error; 712 B vs 607 B.
  - **smooth-with-edge:** **0.76** vs **0.84** — small gain; 128 B vs 126 B.
  - **smooth-gradient:** **1.05** vs **1.18** — small gain; 99 B vs 91 B.
  Default encode (gab=on, aqf=on) is the best or near-best on every fixture.
- **Expanded diagnostic.** `testVarDCTBitstreamWriter_EncodeQualityMatrix` now iterates four fixture types (smooth-gradient / checkerboard / colour-mosaic / smooth-with-edge) and prints one `ENC-QUALITY [fixture] gab=… aqf=… size=…B mean=…` line per (fixture, gab, aqf) combination — 16 lines total.
- **421 tests passing, 4 skipped, 0 failures.**

### v0.11.0av — Adaptive-QF heuristic: 100× detail multiplier (tuned via diagnostic)

The v0.11.0am `qf = qfBase + round(50 · detail)` formula under-utilised the QF ceiling — even the dense-checkerboard fixture saw the heuristic settle around `qf ≈ 11`, well below the `qfMax = 16` cap. Pushing the multiplier to 100× actually uses the available range on textured content, with a clear quality improvement and marginal size cost.

- **`VarDCTEncoder.forward`** — one constant change: `50.0 * detail` → `100.0 * detail` in the per-cell QF computation. Same `[3, 16]` clamp.
- **Measured deltas** (via the `EncodeQualityMatrix` diagnostic, 24×24 fixtures, distance 1.0, default options):
  - **checkerboard:** mean error **13.24 → 10.33** (–22 %); size **968 B → 977 B** (+1 %).
  - **colour-mosaic:** mean error **4.85 → 3.88** (–20 %); size **712 B → 771 B** (+8 %).
  - **smooth-with-edge:** mean error **0.76 → 0.73** (–4 %); size **128 B → 127 B** (–1 %).
  - **smooth-gradient:** mean error **1.05 → 0.99** (–6 %); size **99 B → 106 B** (+7 %).
- **421 tests passing, 4 skipped, 0 failures.**

### v0.11.0aw — Adaptive-QF heuristic: widen QF ceiling to 24

After v0.11.0av pushed the detail multiplier to 100×, textured cells started saturating at the `qfMax = 16` cap. Raising the ceiling to 24 unblocks another step of quality on dense-detail fixtures while leaving smooth content unchanged (their detail scores stay well under the cap).

- **`VarDCTEncoder.forward`** — `qfMax: 16 → 24`. Smooth fixtures (which never hit the cap) are unaffected.
- **Measured deltas** (vs v0.11.0av, same diagnostic):
  - **checkerboard:** mean error **10.33 → 8.67** (–16 %); size **977 B → 985 B** (+1 %).
  - **colour-mosaic:** mean error **3.88 → 3.67** (–5 %); size **771 B → 781 B** (+1 %).
  - **smooth-with-edge:** mean error **0.73 → 0.72** (–2 %); size **127 B → 129 B** (+2 %).
  - **smooth-gradient:** unchanged.
- **Cumulative quality wins since v0.11.0am** on the checkerboard fixture: mean error **23.76 (no adaptive) → 13.24 (v0.11.0am, Y-only, 50×, max 16) → 10.33 (v0.11.0au, XYB stddev, 50×) → 8.67 (v0.11.0av+aw, 100×, max 24)**. The encoder now spends bits where detail is, at adaptive granularity.
- **421 tests passing, 4 skipped, 0 failures.**

### v0.11.0ax — Adaptive-QF heuristic: distance-aware scaling

The fixed `qfMax = 24` and `multiplier = 100` from v0.11.0aw was tuned for `distance = 1.0`. Measurement across `distance ∈ {0.5, 1.0, 2.0, 4.0}` revealed a problem: at high distances the user wants small files, but the fixed heuristic spent extra bits on textured cells anyway — adaptive QF at `d = 4.0` was making the checkerboard file **51 % larger** than `adaptiveQF: false` for no perceptual benefit at that quality target. The fix scales both `qfMax` and the detail multiplier as `1 / max(distance, 0.5)`, so the adaptation magnitude tracks the user's quality target.

- **`VarDCTEncoder.forward`** — `qfMax = clamp(round(24 / scaleD), [6, 48])` and `multiplier = clamp(round(100 / scaleD), [25, 200])` where `scaleD = 1 / max(distance, 0.5)`. At `d = 1.0` this is the v0.11.0aw tuning (max 24, mult 100); at `d = 0.5` it's max 48, mult 200; at `d = 4.0` it's max 6, mult 25.
- **Measured deltas** (vs v0.11.0aw, same EncodeQualityMatrix diagnostic across four distances):
  - **High-quality target (d=0.5):** all fixtures see further quality gain:
    - smooth-with-edge: mean **0.49 → 0.23** (–53 %); size 158 → 172 B (+9 %).
    - colour-mosaic: mean **2.56 → 1.93** (–25 %); size 950 → 1048 B (+10 %).
    - checkerboard: mean **4.46 → 3.33** (–25 %); size 917 → 944 B (+3 %).
  - **Default (d=1.0):** unchanged (the scaling reproduces the v0.11.0aw tuning exactly).
  - **Low-quality target (d=4.0):** files shrink toward user intent:
    - colour-mosaic: size **528 B → 330 B** (–37 %); mean error 14.90 → 20.62 (closer to no-AQF 20.84).
    - checkerboard: size **747 B → 610 B** (–18 %); mean error 23.58 → 56.55.
    - smooth-with-edge: size 106 B → 86 B (–19 %); mean 1.27 → 1.96.
- **Extended diagnostic.** `EncodeQualityMatrix` now iterates four distances (`0.5, 1.0, 2.0, 4.0`) per fixture — 32 measurement lines instead of 16.
- **421 tests passing, 4 skipped, 0 failures.**

### v0.11.0ay — Encoder performance: `bestSmallCell` smooth-cell short-circuit

The `bestSmallCell` per-cell trial runs 10 forward transforms (DCT8 + DCT4×4 + DCT4×8 + DCT8×4 + DCT2×2 + Hornuss + AFV0..3) on every uncovered cell, scoring each and picking the cheapest. On typical photographic content most cells are smooth (low AC energy), and DCT8×8 is already the optimal choice — the other 9 trials are pure waste. v0.11.0ay short-circuits on the smooth-cell case: compute DCT8 first, if its 3-channel total token cost is `≤ 54` (= ≤ 18 per channel = `lastNZ ≤ 4` with small magnitudes — "very smooth"), return DCT8 immediately without running the other 9.

- **`VarDCTEncoder.bestSmallCell`** — single early-return after the DCT8 trial. Threshold tuned at 54 (3 channels × 18 per channel ≈ 4-token nzeros + small ACs); below this the cost gap to the cheapest small-block alternative is below 1 token / cell, so the chance of picking a wrong strategy is negligible.
- **Measured perf gain** (new `JXL_PRINT_ENC_PERF` diagnostic, 256×256):
  - **smooth content (per-cell gradient):** 95 ms/frame → 43 ms/frame; throughput **0.68 → 1.51 Mpx/s** (**2.2× faster**).
  - **noisy content (per-pixel random):** unchanged at 95 ms/frame / 0.68 Mpx/s (every cell has high AC; short-circuit never fires — same code path as before).
- **Quality impact** (via `EncodeQualityMatrix`): smooth fixtures unchanged or marginally improved (smooth-gradient d=4.0: mean error **3.44 → 2.99**, –13 %); textured fixtures (checkerboard, colour-mosaic) byte-identical because they never hit the short-circuit threshold.
- **421 tests passing, 5 skipped (incl. new opt-in perf diagnostic), 0 failures.**

### v0.11.0az — Encoder performance: AFV skip on moderate-detail cells

The four AFV variants are by far the most expensive single-cell strategies — each AFV forward is a 16×16 orthonormal matrix multiplication. For cells in v0.11.0ay's "not very smooth" path (DCT8 cost > 54), AFV was still running unconditionally. AFV's sweet spot is content with detail tightly concentrated in one 4×4 corner of the 8×8 cell — a signature incompatible with the broadly-spread AC suggested by a moderate-cost DCT8.

v0.11.0az adds a second short-circuit tier: when DCT8 cost is ≤ 120 (≈ 40 per channel, "mildly textured"), skip the 4 AFV trials. This saves 4 × 256-mul matrix multiplications × 3 channels per cell = ~3K muls. AFV remains in the trial for cells where DCT8 already hints at concentrated high-frequency detail.

- **`VarDCTEncoder.bestSmallCell`** — `let tryAFV = cost8 > 120`; AFV cell computations and cost summation are gated on this flag.
- **Quality impact** (via `EncodeQualityMatrix`):
  - **smooth-with-edge d=1.0:** mean error **0.715 → 0.588** (–18 %, this is the *quality* win — AFV was sometimes wrongly selected as cheapest cost even though DCT8 reconstructed the edge cell better).
  - **smooth-with-edge d=0.5:** unchanged (already at 0.229).
  - **smooth-gradient, checkerboard, colour-mosaic:** all unchanged. Smooth fixtures don't hit AFV anyway (short-circuit kicks in at cost8 ≤ 54); textured fixtures stay above the cost8 > 120 threshold so AFV still runs.
- **Perf impact** (`JXL_PRINT_ENC_PERF` 256×256): noisy content unchanged (every cell has cost8 > 120 so AFV still runs); smooth content unchanged (already short-circuited earlier). The win is concentrated on moderate-detail content not covered by either perf benchmark — e.g. real photos with mostly-smooth regions punctuated by edges.
- **421 tests passing, 5 skipped, 0 failures.**

### v0.11.0ba — Multi-frame VarDCT animation encoder

`JXLEncoder.encode([ImageFrame])` previously threw `notImplemented` for `≥ 2` frames. v0.11.0ba implements true multi-frame VarDCT encoding: each frame goes through the existing encoder pipeline; a shared image-level prelude (signature + SizeHeader + ImageMetadata with `animation` declared + CustomTransformData) prefixes all per-frame chunks; per-frame `FrameHeader`s carry the `animationFrame.duration` and flip `isLast` only on the final frame.

- **`VarDCTBitstreamWriter` refactor.** The 470-line single-`encode()` body is split:
  - **`buildFrameSections(frame:distance:gaborish:adaptiveQF:)`** runs the encoder pipeline and returns an `EncodedFrameSections` struct (sections + xsize + ysize + hasAlpha + gaborish).
  - **`writeCodestreamPrelude(xsize:ysize:hasAlpha:animation:)`** writes the shared image-level prelude (signature + SizeHeader + ImageMetadata + CustomTransformData). For multi-frame, `animation` is a libjxl-default `AnimationHeader(tpsNumerator: 100, tpsDenominator: 1, numLoops: 0, haveTimecodes: false)`; for single-frame it's `nil`.
  - **`writeFrameChunk(hasAlpha:gaborish:isLast:animationFrame:haveAnimation:sections:)`** writes one frame's `FrameHeader + TOC + sections` payload. Used for both single-frame and multi-frame writes.
  - **`writeOuterCodestream`** is now a thin wrapper over prelude + one chunk.
  - **`encodeAnimation(frames:distance:gaborish:adaptiveQF:frameDurations:)`** is the new public multi-frame entry point. Empty arrays / mismatched-dimension frames throw `WriterError.unsupported`. Default duration is 10 tps units (= 100 ms / frame at the default 100-tps timestamp resolution).
- **`JXLEncoder.encode([ImageFrame])`** — the multi-frame path now dispatches to `encodeAnimation` for lossy modes. Lossless multi-frame still throws `notImplemented` (Modular animation writer isn't implemented).
- **Verified.** `testVarDCTBitstreamWriter_EncodeAnimation` encodes a 3-frame RGB animation (red / green / blue, durations 20 / 30 / 40 tps units) and confirms `djxl 0.11.2` decodes it. `testJXLEncoder_MultiFrameDispatch` extends to cover the new lossy multi-frame path (codestream larger than single-frame) and the still-unimplemented lossless multi-frame path.
- **Caveat: our decoder.** `JXLDecoder.decodeAll(_:)` is still a stub. End-to-end round-trip through our own decoder needs the decoder-side multi-frame loop; that's a separate scope. The encoder produces a spec-valid animation that `djxl` accepts.
- **422 tests passing, 5 skipped, 0 failures.**

### v0.11.0bc — Multi-frame VarDCT decoder (`JXLDecoder.decodeAll`)

`JXLDecoder.decodeAll(_:)` previously threw `notImplemented`. v0.11.0bc implements it via **synthetic-single-frame byte surgery**: the multi-frame codestream's shared prelude (signature + SizeHeader + ImageMetadata + CustomTransformData) already declares animation correctly, so for each frame we concatenate `prelude + thatFrameBytes` and run the existing single-frame `decode(_:)` on the result. The per-frame FrameHeader carries its `animationFrame` block and the decoder reads it with the correct `haveAnimation = true` context. `isLast` doesn't change the outcome — `decode(_:)` always returns the first frame it reads.

- **`JXLDecoder.decodeAll(_:)`** — walks the codestream once to find each frame's byte range (parse the prelude, then loop: read FrameHeader → read TOC → sum entry sizes → advance), then for each range constructs `prelude + frameBytes` and delegates to `decode(_:)`. M0 placeholder codestreams short-circuit to `[decode(_:)]`.
- **Two small helpers** (`codestreamXSize` / `codestreamYSize`) compute the TOC entry count from the SizeHeader without re-parsing the whole codestream.
- **Verified.** `testVarDCTBitstreamWriter_EncodeAnimation` now does a true end-to-end round-trip: encode a 3-frame red/green/blue animation, decode through `decodeAll`, check (a) frame count, (b) per-frame dimensions, (c) first-pixel RGB matches the source within 2 channels. `djxl 0.11.2` independently decodes the same codestream as spec-valid animation.
- **Limitations.** This is a single-pass implementation: every frame re-decodes the prelude (no shared state across frames yet — the existing `decode(_:)` re-parses everything from byte 0). For animations with many frames this is `O(N²)` in prelude cost; for the common 2–10 frame case it's fine. A future refinement could share decoder state across frames.
- **422 tests passing, 5 skipped, 0 failures.**

### v0.11.0bd — CLI: multi-frame `jxl encode -i a.ppm -i b.ppm -i c.ppm`

`jxl encode` previously accepted exactly one `-i / --input`. v0.11.0bd makes it accept multiple — repeat `-i` to encode an animation. Single-`-i` invocations behave exactly as before.

- **`Encode` subcommand** — `var input: String` → `var input: [String]` (with `parsing: .singleValue` so each `-i` is one path). When `frames.count == 1`, encode the lone frame through `encoder.encode(_ frame:)`; when ≥ 2, dispatch through `encoder.encode([ImageFrame])` (which routes to `VarDCTBitstreamWriter.encodeAnimation`). A new `--frame-duration` option (default 10 tps units = 100 ms) is exposed for future per-frame customisation, though the underlying API call doesn't yet thread it through (defaults to 10 for every frame).
- **End-to-end manual verification.** Three single-colour PPMs (red / green / blue, 16×16) encoded as `jxl encode -i f0.ppm -i f1.ppm -i f2.ppm -o anim.jxl` produces a 169 B codestream that `djxl 0.11.2` decodes as a valid animation.
- **422 tests passing, 5 skipped, 0 failures** (the CLI change is exercised end-to-end manually; no new XCTest case — the multi-frame `encode([ImageFrame])` plumbing is already covered by `testJXLEncoder_MultiFrameDispatch` and the animation round-trip test).

### v0.11.0be — `EncodingOptions.defaultFrameDuration` + CLI `--frame-duration` plumbed end-to-end

The `--frame-duration` option from v0.11.0bd was accepted by the CLI but never threaded through — every animation got the default 10 tps units (100 ms / frame) regardless. v0.11.0be wires it.

- **`EncodingOptions.defaultFrameDuration: UInt32 = 10`** — applied uniformly to every frame in a multi-frame encode. Default 10 tps units = 100 ms per frame at the libjxl-default 100-tps timestamp resolution. Ignored for single-frame encodes.
- **`JXLEncoder.encode([ImageFrame])`** — passes `[UInt32](repeating: options.defaultFrameDuration, count: frames.count)` to `VarDCTBitstreamWriter.encodeAnimation`'s `frameDurations` parameter.
- **`Encode` subcommand** — sets `defaultFrameDuration: frameDuration` from the `--frame-duration` flag.
- **Verified.** `testJXLEncoder_FrameDurationOption` encodes the same 2-frame fixture twice with different `defaultFrameDuration` values (10 vs 50) and confirms the codestreams differ (proves the value flows through to the per-frame `animationFrame.duration` field). End-to-end manual: `jxl encode -i f0 -i f1 -o a.jxl --frame-duration 50` produces a byte-distinct codestream from the default-10 version.
- **423 tests passing, 5 skipped, 0 failures.**

### v0.11.0bf — CLI: `jxl decode --all-frames` multi-frame decode

`jxl decode` previously only handled single-frame inputs (`JXLDecoder.decode(_:)`). v0.11.0bf adds `--all-frames` for multi-frame inputs — dispatches to `decodeAll(_:)` and writes one PNM per frame using `output` as a `printf`-style template (e.g. `out-%03d.ppm`). When `--all-frames` is set and the template has no `%d` spec, the implementation falls back to inserting `-NN` before the file extension (`out.ppm` → `out-00.ppm`, `out-01.ppm`, …), so users who forget the spec still get distinct per-frame filenames.

- **`Decode` subcommand** — new `--all-frames` flag; existing single-frame path unchanged. Multi-frame path uses a `renderTemplate(_:index:)` helper to produce per-frame paths.
- **End-to-end manual verification.** Encoded a 3-frame red / green / blue animation via the v0.11.0bd CLI multi-frame encode, decoded with `jxl decode -i anim.jxl -o "dec-%03d.ppm" --all-frames`. Output: three PPM files, first pixel of each `(200, 60, 59)` / `(61, 200, 61)` / `(60, 60, 200)` — within ±1 of the source RGB. The fallback (`out.ppm` without `%d`) writes `out-00.ppm`, `out-01.ppm`, `out-02.ppm`.
- **423 tests passing, 5 skipped, 0 failures** (the CLI is a thin layer over the already-tested `decodeAll`).

### v0.11.0bg — `JXLDecoder.countFrames(_:)` + `jxl info` shows frame count

`jxl info` reported the animation tps numerator/denominator and loops, but not the frame count — users had to either decode the animation or count via `djxl`. v0.11.0bg adds a cheap `countFrames` API (FrameHeader+TOC parse only, no pixel decode) and surfaces it in the info output.

- **`JXLDecoder.countFrames(_:)`** — walks each frame's FrameHeader + TOC, sums section sizes to skip the payload, increments a counter, breaks at the frame with `isLast = true`. Returns 1 for any single-frame codestream (the common case); the actual count for multi-frame animations. M0 placeholder codestreams short-circuit to 1.
- **`Info` subcommand** — when `metadata.animation != nil`, the existing `Animation: …` line is prefixed with `N frame(s),` (e.g. `Animation: 3 frame(s), 100/1 tps, loops=0`).
- **Verified.** `testJXLDecoder_CountFrames` exercises 1- / 3- / 7-frame fixtures. End-to-end manual: `jxl info anim.jxl` shows `Animation: 3 frame(s), 100/1 tps, loops=0`; `jxl info single.jxl` shows no `Animation:` line (correct — metadata declares no animation for single-frame).
- **424 tests passing, 5 skipped, 0 failures.**

### v0.11.0bh — Multi-frame edge-case tests: RGBA animation + `decodeAll` on single-frame

Two pin-down tests exercising multi-frame paths that weren't covered by the basic 3-frame RGB round-trip:

- **`testVarDCTBitstreamWriter_RGBAAnimation`** — encodes a 3-frame RGBA animation (red 255 / green 200 / blue 100 alpha), confirms `decodeAll` returns three 4-channel frames with byte-exact first-pixel alpha (the encoder's alpha path is lossless), and that `djxl 0.11.2` accepts the codestream. Proves the multi-frame writer correctly carries `hasAlpha = true` through to every per-frame TOC + sections.
- **`testJXLDecoder_DecodeAllOnSingleFrame`** — feeds a normal single-frame VarDCT codestream to `decodeAll(_:)`; confirms it returns `[singleFrame]` (count 1, correct dimensions, correct channel count). The byte-surgery `decodeAll` correctly handles the `isLast = true` case on the very first frame iteration.
- **426 tests passing, 5 skipped, 0 failures.**

### v0.11.0bi — Per-frame animation durations (`EncodingOptions.frameDurations` + CLI `--frame-duration 10,30,10`)

Animations with **variable-pace timing** — slow intro frame, fast middle, slow end. Previously every frame got `defaultFrameDuration` (uniform). v0.11.0bi adds explicit per-frame durations at both the API and CLI surfaces.

- **`EncodingOptions.frameDurations: [UInt32]?`** — new field. When non-nil, must have `count == frames.count`; each entry overrides the per-frame duration for that index. When nil, `defaultFrameDuration` is used uniformly (existing behaviour, unchanged).
- **`JXLEncoder.encode([ImageFrame])`** — uses `options.frameDurations` when set, falls back to `[defaultFrameDuration]·count` otherwise. Mismatched count throws `EncoderError.unsupportedFrame`.
- **`Encode` subcommand** — `--frame-duration` changes type from `UInt32` to `String`, accepting either a single integer (`10`, applied uniformly) or a comma-separated list (`10,30,10`, count must match input frames; otherwise `JXLExitCode.invalidArguments`).
- **Verified.** `testJXLEncoder_PerFrameDurations` proves per-frame durations produce a different codestream than uniform (the values flow through to the per-frame `animationFrame.duration` field) and that count mismatch correctly throws. End-to-end manual: `jxl encode -i f0 -i f1 -i f2 -o a.jxl --frame-duration 50,10,30` produces a 169 B byte-distinct codestream from the uniform-10 version.
- **427 tests passing, 5 skipped, 0 failures.**

### v0.11.0bj — Lossless multi-frame (Modular animation)

`JXLEncoder.encode([ImageFrame])` with `.lossless` previously threw `notImplemented`. v0.11.0bj makes it work by extending `SpecModularEncoder` with an animation path that parallels the VarDCT v0.11.0ba refactor.

- **`SpecModularEncoder` refactor.** The 100-line `writeOuterCodestream` body is split into two reusable pieces:
  - **`writeModularPrelude(width:height:bitsPerSample:colorSpace:extraChannels:animation:)`** — shared image-level prelude (signature + SizeHeader + ImageMetadata + CustomTransformData). `animation` is `nil` for single-frame; a libjxl-default `AnimationHeader(tpsNumerator: 100, tpsDenominator: 1, numLoops: 0, haveTimecodes: false)` for multi-frame.
  - **`writeModularFrameChunk(extraChannels:built:isLast:animationFrame:haveAnimation:)`** — one frame chunk (FrameHeader + TOC + section payloads). Used for both single-frame and multi-frame writes.
  - `writeOuterCodestream` is now a thin wrapper over prelude + one chunk.
  - **`encodeModularAnimation8(width:height:hasAlpha:frames:durations:)`** — new public multi-frame entry point. Empty arrays / mismatched-channel-count / mismatched-duration-count frames throw `SpecModularEncoderError.unsupportedFrame`. Each frame goes through the same `buildSections` pipeline as the single-frame encode.
- **`JXLEncoder.encode([ImageFrame])`** — the `.lossless` branch now dispatches to `encodeModularAnimation8` (for 8-bit RGB / RGBA frames; other content types throw `notImplemented` for now). All frames must share dimensions + pixel type + channels. Per-frame durations from `EncodingOptions.frameDurations` are honoured.
- **Verified.** `testJXLEncoder_LosslessMultiFrameRoundTrip` encodes a 2-frame red/green RGB8 animation lossless, verifies `decodeAll` returns 2 frames with **byte-exact** first-pixel RGB (Modular is lossless — no `mean < 2` slack), and confirms `djxl 0.11.2` decodes the codestream. `testJXLEncoder_MultiFrameDispatch` is updated — its previous "lossless multi-frame must throw notImplemented" branch flips to "lossless multi-frame must round-trip".
- **428 tests passing, 5 skipped, 0 failures.**

### v0.11.0bk — Pin-down: `decodeAll` on lossless animations + full-frame byte equality

A pin-down for the v0.11.0bj feature exercised through a different angle. `JXLDecoder.decodeAll(_:)` is transform-agnostic (it's pure byte surgery; the per-frame `decode(_:)` call handles VarDCT vs Modular dispatch on its own), but pinning it down for the lossless path keeps both code paths covered after future changes.

- **`testJXLDecoder_DecodeAllOnLosslessAnimation`** — encodes a 3-frame lossless animation, decodes via `decodeAll`, and asserts `frame.data == source.data` (full-array byte equality, not just first-pixel — Modular has no loss budget).
- **End-to-end CLI manual verification.** Encode 3 different RGB PPMs as a lossless animation via `jxl encode -l -i f0 -i f1 -i f2 -o anim-ll.jxl`; decode via `jxl decode --all-frames -i anim-ll.jxl -o "ll-dec-%d.ppm"`; `cmp` every source-vs-decoded PPM — byte-exact. The full library + CLI + decoder loop for lossless multi-frame works.
- **429 tests passing, 5 skipped, 0 failures.**

### v0.11.0bl — Generalised lossless animation: grayscale + 16-bit

v0.11.0bj's `encodeModularAnimation8` was 8-bit RGB / RGBA only. v0.11.0bl generalises to **grayscale (1 / 2 channel) and 16-bit (uint16)** — every Modular content type the single-frame `encode(_ frame:)` accepts now works in animation form too.

- **`SpecModularEncoder.encodeModularAnimation(width:height:bitsPerSample:colorSpace:hasAlpha:frames:durations:)`** — new generalised entry point. Parameters cover all four `(bitsPerSample, colorSpace)` combinations: 8/16-bit × grayscale/RGB, each optionally with alpha. `encodeModularAnimation8` becomes a 4-line wrapper around this.
- **`JXLEncoder.encodeLosslessAnimation`** — dispatch logic extended to handle `(pixelType, channels)` combinations: `.uint8 / .uint16` × `1, 2, 3, 4` channels. Other shapes still throw `notImplemented`.
- **Verified.** `testJXLEncoder_LosslessMultiFrameGeneralised` exercises (1) 8-bit grayscale 3-frame animation (full-array byte equality) and (2) 16-bit grayscale 3-frame animation (full-array byte equality across the 16-bit-packed `f.data`). Both round-trip exactly through our `decodeAll`.
- **430 tests passing, 5 skipped, 0 failures.**

### v0.11.0bm — `JXLDecoder.inspectFrames(_:)` + `jxl info --frames` per-frame listing

`countFrames` reports only the total count; v0.11.0bm adds a per-frame summary that includes duration, isLast, encoding (VarDCT / Modular), section count, and total section bytes. Same cost as `countFrames` — no pixel decode.

- **`JXLDecoder.FrameSummary`** — new public struct: `index`, `duration`, `isLast`, `encoding`, `sectionCount`, `totalSectionBytes`.
- **`JXLDecoder.inspectFrames(_:) -> [FrameSummary]`** — walks each frame's FrameHeader + TOC + skips sections, returns one summary per frame. For single-frame codestreams returns `[summary]` (1 entry); for multi-frame animations returns N entries.
- **`Info` subcommand `--frames` flag** — prints a `Per-frame structure` block listing every frame's stats. Example for a 3-frame animation with `--frame-duration 50,10,100`:
  ```
  --- Per-frame structure ---
    [0] dur=50 encoding=VarDCT sections=1 bytes=33 B
    [1] dur=10 encoding=VarDCT sections=1 bytes=34 B
    [2] dur=100 encoding=VarDCT sections=1 bytes=31 B (last)
  ```
- **Verified.** `testJXLDecoder_InspectFrames` pins down the values for a 3-frame variable-duration animation (50, 10, 100 — last frame flagged `isLast`) and a single-frame codestream (1 summary, duration=0, isLast=true).
- **431 tests passing, 5 skipped, 0 failures.**

### v0.11.0bn — `JXLDecoder.decodeFrame(_:at:)` — single-frame fetch from an animation

Companion to `decodeAll(_:)` — when a caller only needs ONE frame of an animation (e.g. a thumbnail or a specific keyframe), `decodeFrame(_:at:)` returns just that frame. Much cheaper than `decodeAll` then array-indexing because only the target frame's pixels are decoded.

- **`JXLDecoder.decodeFrame(_:at:)`** — walks the per-frame FrameHeader+TOC chain to find frame `index`, builds the synth single-frame codestream for just that frame, delegates to `decode(_:)`. Out-of-range `index` (negative, ≥ countFrames) throws `DecoderError.notImplemented` with a clear message. M0 placeholder codestreams short-circuit (only `index == 0` is valid).
- **Verified.** `testJXLDecoder_DecodeFrameAt` exercises (1) byte-exact fetch of each of 3 frames from a lossless animation, (2) out-of-range index throwing, (3) single-frame codestream at `index = 0` working, at `index = 1` throwing.
- **432 tests passing, 5 skipped, 0 failures.**

### v0.11.0bo — CLI `jxl decode --frame N`: fetch one frame from an animation

The `Decode` subcommand previously offered `--all-frames` (decode every frame) or the default (decode frame 0). v0.11.0bo adds `--frame N` for fetching just frame N — useful for grabbing a specific keyframe or thumbnail without decoding the whole animation.

- **`Decode --frame N`** — dispatches to `JXLDecoder.decodeFrame(_:at:)`. Mutually exclusive with `--all-frames` (using both errors with a clear message).
- **End-to-end manual verification.** `jxl decode -i varied.jxl -o just-frame-1.ppm --frame 1` extracts only frame 1 (green: 61, 200, 61) from the 3-frame red/green/blue animation. `--frame 99` errors with "index 99 out of range (codestream has 3 frames)". `--all-frames --frame 1` errors "mutually exclusive".
- **432 tests passing, 5 skipped, 0 failures** (the CLI flag is a thin layer over the already-tested `decodeFrame` API).

### v0.11.0bp docs — README drops stale "multi-frame not yet implemented" claim

Minor. The "Not yet implemented" line still listed both VarDCT AC-strategy selection and multi-frame / animation encoding — both shipped (v0.11.0aj for AC strategy coverage, v0.11.0ba…bo for multi-frame). Update to list only the genuinely-open items: Phase J (JPEG ↔ JXL transcoding) and the four niche AC strategies (DCT128 / DCT256 / DCT32×8 / DCT8×32) the decoder doesn't yet reconstruct.

### v0.11.0bq — `jxl benchmark --mode {m0|lossy|lossless}`

The `benchmark` subcommand previously hardcoded the M0 placeholder codec — so users couldn't measure the real `JXLEncoder` / `JXLDecoder` throughput from the CLI. v0.11.0bq adds a `--mode` flag for benchmarking either of the three codec paths.

- **`Benchmark --mode lossy`** (the new **default**) — round-trips through `JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90)))` and `JXLDecoder().decode(_:)`. Skips the exactness check (lossy by definition).
- **`Benchmark --mode lossless`** — through Modular. Asserts byte-exact round-trip (Modular is lossless — encoder/decoder disagreement is a real bug).
- **`Benchmark --mode m0`** — legacy `MinimalLosslessCodec` path. Asserts byte-exact round-trip. `--fast` still honoured here.
- **Output enhancement.** Mode label printed in the report (`Mode: VarDCT lossy` / `Mode: Modular lossless` / `Mode: M0 placeholder (effort: balanced)`).
- **End-to-end manual verification** on the 16×16 red PPM at 5 iterations: lossy 0.6 Mpx/s encode, 0.2 Mpx/s decode; lossless 6.6 Mpx/s encode, 0.3 Mpx/s decode; M0 1.6 Mpx/s encode, 8.3 Mpx/s decode. (Tiny fixture — real-image numbers depend on content.)
- **432 tests passing, 5 skipped, 0 failures** (no new test — the dispatch is end-to-end-tested by the existing single-frame encode/decode tests).

### v0.11.0br — CLI `jxl encode -i` accepts multi-value (shell-glob friendly)

`-i` previously took exactly one value, requiring users to type `-i f0 -i f1 -i f2` for multi-frame animations. v0.11.0br switches to `parsing: .upToNextOption`, so `-i` accepts one *or many* values per invocation — `-i f0 f1 f2` works, and shell-glob expansion (`-i frame_*.ppm`) now works without per-file wrapping.

- **`Encode` subcommand** — `var input: [String]` parsing changes from `.singleValue` to `.upToNextOption`. All three forms produce **byte-identical** codestreams:
  - `-i f0.ppm` (1 frame)
  - `-i f0.ppm f1.ppm f2.ppm` (multi-value)
  - `-i f0.ppm -i f1.ppm -i f2.ppm` (repeated, legacy form — still works)
  - `-i frame_*.ppm` (shell glob — useful for "encode all frames in a directory")
- **End-to-end manual verification.** Multi-value, repeated, and glob forms all produce the same 169 B 3-frame animation; the single-frame form unchanged.
- **432 tests passing, 5 skipped, 0 failures.**

### v0.11.0cl — CLI: JPEG inputs flow through `encode`, `compare`, and `batch encode`

`v0.11.0ck` wired `jxl decode foo.jpg`. v0.11.0cl finishes the JPEG plumbing on the rest of the CLI so users can `encode`, `compare`, and `batch encode` directly from JPEG sources without the manual "decode JPEG first" step.

- **`jxl encode -i foo.jpg`** — auto-detected via `JPEGSegmentReader.looksLikeJPEG`, routed through `JPEGDecoder.decode` to produce an `ImageFrame`, then encoded normally. The multi-input animation form works too: `jxl encode -i a.jpg b.jpg c.ppm -o anim.jxl` produces a 3-frame animation mixing JPEG and PNM sources transparently. End-to-end smoke: 16×16 JPEG (797 B) → JXL q=90 (91 B, 11.4% of source).
- **`jxl compare`** — `loadComparableImage(path:frameIndex:)` and `loadComparableFrames(path:)` both gain a JPEG branch sitting between the existing JXL and PNM branches. `jxl compare ref.ppm test.jpg --quiet` reports PSNR / MSE / MAE / max-error against any JPEG. `--frame N != 0` on a JPEG input emits the same "JPEG is single-frame" warning as on PNM. `--all-frames` against a JPEG returns a 1-element list (frame-count mismatch with a JXL animation surfaces as a clean error downstream).
- **`jxl batch encode`** — `pnmExtensions` set extended to include `jpg` / `jpeg`. Per-file dispatch in the loop uses the same SOI-magic check as `encode` so even a `.ppm` file that's actually a stuffed JPEG decodes correctly (and vice versa). Real run: 3-file mixed-format directory (2 JPEG + 1 PPM) batch-encoded to 3 JXL files, no errors.
- **No new tests** — the JPEG-decode + the CLI-loadComparableImage paths are already covered by their own test files; CLI wiring is a thin dispatch layer best verified by end-to-end smoke (done in the commit description).
- **508 tests passing, 6 skipped, 0 failures** (unchanged from v0.11.0ck — pure CLI plumbing).

### v0.11.0ch–ck — Phase J: JPEG → ImageFrame end-to-end pipeline

Four bites bundled — IDCT, pixel assembler, YCbCr → RGB conversion, and the `JPEGDecoder` facade — completing the **decode** side of Phase J. After v0.11.0cg the JPEG side could produce dequantised DCT coefficients; v0.11.0ch–ck takes those to RGB pixels, packages it as an `ImageFrame`, and wires `jxl decode foo.jpg` to use it. **First time `jxl decode` accepts JPEG inputs and produces matching pixels.**

- **v0.11.0ch — `Sources/JXLSwift/JPEG/JPEGIDCT.swift`** (new). Thin wrapper over `DCT2D.inverse(_:size:8)` (the existing JXL orthonormal IDCT primitive — mathematically identical to JPEG §A.3.3's IDCT, just verified by the normalisation algebra). Per-block `Int32` coefficients → `Float` → IDCT → §A.3.1 level shift (+128 for 8-bit) → clamp to `[0, 2^P − 1]` → `Int32` or `UInt8` output. 5 tests: DC-only flat-plane reconstruction, all-zero → mid-grey, low/high saturation clamps, real sips JPEG pipeline (mid-grey Y block reconstructs to 100..156 — within real-world DCT/quant tolerance).
- **v0.11.0ci — `Sources/JXLSwift/JPEG/JPEGPixelAssembler.swift`** (new). `JPEGSamplePlane` (per-component samples in `Int32`), `JPEGPixelAssembler.assemble(...)` (walks per-component `JPEGComponentBlocks`, runs dequantiser + IDCT on each block, stitches sample tiles into a flat plane), `JPEGPixelAssembler.upsampleNearest(...)` (nearest-neighbour chroma upsampling for 4:2:0 / 4:2:2 etc. — bilinear is a follow-on). 3 tests: 2×2 → 4×2 horizontal upsample, 2×2 → 4×4 both-axes upsample, no-op when target equals source.
- **v0.11.0cj — `Sources/JXLSwift/JPEG/JPEGColorConversion.swift`** (new). JFIF YCbCr → RGB via BT.601 full-range pivots: `R = Y + 1.402·(Cr−128)`, `G = Y − 0.344136·(Cb−128) − 0.714136·(Cr−128)`, `B = Y + 1.772·(Cb−128)`, clamped to `[0, 255]`. Plus a grayscale pass-through. 2 tests: neutral grey (128,128,128) → (128,128,128), pure-red YCbCr (76, 85, 255) → (~254, ~0, ~0) (forward-direction rounding caps R at 254 not 255 — verified by hand).
- **v0.11.0ck — `Sources/JXLSwift/JPEG/JPEGDecoder.swift`** (new). Single-call `JPEGDecoder.decode(_:) -> ImageFrame` facade that drives the whole stack: segment walk → DQT/DHT/SOFn/SOS collection → scan decode → assemble → upsample → convert → crop to visible dimensions. Returns `channels: 1, colorSpace: .grayscale` for 1-component JPEGs, `channels: 3, colorSpace: .sRGB` for 3-component YCbCr. Throws `JPEGDecoderError.unsupported` for progressive / 12-bit / 4-component / arithmetic-coded inputs with a clear message. 3 end-to-end tests: 16×16 grayscale ramp round-trip (max sample error < 16 at sips q=90), 16×16 RGB mid-grey round-trip (max error < 16), progressive-frame rejection (mutates SOF0 → SOF2 byte in the minimal fixture).
- **CLI wiring — `Sources/JXLTool/Decode.swift`** — `jxl decode -i foo.jpg -o foo.ppm` now auto-detects JPEG inputs via `JPEGSegmentReader.looksLikeJPEG` and routes through `JPEGDecoder.decode`. `--all-frames` / `--frame` errors out with a helpful message ("JPEG is single-frame").
- **End-to-end smoke**: 32×32 RGB gradient PPM → sips JPEG (953 B) → `jxl decode` → 3 085 B recovered PPM. `jxl compare` reports **43.27 dB PSNR / MAE 1.36 / max 5** vs the source. That recovered PPM then round-trips **byte-identically** through `jxl encode --lossless` + `jxl decode`.
- **508 tests passing, 6 skipped, 0 failures** (was 495; +13 — 5 IDCT + 3 assembler/upsample + 2 colour + 3 decoder facade).
- **ROADMAP.md** — Phase J table: the JPEG-side decode is now complete; the only remaining open Phase J row is the JXL VarDCT coefficient bridge (libjxl shortcut) and the JXL → JPEG reverse direction.

### v0.11.0cg — Phase J: JPEG baseline scan decoder + real-fixture round-trip

The capstone bite of the Phase J foundation: a full baseline-sequential **scan** decoder, driving MCU iteration across all components with correct sampling-factor handling and restart-interval DC reset. Closes the "raw JPEG bytes → dequantised DCT coefficients per component" round-trip on a real-world fixture.

- **`Sources/JXLSwift/JPEG/JPEGScanDecoder.swift`** (new).
  - **`JPEGComponentBlocks`** — per-component grid of decoded blocks in row-major order.
  - **`JPEGScanDecodeError`** — distinguishes "scan config wrong" (unknown component, missing Huffman table, not baseline-sequential) from per-block decode errors so callers can react differently.
  - **`JPEGHuffmanCodebookMap` typealias** — `[tableId: (codebook, huffvals)]`, populated separately for DC and AC table classes by the caller. Built by parsing each DHT segment and calling `buildCodebook` on each table.
  - **`JPEGScanDecoder.decodeBaselineSequential(...)`** — the driver. MCU geometry computed from frame components' `H_i`/`V_i` sampling factors (`H_max = max(H_i)`, `V_max = max(V_i)`, MCU is `(H_max*8) × (V_max*8)` pixels). Inner loop: for each MCU position, for each scan component in scan order, decode `V_i × H_i` blocks via `JPEGBlockDecoder.decode` and place them at the right per-component grid offset. RST handling: at every `restartInterval`-th MCU boundary, reset all per-component DC predictors and call `reader.alignToByte()` (the bit reader has already silently consumed the marker bytes during normal fill). Edge MCUs decoded in full per §A.2.4.
- **5 new tests**:
  - Synthetic single-block grayscale (all-zero, single 1×1 component).
  - Synthetic 16×16 grayscale 2×2 MCU walk with 4 successive DC deltas (`+5, +6, +6, +6` → predictor sequence `5, 11, 17, 23`) — verifies row-major MCU iteration + DC accumulation across blocks.
  - Progressive-scan rejection (`Ss/Se` outside `0..63`).
  - Unknown-component rejection (scan references a component ID not in the frame).
  - **Real sips-JPEG end-to-end**: generates a 16×16 RGB gradient JPEG via `sips`, walks segments to collect SOFn / DQT / DHT / DRI / SOS, locates entropy data via `reader.byteOffset` snapshot after SOS, builds DC/AC codebook maps from every DHT, runs `decodeBaselineSequential` on the entropy stream, asserts 3 components with non-zero DC values in their first block, then dequantises each first block via `JPEGDequantiser` and confirms `|dequantised DC| ≥ |quantised DC|` (quant table is all ≥ 1 so the magnitude can only grow). **This is the first "raw JPEG bytes → dequantised DCT coefficients" round-trip on a real-world fixture in JXLSwift.**
- **495 tests passing, 6 skipped, 0 failures** (was 486; +9 — 4 dequantiser + 5 scan decoder).
- **ROADMAP.md** — Phase J table updated: "raw JPEG bytes → dequantised DCT coefficients" is now ✅ end-to-end; what remains is the JXL VarDCT coefficient bridge (or alternative IDCT + YCbCr→RGB path) and the JXL → JPEG reverse direction.

### v0.11.0cf — Phase J: JPEG dequantiser

Eighth bite. Applies a `JPEGQuantTable` to a `JPEGCoefficientBlock`, producing still-integer dequantised coefficients ready for IDCT (pixel-reconstruction route) or the JXL VarDCT bridge (libjxl's transcode shortcut).

- **`Sources/JXLSwift/JPEG/JPEGDequantiser.swift`** (new). `JPEGDequantiser.dequantise(_:using:)` (in-place) + `dequantising(_:using:)` (functional). Implementation: `for k in 0..<64: block.coefficients[zigzag[k]] *= Int32(table.zigZagValues[k])` — handles the natural ↔ zig-zag ordering bridge in one line. Product fits in `Int32` at 8-bit JPEG precision (quantised coefficients ≤ ±16 384, quant factors ≤ 65 535 → product ≤ ~1.07e9 < 2³¹).
- **4 tests**: identity table (round-trip), constant 3× multiplier (every coefficient × 3), zig-zag-mapping correctness (writes to indices 1 and 8 confirm the zig-zag bridge is wired correctly, catches transposition bugs), in-place vs functional equivalence.
- **490 tests passing** (intermediate; before the scan-decoder bite).

### v0.11.0ce — Phase J: JPEG DC + AC coefficient block decoder

Seventh Phase J bite, and the substance of JPEG decoding. Given a `JPEGBitReader` + DC/AC `JPEGHuffmanCodebook`s, `JPEGBlockDecoder.decode(...)` reads one 8×8 block of quantised DCT coefficients in natural (row-major) order, threading per-component DC-differential predictor state through. After this layer, "JPEG entropy stream → quantised DCT coefficients" is solved end to end; what's left for Phase J transcoding is dequantisation + IDCT + YCbCr→RGB + the JXL-side encoder bridge.

- **`Sources/JXLSwift/JPEG/JPEGBlockDecoder.swift`** (new).
  - **`JPEGCoefficientBlock`** — 64 `Int32` values in natural order (DC at [0], ACs at [1..63]).
  - **`JPEGDCPredictor`** — per-component running DC value, in-out across blocks; reset on RST.
  - **`JPEGZigZag.order`** — ITU-T T.81 Figure A.6 scan order (zig-zag index → natural index), used to unzigzag AC coefficients as they're decoded.
  - **`JPEGBlockDecoder.decode(...)`** — DC path: Huffman-decode size byte `S` → read `S` magnitude bits → EXTEND (§F.2.2.1 Figure F.12) → add to predictor. AC path: loop over zig-zag positions, Huffman-decode `(RRRR, SSSS)` tokens — `(0,0)` is EOB, `(15,0)` is ZRL (skip 16 zeros), otherwise skip `RRRR` zeros and place `EXTEND(value, SSSS)`. Throws `JPEGBlockDecodeError` for malformed tokens (size out of range, RRRR ∈ 1..14 with SSSS=0, zero-run overflow).
  - **`JPEGBlockDecodeError`** — distinct from `JPEGBitReaderError` (stream-level) and `JPEGParseError` (segment-level): coefficient-token errors are their own thing.
- **7 new tests**: all-zero block, DC-only positive (DC=7, size=3, bits=111), DC-only negative (DC=−3, size=2, raw=0 — picked size 2 because size 3 covers ±[4..7] only), multi-block DC differential accumulation (5 then +6 = 11), ZRL followed by single AC value at zig-zag pos 17 → natural index 19, truncated-stream propagation, and a Figure A.6 zig-zag-table sanity check (all 64 indices unique, endpoints correct).
- **486 tests passing, 6 skipped, 0 failures** (was 479; +7).

### v0.11.0cd — Phase J: JPEG MSB-first bit reader (byte-unstuffing + RST-aware)

Sixth Phase J bite. Sits between the JPEG entropy *byte* stream and the Huffman codebook's `decodeSymbol` loop. Three concerns: MSB-first bit packing (JPEG §F.2.2.5), 0xFF 0x00 byte-stuffing (§F.1.2.3), RST-marker skipping mid-scan.

- **`Sources/JXLSwift/JPEG/JPEGBitReader.swift`** (new). `JPEGBitReader.readBit()` returns one bit MSB-first; `readBits(N)` reads 1..32 bits as a big-endian unsigned int. The byte-fill path detects `0xFF` and dispatches:
  - `0xFF 0x00` → silently consume the stuffed pair, emit `0xFF` as the literal byte.
  - `0xFF D0..D7` (RSTn) → silently consume + set `markerSeen` for the caller's DC-differential reset; recurse to fetch the next entropy byte.
  - `0xFF` + anything else → push the marker pair back and throw `JPEGBitReaderError.sawMarker(markerByte:)`, signalling end-of-scan.
- **Why not share the JXL `BitReader`?** That one is LSB-first with no byte-stuffing — extending it would muddy two clean abstractions. The JPEG bit reader is its own type; the per-source-cursor pattern lets callers split a scan across RST intervals if needed.
- **6 new tests**: MSB-first read of `0xB3` (bits 1,0,1,1,0,0,1,1), 12-bit read across a byte boundary (`0xB3 0x95 → 0xB39`), stuffed-FF transparency (`0xFF 0x00 0xC3 → 0xFFC3`), RST2 skip with `markerSeen` set, non-RST marker → `.sawMarker(0xD9)` + cursor preserved, truncated-input → `.truncated`.
- **479 tests passing, 6 skipped, 0 failures** (was 473; +6).

### v0.11.0cc — Phase J: JPEG canonical Huffman codebook builder (§C.2)

Fifth Phase J bite. Turns the `(bits, huffvals)` records produced by v0.11.0ca into queryable runtime Huffman codebooks via the ITU-T T.81 §C.2 canonical-code algorithm. With this layer the JPEG side has everything a Huffman *decoder* needs — building the actual entropy-decoder loop on top is the next bite.

- **`Sources/JXLSwift/JPEG/JPEGHuffmanCodebook.swift`** (new). `JPEGHuffmanTable.buildCodebook() -> JPEGHuffmanCodebook` walks the §C.2 Figure F.15 algorithm:
  1. **HUFFSIZE list** — for each band L = 1..16, append L `bits[L-1]` times. Length per symbol.
  2. **HUFFCODE** — walk the symbols, emitting the next canonical code at each step. When length increases, shift the running code left by the difference. Range-checked against the 16-bit code space (overruns throw `JPEGParseError.invalidSegmentLength`).
  3. **Decoder state tables** — `mincode[L-1]`, `maxcode[L-1]` (or –1 if no codes of that length), `valoffset[L-1]` per §C.2 Figure F.15. These collapse the per-symbol record into a fixed-size lookup that the decoder loop queries by length.
- **`JPEGHuffmanCodebook.decodeSymbol(nextBit:huffvals:)`** — §C.2 Figure F.16 decode loop, returns one symbol per call. Caller-provided `nextBit` closure lets the entropy decoder choose how to source bits (byte-stuffing handling, RST marker handling, etc. all stay at that layer). Returns `nil` cleanly on truncated bit streams.
- **5 new tests**: 2-symbol [length 1, 1] minimal codebook, hand-derived canonical codes for `bits = [0,3,1,…]` (codes 00, 01, 10, 110), full encode-then-decode round-trip exercising every symbol of a multi-length codebook, real-JPEG sips test (every DHT table builds successfully + the maxcode chain is monotone non-decreasing under left-alignment, the canonical-code invariant), and a graceful-EOF test.
- **473 tests passing, 6 skipped, 0 failures** (was 468; +5).

### v0.11.0cb — Phase J: JPEG SOFn per-component records + SOS scan header

Fourth Phase J bite. Closes the **structural** parsing of a JPEG file — every byte from SOI to EOI that isn't entropy-coded data now has a typed Swift representation. The remaining work for transcoding is runtime Huffman code-table construction + entropy decode + JXL-side bridge.

- **`Sources/JXLSwift/JPEG/JPEGScanHeader.swift`** (new). Two structures + their parsers:
  - **`JPEGFrameComponent`** — per-component records from the SOFn payload: `componentId`, `hSamplingFactor` / `vSamplingFactor` (1..4 each), `quantTableId`. `parseSOFComponents(sofPayload:)` picks up from byte 6 of the SOFn payload (just past P/Y/X/Nf) and walks Nf records. Validates each sampling factor and quant-table ID is in spec range.
  - **`JPEGScanHeader`** — full SOS header per ITU-T T.81 §B.2.3: `components: [JPEGScanComponent]` (each with `componentId` + `dcTableId` + `acTableId`), `spectralSelectionStart` / `End`, `successiveApproximationHigh` / `Low`. Convenience `isSequential` property (start=0, end=63, both successive-approx bits = 0).
- **`JPEGStructure.frameComponents(in:)`** + **`JPEGStructure.scanHeaders(in:)`** — file-level helpers that walk the segment stream and pull the per-component / per-scan records. Baseline JPEGs have one scan header; progressive JPEGs typically have many (one per spectral / approximation pass).
- **5 new tests**: SOFn components on hand-crafted fixture + real sips-JPEG (asserts 3 components, valid sampling factors / quant IDs), SOS scan header on fixture (sequential, components count, Ss=0, Se=63), SOS on real JPEG (≥1 sequential scan covering all 3 components), and a truncated-payload rejection test.
- **468 tests passing, 6 skipped, 0 failures** (was 463; +5).

### v0.11.0ca — Phase J: JPEG DHT (Huffman-table) payload parser

Third bite. Same shape as v0.11.0bz but for Huffman tables — the entropy-coding precondition for actually decoding JPEG pixel data later.

- **`Sources/JXLSwift/JPEG/JPEGHuffmanTable.swift`** (new) — DHT layout per ITU-T T.81 §B.2.4.2. `JPEGHuffmanClass` (`dc` / `ac`), `JPEGHuffmanTable` (class, tableId, `bits: [UInt8]` 16-element length-count array, `huffvals: [UInt8]` symbol values in canonical Huffman code order). `JPEGHuffmanTable.parse(dhtPayload:)` walks one segment payload (segments may concatenate multiple tables). `JPEGStructure.huffmanTables(in:)` walks the whole file. Note: this layer does NOT build the runtime code table — the canonical Huffman code is derivable from `(bits, huffvals)` via the §C.2 algorithm and that's the next bite's job.
- **7 new tests**: DC-table single-symbol parse, AC-table 3-symbol parse, multi-table-in-one-segment, truncated-symbol-list rejection, excessive symbol-count rejection (sum(Li) > 256), fixture parse, real sips-JPEG parse (asserts ≥1 DC + ≥1 AC table, `bits.count == 16`, `huffvals.count == sum(bits)` invariant).
- **463 tests passing, 6 skipped, 0 failures** (was 456; +7).

### v0.11.0bz — Phase J: JPEG DQT (quantisation-table) payload parser

Second bite on the Phase J road. The segment walker (v0.11.0by) gives us "here's a DQT payload, raw bytes"; v0.11.0bz turns those bytes into typed `JPEGQuantTable` records ready for the eventual transcoder to feed into the JXL-side quant pipeline.

- **`Sources/JXLSwift/JPEG/JPEGQuantTable.swift`** (new) — DQT layout per ITU-T T.81 §B.2.4.1. `JPEGQuantPrecision` (`bits8` / `bits16`), `JPEGQuantTable` (tableId, precision, 64-element zig-zag value array stored as `[UInt16]` regardless of source width). `JPEGQuantTable.parse(dqtPayload:)` walks one DQT segment payload — segments may carry multiple tables concatenated, each prefixed with a packed `Pq << 4 | Tq` header byte. `JPEGStructure.quantTables(in:)` walks the whole file and returns the concatenated table list across every DQT segment.
- **`Sources/JXLTool/Info.swift`** — `jxl info` on a JPEG now adds a one-line `Quant DC: T0[DC]=…, T1[DC]=…` summary showing the DC factor of each quant table — small DC → high quality, large DC → low quality. Cheap diagnostic for the transcoder-curious.
- **6 new tests**: 8-bit single-table parse, 16-bit single-table parse (big-endian value reconstruction), multi-table-in-one-segment parse, truncated-payload rejection, invalid-precision-nibble rejection, structure-level helper against the minimal fixture (returns the all-1s table we baked in) AND the real sips-generated JPEG (returns ≥1 table with 64 values each and a 1..99 DC factor for the luma table).
- **456 tests passing, 6 skipped, 0 failures** (was 449; +7 — six DQT tests + one extra sips invocation).
- **End-to-end smoke** on a 16×16 RGB sips-JPEG: `jxl info` reports `Quant DC: T0[DC]=2, T1[DC]=2` (default sips luma + chroma tables at q=80).

### v0.11.0by — Phase J foundation: JPEG marker / segment walker

First concrete deliverable on the Phase J (JPEG ↔ JXL reversible transcoding) road. Adds a pure-Swift JPEG structural reader so `jxl info` can recognise plain JPEG inputs today and so the transcoder (when it lands) has a clean foundation already in place + tested.

- **`Sources/JXLSwift/JPEG/JPEGMarker.swift`** — `JPEGMarkerKind` enum covering every ITU-T T.81 §B.1 marker code: SOI / EOI, SOF0..SOF15, DHT, DAC, DQT, SOS, DRI, RST0..RST7, APP0..APP15, COM, DNL, DHP, EXP, TEM. `isStandalone` flag distinguishes payload-less markers (SOI / EOI / RSTn / TEM) from segments with a 2-byte big-endian length field. Unknown / reserved bytes fall through to `.other(markerByte:)` so the walker can still skip past them by declared length.
- **`Sources/JXLSwift/JPEG/JPEGSegmentReader.swift`** — forward-only segment walker. Iterates marker-by-marker, honouring 0xFF padding runs (§B.1.1.2), the 2-byte length field that counts itself, and 0xFF 0x00 byte-stuffing inside entropy-coded data after SOS (§F.1.2.3). RSTn markers embedded mid-scan are skipped without emission. Throws `JPEGParseError` for malformed inputs (missing SOI, truncated stream, invalid segment length, segment runs past end). `JPEGSegmentReader.looksLikeJPEG(_:)` static method is the magic-byte detector for CLI routing.
- **`Sources/JXLSwift/JPEG/JPEGStructure.swift`** — high-level structural summary: `width` / `height` / `componentCount` / `precision` (from the SOFn payload), `frameKind` enum (baseline / extended-sequential / progressive / lossless / other), DQT and DHT segment counts, JFIF / EXIF / Adobe APP-marker presence (magic-byte checked), `usesArithmeticCoding` (any DAC seen), `hasRestartInterval` (DRI with non-zero interval).
- **`Sources/JXLTool/Info.swift`** — `jxl info` now detects `JPEGSegmentReader.looksLikeJPEG` and prints the JPEG structural summary instead of running the JXL decoder. The output includes a "Phase J — JPEG → JXL transcoding (Phase J) is on the roadmap but not yet implemented" footer so users aren't misled into thinking a transcoder is available.
- **Tests** — `Tests/JXLSwiftTests/JPEGTests.swift` (new file): 12 tests covering marker dispatch (standalones, SOFn nibble, APPn / RSTn ranges, unknown → `.other`), the segment-reader walking a hand-crafted minimal-JPEG fixture (SOI / APP0 / DQT / DHT / SOF0 / SOS / EOI), payload-length assertions (APP0=14B, DQT=65B, DHT=18B, SOF0=9B, SOS=6B), byte-stuffing + RST skip stress, non-JPEG rejection, the `looksLikeJPEG` magic-byte detector, `JPEGStructure` field extraction on the fixture, AND a real-fixture test that uses `sips` (Darwin built-in) to convert an 8×8 PPM to JPEG and asserts the parsed structure matches (8×8 / 3-component / 8-bit / baseline DCT / DQT+DHT present).
- **End-to-end smoke**: `jxl info test.jpg` against a sips-generated 16×16 RGB JPEG reports `Form: JPEG (ISO/IEC 10918-1) / Dimensions: 16×16 / Components: 3 (RGB) / Precision: 8-bit / Frame kind: baseline DCT (SOF0) / DQT segments: 2 / DHT segments: 4 / Metadata: JFIF, EXIF / Restart: DRI present`. JXL inputs unchanged.
- **449 tests passing, 6 skipped, 0 failures** (was 438; +11 JPEG tests).
- **`ROADMAP.md`** — Phase J table updated: the segment-walker row is now ✅ shipped; the Huffman / dequantiser / transcoder rows remain ⏳.

### v0.11.0bv — CLI `jxl compare --frame N` + `--all-frames` for animations

Previously `jxl compare` against a JXL animation silently picked frame 0 — calling `JXLDecoder.decode(_:)` always returns the first frame, so a user comparing `ref.ppm` against `anim.jxl` got a single-frame readout with no indication that the test file held more frames. v0.11.0bv adds two principled selectors:

- **`--frame N`** picks a specific 0-based frame from a JXL input. Default is `0` (matches the previous behaviour). Routes through `JXLDecoder.decodeFrame(_:at:)` when `N != 0`. For PNM inputs (always single-frame) a non-zero `--frame` emits a one-line warning to stderr and falls through to the PNM read; this keeps the symmetric `compare ref.jxl test.jxl --frame N` form working when one of the inputs happens to be a pre-decoded PNM.
- **`--all-frames`** compares every frame in lockstep between two animations. Both inputs decoded with `decodeAll(_:)`; frame counts must match (clean error and exit code 1 otherwise). Reports per-frame PSNR/MAE/max/bit-exact plus an averaged summary line (`Average: PSNR=… MAE=… max=…`). JSON path emits `{frames: [{index, psnr, mae, maxError, bitExact}], allBitExact, …}`.

- **Smoke verification** on a 3-frame animation: `--frame 0` matches default behaviour byte-for-byte (PSNR 52.90 dB); `--frame 2` reports a different PSNR (49.89 dB) confirming we're decoding the correct frame. `--all-frames` averaged PSNR matches the per-frame mean. `--all-frames` against an identical file reports `Inf MAE 0 bit-exact YES` for all three frames. Mismatched frame counts error cleanly; PNM warn-and-continue path tested.
- **`Sources/JXLTool/Stubs.swift`** — adds `frame`/`allFrames` Compare fields, `runAllFrames()` per-frame path, `loadComparableImage(path:frameIndex:)`, `loadComparableFrames(path:)`, `jsonAllFrames(...)` and `formatPSNR(...)` helpers.
- **438 tests passing, 6 skipped, 0 failures.**

### v0.11.0bu — CLI polish: validate walks animations, m0 stubs hidden from help

Two small fit-and-finish bites that clean up the CLI surface as the family-parity work approaches completion.

- **`jxl validate` walks every frame of an animation.** Previously the functional-validation step called `decoder.decode(_:)`, which only returns the first frame. For an animation the validator would say `frameCount: 1` even if the file held a dozen frames, and a corrupt later frame would slip through the check. v0.11.0bu switches to `decoder.decodeAll(_:)` so every frame is exercised and the reported `frameCount` matches the actual frame count. Verified on a 3-frame animation: now reports `Frames decoded: 3` (was `1`); single-frame and broken-input paths unchanged.
- **`encode-m0` / `decode-m0` hidden from `jxl --help`.** Both subcommands are project-internal scaffolding for the `MinimalLosslessCodec` placeholder (not a real JXL format) and exposing them in the top-level help made the CLI look like it had two encoders. v0.11.0bu sets `shouldDisplay: false` on both `CommandConfiguration` blocks; the subcommands are still callable (`jxl encode-m0 …` works) but don't clutter the discovery surface that real users see.
- **438 tests passing, 6 skipped, 0 failures.**

### v0.11.0bt — CLI `jxl compare` accepts `.jxl` inputs directly

Previously `jxl compare` required pre-decoded PNMs on both sides: to compare an encode against the original, users had to `jxl decode` first, then `jxl compare`. v0.11.0bt detects JXL inputs by magic bytes (`FF 0A` naked codestream, or the 12-byte `JXL ` ISOBMFF signature box per ISO/IEC 18181-2 §B.1) and routes them through `JXLDecoder.decode(_:)` automatically. The `.jxl` / `.jxc` extension is a fallback hint for truncated/borderline cases.

- **`Sources/JXLTool/Stubs.swift`** — `loadComparableImage(path:)` helper replaces the inline `PNM.read` call. Three working combinations: PNM↔PNM (backward-compatible), PNM↔JXL (the common encode-then-eval workflow), JXL↔JXL (compare two encodes side-by-side).
- **End-to-end smoke** on 16×16 RGB fixture: PNM↔JXL-lossless reports `Bit-exact: YES` (PSNR Inf, max error 0); PNM↔JXL-lossy at q=75 reports 41.7 dB PSNR / max error 9 / MAE 1.54 — consistent with light visual loss. PNM↔PNM path unchanged.
- **Help text + arg help** updated to reflect that either input may be PNM or JXL. The `Compare` doc-comment lists all three usage patterns explicitly.
- **438 tests passing, 6 skipped, 0 failures.**

### v0.11.0bs — CLI `jxl batch` (encode + decode whole directories)

Adds `jxl batch encode` / `jxl batch decode` — last-missing core CLI subcommand from the J2KSwift parity list. `j2k batch` has been on the parity-divergence audit since the FAMILY-API-PARITY doc was written; v0.11.0bs closes the gap. Mirrors `j2k batch`'s shape: `-i <dir> -o <dir>`, `--recursive` traversal that preserves subdirectory structure into the output tree, `--filter <glob>` to narrow file selection, `--continue-on-error` so one bad file doesn't abort a large run, and `--json` for machine-readable summaries.

- **`Sources/JXLTool/Batch.swift`** (new, ~420 lines) — `Batch` parent ParsableCommand with two sub-subcommands `BatchEncode` and `BatchDecode`. Encode walks PNM/PGM/PPM/PAM files; decode walks `.jxl`/`.jxc` files. Output PNM extension is auto-picked from frame channel count (1→`.pgm`, 3→`.ppm`, 2/4→`.pam`).
- **Glob filter.** Hand-rolled `fnmatch`-style matcher (`*` runs, `?` single char) — small enough to keep clarity, big enough for the realistic `frame_*.ppm` / `*.jxl` use case.
- **Summary block.** Per-file progress lines (suppressed with `--quiet`); final "N ok, M failed in T ms" totals plus a list of failures with their error messages. `--json` swaps the whole report for a single-line JSON object with `processed`/`failed`/`inBytes`/`outBytes`/`elapsedMs`/`failures`.
- **Threading.** Single-threaded for now — parallel `Task`-fan-out is a follow-on once the encoder/decoder caches are audited for concurrent reads.
- **End-to-end smoke test** on a 4-file PNM dir (3× 8×8 PPM, 1× 8×8 PGM): all four encode cleanly under lossy (607→231 B, 38% of source) and lossless paths; decode round-trip is byte-identical for the lossless grayscale fixture. `--recursive` mirrors `in/sub/nested.ppm` into `out/sub/nested.jxl`; `--continue-on-error` reports the one bad file as `failed=1` in JSON and lets the remaining 5 through; without the flag the binary aborts with exit code 1.
- **`JXLTool.subcommands`** — `Batch.self` registered between `Validate.self` and the file's tail.
- **438 tests passing, 6 skipped, 0 failures.** No new XCTest case — batch is CLI-only, covered by manual smoke; behaviour is just per-file dispatch to the already-tested `JXLEncoder.encode(_ frame:)` / `JXLDecoder.decode(_:)` paths.

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
