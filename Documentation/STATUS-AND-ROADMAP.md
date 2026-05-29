# JXLSwift — Status & Roadmap

**A current-state knowledge map of the project.** Snapshot as of **v0.12.0hs** (2026-05-29).
For the original project charter + constraints see [ROADMAP.md](../ROADMAP.md); for the
load-bearing rules see [CLAUDE.md](../CLAUDE.md); for release-by-release detail see
[CHANGELOG.md](../CHANGELOG.md).

---

## 1. What JXLSwift is

A **ground-up, independent** implementation of the JPEG XL Image Coding System
(ISO/IEC 18181), written **Swift-first** (Swift 6.2, strict concurrency). C/C++ is permitted
*only* as an optional, measured hot-path optimisation behind a clean boundary — the scalar
Swift path is always the source of truth. libjxl is a **test-only oracle** (`cjxl` / `djxl` /
`jxlinfo` / `brotli` shelled out in tests), never a runtime dependency.

It is part of a Swift compression-library family alongside **J2KSwift** (JPEG 2000); the public
API + CLI surface are kept in parity so callers can switch codecs without re-learning syntax.

**Not in scope:** DICOM (lives in DICOMkit), comparative-benchmark prose (legal exposure),
GPU paths (land later, behind the proven scalar path).

---

## 2. Current state at a glance

| | |
|---|---|
| **Version** | v0.12.0hs (Phase J line) |
| **Tests** | 666 passing / 7 skipped / 0 failures (`swift test -c release`, ~49 s) |
| **Dependencies** | `swift-argument-parser` (CLI only). Zero runtime deps. |
| **Headline capability** | **Lossless JPEG ⇄ JXL transcoding is byte-identical in both directions**, with no `--source` needed — across baseline + progressive, all chroma, odd dims, grayscale, and metadata. The forward path emits a full lossless-JPEG container that `djxl --jpeg` also reconstructs byte-for-byte. Forward file size is now within **~1.06–1.13× of cjxl** (multi-cluster rANS); the largest remaining gap is the single-AC-group limit (inputs > one 256-px group). |

**What works end-to-end today**

- `jxl-tool info <file>` — inspect JXL/JPEG structure.
- `jxl-tool transcode --mode reverse in.jxl out.jpg` — **byte-identical** JXL → JPEG,
  autonomous (reconstructs everything from the JXL alone).
- `jxl-tool transcode --mode coefficient-bridge in.jpg out.jxl` — JPEG → JXL coefficient
  bridge (coefficient-faithful, `djxl`-decodable).
- `jxl-tool transcode in.jpg out.jxl` — pixel-fallback (lossy) JPEG → JXL.
- `jxl-tool encode` / `decode` / `compare` / `batch` — the surrounding CLI.

---

## 3. Source layout (`Sources/JXLSwift/`)

| Module | Files | Responsibility |
|---|---:|---|
| `Bitstream/` | 4 | `BitReader` / `BitWriter` (LSB-first §2.4), U32/U64/Enum spec integers |
| `Container/` | 1 | ISOBMFF box parser/builder (ISO/IEC 18181-2) |
| `Codestream/` | 10 | Signature, SizeHeader, BitDepth, ColorEncoding, ImageMetadata, **FrameHeader**, ICCStream |
| `Entropy/` | 15 | HybridUint, prefix codes, rANS/ANS, context maps, LZ77, token streams |
| `Modular/` | 14 | Predictors (W/N/NW/NE/avg/gradient/MED), RCT (YCoCg-R), zigzag, channel decode |
| `VarDCT/` | 27 | AC strategy, coeff orders, dequant matrices, quant encoding, DC predictor, block-context map, AFV/DCT transforms |
| `Codec/` | 10 | `JXLEncoder`, `JXLDecoder`, `VarDCTEncoder`, **`VarDCTBitstreamWriter`**, `EncodingOptions` |
| `Brotli/` | 9 | Full Brotli decoder (RFC 7932): meta-blocks, prefix codes, distance, insert-copy, **static dictionary** |
| `JPEG/` | 24 | JPEG decode → coefficients, the **JPEG ⇄ JXL bridge** adapters, jbrd box, scan encoder |

CLI lives in `Sources/JXLTool/`.

---

## 4. Implementation status by phase

Legend: ✅ done · 🟩 substantially done · ⏳ in progress · ⬜ not started

| Phase | Area | Status | Notes |
|---|---|---|---|
| **F** | Foundation (bitstream, container, signature, SizeHeader) | ✅ | read + write + round-trip |
| **H** | Image headers (BitDepth, ColorEncoding, ExtraChannelInfo, ImageMetadata) | ✅ | read + write + round-trip |
| **E** | Entropy (HybridUint, prefix codes, rANS, dist serialisation, context maps, LZ77) | ✅ | read + write incl. complex histograms and the full entropy-coded context-map path (both directions); LZ77 back-reference *encoding* still pending |
| **M** | Modular sub-codec (lossless path) | 🟩 | predictors, RCT, channel decode, MA-tree all used by the VarDCT/bridge decode |
| **V** | VarDCT | 🟩 | **decoder** decodes real cjxl frames (DC/AC groups, context maps, coeff orders, CFL, RAW quant, chroma subsampling, ICC); **encoder** writes coefficient-bridge frames |
| **R** | Restoration filters (Gaborish, EPF) | ⬜ | bridge frames disable them (`kSkipAdaptiveLFSmoothing`); pixel-path filters not yet implemented |
| **J** | JPEG ⇄ JXL transcoding | 🟩 | **both directions byte-identical** (baseline + progressive, all chroma, odd dims, grayscale); forward emits a full lossless container, djxl-valid. Open gap: forward file size (see §5) |
| **Brotli** | RFC 7932 decoder + uncompressed encoder | ✅ | decoder: meta-blocks, simple/complex prefix codes, distance ring buffer, **static dictionary + 121 transforms**; encoder: uncompressed meta-blocks (jbrd tail). Context-maps/multi-block-type (NTREES>1) not needed for jbrd payloads |

> The CLAUDE.md phase table predates the v0.12.0g–hj work and under-states **V** and **J**.
> This table is the current truth.

---

## 5. Phase J — the transcoding capstone (deep dive)

This is where the bulk of recent work landed. JPEG ⇄ JXL transcoding via the **coefficient
bridge** (no IDCT/DCT round-trip) + the **jbrd** (JPEG Bitstream Reconstruction Data) box.

### 5.1 Reverse: JXL → JPEG — ✅ **complete, byte-identical, autonomous**

`transcode --mode reverse` reconstructs the source JPEG **byte-for-byte from the JXL alone**
(no `--source`). Verified across:

- **Baseline (SOF0) and progressive (SOF2)** — incl. all four progressive entropy modes
  (DC first/refine, AC first/refine with EOB-run + correction bits).
- **Chroma:** 4:4:4, 4:2:2, 4:2:0, 4:4:0.
- **Dimensions:** odd / non-MCU-aligned (e.g. 17×23) — true `SizeHeader` SOF dims +
  subsampling-aware block-grid padding.
- **Grayscale** (1 component) — libjxl stores it as a 3-channel YCbCr frame with luma in Y;
  the adapter extracts channel 1.
- **Restart markers** (DRI + RST0–7).
- **Metadata:** ICC profiles (recovered from the codestream `ICCStream`), EXIF, XMP, and
  **large Brotli-compressed metadata** (the full RFC 7932 static dictionary).
- Sizes ≥ 1024×1024 (multi-AC-group).

Pipeline: `parse container → jbrd Bundle → Brotli-decode tail → JXLDecoder.decodeJPEGBridgeData
(coefficients + RAW quant + chroma + colour transform + ICC) → JXLToJPEGAdapter.reconstruct`.

### 5.2 Forward: JPEG → JXL — ✅ **lossless container, byte-identical round-trip**

`JXLEncoder.encodeLosslessJPEG` (CLI `transcode --mode coefficient-bridge`) emits a complete
ISOBMFF container — signature + `ftyp` + `jbrd` + `jxlc` — a true lossless-JPEG JXL. Reverse
(`--mode reverse`) reconstructs the source **byte-for-byte** from the JXL alone.

- **Coefficient fidelity proven:** forward-encode → decode with our byte-exact reverse decoder
  → every quantised coefficient matches the source exactly. Our output decodes to *identical*
  coefficients + quant matrix as cjxl's `--lossless_jpeg=1`.
- **`djxl --jpeg`-valid:** libjxl reconstructs the source JPEG byte-for-byte from our container
  (4:4:4 / 4:2:0 / grayscale) — it accepts our jbrd box, container, and codestream.
- **Forward `jbrd` builder** (`JBRDBox.extract(fromJPEG:)`) captures marker order, Huffman
  tables (EOI sentinel), scan structure, quant metadata, component bindings, app/COM/tail.
- **Brotli encoder** (`BrotliEncoder.encodeUncompressed`) carries the jbrd tail as
  uncompressed RFC 7932 meta-blocks.
- **Input coverage:** baseline (SOF0), **progressive (SOF2 — all four entropy modes)**,
  extended-sequential; 4:4:4 / 4:2:2 / 4:2:0; odd dimensions; grayscale. The pure-Swift
  progressive scan decoder (`JPEGScanDecoder.decodeProgressive`) folds the full multi-scan
  coefficient state during `decodeToCoefficients`.

### 5.3 What remains in Phase J

- **Forward entropy-coding size — now ~1.06–1.13× cjxl.** The AC group uses **rANS**
  (v0.12.0hq) with **multi-cluster context modelling** (v0.12.0hs): 256² 4:2:0 is ~29.5 KB
  (cjxl ~27.2 KB, 1.085×), 4:4:4 1.064×, 4:2:2 1.078×, progressive 1.085×, grayscale 1.134× —
  down from ~1.27× single-cluster. The clusterer groups the *used* AC contexts (greedy
  agglomerative, cap 16) and serialises the map via `ContextMap.writeFullPath`; the codebook
  builder cost-gates Huffman / 1-cluster rANS / multi-cluster rANS and keeps the smallest. Both
  our reverse path and `djxl` reconstruct byte-for-byte.
- **Remaining size/scope work** (all lossless recodes, not correctness):
  (a) **single-AC-group limit** — the forward bridge assembly (`JXLBridgeEncoder.write`)
  hardcodes one group + one TOC entry, so inputs larger than one 256-px group only encode the
  top-left group. Lifting this (multi-group TOC + per-group AC writes) is now the **largest**
  forward gap. (b) convert the **DC / ACMetadata modular** sections to rANS (they share one
  codebook across sub-images → needs multi-sub-image stream handling). (c) reduce the **block
  context map** (cjxl drops `all_default` and tailors block contexts; we use the 15-context
  default → a 7425-entry AC map vs cjxl's ~990).
- Foundations in place: `SpecANSDistribution.writeComplex` (v0.12.0ho), `ANSTokenStreamWriter`
  (v0.12.0hp), and `ContextMap.writeFullPath` (v0.12.0hr).

---

## 6. Key design insights (hard-won, worth remembering)

These are the non-obvious facts that took real debugging to establish:

- **Grayscale VarDCT is 3-channel.** libjxl stores a grayscale JPEG as a **3-channel YCbCr**
  VarDCT frame (luma in the Y/XYB-index-1 channel, X/B all-zero) with **grayscale image
  metadata**. A 1-channel VarDCT frame is rejected by libjxl's decoder. Reverse extracts
  channel 1; forward expands the luma into channel 1.
- **Subsampling-aware block grid.** Block dims use libjxl `FrameDimensions`:
  `xsizeBlocks = DivCeil(xsize, 8 << maxHShift) << maxHShift`. The naive `(xsize+7)/8` only
  matches for dims that are already a multiple of `8 << shift` — odd 4:2:0/4:2:2 frames break
  without this.
- **CFL (chroma-from-luma) is JPEG-recompression-specific** and 3-channel only — gated off for
  grayscale. Inverse: `cfl_factor = (Y·coeff_scale + round) >> 11`.
- **Brotli complex prefix codes** need repeat-code accumulation (`rep = ((rep−2)<<extra)+…`)
  **and** a Kraft `space` budget early-stop with zero-filled tail — both for JXL ANS and the
  separate Brotli decoder.
- **Progressive AC-refinement** is the subtle one: ZRL must be emitted *before* the
  already-nonzero correction-bit branch (libjpeg `encode_mcu_AC_refine`); correction bits go
  *after* the run/size symbol + sign; flush the EOB run at block start.
- **Pixel comparison across decoders is not byte-exact.** `djxl` (float IDCT + AdjustQuantBias)
  vs `djpeg` (integer IDCT) differ by ±tens — cjxl's own output shows the same. The
  **quantised-coefficient round-trip** is the real correctness metric, not pixel diff.

---

## 7. Hard constraints (do not relax — from CLAUDE.md)

1. **Swift-first.** C/C++ only for measured hot paths behind a clean boundary, with the scalar
   Swift path as source of truth. Parsers/transforms/bitstream stay Swift.
2. **Strict concurrency complete.** Public API `Sendable`; no `nonisolated(unsafe)` mutable
   state in `Sources/JXLSwift/`.
3. **No shared mutable global state.** `actor` for shared mutability.
4. **libjxl is a test-only oracle.** Never a runtime dependency or fallback codec.
5. **Not DICOM-aware.** DICOM lives in DICOMkit.
6. **Family parity with J2KSwift.** Mirror public API + CLI; check before adding/changing.

Conventions: `///` doc comments on public API · no force unwraps/casts in production · cite
`§` spec sections · British English in user-facing strings · every "X works" claim needs a
round-trip test.

---

## 8. Build, test, use

```bash
swift build -c release
swift test  -c release            # 666 tests / 7 skipped, ~49 s
.build/release/jxl-tool --version

# byte-identical reverse transcode (no source needed)
.build/release/jxl-tool transcode --mode reverse in.jxl out.jpg

# forward coefficient bridge
.build/release/jxl-tool transcode --mode coefficient-bridge in.jpg out.jxl
```

Test oracles (optional, dev-time): `cjxl` / `djxl` / `jxlinfo` / `brotli` / `cjpeg` / `djpeg`
(Homebrew). Tests `XCTSkip` cleanly when these aren't present.

---

## 9. Suggested next milestones (priority order)

1. **Forward multi-AC-group support** — lift the single-group limit in `JXLBridgeEncoder.write`
   (multi-entry TOC + per-group AC writes + `num_histograms`/HfGlobal handling) so inputs larger
   than one 256-px group transcode correctly. This is now the largest forward gap; entropy-coding
   size is otherwise within ~1.06–1.13× cjxl (rANS + multi-cluster, v0.12.0hq/hs).
2. **Restoration filters (Phase R)** — Gaborish + EPF for the lossy pixel-decode path.
3. **Full lossy VarDCT** beyond the JPEG-bridge subset (XYB colour, full AC-strategy search on
   encode).
4. **Brotli NTREES>1 / NBLTYPES>1** — only if a non-cjxl Brotli stream ever needs decoding
   (cjxl jbrd payloads don't).

---

*Maintained alongside the code. When a milestone lands, update §2, §4, §5 and the CHANGELOG.*
