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
