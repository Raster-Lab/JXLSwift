# JXLSwift

A ground-up, independent implementation of the JPEG XL Image Coding System (ISO/IEC 18181) written in **100% pure Swift 6.2 with strict concurrency**. **No C dependencies, no native libraries, no transitive runtime requirements.**

Primary target: **macOS on Apple Silicon (arm64)**. Modular support for macOS Intel and Linux Intel.

JXLSwift is intended for integration into the **DICOMkit** ecosystem but is fully independent and **not DICOM-aware** — the library is a general-purpose codec usable in any imaging or compression workflow.

See [ROADMAP.md](ROADMAP.md) for the full project summary and design constraints.

## Status: working codec — decode + encode

JXLSwift decodes and encodes JPEG XL today, in pure Swift, with no libjxl at runtime:

- **VarDCT decoder.** Byte-exact against `djxl 0.11.2` on `cjxl -d 0.5`/`-d 1.0` SWEEP fixtures and on DCT8/16/32/64 / AFV / IDENTITY (Hornuss) / DCT2×2 / DCT4×4 / DCT4×8 / DCT8×4 fixtures. DCT32×8 / DCT8×32 ported v0.12.0c (composition-of-verified-parts, no real-fixture probe — cjxl rarely picks them). `cjxl -d 2/5/10` retains a small B-channel residual (max ~12–14 per channel, mean < 0.7) — visually indistinguishable but not yet bit-exact. Multi-AC-group, multi-DC-group, adaptive DC smoothing, EPF0 / EPF1 / EPF2 restoration. **Decoder gaps:** DCT128 / DCT256 transforms not ported (the longest tail — rare on real images); Splines / Noise / Patches synthesis throws `.notImplemented`.
- **VarDCT lossy encoder.** `VarDCTBitstreamWriter` emits genuine spec-compliant JPEG XL that `djxl` decodes: 8-bit RGB / RGBA up to 8192 px, a `distance` quality knob, single- and multi-section codestreams, multi-DC-group, every decoder-supported AC strategy (DCT8/16/32/64 + asymmetric ord-4/6/8 + AFV0–3 + Hornuss + DCT2×2 + DCT4×4 + DCT4×8 + DCT8×4) via a hierarchical trial-encode, libjxl 5×5 inverse-Gaborish pre-pass, distance-aware per-block adaptive QF, adaptive 1/2/3-cluster AC histograms, and **multi-frame animation** (`encodeAnimation([ImageFrame])`).
- **Modular lossless decoder + encoder.** 8/16-bit grayscale / RGB / RGBA, byte-exact round-trips through `cjxl`/`djxl`. Palette transform throws `.paletteUnsupported`; ICC compressed-profile boxes are not yet parsed (uncompressed profiles work).
- **JPEG decode side** (Phase J foundation, v0.11.0by–cm). `JPEGDecoder.decode(_:)` reads baseline-sequential 1- or 3-component 8-bit JPEGs and returns an `ImageFrame`. Wired into `jxl decode foo.jpg`, `jxl encode -i foo.jpg`, `jxl compare ref.jpg test.jxl`, and `jxl batch encode photos/`. Progressive / 12-bit / arithmetic-coded / 4-component CMYK JPEGs throw `JPEGDecoderError.unsupported` with a clear message. **Bit-perfect JPEG ↔ JXL transcoding (the VarDCT coefficient bridge) is the next Phase J capstone — not in v0.11.0.**
- **`JXLEncoder` / `JXLDecoder` public API.** `encode(_:)` picks VarDCT (lossy modes) or Modular (`.lossless`); `decode(_:)` returns pixels. Both are real, not stubs.

See [CHANGELOG.md](CHANGELOG.md) for the v0.5.0 → v0.11.0 trajectory and [ROADMAP.md](ROADMAP.md) for the phase grid.

The spec-layer foundation the codec is built on:

**Phase F — Foundation (§2.4, §C.2, §C.3.1–§C.3.2):**
- LSB-first bitstream reader / writer
- Spec-defined `U32` / `U64` / `Enum` integer encodings
- ISOBMFF container parse + build (`ftyp`, `jxlc`, `jxlp`, naked codestreams)
- Codestream signature recognition
- `SizeHeader` read + write

**Phase H — Image headers (§C.3.3–§C.3.7):**
- `BitDepth` (uint8 / uint16 / float16 / float32 / custom)
- `ColorEncoding` (named primaries, white points, transfer functions)
- `ExtraChannelInfo` (alpha, depth, thermal, CFA, spot color, …)
- `ImageMetadata` (orientation, intrinsic size, preview, animation, tone mapping, extensions)

Every parser is paired with a writer; round-trip tests cover the medical-imaging cases (16-bit grayscale, RGBA16, EXIF orientation, float HDR, animation header).

**Phase E — Entropy primitives (§C.5–§C.6.3):**
- `HybridUintConfig` (§C.5) — variable-length integer split into (token, extra bits)
- `PrefixCodeTable` (§C.6.2) — canonical Huffman with O(1) encode + decode via lookup tables
- `SimplePrefixCodeFormat` + `ComplexPrefixCodeFormat` (§C.6.2.1) — bitstream serialisation of prefix-code tables, both simple (1–4 explicit symbols) and complex (meta-Huffman with run-length symbols 16/17) branches
- `ANSDistribution` + `ANSEncoder` + `ANSDecoder` (§C.6.3) — 32-bit-state rANS with 16-bit renormalisation, tabSize=4096
- `ANSDistributionFormat` (§C.6.3.2) — bitstream serialisation of rANS distributions: constant (1-symbol), simple (1–4 symbols with predefined splits), and flat (uniform). The full per-symbol-frequency mode is not yet implemented.
- `SimpleEntropyStream` — the integration layer that wires the entropy primitives into a single-context "encode a `[UInt32]` stream into a byte buffer; decode it back" round-trip. Useful as a building block for Phase M.

Each primitive has round-trip tests; the compression-ratio sanity test confirms rANS reaches near-Shannon-entropy bounds on highly-skewed distributions (1000 symbols → < 50 bytes for a 0.08-bit-entropy stream).

**Spec-compliance pass against libjxl (April 2026):** read libjxl 0.11.2 source side-by-side with each Phase F/H/E header serialiser. Found and fixed eight latent bit-layout bugs that round-trip tests couldn't catch (encoder + decoder were both wrong, so the data flowed through fine):
- `Enum()` distribution — was `(0, 1, 2, 1+u(4))` (max value 16); spec is `(0, 1, 2+u(4), 18+u(6))` (max 81). Cascaded into wrong reads of every ColorEncoding field; HLG (=18) and DCI-P3 (=17) transfer functions were silently unreachable.
- ColorEncoding skip flags — XYB implies D65 (no white point on the wire) and grayscale/XYB have no primaries.
- BitDepth float exponent — raw `1+u(4)`, not the project-internal `(2, 5, 10, 7+u(4))` distribution.
- ExtraChannelInfo spot color — 4 × F16, not 4 × F32 raw.
- ExtraChannelInfo dim_shift — `(0, 3, 4, 1+u(3))`, not `(0, 3, 4+u(2), 8+u(3))`.
- ImageMetadata extensions — read/write a U64, not a 1-bit gate.
- ContextMap — drop the project-internal `num_clusters - 1` u(8) prefix; derive from `max(map) + 1` as libjxl does.
- LZ77Config — spec U32 distributions for min_symbol/min_length, embedded length-uint-config always reads at log_alpha_size=8.

Cross-validation tests added against `cjxl`-emitted Linear, sRGB, PQ, and HLG transfer functions to lock in the Enum fix.

**Phase F continued — frame structure (§C.8.1):**
- `FrameHeader` (§C.8.1) — full spec layout. Every field libjxl `FrameHeader::VisitFields` writes round-trips through our Swift implementation: `frame_type`, `is_modular`, `flags` (U64), color transform (XYB / None / YCbCr), `chroma_subsampling`, `upsampling`, `extra_channel_upsampling`, `group_size_shift`, `xQmScale` / `bQmScale`, the multi-pass `Passes` block, `dc_level`, `custom_size_or_origin` with origin/size U32-encoded, per-channel blending info, animation duration and timecode, `is_last`, `save_as_reference`, name string, and the EPF / Gaborish loop filter.
- `TOC` (§C.8.1.5) — frame Table of Contents. Each TOC entry is a U32 group size; the `numEntries` formula is exposed for callers (single-group single-pass = 1 entry; multi-group = 2 + DC-groups + passes × groups). Permutation flag is recognised; the entropy-coded permutation payload itself is the next E-phase prerequisite.
- `EntropySectionHeader` (§C.6 prefix) — the structural prefix every JXL ANS or prefix-coded section shares: LZ77 config, optional context map, `use_prefix_code`, `log_alpha_size`, and per-cluster HybridUintConfig.
- `MultiClusterCodebook` (§C.6 body) — per-cluster code tables that follow the entropy-section header. Picks Huffman vs rANS based on `usePrefixCode`. For prefix codes: `VarLenUint16+1` alphabet sizes per cluster, then `PrefixCodeFormat.decode` (which dispatches simple / complex by `hskip`). For rANS: `SpecANSDistribution.readHistogram` per cluster. Both `ReadHistogram` shape branches (simple, flat, RLE-coded complex) implemented; the `cll` static-Huffman lookup uses the spec's 16-entry table with Kraft-budget early termination.
- `TokenStreamReader` (libjxl `ANSSymbolReader::ReadHybridUint`) — context-routed token reads from an entropy section. Looks up `cluster = contextMap[ctx]`, decodes a Huffman symbol from `huffmanTables[cluster]` OR pulls one from the streaming `ANSStreamDecoder`, then expands via the cluster's HybridUintConfig. Both paths complete.
- `ANSStreamDecoder` (§C.6.3 / libjxl `ANSSymbolReader`) — rANS decoder reading state init (32 bits) and renormalisation words (16 bits) inline from the same `BitReader` that drives the rest of the entropy section. Lazily initialises state on first read; subsequent reads only touch the BitReader for the renorm hop when state drops below 2¹⁶. Backed by `AliasTable` (Vose's alias method) for the slot → (symbol, freq, offset) lookup — required for byte-equality with cjxl-emitted bitstreams.
- `AliasTable` (libjxl `InitAliasTable` + `Lookup`) — Vose's alias method for rANS slot lookup. Each table entry holds `cutoff / right_value / freq0 / offsets1 / freq1`; lookup divides slot by entry size, picks the entry, then routes via cutoff to the entry's "left" (`pos < cutoff` → `value=i, offset=pos`) or "right" (`pos ≥ cutoff` → `value=right_value, offset=offsets1+pos`) symbol.
- `ModularTree` (§C.7.4) — typed `[ModularTreeNode]` reconstructed from the MA-tree token stream. Decision nodes carry `(property, splitVal, leftChild, rightChild)`; leaves carry `(predictor, rawPredictor, predictorOffset, multiplier)`. `ModularTree.walk(properties:)` routes a 16-element properties array to a leaf using libjxl's `>` decision rule.
- `GroupHeader` (§C.7.2) — per-group prelude with `useGlobalTree`, the `WeightedPredictorHeader` (`all_default` bit + custom 7×u(5)+4×u(4) weights), and the per-group `ModularTransform` array (RCT, Palette, Squeeze with their full distribution sets).
- `computeModularProperties` (§C.7.4) — computes the 16 standard pixel-context features from a pixel's neighbours (top, left, topLeft, topRight, leftLeft, topTop). Properties 0–14 match libjxl exactly; property 15 (the weighted-predictor output) is placeholder zero, deferred until the WP state machine lands.
- `applyLibjxlPredictor` — all 14 spec / libjxl Modular predictors (`Zero`, `Left`, `Top`, `Average0`, `Select`, `ClampedGradient`, `Weighted`, `TopRight`, `TopLeft`, `LeftLeft`, `Average1..4`) directly from the raw 0..13 index. Source of truth for byte-exact pixel reconstruction; predictor 6 (Weighted) consumes the `wpResult` produced by the WP state machine.
- `WeightedPredictor` (§C.7.5 / libjxl `weighted::State`) — the stateful WP machine: 4 sub-predictors, per-row error tally arrays, division-avoiding `WeightedAverage` (1<<24 / (i+1) LUT), `ErrorWeight` floor-log2 weight scaler, and the conditional clamp branch. `propertyValue(...)` returns property 15 (kWPProp); `predict(...)` returns the WP scalar prediction; `update(actual:...)` folds the actual decoded pixel into the running error arrays.
- `decodeModularChannel` (§C.7) — streaming per-pixel decode driver for one Modular channel. Iterates row-major; for each pixel computes property 15 from the live `WeightedPredictor` + the other 15 standard properties → walks the tree → reads a token via `TokenStreamReader` at `context = leaf.leafId` → `ZigZag.unpack` × multiplier → adds predictor output (which sources predictor-6 from WP) + leaf offset → updates WP state. `decodeAllChannels(...)` iterates the wire-level channel list and threads a fresh WP per channel through a shared `TokenStreamReader`.
- `ModularImage` + `metaApplyTransforms` (libjxl `Transform::MetaApply`) — channel-list geometry for `[ModularTransform]`. RCT keeps geometry; Squeeze halves source channels along the chosen axis and inserts residual placeholders, bumping `hshift` / `vshift`. `defaultSqueezeParameters` mirrors libjxl's auto-generated 4:2:0 chroma + recursive main squeeze chain. Palette is reserved (`.paletteUnsupported`) until ported.
- `SpecRCT` (full 42 RCT types) — `inverse(rctType:c0:c1:c2:)` covers permutation × custom for the entire 0..41 range, including YCoCg-R (type 6). Mirrors libjxl `InvRCTRow<custom>` exactly.
- `SpecSqueeze` (un-squeeze with SmoothTendency) — `inverseHorizontal(ll:residual:)` and `inverseVertical(...)` combine LL + HL channels back into full resolution. Implements libjxl's `SmoothTendency` predictor (small monotone-area correction proportional to `4B − 3n − a`).
- `applyInverseTransforms(image:transforms:)` — walks the transform list in reverse order and undoes each step on `ModularImage.channels`. RCT routes through `SpecRCT`; Squeeze through `SpecSqueeze`; Palette throws.
- `JXLDecoder.decodeModular(_:)` — end-to-end Modular pixel-decode API, **byte-exact against `cjxl`/`djxl`** for in-scope inputs (single-group, single-pass Modular lossless; RCT 0..41; Squeeze; predictors 0..13 inc. Weighted; rANS or prefix codes). Walks container → headers → frame → TOC → matrices DC → has_tree → tree-section → post-tree codebook → GroupHeader → metaApply → per-channel decode → inverse transforms → returns a `ModularImage` whose channels are the post-inverse-transform colour channels (R, G, B for typical RGB inputs).
- `VarLenUint8` / `VarLenUint16` (libjxl `DecodeVarLenUint*`) — the variable-length integer codings used inside histogram bodies and per-cluster alphabet sizes.

The codestream reader chain now walks **thirteen spec layers deep** into a real cjxl-emitted Modular lossless file and runs all 1024 pixels of a 32×32 channel through the **complete** per-pixel pipeline (rANS state init + 1024 token reads + 1024 tree walks with property 15 from WP + 1024 predictor/offset/multiplier applications including predictor 6 sourced from the WP state machine). Layers: signature → SizeHeader → ImageMetadata → FrameHeader → TOC → DequantMatrices DC flag → Modular `has_tree` → tree-section EntropySectionHeader → per-cluster Huffman tables → MA-tree token stream → typed `ModularTree` → post-tree pixel-data EntropySectionHeader → byte-aligned **`GroupHeader`** → **per-pixel `decodeModularChannel` with WP**. The remaining work for byte-equality with djxl is multi-channel iteration + Modular Transform application (RCT inverse, Squeeze inverse) on the reconstructed channel arrays.

`JXLDecoder.inspect(_:)` parses any spec-compliant `.jxl` and reports container form, box list, dimensions, bit depth, channel count, alpha, animation, and HDR metadata.

`JXLEncoder.encode(_:)` and `JXLDecoder.decode(_:)` are fully wired: encode produces a spec-compliant codestream (lossy VarDCT or lossless Modular per `EncodingOptions.mode`), decode reconstructs pixels into an `ImageFrame`.

See [ROADMAP.md](ROADMAP.md) for the spec-section status grid.

## Quickstart

```bash
swift build -c release
swift test  -c release           # 573 tests — foundation, headers, entropy,
                                 # Modular + VarDCT decode/encode, JPEG decode,
                                 # JPEG→JXL bridge (in-progress), byte-exact
                                 # cjxl/djxl cross-validation
.build/release/jxl-tool --version
.build/release/jxl-tool info path/to/file.jxl
.build/release/jxl-tool encode -i in.ppm -o out.jxl       # lossy VarDCT
.build/release/jxl-tool encode -i in.ppm -o out.jxl --lossless
.build/release/jxl-tool decode -i out.jxl -o out.ppm
```

The `jxl encode` CLI also exposes the VarDCT encoder's quality knobs:

```bash
# Default (lossy, quality 90, Gaborish + adaptive QF on).
.build/release/jxl encode -i in.ppm -o out.jxl

# Disable the inverse-Gaborish pre-pass (skip the libjxl
# butteraugli-optimised sharpening).
.build/release/jxl encode -i in.ppm -o out.jxl --no-gaborish

# Disable per-block adaptive QF (uniform quantiser everywhere).
.build/release/jxl encode -i in.ppm -o out.jxl --no-adaptive-qf
```

Multi-frame animations and helper subcommands:

```bash
# Encode a 3-frame animation (multi-value -i, or repeated -i, or a shell glob).
.build/release/jxl encode -i frame_*.ppm -o anim.jxl --frame-duration 10,20,30

# Decode every frame to a per-frame template.
.build/release/jxl decode -i anim.jxl -o out-%03d.ppm --all-frames

# Validate an arbitrary .jxl (walks every frame of an animation).
.build/release/jxl validate anim.jxl --json

# Compare two encodes — accepts PNM or JXL on either side.
.build/release/jxl compare original.ppm encoded.jxl --frame 1
.build/release/jxl compare ref.jxl test.jxl --all-frames

# Batch-encode every PNM in a directory tree.
.build/release/jxl batch encode -i pnm/ -o jxl/ --recursive --continue-on-error
```

JPEG inputs are accepted everywhere PNM is (Phase J decode side, since v0.11.0ck–cl) — auto-detected by SOI magic bytes, decoded through the pure-Swift JPEG pipeline, then handed to the JXL encoder / comparison / batch loop. Baseline-sequential 1- or 3-component 8-bit JPEGs are supported today; progressive / 12-bit / arithmetic-coded / 4-component CMYK are rejected with a clear error message:

```bash
# JPEG → PNM via the pure-Swift JPEG decoder.
.build/release/jxl decode -i photo.jpg -o photo.ppm

# JPEG → JXL (decode + re-encode; not bit-perfect transcoding —
# that's the JXL VarDCT coefficient bridge, in-progress Phase J).
.build/release/jxl encode -i photo.jpg -o photo.jxl -q 90

# Same conversion via the typed `transcode` subcommand. Today
# routes through the pixel-fallback path; `--mode coefficient-bridge`
# is reserved for the eventual bit-perfect path (currently throws
# with a pointer to Documentation/PHASE-J-COEFFICIENT-BRIDGE.md).
.build/release/jxl transcode photo.jpg photo.jxl -q 90

# Convert a whole directory of JPEGs (and any PNMs alongside).
.build/release/jxl batch encode -i photos/ -o jxl/ --recursive

# Compare a JPEG reference against a JXL re-encode.
.build/release/jxl compare ref.jpg test.jxl

# Inspect JPEG structure (dimensions, DCT mode, quant DC, JFIF/EXIF).
.build/release/jxl info photo.jpg
```

Requires Swift 6.2+ on macOS 13+. **No external dependencies.** (`swift-argument-parser` for the CLI is the only Swift-package dep.)

`jxl-tool info` now reports the frame structure of any cjxl-emitted file — encoding mode, TOC entries, MA-tree leaf count, post-tree pixel codec (prefix codes vs rANS):

```
$ jxl-tool info hdr.jxl
File:         hdr.jxl
Dimensions:   16×16
--- ImageMetadata ---
HDR:          intensity target = 10000.0 cd/m²
--- Frame structure ---
Encoding:     Modular
TOC entries:  1 (106B)
MA-tree:      present
Tree leaves:  4
Pixel codec:  rANS
```

### M0 placeholder codec — exercise the pixel pipeline today

`encode-m0` / `decode-m0` round-trip **8/16-bit grayscale, gray+alpha, RGB, and RGBA** images through the **project-internal M0 placeholder format** (`MinimalLosslessCodec`). Reads and writes binary PNM (PGM for 1-channel, PPM for RGB, PAM for alpha-bearing images) so any tool that handles PNM can feed pixels in:

```bash
# 1- or 3-channel via PGM/PPM
convert input.png input.pgm                     # or .ppm
.build/release/jxl-tool encode-m0 -i input.pgm -o out.m0
.build/release/jxl-tool decode-m0 -i out.m0   -o out.pgm
diff -q input.pgm out.pgm                       # round-trip is pixel-exact

# RGBA (or grayscale+alpha) via PAM
convert rgba.png rgba.pam
.build/release/jxl-tool encode-m0 -i rgba.pam -o rgba.m0
.build/release/jxl-tool decode-m0 -i rgba.m0 -o rgba_out.pam
diff -q rgba.pam rgba_out.pam
```

Sample compression ratios on synthetic data:

| Source                                          | Raw size  | M0 size  | Ratio |
|---|---|---|---|
| 8-bit grayscale smooth gradient (32×32)         | 1024 B    | ~80 B    |   8 % |
| 16-bit grayscale large-step gradient (32×32)    | 2048 B    | 1300 B   |  63 % |
| 8-bit correlated RGB (R≈G≈B, 32×32)             | 3072 B    |  543 B   |  18 % |
| 8-bit correlated RGBA (RCT + alpha, 16×16)      | 1184 B    |  294 B   |  27 % |
| 8-bit natural-shaped grayscale (gradient+noise, 128×128) | 16 384 B | 6.9 KB | **43 %** |

The pipeline is `optional RCT (R/G/B only when channels ≥ 3) → per-channel predictor selection → ZigZag-packed residuals → auto-selected distribution shape (simple / flat / full per histogram bit-cost estimate) → SimpleEntropyStream`. **M0 output is NOT a JPEG XL file** — it has a 'M0' marker so a spec-compliant decoder rejects it cleanly. M0 predates the real codec and is kept for benchmark continuity; for genuine JPEG XL output use `jxl-tool encode` / `JXLEncoder`, which emit spec-compliant codestreams.

#### M0 throughput

`jxl-tool benchmark -i input.pgm` times the encode/decode loop and reports source-pixels-per-second throughput. Sample numbers on Apple Silicon (release build, 10 iterations):

| Image                                      | Balanced encode | Fast encode  | Decode      |
|---|---|---|---|
| 128×128 8-bit grayscale (gradient + noise) | ~14 Mpx/s       | —            | 54 Mpx/s    |
| 256×256 8-bit grayscale                    | **18 Mpx/s**    | 20 Mpx/s     | 75 Mpx/s    |
| 1024×1024 8-bit grayscale                  | **18 Mpx/s**    | 21 Mpx/s     | 74 Mpx/s    |
| 256×256 8-bit correlated RGB               | **6.7 Mpx/s**   | 9.6 Mpx/s    | 30 Mpx/s    |

Numbers measured on Apple Silicon (M-series), release build, 10 iterations. The encoder is now **dual-level parallelised**: per-channel work runs in parallel (RGB/RGBA), and within each channel the 6 predictor evaluations run in parallel via GCD `concurrentPerform`. Cumulative encode speedup vs the original sequential baseline is **2.4× on grayscale** and **4.5× on RGB**.

`encode-m0 --fast` (or programmatically `MinimalLosslessCodec.encode(_:effort: .fast)`) skips predictor + RCT search and uses `Predictor.gradient` + `RCTVariant.identity` unconditionally. **2.7–4.4× faster encode** with 1–2 percentage points worse compression on natural-shaped images. Useful for real-time use cases where throughput matters more than the last few percent of ratio.

## What works today

```swift
import JXLSwift
import Foundation

let data = try Data(contentsOf: URL(fileURLWithPath: "image.jxl"))

// Container parsing — works on naked codestreams and ISOBMFF wrappers
switch try parseJXLContainer(data) {
case .naked:
    print("naked codestream")
case .iso(let boxes):
    print("ISOBMFF: \(boxes.map(\.type).joined(separator: ", "))")
}

// Foundation-level inspection — gives dimensions without decoding pixels
let info = try JXLDecoder().inspect(data)
print("\(info.xsize)×\(info.ysize)")

// Bitstream primitives — write LSB-first, read back
var w = BitWriter()
w.write(bits: 4, value: 0b1011)
w.write(bits: 13, value: 5000)
let bytes = w.finishToData()

var r = BitReader(bytes)
print(try r.read(bits: 4))   // 11
print(try r.read(bits: 13))  // 5000

// JXL spec U32 / U64 codings
let dists: (UInt32Distribution, UInt32Distribution, UInt32Distribution, UInt32Distribution) = (
    .literal(0),
    .offset(constant: 1, extraBits: 4),
    .offset(constant: 17, extraBits: 8),
    .offset(constant: 273, extraBits: 30)
)
var w2 = BitWriter()
try w2.writeU32(50_000, distributions: dists)
```

## Encoding and decoding

```swift
import JXLSwift

// Decode a JPEG XL file to pixels.
let jxlData = try Data(contentsOf: URL(fileURLWithPath: "image.jxl"))
let frame = try JXLDecoder().decode(jxlData)
print("\(frame.width)×\(frame.height), \(frame.channels)ch")

// Encode — lossy VarDCT (default) or lossless Modular.
let lossy = try JXLEncoder().encode(frame)                       // VarDCT
let lossless = try JXLEncoder(
    options: EncodingOptions(mode: .lossless)).encode(frame)     // Modular
```

`encode(_:)` routes 8-bit RGB/RGBA through the VarDCT lossy codec for lossy modes (falling back to lossless Modular for inputs VarDCT cannot take); `.lossless` always uses Modular. Every codestream JXLSwift emits is decodable by `djxl 0.11.2`.

**Not yet pixel-equivalent:** JPEG ↔ JXL coefficient-bridge transcoding (Phase J — `JXLEncoder.encodeFromJPEGCoefficients(_:)`). The wire-up is in place from v0.12.0ee and the codestream envelope is byte-perfect against `cjxl --lossless_jpeg=1` (v0.12.0ff), but `djxl` rejects the section content — at least one more diverging field. The diagnostic harness is built in (`JXLSWIFT_BRIDGE_DJXL_DIAG=1`) for the next debug session. The pixel-fallback transcode (`encode(JPEGDecoder.decode(jpegBytes))`) works end-to-end today. Also pending: four niche AC strategies (DCT128 / DCT256 / DCT32×8 / DCT8×32) the **decoder** doesn't yet reconstruct.

## Why pure Swift

The previous JXLSwift was a libjxl wrapper. Removing the C dependency means:

- No libjxl shared library at runtime — single-binary distribution.
- Native iOS / Linux / Windows builds without the Homebrew dependency story.
- Memory safety from Swift 6.2's strict concurrency throughout the codec.
- No transitive licence / patent surface from C++ codec libraries.

The trade-off: building a JPEG XL codec is comparable in scope to a small open-source codec project; the libjxl reference is approximately 150 KLOC of expert C++ compression code. ROADMAP.md tracks honest progress.

## Project layout

```
Sources/JXLSwift/Bitstream/   BitReader, BitWriter, U32/U64 spec integers
Sources/JXLSwift/Container/   ISOBMFF box parser/builder
Sources/JXLSwift/Codestream/  Signature + headers (SizeHeader, BitDepth,
                              ColorEncoding, ExtraChannelInfo,
                              ImageMetadata)
Sources/JXLSwift/Entropy/     HybridUint, PrefixCodeTable, rANS encoder/
                              decoder, ANSDistribution
Sources/JXLSwift/Modular/     Predictors, RCT, ZigZag, ModularImage
Sources/JXLSwift/VarDCT/      AC strategies, IDCT/DCT, quant weights,
                              colour correlation, EPF, AFV
Sources/JXLSwift/Codec/       JXLEncoder / JXLDecoder (working codec),
                              VarDCTEncoder / VarDCTBitstreamWriter,
                              ImageFrame, EncodingOptions
Sources/JXLTool/              jxl-tool CLI (info / encode / decode / …)
Tests/JXLSwiftTests/          573 tests across foundation, headers, entropy,
                              Modular + VarDCT decode/encode, JPEG decode,
                              JPEG → JXL coefficient bridge (in progress)
```

JXLSwift is **not DICOM-aware** — DICOM file format / metadata / transfer-syntax handling lives in DICOMkit, not here. JXLSwift accepts and emits raw pixel buffers (`ImageFrame`) at the bit depths medical imaging needs (8/10/12/16-bit, grayscale or RGB).

## Branches

| Branch | What's there |
|---|---|
| `main` | Pure-Swift implementation (active development) |
| `libjxl-backend` | Historical reference only — the libjxl-wrapped implementation that preceded the pure-Swift restart. **Not** a supported runtime path; libjxl is never a dependency, fallback, or required runtime for JXLSwift. |
| `pre-rewrite-snapshot` | Original failed pure-Swift attempt (preserved for lessons learned) |
| Tag `v0.4-libjxl` | Snapshot of the libjxl-wrapped `main` |

## Contributing

The development principles are spelled out in [ROADMAP.md](ROADMAP.md) and [CLAUDE.md](CLAUDE.md). Pick a phase, write a round-trip test (or, where the spec defines exact bytes, a hand-derived test vector), submit a PR. Spec-driven only — no shortcuts that would produce non-spec-compliant bitstreams.

## Documentation

- [ROADMAP.md](ROADMAP.md) — project summary + phase-by-phase status against ISO/IEC 18181 sections
- [CLAUDE.md](CLAUDE.md) — guidance for AI-assisted contributors
- [CHANGELOG.md](CHANGELOG.md) — release notes
- [Documentation/SESSION-NOTES.md](Documentation/SESSION-NOTES.md) — handoff notes for the next contributor
- [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) — design overview (libjxl-backed era; will be updated for pure-Swift as the codec lands)
- [Documentation/legacy/](Documentation/legacy/) — pre-rewrite history (read-only)

## Licence

See [LICENSE](LICENSE).
