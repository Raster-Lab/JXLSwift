# Phase J — JPEG ↔ JXL transcoding: design + implementation plan

**Audience.** Anyone (human or AI) picking up the Phase J transcoding work after v0.12.0e. Updated for the v0.12.0 line.

**Status at time of writing.** The JPEG-decode side of Phase J is complete end-to-end (v0.11.0by–cm: segment walker → DQT → DHT → SOFn/SOS → Huffman codebook → bit reader → block decoder → dequantiser → scan decoder → IDCT → pixel assembler → YCbCr → RGB → `JPEGDecoder.decode(_:) → ImageFrame`). The CLI carries the result: `jxl decode foo.jpg`, `jxl encode -i foo.jpg`, `jxl compare ref.jpg test.jxl`, `jxl batch encode photos/`, `jxl transcode foo.jpg foo.jxl`, and `jxl info foo.jpg`. v0.12.0a added `JPEGCoefficientImage` + `JPEGDecoder.decodeToCoefficients(_:)` — the structured handoff that the coefficient bridge will consume.

What's **not** done: bit-perfect JPEG ↔ JXL transcoding via the libjxl-style coefficient bridge + `jbrd` (JPEG Bitstream Reconstruction Data) box. The forward direction (JPEG → JXL pixel-matching, no IDCT/DCT round-trip in the middle) and reverse direction (`jbrd`-driven byte-identical JPEG reconstruction) are this document's subject.

---

## 1. What the coefficient bridge is and why it matters

Today, `jxl encode -i foo.jpg` and `jxl transcode foo.jpg foo.jxl` use the **pixel-fallback** path:

```
foo.jpg → JPEGDecoder.decode  → ImageFrame (pixels, lossy at YCbCr→RGB step)
       → JXLEncoder.encode    → foo.jxl   (lossy at VarDCT-quant step)
```

That's *lossy twice*. The source JPEG is not recoverable from the output, and the output JXL's decoded pixels differ from the source JPEG's decoded pixels by both rounds of quantisation.

libjxl's **coefficient bridge** does something cleverer:

```
foo.jpg → JPEGDecoder.decodeToCoefficients → JPEGCoefficientImage (quantised DCT coefficients)
       → JXLFromJPEG.pack                  → JXL frame whose VarDCT decoder produces
                                              pixels matching the source JPEG exactly
       → jbrd box                          → captures Huffman tables + marker order so
                                              JXL → JPEG can reconstruct the source bytes
```

Three benefits:
1. **Smaller files.** The JPEG quantised coefficients are already a compact representation; JXL's entropy coding compresses them further. Typical real-world ratio is JXL ≈ 0.75 × JPEG size for the same quality.
2. **Pixel-faithful.** Decoding the JXL produces the exact pixels the source JPEG would have produced. No additional quantisation loss.
3. **Bit-perfect reverse.** With `jbrd`, the original JPEG bytes can be reconstructed exactly — every Huffman table choice, every byte-stuffing position, every marker ordering preserved.

---

## 2. The four work items (forward direction)

### 2.1 `JPEGCoefficientImage` data type ✅ shipped v0.12.0a

Per-component quantised DCT coefficients in natural order + quant tables in zig-zag order + frame components with sampling factors. The structured handoff the bridge consumes. No changes needed.

### 2.2 Forward bridge: `JPEGCoefficientImage` → JXL VarDCT frame ⏳

The substantive work. **Estimate: 3–5 sessions** to first working forward transcode with djxl-decoded-pixel verification against source-JPEG-decoded-pixel.

#### Inputs

- `JPEGCoefficientImage` from `JPEGDecoder.decodeToCoefficients(_:)`.

#### Outputs

- A naked JPEG-XL codestream (or ISOBMFF-wrapped) whose VarDCT decode pipeline produces the same pixels as `JPEGDecoder.decode(_:)` would on the source bytes.

#### Required surgical changes to existing JXL encoder

1. **Skip `VarDCTEncoder.forward`.** Currently the encoder runs pixels → linear → OpsinXYB → DCT8×8 → quantise. For the bridge, we already have the quantised coefficients; we want to inject them directly into the bitstream writer's `Quantized` shape without round-tripping through the spatial domain.
   - Need: a new entry point that constructs `VarDCTEncoder.Quantized` from `JPEGCoefficientImage`. The structural shape (per-channel DC + AC, block grids per channel) maps cleanly; the per-coefficient *values* are different because JPEG and JXL use different quant matrices by default.

2. **Use JPEG quant tables as JXL quant matrices.** This is the crux. JXL's VarDCT decoder dequantises with `dequant = AdjustQuantBias(quant) / qweight × invQuantAC × dm_multiplier` (per channel). For the JXL output to dequantise to the JPEG's dequantised values, the encoder must emit a custom `DequantMatrices` payload whose values cause the JXL dequant formula to recover `jpegQuant[k] × jpegQt.zigZagValues[k]` from the JXL-stored `quant`.
   - The cleanest map: pick `qweight` so that `1 / qweight = jpegQt.zigZagValues[k] / (jpegBlockQF × jpegInvGlobalScale)`. Then `dequant(quant) = quant × jpegQt[k]`, matching JPEG's `dequantised = quant × jpegQt[k]`.
   - Spec wrinkle: JXL's `DequantMatrices` payload uses `kQuantMode{Library,DCT,DCT2,…}` selectors. For arbitrary JPEG quant tables we'd use `kQuantModeRAW` (libjxl's "RAW" mode) which takes a flat 64-value table. This mode is rare in real cjxl output; our **decoder** currently doesn't support it. **Decoder work blocks encoder work here** — porting `kQuantModeRAW` decode is the first concrete bite.

3. **`color_transform = None`.** JXL frames default to `color_transform = XYB`, which transforms pixels through `OpsinXYB.forward` before quantisation. For JPEG transcode, we want JXL to skip XYB and treat the three channels as raw YCbCr (matching what JPEG's bitstream stores).
   - `FrameHeader.colorTransform = .none` is what we need. Our `FrameHeader` writer supports this already — just hasn't been exercised on the encode side.

4. **Chroma subsampling per `JPEGFrameComponent.{h,v}SamplingFactor`.** JPEG 4:2:0 means Cb/Cr have H=V=1 while Y has H=V=2. JXL has per-channel `chroma_subsampling` fields in `FrameHeader`. Map JPEG H_max/V_max → JXL `chroma_subsampling = (log2(H_max / H_i), log2(V_max / V_i))` per chroma channel.

5. **All-DCT8×8 strategy plane.** JPEG has only one block size; the JXL frame's AC strategy plane is uniformly `DCT8×8`. This is the simplest case for the encoder — no per-block strategy search needed. Just emit the AC strategy plane as a single-cluster constant plane.

6. **Skip Gaborish + adaptive QF.** These belong to the pixel-encode pipeline. For the bridge, both should be off (`gaborish: false`, `adaptiveQF: false` in `EncodingOptions`). The current encoder already supports these flags.

7. **Per-component QF = 1.** JPEG's quantisation is fully captured in the quant tables; there's no additional JXL-side quant factor. Emit `qfPerBlock[*] = 1` (or whatever `invGlobalScale = 1` requires for the dequant formula to come out right).

#### Required decoder change (blocking the encoder)

- **Port libjxl `kQuantModeRAW` decode.** Our `QuantWeights` infrastructure handles the spec's library + DCT + DCT2 + DCT4X8 + AFV + Identity modes; RAW is missing. Add `QuantWeights.getRAWQuantWeights(payload:)` that takes a flat 64-value table per channel and returns a `qweights` array. Wire into `JXLDecoder`'s quant-matrix dispatch.

#### Verification

- Write a `testJPEGToJXLCoefficientBridge_RealFixture` test that:
  1. Takes a sips-generated JPEG.
  2. Calls `JXLEncoder.encodeFromJPEGCoefficients(_ coef: JPEGCoefficientImage)`.
  3. Decodes both the source JPEG (via `JPEGDecoder.decode`) and the bridge output (via `JXLDecoder.decode`).
  4. Asserts the two pixel arrays are **byte-identical**.
- File size should be smaller than `JXLEncoder.encode(JPEGDecoder.decode(jpg))` at equivalent visual quality (since the bridge avoids the IDCT-then-DCT round-trip's quantisation drift).

### 2.3 Reverse bridge: JXL VarDCT frame → JPEG bytes ⏳ (gated on Brotli)

Reads the `jbrd` box from a coefficient-bridge JXL file, extracts the original Huffman tables + marker order, decodes the JXL VarDCT coefficients, re-encodes them as JPEG entropy data following the captured tables, wraps with the original markers, byte-stuffs as needed, emits byte-identical JPEG bytes.

**Blocking dependency: pure-Swift Brotli decompressor.** The `jbrd` box payload is Brotli-compressed (`Box::kJpegRecBoxType` in libjxl `lib/jxl/jpeg/dec_jpeg_data.cc`). Per CLAUDE.md constraint 1 ("C/C++ permitted only for measured optimisation; correctness logic stays Swift"), a C-FFI to libbrotli is **not** an option here. A pure-Swift Brotli decoder is a multi-session project on its own:

- **Brotli format** (RFC 7932): LZ77 variant with custom dictionary + context modeling + complex Huffman coding. ~3–5 sessions to implement from scratch.
- **Vendoring**: there is no widely-used pure-Swift Brotli library at time of writing. Closest is `swift-corelibs-foundation`'s `Brotli` support which is a libbrotli wrapper.
- **Scope reduction**: a decode-only Brotli implementation is enough for `jbrd` (we only ever read these boxes, never write them — and even encoding the box just needs Brotli compression which we could implement after).

### 2.4 `jbrd` box parser ⏳ (also gated on Brotli)

Once Brotli decompression works, the `jbrd` box parsing itself is small:

- ISOBMFF box type `'jbrd'`.
- Payload is Brotli-compressed serialised `jpeg::JPEGData` (libjxl's `lib/jxl/jpeg/jpeg_data.h`).
- Contains: marker order list, Huffman tables (or "default Huffman" flag), DC/AC scan parameters, restart interval, padding bits at end of each scan, original APP segments, comment segments.

Parser is a deserialiser over a Brotli-decompressed byte stream. ~1 session once Brotli is up.

---

## 3. Recommended implementation order

| step | what | sessions | unlocks |
|---|---|---|---|
| 1 | Port `kQuantModeRAW` decode | 1 | Decoder ready for bridge output |
| 2 | `JXLEncoder.encodeFromJPEGCoefficients(_:)` API stub returning `.notImplemented` | 0.25 | API surface frozen for callers |
| 3 | Coefficient-bridge forward implementation (items 2.2.1–2.2.7) | 3–4 | Pixel-faithful forward transcoding works |
| 4 | `jxl transcode --mode coefficient-bridge` wiring | 0.25 | CLI users can invoke the bridge |
| 5 | Pure-Swift Brotli decoder | 4–8 | Reverse direction + compressed ICC profile boxes unblocked |
| 6 | `jbrd` box parser | 1 | Reverse direction data layer ready |
| 7 | Reverse-bridge implementation | 2–3 | Bit-perfect JXL → JPEG works |
| 8 | `jxl transcode --mode reverse` wiring + tests | 0.5 | Round-trip JPEG → JXL → JPEG byte-identical |

**Total realistic estimate to bit-perfect JPEG ↔ JXL transcoding: 12–18 sessions.** The Brotli decoder alone is roughly a third of that. For a faster path to *forward-only* coefficient-bridge transcoding, items 1–4 are 4.5–5.5 sessions.

---

## 4. Open questions

- **Is RAW quant matrix mode actually what libjxl uses for its JPEG transcode output?** Worth confirming by inspecting a few `cjxl --lossless_jpeg=1` outputs with `jxl info` (once `jxl info` reports quant-matrix mode). The libjxl source is the canonical answer.
- **Does the JXL VarDCT spec permit arbitrary per-channel quant matrices for an `XYB`-mode frame, or is it `color_transform=None`-only?** Probably the latter; need to confirm.
- **For non-square JPEG sampling factors** (4:2:2, 4:1:1, etc.), how does the JXL chroma_subsampling field map exactly? Likely a direct mapping but worth deriving from the spec.

---

## 4a. v0.12.0 progress checklist

| sub-step | what | status |
|---|---|---|
| 3.0 | `JPEGCoefficientImage` + `decodeToCoefficients(_:)` data handoff | ✅ v0.12.0a |
| 3.0 | `jxl info` surfaces coefficient-image structure | ✅ v0.12.0b |
| 3.0 | `jxl transcode` CLI surface + this design doc | ✅ v0.12.0e |
| 3.0 | `QuantWeights.getRAWQuantWeights` math primitive | ✅ v0.12.0f |
| 3.0 | `JXLEncoder.encodeFromJPEGCoefficients(_:)` API stub + CLI wire | ✅ v0.12.0g |
| 3.1 | Shape adapter: `JPEGCoefficientImage` → `JXLCoefficientPlanes` (4:4:4 only) | ✅ v0.12.0i |
| 3.2 | Channel-order remap (`JpegOrder` port) for `.ycbcr` / `.none` color_transforms | ✅ v0.12.0j |
| 3.3 | Color decorrelation (`DCzero` for DC, optional AC CFL for `.ycbcr` mode) | ✅ v0.12.0l — DC adjustment done; AC CFL deferred (libjxl default is off too) |
| 3.4 | Quant-matrix injection: data payload (qtable + qtable_den + dcQuantization) | ✅ v0.12.0m — payload structure built per libjxl `enc_frame.cc:770-799`; bitstream-write side (`enc_modular.cc::EncodeQuantTable` calls `ModularGenericCompress`) is a side-quest before 3.6 |
| 3.5 | Frame-header parameter derivation (colorTransform, chromaSubsampling, LoopFilter, encoding) | ✅ v0.12.0n — `JXLBridgeFrameHeaderParams` builder; LoopFilter pinned writable as `gab=false, epfIters=0`. AC strategy plane (all-DCT8×8) is a bridge-encoder concern, not a frame-header field. |
| 3.6 entry | `JXLBridgeEncoder.prepareFromJPEG(_:colorTransform:)` composes 3.1–3.5 into a `JXLBridgeEncoderState` | ✅ v0.12.0o |
| 3.6 write — dep 1 | local-tree modular sub-image encode + decode | ✅ v0.12.0r |
| 3.6 write — dep 2 (prelude) | outer-codestream prelude scaffold (signature + SizeHeader + ImageMetadata + CustomTransformData + FrameHeader) via `VarDCTBitstreamWriter.writeBridgePrelude(state:)` | ✅ v0.12.0v |
| 3.6 write — dep 2 (quant) | per-slot writers + `DequantMatrices` envelope (`writeLibraryEncoding`, `writeRAWEncoding`, `writeDequantMatrices`) | ✅ v0.12.0s + u |
| 3.6 write — dep 2 (sections) | TOC + DC plane + AC global + AC group writers from `state.planes` | ✅ v0.12.0y/z/aa/bb — four section writers shipped |
| 3.6 write — dep 3 | decoder-side local-tree decode (meta-channels path) | ✅ v0.12.0w — `useGlobalTree=false` branch added to `JXLDecoder` reading local tree section + post-tree codebook inline. |
| 3.6 write — `JXLBridgeEncoder.write(state:)` proper | wires dep 1 + dep 2 into bytes | ✅ v0.12.0cc + dd — wire-up + histogram-derived codebooks |
| 3.7 — wire-up | swap `encodeFromJPEGCoefficients(_:)` stub to call `prepareFromJPEG + write` | ✅ v0.12.0ee |
| 3.7 — envelope byte-perfect | FrameHeader + TOC byte-identical to `cjxl --lossless_jpeg=1` | ✅ v0.12.0ff (FrameHeader↔TOC contiguity fix + `kSkipAdaptiveLFSmoothing` flag) |
| 3.7 — section-content bugs found | (a) DC channel wire order [Y, X, B], (b) ACMetadata per-channel dimensions, (c) F16 overflow with `qt[0] < 4` (documented; test fixture updated) | ✅ v0.12.0fh + fi |
| 3.7 — single-section bit-stream continuity | libjxl `is_small_image` short-circuit (`num_groups==1 && num_passes==1`) writes LfGlobal + DC + HfGlobal + AC into ONE shared `BitWriter` with no byte-alignment between sub-sections. Our writer was using four separate BitWriters byte-aligned at each boundary. | ✅ v0.12.0fk |
| 3.7 — djxl decodes the bridge output | `djxl` accepts bridge bytes and produces correct pixels (all-mid-gray 0x80 for the all-zero-coefficient fixture) | ✅ v0.12.0fk — `testJXLEncoder_FromJPEGCoefficients_DjxlAccepts` hard-passes |
| 3.7 — real-content fixture + JPEGDecoder pixel parity | non-zero DC + AC fixture → `djxl(bridgeBytes)` pixels match `JPEGDecoder.decode(jpgBytes)` pixels | 🎉 **shipped** v0.12.0fr — pixel-equivalent within ±2 JPEG-decode rounding tolerance (same tolerance `cjxl --lossless_jpeg=1 + djxl` exhibits vs `djpeg`). The closing-the-loop trajectory across this session: v0.12.0fo (DC scale inversion: stored `1/dcquantization` per libjxl `SetDCQuant`) `max=209→139`, v0.12.0fq (AC coefficient transpose at adapter: `ac[bi][y*8+x] = jpeg[x*8+y]` per libjxl `enc_frame.cc:969`) `139→82`, v0.12.0fr (`base_correlation_b=0` explicit non-default ColorCorrelation DC: libjxl initialises this to `kYToBRatio=1.0` which leaks Y into Cr) `82→2`. |
| 4   | Lift the 4:4:4-only restriction + multi-block bridge fix | ✅ shipped (v0.12.0ft + v0.12.0fx). v0.12.0ft: adapter accepts `{H1V1, H2V1, H1V2, H2V2}` Y sampling with H1V1 chroma; per-channel block dims; `chroma_subsampling` FrameHeader from JPEG factors. v0.12.0fw: 4:4:4 16×16 control test exposes that the residual is a **multi-block** bug. v0.12.0fx: **fixed** — the bridge DC predictor was passing `lo: 0, hi: 127` to `Predictor.gradient.apply(...)`, truncating any DC value > 127. Removed the clamp (libjxl's `ClampedGradient` only does `[min(n, w), max(n, w)]` intrinsically). After-fix diffs: 4:4:4 8×8 `max=2`, 4:4:4 16×16 `max=2`, 4:2:0 16×16 `max=9` (residual ~9 is chroma upsampling filter difference between libjxl and JPEG reference). Test bounds tightened to `≤ 5` (4:4:4) and `≤ 15` (4:2:0). |
| 5   | Pure-Swift Brotli decoder (unblocks `jbrd` + compressed ICC) | 🚧 partial v0.12.0fz → ga → gb. `Sources/JXLSwift/Brotli/` has `BrotliErrors`, `BrotliBitReader` (incl. `readVarLenU8`), `BrotliPrefixCode` (simple + complex format), `BrotliMetaBlock` (stream header WBITS verified vs `brotli --lgwin=N`; meta-block header), `BrotliDecoder` (top-level shell + uncompressed meta-block path verified vs `brotli --quality=0`). 23 unit tests. **Uncompressed Brotli streams (including all real cjxl jbrd payloads for simple JPEGs) decode end-to-end today.** Remaining for compressed-stream support: literal/insert+copy/distance alphabets (RFC 7932 §7), context modeling, static dictionary (~120KB + transforms, §8), LZ77 reconstruction loop. Compressed support is needed only for JPEGs with large EXIF/XMP/ICC blobs that Brotli encodes compressed. |
| 6   | `jbrd` box parser | ✅ shipped v0.12.0g7–g9. `JPEG/JBRDBox.swift` full Bundle walk for the entire `JPEGData::VisitFields` traversal (markers, app/com types and lengths, quant tables, components, Huffman codes with EOI-sentinel handling, scan info, restart interval, reset points + extra zero runs, intermarker, tail, padding bits, marker-order validation cross-check). `JBRDBoxWriter` mirrors the reader; round-trip verified on a real cjxl payload. `JBRDBox.distributeBrotliPayload` (v0.12.0gd) splices decoded Brotli bytes into app/com/inter-marker/tail slots. |
| 7   | Reverse bridge implementation | 🎉 **BYTE-IDENTICAL** shipped v0.12.0g1 → ge. `JXLToJPEGAdapter.reconstruct(coefficients:jbrd:colorTransform:)` walks `jbrd.markerOrder`, emits markers in source order, splices APP/COM/inter-marker payloads from the jbrd's filled byte arrays, emits DQT/SOFn/DHT/SOS via the inverse-bridge pipeline (with EOI-sentinel decrement in DHT bits emission), and produces JPEG bytes that match the source byte-for-byte for the simple-JPEG case. Verified by `testEndToEnd_ByteIdenticalReconstruct_RealCjxlPayload`. `reconstructMinimal(...)` remains the coefficient-identical-only alternative for callers without a jbrd. |
| 8   | `jxl transcode --mode reverse` wiring + tests | 🎉 **shipped** v0.12.0gh — `jxl transcode --mode reverse --source orig.jpg in.jxl out.jpg` produces a byte-identical JPEG for the common-case JPEG. CLI path: parse JXL container → `extractJBRDBox(from:in:)` → parse Bundle → decode Brotli → distribute payload → splice quant + sampling from source → forward-bridge to JXL planes → `JXLToJPEGAdapter.reconstruct(...)` → write output + report byte-identicality. `--source` is required today as a mock for `JXLDecoder.decodeToCoefficients(_:)` (which would extract coefficient planes from the JXL frame's VarDCT bitstream; that API is the remaining piece for a fully autonomous reverse CLI). |

**Next concrete bite when picking this back up:** the **reverse direction** ships at **byte-identicality** for the common-case JPEG (v0.12.0ge). The end-to-end test `testEndToEnd_ByteIdenticalReconstruct_RealCjxlPayload` proves: real cjpeg 4:2:0 fixture → forward bridge → `JXLToJPEGAdapter.reconstruct(...)` driven by a real cjxl-emitted jbrd → rebuilt JPEG matches the source byte-for-byte. The remaining work targets less-common cases: (a) **Brotli compressed-stream support** for JPEGs with large EXIF/XMP/ICC blobs (multi-session — literal/insert+copy/distance alphabets, context modeling, static dictionary, LZ77); (b) **canonical-marker-template reconstruction** for `kICC`/`kExif`/`kXMP` app markers — libjxl `dec_jpeg_data.cc:74-80` rewrites the marker prefix with the well-known tag (`ICC_PROFILE\0`/`Exif\0`/XMP namespace URL) before filling the rest from Brotli; (c) **progressive scan support** in `JPEGScanEncoder` (currently baseline-sequential only). For the CLI: `jxl transcode --mode reverse` needs (a) JXL container parser to find the `jbrd` box, (b) JXL frame decode to recover coefficient planes, (c) `JXLCoefficientPlanes` shape detection. Most pieces are in place from the forward direction.

After step 4, the remaining work for the reverse direction is the pure-Swift Brotli decoder (step 5), then `jbrd` box parser (step 6), then reverse-bridge implementation (step 7), then CLI reverse wiring (step 8).

The diagnostic harness from v0.12.0ff (`testDiagnostic_CompareBridgeToCjxlReference`, `testDiagnostic_DecodeOurBridgeBytes`) stays in place for any future regression hunt — skipped unless `/tmp/jxlswift-bridge-debug.jxl` and `/tmp/cjxl-reference.codestream` exist, so no CI noise.

## 4b. Step 3.6 write — three blocking dependencies (added v0.12.0q)

`JXLBridgeEncoder.write(state:)` was stubbed in v0.12.0q with three named dependencies. Each is a real session of work; the order below minimises rework.

### Dep 1: Modular sub-image encoder with a local tree ✅ shipped v0.12.0r

`Sources/JXLSwift/Modular/ModularSubImage.swift` ships both halves — `ModularSubImage.write(...)` and `ModularSubImage.read(...)` — so they validate each other via round-trip tests without needing a surrounding JXL frame for `djxl` verification. 6 round-trip tests cover constant single-channel, three distinct channels, the 3×8×8 quant-table shape, deterministic pseudo-random content, plus bad-input-shape + channel-count-mismatch rejection paths.

Scope: no transforms, single-leaf default tree (Gradient predictor / multiplier 1 / offset 0). Multi-leaf trees + transforms are follow-on extensions; the v0.12.0r scope matches what the quant-table embedded sub-image needs.

The `read(...)` method here is the foundation for dep 3 (decoder-side local-tree decode), modulo integration with `JXLDecoder`'s frame-level flow.

### Dep 2: VarDCTBitstreamWriter parallel path bypassing `VarDCTEncoder.forward`

The existing `VarDCTBitstreamWriter.encode(frame:distance:gaborish:adaptiveQF:)` calls `VarDCTEncoder.forward(frame:…)` which runs the full **pixel → linear → OpsinXYB → pad → DCT8×8 → quantise** pipeline. The bridge skips all of that and supplies pre-quantised coefficients directly via `JXLBridgeEncoderState`.

The parallel path needs to:
  - Build the JXL `Quantized` shape from `JXLBridgeEncoderState.planes` (DC plane from `planes.dcPerChannel`; AC blocks from `planes.acPerChannel`; AC strategy plane all DCT8×8).
  - Skip Gaborish and adaptive-QF (they don't apply when input is already-quantised coefficients).
  - Write `DequantMatrices` with `kQuantModeRAW` using `state.rawQuantPayload` + Dep 1's encoder for the embedded qtable sub-image.
  - Write `FrameHeader` from `state.frameHeaderParams` (color_transform, chroma_subsampling, loop_filter, encoding).
  - Use `state.colorTransform == .ycbcr ? (1, 0, 2) : (0, 1, 2)` for the JPEG-component → JXL-channel mapping at the AC encoder level (already pre-applied at the data-layer in `state.planes`; just needs to match the FrameHeader).

Estimated work: ~2 sessions. The largest piece by far.

### Dep 3: Decoder-side local-tree decode

Our `JXLDecoder` throws `.notImplemented` on `useGlobalTree = false` (`JXLDecoder.swift` ~line 381). This blocks **decode** of bridge-emitted JXLs through our decoder. The bridge **encoder** doesn't depend on this — verification can use `djxl` against `JPEGDecoder.decode` pixels — but for "decode any in-the-wild cjxl `--lossless_jpeg=1` output" we need it.

Estimated work: ~1 session. Reuse the existing tree-decode machinery (`ModularTree.decode`) at the per-group level instead of pulling from the frame's global tree.

### Recommended order

Dep 1 → Dep 2 → ship `write` → ship 3.7 (swap `encodeFromJPEGCoefficients` stub) → forward-only bridge end-to-end testable via `djxl` verification. Then Dep 3 to unlock decode of bridge output through our own decoder. Then steps 4–8 (subsampling, Brotli, reverse).

## 5. Until then: what `jxl transcode` does today (v0.12.0e)

- **Forward (JPEG → JXL):** pixel-fallback path. Decode JPEG to RGB pixels via `JPEGDecoder.decode`, then VarDCT-encode via `JXLEncoder.encode`. Lossy at both steps. Source JPEG is **not** recoverable from the output.
- **Reverse (JXL → JPEG):** throws `JXLExitCode.notImplemented` with a pointer to this doc.
- **`--mode coefficient-bridge`:** throws with a pointer to this doc.
- **`--mode reverse`:** throws.

The CLI surface is in place so callers can wire against it today; future v0.12.x bites swap the internals to the coefficient-bridge path without API breakage.
