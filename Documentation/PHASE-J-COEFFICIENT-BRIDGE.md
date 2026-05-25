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

## 5. Until then: what `jxl transcode` does today (v0.12.0e)

- **Forward (JPEG → JXL):** pixel-fallback path. Decode JPEG to RGB pixels via `JPEGDecoder.decode`, then VarDCT-encode via `JXLEncoder.encode`. Lossy at both steps. Source JPEG is **not** recoverable from the output.
- **Reverse (JXL → JPEG):** throws `JXLExitCode.notImplemented` with a pointer to this doc.
- **`--mode coefficient-bridge`:** throws with a pointer to this doc.
- **`--mode reverse`:** throws.

The CLI surface is in place so callers can wire against it today; future v0.12.x bites swap the internals to the coefficient-bridge path without API breakage.
