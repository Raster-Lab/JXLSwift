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
| 3.6 write — dep 2 (sections) | TOC + DC plane + AC global + AC group writers from `state.planes` | ⏳ (~1 session — the substantive piece) |
| 3.6 write — dep 3 | decoder-side local-tree decode (not blocking ship — `djxl` verifies bridge output) | ⏳ (~1 session) |
| 3.6 write — `JXLBridgeEncoder.write(state:)` proper | wires dep 1 + dep 2 into bytes | ⏳ stub shipped v0.12.0q |
| 3.7 | Swap `encodeFromJPEGCoefficients(_:)` stub to call the real path; integration test asserts byte-identical pixels vs `JPEGDecoder.decode` on the source bytes | ⏳ |
| 4   | Lift the 4:4:4-only restriction in the adapter (4:2:0 / 4:2:2 chroma subsampling support) | ⏳ |
| 5   | Pure-Swift Brotli decoder (unblocks `jbrd` + compressed ICC) | ⏳ |
| 6   | `jbrd` box parser | ⏳ |
| 7   | Reverse bridge implementation | ⏳ |
| 8   | `jxl transcode --mode reverse` wiring + tests | ⏳ |

**Next concrete bite when picking this back up:** sub-step 3.3 (color decorrelation). It's the one that needs the most libjxl-source consultation — `DCzero` semantics in `enc_frame.cc::ComputeJPEGTranscodingData` and the relationship between JPEG DC values and JXL's modular DC sub-image storage. After 3.3, 3.4 is a straightforward use of the `kQuantModeRAW` math from v0.12.0f (just figure out `qtableDen` so the JXL dequant formula `quant / weight × invQuantAC` recovers `quant × jpegQt[k]`). 3.5–3.7 are then mechanical wiring once 3.3+3.4 produce verifiable per-channel inputs.

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
