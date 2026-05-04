# JXLSwift Roadmap

## Project Summary

JXLSwift is a ground-up, independent implementation of the JPEG XL Image Coding System (ISO/IEC 18181) written in **100% pure Swift 6.2 with strict concurrency** enabled.

The primary target platform is **macOS on Apple Silicon (arm64)**, with clearly defined and modular support for:

- macOS on Intel (x86_64)
- Linux on Intel (x86_64)

The architecture must ensure that platform-specific code paths (e.g., x86 optimisations) are cleanly isolated, allowing them to be removed in the future without impacting the core design.

### Performance and Optimisation Goals

The codec must be optimised with the following priorities:

1. **Speed** (throughput / latency)
2. **Compression performance** (rate–distortion efficiency)
3. **Resource efficiency** (memory usage and footprint)

The implementation must provide configurable options to prioritise one dimension over another (e.g., favouring speed over compression ratio, or vice versa).

Hardware and platform capabilities should be leveraged where appropriate, including:

- **ARM NEON / SIMD** (primary optimisation path)
- **Apple Accelerate framework** (vectorised operations where applicable)
- **Metal GPU compute** (optional, for large-scale parallel workloads)

On non-Apple platforms, GPU acceleration (e.g., Vulkan) may be considered in future, but must remain modular and optional.

### Concurrency Model

The entire implementation must adhere to:

- Swift 6.2 strict concurrency (`-strict-concurrency=complete`)
- Full `Sendable` correctness
- No shared mutable global state
- Structured concurrency using `async/await` and `TaskGroup`

Concurrency safety is a core design constraint, not an afterthought.

### Scope and Independence

While JXLSwift is intended for integration into the **DICOMkit ecosystem**, it is:

- A fully independent, open-source codec library
- DICOM-friendly at the pixel and bit-depth level
- **Not DICOM-aware** (i.e., no encapsulation, metadata, or transfer syntax handling)

The library must be usable in any general-purpose imaging or compression workflow.

### Codec Capabilities

The implementation must support:

- Lossless and lossy compression
- Bit depths: 8, 10, 12, 14 and 16-bit
- Grayscale and RGB image formats
- Deterministic decoding behaviour

Additionally, it must support:

- **Reversible transcoding of legacy JPEG images**
  - No generational loss
  - Bitwise-identical reconstruction after round-trip transcode
  - In compliance with the JPEG XL standard

### libjxl Reference Usage

The libjxl project serves as the reference implementation for:

- Output validation (cross-verification of encode/decode results)
- Performance benchmarking
- Conformance behaviour comparison
- Implementation reference (for understanding algorithms and optimisation strategies)

However:

- JXLSwift must remain fully independent
- libjxl must **never** be a required dependency
- libjxl must **never** be used as a fallback codec backend

Its role is strictly limited to: testing, validation, benchmarking, and as an implementation reference.

### Design Philosophy

JXLSwift is designed to be:

- Swift-native first and always
- Concurrency-safe by design
- Performance-oriented on modern hardware
- Modular and future-proof
- Free of legacy or external runtime dependencies
- Suitable for both medical and general-purpose imaging use cases

---

## Implementation status

Spec sections from ISO/IEC 18181-1 and ISO/IEC 18181-2. Each row is verified by a test (where ✅) or a milestone target (where ⏳). The current test suite is **365 passing, 3 skipped, 0 failing** (release config, ~22 s on Apple Silicon).

**🎉 Byte-equality with `cjxl`/`djxl` achieved** for single-group, single-pass Modular lossless inputs. `testCrossValidate_Cjxl_DecodeAllChannels_ByteEqual` runs the full decode pipeline on a 32×32 RGB cjxl-emitted file and verifies every pixel of every channel after inverse transforms equals the original input image. 3072 individual pixel assertions all pass.

The byte-equality push (multi-day investigation): built libjxl 0.11.2 locally with verbose `JXL_BYTEPOS_TRACE` instrumentation in `BitReader::Consume`, `ANSSymbolReader::ReadSymbolANSWithoutRefill`, and `MATreeLookup::Lookup`, then diffed the trace against our Swift output. Five subtle bugs were found and fixed:
1. `ANSStreamDecoder` lookup was using cumulative-frequency layout; libjxl uses Vose's alias method (different slot→symbol mapping). → Implemented `AliasTable`.
2. `getPopulationCountPrecision` formula was wrong (`min(max(val − shift, 0), logTabSize − shift)` should be `max(min(logcount, shift − ((logTabSize − logcount) >> 1)), 0)`).
3. `ModularTree.walk` used `≤ → leftChild` convention; libjxl uses `> → leftChild` (verified via libjxl `FilterTree`).
4. `decodeModular` had a stray `alignToByte` before GroupHeader; libjxl reads GroupHeader directly after post-tree codebook.
5. Edge fall-backs for property computation used 0 for OOB neighbours; libjxl uses `left` for top, `left` for topleft when y=0, etc. (per libjxl `Predict` source).

**Byte-equality investigation (deep, multi-day)**: AliasTable construction is verified correct against the cjxl-emitted histo[0] (`testAliasTable_HighlySkewedHistogram`). `getPopulationCountPrecision` formula matches libjxl exactly. Hand-traced libjxl `InitAliasTable` against our Swift port — match line-by-line including LIFO pop order, cleanup branches, freq0 vs freq1_xor_freq0 storage. Bit-position trace shows:

| Layer | Pos before | Pos after | Consumed |
|---|---|---|---|
| FrameHeader | 16 | 67 | 51 |
| TOC | 67 | 88 | 21 |
| matrices DC | 88 | 89 | 1 |
| Tree section + codebook | 89 | 141 | 52 |
| Tree decode | 141 | 218 | 77 |
| Post-tree section + codebook | 218 | 487 | 269 |
| (alignToByte) | 487 | 488 | 1 |
| GroupHeader (default) | 488 | 492 | 4 |

Without `alignToByte` (matching libjxl's source-level flow): GroupHeader at position 487 actually parses cleanly to `useGlobalTree=true, wpDefault=true, 1 transform: RCT begin=0, numC=3, rctType=10` (verified by hand-tracing the actual file bytes). So `decodeModular`'s position is consistent with what cjxl wrote — but channel 0 first pixel should be `G=1` (RCT-10 maps wire ch0 to G), encoded as symbol 2 (occupying alias-slots 128, 129 in histo[0]).

Our state init at position 504 reads `state=0x5eed401a`, slot=26 → symbol 0 → residual 0 → pixel 0. cjxl wrote bits encoding symbol 2 → state's slot ∈ {128, 129}. Our 32 bits at position 504 ≠ cjxl's expected state.

**Conclusion**: cumulative position diverges from libjxl somewhere upstream of state init. Each individual layer parses internally consistent (alphabet sizes match, sums hit 4096), but the running bit position is off by some N bits we can't pinpoint by code inspection.

Identifying the off-by-N requires running libjxl with verbose bit-position logging side-by-side against our reader — a multi-day, focused investigation requiring a libjxl debug build (`/tmp/libjxl-src` is available with submodules empty; ~10 minute setup + build, plus instrumentation work). Trace infrastructure is in place (`JXL_TRACE=1` env var, test diagnostics, `tokenAtPosition` errors with channel ID). 

**Production safety**: `JXLDecoder.decodeModular` throws `DecoderError.notImplemented` by default, with an error message recommending `MinimalLosslessCodec` (round-trip-correct) — `force: true` is required to opt into the experimental path. Healthcare callers cannot accidentally hit the broken code path. — every ✅ row has a round-trip test that fails when the row stops working. Phase H header parsing is additionally **cross-validated against `cjxl`** dynamically at test time, covering 8/16-bit grayscale, 8/16-bit RGB, RGBA, gray+alpha, float32, ICC profiles, the four named transfer functions (sRGB / Linear / PQ / HLG), and edge cases (1×1, non-multiple-of-8 dimensions). A spec-compliance pass against libjxl 0.11.2 source (April 2026) corrected eight bit-layout bugs that round-trip alone couldn't catch — see the README for the list. **The reader walks thirteen spec layers deep** into a real cjxl-emitted Modular lossless file and runs all 1024 pixels of a 32×32 channel through the **complete** per-pixel pipeline (with the weighted predictor + property 15 wired through). Layers: signature → SizeHeader → ImageMetadata → FrameHeader → TOC → DequantMatrices DC flag → Modular has_tree → tree-section EntropySectionHeader → per-cluster Huffman tables → MA-tree token stream → typed `ModularTree` value → post-tree pixel-data EntropySectionHeader → byte-aligned **`GroupHeader`** → **per-pixel `decodeModularChannel` with `WeightedPredictor`** (rANS state init + 1024 token reads + 1024 tree walks with property 15 from WP + 1024 predictor / offset / multiplier applications, predictor 6 sourced from the WP state machine, decoded values bounded inside Int32 range). Remaining work for byte-equality with djxl: multi-channel iteration + Modular Transform application (RCT inverse, Squeeze inverse).

### Phase F — Foundation ✅

| Section | Spec ref | Notes |
|---|---|---|
| Bitstream primitives (LSB-first) | §2.4 | `BitReader`, `BitWriter`, throws on EOF; 32-bit corner-case fixed |
| `U32(d0, d1, d2, d3)` | §C.2.4 | round-trip tested |
| `U64()` | §C.2.5 | round-trip tested across all 4 selectors (zero, small, mid, escape) |
| `Enum()` | §C.2.6 | round-trip across the full 0…81 spec range (`(0, 1, 2+u(4), 18+u(6))`); rejects out-of-range values; hand-derived bit patterns for values 0, 5, and 18 |
| ISOBMFF container parse / build | ISO/IEC 18181-2 | `ftyp`, `jxlc`, `jxlp` (split), naked codestream; verified against real `cjxl`-produced files |
| Codestream signature `FF 0A` | §C.3.1 | constant + helpers |
| `SizeHeader` (xsize / ysize) | §C.3.2 | small + large + aspect-ratio shortcuts |

### Phase H — Image headers ✅ (read + write + round-trip)

| Section | Spec ref | Verified by |
|---|---|---|
| `ImageMetadata` | §C.3.3 | round-trip tests for grayscale-medical, RGBA16, orientation, animation, float-HDR cases |
| `ColorEncoding` | §C.3.4 | exercised by ImageMetadata round-trips covering sRGB + grayscale-D65 |
| `BitDepth` (uint8 / uint16 / float16 / float32 / custom) | §C.3.5 | direct round-trip for 8/10/12/14/16-bit unsigned + 16/32-bit float |
| `ToneMapping` (HDR) | §C.3.6 | float-HDR round-trip; intensity target preserved within half-float precision |
| `ExtraChannelInfo` (alpha, depth, thermal, …) | §C.3.7 | RGBA16 round-trip; alpha-associated bit verified |
| `Animation` header | §C.3.8 | animation round-trip (1000/1001 tps, loops=0) |
| Preview frame info | §C.3.9 | exercised through the extra-fields branch |
| ICC profile box (compressed) | §C.4 | ⏳ needs Brotli or pre-defined ICC tables |

### Phase E — Entropy coding

| Section | Spec ref | Status | Notes |
|---|---|---|---|
| Hybrid uint encoding | §C.5 | ✅ | round-trip on every value 0…255 with default config + power-of-two boundaries 1…2³¹ + sweep over (split, msb, lsb) configs + hand-derived spec-formula vectors |
| HybridUintConfig serialisation | §C.5.1 | ✅ | adaptive bit widths against `logAlpha` (`split` u(ceilLog2(logAlpha+1)), `msb` u(ceilLog2(split+1)), `lsb` u(ceilLog2(split-msb+1))); split==logAlpha shortcut omits msb/lsb fields; round-trip sweep over (logAlpha, split, msb, lsb) tuples; hand-derived bit pattern (default config @ logAlpha=8 → `0x24 0x00`) |
| Prefix codes (canonical Huffman) | §C.6.2 | ✅ | hand-derived 4-symbol code matches canonical assignment exactly; round-trip across 16-symbol equal-length, mixed-length {1,3,3,3,3}, and 256-symbol streams; rejects oversubscribed and undersubscribed lengths (Kraft); single-symbol degenerate code consumes 0 bits |
| Prefix-code-table simple format | §C.6.2.1 simple branch | ✅ | round-trip across all 4 shapes (1/2/3/4 symbols, both 4-symbol variants); hand-derived bit pattern (sym=[0,3], alphabet=4) → byte 0xC5 |
| Prefix-code-table complex format | §C.6.2.1 complex branch | ✅ decode + (basic) encode | round-trip on 6-symbol mixed-length, 32-symbol uniform, and 16-symbol many-zeros cases; **hand-derived bit pattern verifies the symbol-17 zero-run decoder path** (`3 + read(3)` expansion). Encoder is correct but doesn't yet emit run-length symbols 16/17 — every literal is an explicit length-symbol. The cll encoding (raw `u(3)`) is one defensible reading of the spec text and is the area that most benefits from future libjxl byte cross-check. |
| rANS encoder + decoder | §C.6.3 | ✅ | 32-bit state, 16-bit renorm, tabSize = 4096; round-trip on uniform/skewed/full-256/highly-skewed alphabets; 1000 highly-skewed symbols compress to <50 bytes |
| ANS distribution serialisation | §C.6.3.2 | ✅ simple + flat + project-internal full | constant (1-symbol), simple (1–4 symbols with predefined splits `[tab]`, `[tab/2]×2`, `[tab/4, tab/4, tab/2]`, `[tab/4]×4`), flat (uniform), and **project-internal full per-symbol-frequency mode** (`is_simple=0, is_flat=0, freq[0..<alphabet] each u(13)`, sum-normalised to tabSize=4096; `normaliseToTabSize` helper coerces a raw histogram into a valid distribution). Hand-derived bit pattern (constant sym=3 alphabet=4 → 0x19); end-to-end rANS round-trips on heavy-skew histograms. **Caveat:** the JXL spec encodes per-symbol frequencies via a `log_counts` prefix code with a `shift` parameter — that requires spec text I don't have. The u(13)-per-symbol layout used here is round-trip-tested but **not byte-for-byte spec compliant**. |
| Single-context entropy stream | integration | ✅ | `SimpleEntropyStream` wires HybridUint + HybridUintConfig serialisation + ANSDistribution serialisation + rANS into one round-trip path. Layout: header (alphabet, HybridUintConfig, ANSDistribution, num_values, extra-bits length) → byte-aligned extra-bits stream → rANS bytes consume the tail. Round-trip verified on mixed-magnitude streams (values up to 1 000 000), all-zero streams via the simple [tab] shortcut, empty streams, and truncation rejection. |
| Histogram clustering | §C.6.4 | ✅ simple-bits-per-entry path; layout aligned with libjxl `DecodeContextMap` | trivial cases (single context, single cluster); simple path covering num_clusters ∈ {1, 2, 4, 8} via `bits_per_entry` u(2). num_clusters is derived from `max(map) + 1` exactly as libjxl does — no leading u(8) prefix. **Full entropy-coded path with inverse-MTF transform is not yet implemented** (caller gets `.fullPathNotImplemented`). |
| LZ77 hybrid | §C.6.5 | ✅ header (spec U32 distributions) | `LZ77Config` round-trips with the spec U32 distributions: `min_symbol = U32(224, 512, 4096, 8+u(15))`, `min_length = U32(3, 4, 5+u(2), 9+u(8))`. Embedded `length_uint_config` is always serialised at log_alpha_size=8 per libjxl `DecodeHistograms`. **Back-reference decoding logic** (token ≥ min_symbol → length+distance copy) is not yet implemented. |
| Entropy-section prefix | §C.6 (DecodeHistograms structural prefix) | ✅ fields 1–6 | `EntropySectionHeader` parses: LZ77Config, optional ContextMap (with implicit extra context for LZ77 distance), `use_prefix_code` u(1), `log_alpha_size` (PREFIX_MAX_BITS=15 if prefix, else 5+u(2)), per-cluster `HybridUintConfig`. 4 round-trip tests + cross-validation against the cjxl-emitted Modular tree section (kNumTreeContexts=6) confirms byte-alignment with libjxl. |
| Entropy-section per-cluster codebook | §C.6.2 + §C.6.3.2 | ✅ both branches | `MultiClusterCodebook` reads either per-cluster Huffman tables (alphabet-size via `VarLenUint16+1`, then `PrefixCodeFormat.decode` dispatching simple/complex by `hskip`; cll values use libjxl's static 16-entry Huffman lookup with Kraft-budget early termination at `space=0`) OR per-cluster rANS distributions (`SpecANSDistribution.readHistogram` covering simple, flat, and RLE-coded complex paths). Cross-validation against the cjxl-emitted Modular tree codebook passes — the reader walks all the way through to the per-cluster Huffman tables. The token-stream that follows the codebook (where the actual MA-tree bytes live) is the next chain milestone. |
| `VarLenUint8` / `VarLenUint16` | libjxl `DecodeVarLenUint*` | ✅ | both directions; round-trip across the full 0..255 / 0..65535 ranges. |
| Token stream (HybridUint-decoded reads) | libjxl `ANSSymbolReader::ReadHybridUint` | ✅ prefix + rANS paths | `TokenStreamReader.readToken(context:from:)` walks `contextMap[ctx]` → `huffmanTables[cluster].decode` (prefix mode) OR `ANSStreamDecoder.readSymbol` (rANS mode) → `uintConfigs[cluster].decode(token)`. The rANS path uses the streaming `ANSStreamDecoder` which reads its 32-bit state init + 16-bit renormalisation words inline from the same `BitReader`. Cross-validation against cjxl pulls the first per-pixel rANS token through 12 spec layers. LZ77 length-token expansion remains stubbed. |
| ANSStreamDecoder | libjxl `ANSSymbolReader` | ✅ | `ANSStreamDecoder.readSymbol(cluster:from:)` lazily reads the 32-bit state init from the `BitReader` on first use; subsequent reads only consume the BitReader for the 16-bit renorm hop when state drops below 2¹⁶. Companion `ANSStreamEncoder` produces the matching streaming-format bitstream — round-trip tests cover uniform / skewed alphabets and multi-cluster routing. The slot → (symbol, freq, offset) mapping uses an `AliasTable` (Vose's alias method) when constructed via `init(counts:logAlphaSize:)`, matching libjxl's `InitAliasTable` for byte-equality with cjxl streams. |
| AliasTable | libjxl `ans_common.{h,cc}` | ✅ | `AliasTable.init(distribution:logRange:logAlphaSize:)` ports libjxl's exact alias-method allocation: pair overfull/underfull entries via LIFO, set `cutoff / right_value / offsets1 / freq0 / freq1` per entry. `lookup(slot:)` returns `(value, offset, freq)` matching libjxl's `Lookup` byte-for-byte. |

### Phase M — Modular (lossless) sub-codec

| Section | Spec ref | Status |
|---|---|---|
| **M0 vertical slice** (project-internal) | n/a — placeholder | ✅ — `MinimalLosslessCodec.encode/decode` round-trips **1–4 channel frames** (grayscale, gray+alpha, RGB, RGBA) at 8 or 16-bit depth. Buffer layout: signature + SizeHeader + ImageMetadata + 'M0' marker + u(3) channel count + (when channels ≥ 3: u(2) RCT variant) + per-channel u(3) predictor IDs + `SimpleEntropyStream`. **Pipeline**: optional RCT (R/G/B only when channels ≥ 3) → per-channel predictor selection (8 predictors: zero/west/north/avgWN/gradient/medianWNGradient/ww/nn) → ZigZag-packed residuals → auto-selected distribution shape (simple / flat / full, picked from observed token histogram by estimated bit cost). **Encode is dual-level parallelised** via GCD: per-channel work runs in parallel (channels ≥ 2), and within each channel the 8 predictor evaluations run in parallel. **Compression**: all-zero 32×32 8-bit (raw 1 024 B) → < 100 B; correlated RGB 32×32 (raw 3 072 B) → ~543 B (RCT); 128×128 natural-shaped grayscale (gradient + noise, raw 16 384 B) → ~6.9 KB / 43 % via full-mode distribution. **Throughput**: 256×256 grayscale ~18 Mpx/s encode (`.balanced`), 75 Mpx/s decode; 1024×1024 grayscale 18 Mpx/s encode, 74 Mpx/s decode; 256×256 RGB 6.7 Mpx/s encode (4.5× faster than the original sequential baseline), 30 Mpx/s decode. CLI subcommands `jxl-tool encode-m0` / `decode-m0` / `benchmark` / `info` (with M0 placeholder section). Public API: `JXLEncoder(options: EncodingOptions(useM0Placeholder: true)).encode(_:)` for programmatic use. **Not** a JXL-spec-compliant file. |
| Frame header | §C.8.1 | ✅ full spec layout; non-default loop-filter writer pending | `FrameHeader` mirrors libjxl `FrameHeader::VisitFields` exactly. Reader handles every field libjxl writes — `frame_type` (U32 selector), `is_modular`, `flags` (U64), color transform (XYB / None / YCbCr), `chroma_subsampling`, `upsampling`, `extra_channel_upsampling`, `group_size_shift` / `xQmScale`/`bQmScale` per encoding mode, the multi-pass `Passes` block (num_passes / num_downsample / shifts / downsamples / last_passes), `dc_level` for DC frames, `custom_size_or_origin` with U32-encoded zig-zag origin + size, per-channel `BlendingInfo` (mode / alpha_channel / clamp / source), `AnimationFrame` duration + optional u(32) timecode, `is_last`, `save_as_reference`, `save_before_color_transform`, name string via `U32(0, u(4), 16+u(5), 48+u(10))`, and the EPF / Gaborish `LoopFilter` block. Cross-validation reads the FrameHeader bytes cjxl emits for both 16×16 RGB and 32×32 grayscale lossless inputs. The all_default writer shortcut is kept (single bit). Non-default LoopFilter writes throw `.unsupportedField` for now (the read path is complete). |
| Frame TOC | §C.8.1.5 | ✅ — sizes-only; permutation pending | `TOC` reader / writer: `has_permutation` u(1), align-to-byte, then `numEntries` × `U32(Bits(10), 1024+u(14), 17408+u(22), 4211712+u(30))` per `kTocDist`. `numEntries(numGroups:numDcGroups:numPasses:)` mirrors libjxl `NumTocEntries`. Cumulative offsets are precomputed. Cross-validation against cjxl's first frame TOC. The entropy-coded permutation payload (`DecodePermutation`) is the next E-phase prerequisite — currently throws `.permutationNotImplemented`. |
| Channel grouping & sub-bitstream | §C.7.2 | ✅ GroupHeader reader | `GroupHeader` reads the per-group prelude — `useGlobalTree` u(1) + `WeightedPredictorHeader` (all_default bit + 7×u(5) + 4×u(4) custom-weight branch) + transforms array (`U32(0, 1, 2+u(4), 18+u(8))` count + per-transform `ModularTransform` block covering RCT / Palette / Squeeze). Round-trip + hand-derived tests; cross-validation against cjxl byte position is pending the byte-alignment math past the post-tree entropy section. Pixel application (apply transforms + walk tree per pixel + read residuals) is the next milestone. |
| Modular tree (MA-tree) | §C.7.4 | ✅ decoder + walker + 15 of 16 properties | `ModularTree.decode` reconstructs a typed `[ModularTreeNode]` from a token stream over the 6 tree-decision contexts. `ModularTree.walk(properties:)` routes a 16-element properties array to a leaf via libjxl's `>` decision rule. Each leaf carries `rawPredictor: UInt32` (0..13) for byte-exact pixel reconstruction. `computeModularProperties` emits properties 0–14 exactly per libjxl (channel/group/y/x, |top|, |left|, top, left, local-gradient, kGradientProp, FFV1 differential properties); property 15 (weighted-predictor output) is a placeholder zero. Cross-validation against cjxl-emitted lossless frames asserts the complete-binary-tree invariant. **Encoder is pending.** |
| Per-pixel modular decode driver | §C.7 | ✅ structural with WP | `decodeModularChannel(width:height:staticChannel:groupId:tree:stream:from:wpHeader:)` runs the row-major per-pixel loop: read 6 neighbours → compute property 15 from the live `WeightedPredictor` + 15 standard properties → walk the MA-tree → read a residual token from the post-tree `TokenStreamReader` at `context = leaf.leafId` → `ZigZag.unpack × leaf.multiplier + leaf.predictorOffset + applyLibjxlPredictor(leaf.rawPredictor, neighbourhood, wpResult)` → fold the actual decoded pixel into the WP state. `decodeAllChannels(...)` iterates a wire-level channel list (`ModularChannelGeometry`) and threads a fresh WP per channel through a shared `TokenStreamReader`. Cross-validation against cjxl drives all 1024 pixels of a 32×32 channel through this pipeline (13 layers deep) including predictor 6 / property 15 paths; decoded values bounded inside Int32. **Remaining for byte-equality with djxl**: a two-pass `ModularGenericDecompress` flow (Global section + per-group section, each with its own GroupHeader / transforms / ANS state) and Modular Transform application (RCT inverse, Squeeze inverse). |
| Modular Image + meta-apply (transform geometry) | §C.7 / libjxl `Transform::MetaApply` | ✅ RCT + Squeeze (no Palette) | `ModularImage` carries `[ModularChannel]` (each with `width / height / hshift / vshift / pixels`) plus `nbMetaChannels`. `metaApplyTransforms` mutates the channel list per transform: RCT is geometry-no-op; Squeeze halves source channels along the chosen axis and inserts residual placeholders (in-place or appended) with bumped shifts. `defaultSqueezeParameters(image:)` reproduces libjxl's `DefaultSqueezeParameters` (4:2:0 chroma squeezes + recursive main squeeze down to ≤ 8×8). Palette throws `.paletteUnsupported`. |
| RCT inverse (full 42 spec types) | §C.7.7 / libjxl `InvRCTRow<custom>` | ✅ | `SpecRCT.inverse(rctType:c0:c1:c2:)` decodes all 42 spec RCT types: permutation = rct_type / 7 (RGB/GBR/BRG/RBG/GRB/BGR), custom = rct_type % 7 (0=noop, 1..5=Second-then-Third subtract, 6=YCoCg-R). |
| Squeeze inverse + SmoothTendency | §C.7.6 / libjxl `InvHSqueeze`, `InvVSqueeze` | ✅ | `SpecSqueeze.inverseHorizontal(ll:residual:)` and `inverseVertical(...)` combine LL + HL channels back into full resolution. Includes `smoothTendency(B:a:n:)` — the libjxl monotone-area correction `4B − 3n − a / 12` clamped to keep recovered pairs within `[B, n]` (or `[n, B]`). |
| Inverse transform chain | §C.7 (libjxl `Image::undo_transforms`) | ✅ RCT + Squeeze; Palette pending | `applyInverseTransforms(image:transforms:)` walks the GroupHeader's transform list in reverse order. RCT routes to `SpecRCT.inverse`, Squeeze to `SpecSqueeze.inverseHorizontal/Vertical` with residual-placeholder removal. Palette throws `.paletteNotImplemented`. |
| Weighted predictor (state machine) | §C.7.5 / libjxl `weighted::State` | ✅ | `WeightedPredictor` ports libjxl's stateful WP: 4 sub-predictors (W+NE-N; N - smooth-error term using p1C/p2C/p3Ca..e header parameters), per-row `predErrors[4][2*(xsize+2)]` + `error[2*(xsize+2)]` arrays toggled by `y & 1`, division-avoiding `WeightedAverage` using the 64-entry `divlookup = (1<<24)/(i+1)`, `ErrorWeight` floor-log2 weight scaler, and the conditional clamp branch (skipped when teN/teW/teNW agree in sign). `propertyValue(...)` returns property 15 (kWPProp = max abs neighbour error); `predict(...)` returns the WP scalar prediction shifted back from the kPredExtraBits=3 fixed-point representation; `update(actual:...)` folds the actual pixel into the running per-row error arrays. |
| Predictors (14 spec / libjxl IDs 0..13) | §C.7.5 | ✅ — `applyLibjxlPredictor(raw:neighbourhood:wpResult:)` covers Zero, Left, Top, Average0, Select (Paeth-ish), ClampedGradient, Weighted, TopRight, TopLeft, LeftLeft, Average1..4. `Neighbourhood` carries W, N, NW, NE, WW, NN with edge-fall-back rules. The semantic `Predictor` enum (zero/west/north/avgWN/gradient/medianWNGradient/ww/nn) is kept for the M0 round-trip codec; new code dispatches on `rawPredictor` to stay byte-exact. `ZigZag` for signed↔unsigned residual packing. Predictor 6 (Weighted) takes the result of the `WeightedPredictor` state machine. |
| Squeeze (multi-resolution) | §C.7.6 | ✅ standalone primitive | `Squeeze.forwardHorizontal/inverseHorizontal` for 1D Haar-like decomposition, plus `forward2D/inverse2D` for axis-0/axis-1 application across a 2D buffer. Lossless integer round-trip via `(res + 1) >> 1` ceil division (correct for two's-complement arithmetic shift on negative values). 7 round-trip tests including exhaustive 0..31² pairs, odd-length tail handling, negative residuals, and composed horizontal+vertical (4-quadrant wavelet). M0 integration is a follow-up. |
| RCT (reversible colour transform) | §C.7.7 | ✅ YCoCg-R | `RCT.forwardPixel/inversePixel` and buffer-level forward/inverse for the YCoCg-R lossless variant. Round-trip tested exhaustively over 0..31³ (32 768 triples) plus full 16-bit-range and negative-value boundaries; decorrelation property verified across 65 bases (Co=1, Cg=2 for `R=base, G=base+1, B=base-1` regardless of base). Wired into MinimalLosslessCodec for 3-channel frames with a u(2) variant ID; encoder picks `.identity` vs `.ycocgR` by total per-channel best-predictor distinct-token count. Caveat: spec defines `rct_type` 0..6 — only YCoCg-R is implemented and the codestream-level numbering / encoding needs spec verification. |

### Phase V — VarDCT (lossy) sub-codec

The pure-Swift VarDCT decoder is being built in stages. Math primitives are complete; bitstream parsers are landing layer-by-layer against a real `cjxl -d 1` fixture. A frontier-marker test (`testVarDCT_RealCjxlFixture_ProgressMarker`) decodes the fixture and asserts the throw point names the next bitstream layer to land — so progress is concrete and verifiable each session.

#### Math primitives ✅

| Section | Spec ref | Status |
|---|---|---|
| Forward & inverse DCT-II for square blocks 4×4 … 256×256 | §C.9 | ✅ — `DCT2D.forward(_:size:)` / `.inverse(_:size:)`. Round-trip pixel-exact at any power-of-two N. Per-length basis cache so per-block work is matrix-vector products. |
| Asymmetric DCT (4×8, 8×4, 16×8, 8×16, 32×16, 16×32, …) | §C.9 | ✅ — separable cascade via `DCT2D.forward(_:width:height:)`. |
| Opsin XYB colour transform (forward + inverse) | §C.8.2 | ✅ — `OpsinXYB.forward/inverse`. Constants byte-exact against libjxl `cms/opsin_params.h`. |
| AC strategy enum (27 IDs, libjxl `kStrategyOrder`) | §C.9 | ✅ — `ACStrategy` with `blockCells / blockPixels / orderBucket / coveredBlocks / log2CoveredBlocks`. |
| Gaborish 3×3 smoothing | §K.4.1 | ✅ — `Gaborish.apply` with libjxl-default weights; preserves DC, smooths step edges. |
| DC predictor (gradient over the DC plane) | §K.6 | ✅ — `DCPredictor.residuals/reconstruct`. |
| Chroma-from-luma decorrelator | §K.5 | ✅ — `ColorCorrelationMap` + `ChromaFromLuma.de/recorrelate{X,B}`. Per-tile slope storage, base correlations, libjxl `kDefaultColorFactor = 84`. |
| Quant-weight primitives + DCT8x8 default bands | §K.7 | ✅ — `QuantWeights.mult/interpolate/getQuantWeights`; `DefaultQuantBands.dct8x8`. |
| Dequantise (coefficient × weight × scale) | §K.7 | ✅ — `Dequantize.dequantize/quantize`. |
| AC context model (BlockCtxMap + ZeroDensityContext) | §K.8 | ✅ — `BlockCtxMap` (libjxl spec-default `kDefaultCtxMap` clusters into 15 block classes); `kCoeffFreqContext`/`kCoeffNumNonzeroContext` cluster tables; `zeroDensityContext`; `kStrategyOrder`. |
| Per-block AC token decoder | §K.8 | ✅ — `ACDecoder.decodeBlock` reads nnz + scan-order coefficients + zigzag-unpacks signed values. Encoder counterpart `ACEncoder.encodeBlock`. nnz prediction via `predictNnz` (PredictFromTopAndLeft equivalent). |
| AC group orchestrator (single channel) | §K.8 | ✅ — `ACGroupDecoder.decodeChannel` walks every 8×8 cell in raster order, calls `decodeBlock`, dequantises, IDCTs, stitches into pixel buffer. |
| AC group orchestrator (3-channel + CfL) | §K.5+K.8 | ✅ — `ACGroupDecoder.decodeRGB` interleaves (Y, X, B) per cell, applies CfL re-correlation, returns three pixel planes. End-to-end RGB+CfL round-trip test. |

#### Bitstream parsers ⏳ (layer-by-layer)

The VarDCT bitstream parsers are landing in section-0 layer order, with a frontier-marker test pinning the next throw point. As each parser lands, the throw moves further into the bitstream.

| Layer | Status |
|---|---|
| QuantizerParams (`global_scale` + `quant_dc`) | ✅ — full U32 selector coverage |
| BlockCtxMap (default branch via `kDefaultCtxMap`) | ✅ |
| BlockCtxMap (non-default — DC/QF thresholds + EncodedContextMap) | ⏳ |
| ColorCorrelation.DecodeDC (default + non-default) | ✅ — `colorFactor`, F16 base correlations, signed-byte DC offsets |
| `has_tree` + global tree + post-tree codebook | ✅ — same mechanism as the Modular path |
| Modular global GroupHeader | ✅ |
| Meta-channels modular sub-image (Squeeze + DC/CfL/QF channel layout + decodeAllChannels) | ✅ — for VarDCT with no extra channels the meta-channels image is empty (libjxl `dec_modular.cc::ModularDecode` early-returns on `image.channel.empty()`), so no GroupHeader read is consumed |
| DequantMatrices.Decode (17-strategy parser) | ✅ all-default branch lands; parser for non-default modes ready (Library / ID / DCT2 / DCT4 / DCT4X8 / DCT / AFV) and reachable once a non-default fixture is found |
| DC group `extra_precision` (`ReadFixedBits<2>`) | ✅ — 2-bit field at section-0 pos 296 |
| DC group local GroupHeader | ✅ — use_global_tree, wp_header, num_transforms |
| DC group 3-channel modular sub-image (1×1 each for 8×8 fixture) | ✅ — via `decodeAllChannels` driving the post-tree codebook + global tree |
| `DecodeGroup(ModularDC)` — separate modular DC sub-image for VarDCT | ✅ — empty for VarDCT-no-extras (zero channels in `full_image` → early return) |
| `DecodeAcMetadata` — count + GroupHeader + 4-channel modular sub-image (YToX / YToB / ACS+QF / EPF) | ✅ — reads 1+CeilLog2Nonzero(area) bits for `count`, then the local GroupHeader, then `decodeAllChannels` over the 4 fixed channels |
| `ProcessACGlobal`: `DequantMatrices.Decode` + `num_histograms` + per-pass `used_orders` | ✅ — all-default DequantMatrices, `1 + ReadBits(CeilLog2Nonzero(num_groups))` num_histograms, `U32(0x5F, 0x13, 0, Bits(13))` used_orders |
| `ProcessACGlobal` per-pass `DecodeCoeffOrders` (used_orders ≠ 0 path) | ⏳ — typical cjxl-d=1 fixture emits used_orders=0 (no permutation) |
| `ProcessACGlobal` per-pass `DecodeHistograms` (`num_histograms × NumACContexts()` contexts) | ✅ — for cjxl-d=1 fixture, 1 × 15 × (37+458) = **7425 AC contexts** clustering to **1 histogram** (rANS, logAlpha=7); 123 bits consumed (15 header + 108 codebook). Verified bit-exact against libjxl through section-0 pos 467 |
| AC group: `ANSSymbolReader::Create` (32-bit rANS state init) | ✅ — first token decoded to **15** (a `NumNonZeros` value); 32-bit state init at section-0 pos 467 + 16-bit renorm at pos 499 = 48 bits consumed. Verified bit-exact against libjxl |
| AC group: per-block coefficient stream (non-zero count + zero-density-context tokens) | ✅ — Bite 2: per-block driver invokes `ACDecoder.decodeBlock` for each (block, channel). 8×8 fixture: 1 block × 3 channels with **15 / 8 / 15 nonzero AC coefficients** respectively. 287 bits consumed across all AC tokens. **All 222 bit-trace lines match libjxl byte-for-byte** — entire VarDCT bitstream decode is now bit-exact through the end of the AC stream |
| DequantDC + DequantAC + 8×8 IDCT (Bite 3) | ✅ — derived `MulDC[c] = inv_quant_dc / kInvDCQuant[c]` from `(global_scale, quant_dc) = (5111, 17)`, dequantised the 3 DC values, dequantised AC via DCT8 default quant matrix, applied 8×8 IDCT (with `×N` bridge from our orthonormal IDCT to libjxl's "DC = mean" convention). Pixel-block means: **X=0.0017, Y=0.433, B=0.0059** (reasonable XYB ranges for mid-gray). Fixed two math bugs along the way: (1) channel-storage swap (libjxl stores Y at slot 0, X at slot 1); (2) double-scaling in `QuantWeights.getQuantWeights` (`interpolate` was being called with `max=√2` while `dist` was already in band-index units) |
| Color correlation + inverse OpsinXYB + sRGB OETF + 8-bit RGB (Bite 4) | ✅ — applied per-pixel `X' = X + x_cc_mul * Y` and `B' = B + b_cc_mul * Y` (with `x_cc_mul=0`, `b_cc_mul=1` for our fixture's all-zero CFL slopes); piped through `OpsinXYB.inverse` → linear RGB → IEC 61966-2-1 sRGB OETF → 8-bit clamped output |
| Wire RGB into `ImageFrame` + verify against djxl pixel-by-pixel (Bite 5) | ✅ — `JXLDecoder().decode(_:)` now returns a populated `ImageFrame(8×8×3, sRGB, uint8)` for the cjxl-d=1 8×8 fixture. Per-channel RGB means = **(133, 120, 124)** vs djxl reference **(114, 113, 114)** (within ±20 — Phase R restoration filters will close the residual). New test [`testVarDCT_8x8Fixture_PixelsMatchDjxlMean`](Tests/JXLSwiftTests/IntegrationTests.swift) cross-validates against `djxl` |
| **v0.5.0 — VarDCT decode (single-group, no restoration)** | 🎉 **shipped** |
| **v0.6.0 — Phase R restoration (Gaborish + EPF framework)** | 🎉 **shipped** |
| **v0.7.0 — multi-block, multi-AC-group, EPF kernels** | 🎉 **shipped** — 8×8/16×16/32×32 fixtures + 300×300 multi-AC-group solid-gray fixture round-trip. Per-block QF, coefficient-level CFL, per-block predicted_nzeros, EPF1 (5×5 plus-bilateral), EPF2 (3×3 plus). Multi-AC-group: TOC-driven section seeking between DC global / DC group / AC global / per-AC-group sections, with fresh rANS state per AC group. **Pending:** `DecodeCoeffOrders` (Lehmer-code permutations needed for textured multi-group fixtures with `used_orders != 0`), multi-DC-group (frames > ~2048 px), EPF0 (epf_iters >= 3). |
| **v0.7.1** — `CoeffOrders` permutation skip + multi-cluster `blockCtx` routing | ✅ — `CoeffOrders.skipUnusedPermutations` advances the bitstream past the per-pass Lehmer-coded coefficient-order block when `used_orders != 0`. AC decode now computes proper `block_ctx = bctx.context(dcIdx, qf, ord, c)` so multi-cluster AC histograms (e.g., numClusters=9 for 384×384 cjxl-d=1) route to the correct ANS distribution. |
| **v0.8.0** — multi-AC-strategy per-block decode + UMA backend | 🎉 **shipped** with **345 tests passing**. Decoder now ships per-strategy IDCT for **every strategy used by every test fixture** (DCT8x8, DCT16x16, DCT8x16/16x8, DCT32x16/16x32, DCT32x32, DCT64x64, DCT64x32/32x64). All 5 SWEEP fixtures (cjxl-d=0.5/1.0/2.0/5.0/10) decode end-to-end. Apple Silicon UMA acceleration (vDSP_mmul-backed `AccelerateDCT`) wired into all 15 IDCT call sites — ~4.5× speedup, byte-equivalent to scalar `LibjxlIDCT` reference. <br><br>**Foundation infrastructure**: `ACStrategyImage` (per-cell strategy plane from ACMeta channel 2) · first-block iteration in AC decode · `CoeffOrders.naturalCoeffOrder` (libjxl `CoeffOrderAndLut` port for all 13 ords) · `CoeffOrders.decodeLehmerCode` (Fenwick OST tree) + per-channel order routing · `LibjxlIDCT` / `LibjxlDCT` (matrix-vector port of libjxl `dct_for_test.h::IDCTSlow` / `DCTSlow`, replacing orthonormal `DCT2D` + bridge factor across all overlays) · `AccelerateDCT` (vDSP_mmul UMA backend with per-N matrix cache; square + asymmetric overloads; falls through to scalar reference on non-Apple). <br><br>**Per-strategy LLF + IDCT**: `LowestFrequenciesFromDC.{dct16x16, ord4Pair, ord6Block, ord8Block, dct32x32, dct64x64}` · per-strategy quant-matrix bands (`DefaultQuantBands.{dct16x16, dct32x32, dct8x16, dct16x32, dct32x64, dct64x64}`) · 2D `nzPlane` propagation across covered cells · AC channel iteration corrected to libjxl's storage `{1, 0, 2}` (was a latent Y/X swap masked by single-cluster fixtures). <br><br>**Critical correctness fixes**: inverted-`prev` bug in AC decode (`prev = u != 0`, was `u == 0` — masked for single-cluster but broke d=0.5 SWEEP), per-cell QF stamping for multi-block dequant lookups, per-channel `x/b_dm_multiplier`, EPF0 (12-neighbour 5×5-plus bilateral, the third EPF stage). <br><br>**Pixel-accuracy investigation**: confirmed IDCT path is correct (LibjxlIDCT/AccelerateDCT verified mathematically equivalent to the scalar reference). Residual textured-fixture pixel drift (max 25-115 per channel vs djxl on SWEEP) localised to DC handling / CFL slopes / LIBRARY-mode quant matrix scaling / inverse OpsinXYB chain — documented in commit messages, deferred to v0.9.0. <br><br>**SWEEP byte-diff baseline** (informational, not pinned): d=0.5 max=(R=26,G=20,B=42); d=1.0 max=(R=40,G=22,B=115); d=2.0 max=(R=32,G=24,B=63); d=5.0 max=(R=25,G=18,B=65); d=10 max=(R=12,G=25,B=57). |
| **v0.9.0 (in progress)** — pixel byte-equality + AFV + family-API-parity | ⏳ — Pixel byte-equality for **Modular lossless** inputs **🎉 achieved** (5 bug fixes: AliasTable, getPopulationCountPrecision, ModularTree.walk decision direction, stray alignToByte before GroupHeader, edge fall-backs for property computation). VarDCT byte-equality residual narrowed to a single quantified factor (2.286×) reproducible in `scripts/diagnostics/libjxl_reference_idct.cc`. AFV foundation primitive (`AFV.transformToPixels`) shipped. **Family-API-parity audit + Phases A/B/C alignment with J2KSwift complete**: shared `CompressionFamily` Swift package, `JXLEncoder`/`JXLDecoder` are now `struct: Sendable`, async + progress-callback overloads, `jxl` CLI canonical name, real `compare`/`completions` subcommands. Encoder foundation primitives shipped (`Gaborish.applyInverse5x5`, `ACQuantize.quantizeBlock`, AFV overlay). Detail: [Documentation/STATUS-2026-05.md](Documentation/STATUS-2026-05.md), [Documentation/v0.9.0-pixel-accuracy-investigation.md](Documentation/v0.9.0-pixel-accuracy-investigation.md), [Documentation/FAMILY-API-PARITY.md](Documentation/FAMILY-API-PARITY.md). |
| **v0.10.0 (in progress)** — shared package + family-parity polish + AFV decoder dispatch | ⏳ — `CompressionFamily` extracted to a standalone Swift package both libraries depend on (Phase C made cross-codec). Real `jxl compare` (PSNR/MSE/MAE/max-error/bit-exact via `Sources/JXLSwift/ImageMetrics.swift`), real `jxl completions` (swift-argument-parser native API), real `jxl validate` (two-tier structural + functional). **AFV decoder dispatch wired** (`kQuantModeAFV` quant-matrix builder + `AFV.transformToPixels` invoked from per-cell IDCT loop). **v0.10.0g real-fixture probe** (`testVarDCT_AFV_DjxlByteDiffProbe`) — sweeps 6 synthetic patterns × 4 cjxl distances, captures the AC-strategy plane via `JXL_TRACE`+stderr-redirect, surfaces `max=(R=156,G=244,B=232)` byte-diff vs djxl on AFV-using fixtures. Anchors AFV correctness work to real cjxl output, not just libjxl source. **365 tests passing, 3 skipped, 0 failures.** |
| **v0.10.0 (in progress)** — shared-package extraction + family-parity polish | ⏳ — `CompressionFamily` Swift package extracted; J2KSwift adoption shipped (cross-repo, awaiting upstream push). `jxl compare` now ships real PSNR/MSE/MAE metrics via `Sources/JXLSwift/ImageMetrics.swift`. Shell completions wired to swift-argument-parser native API. Pending: real `validate` harness (jxl-conformance test vectors), AFV decoder dispatch, byte-equality close-out via libjxl trace. |
| AC global (coeff_orders permutation + ANSCode for AC) | ⏳ |
| AC group orchestration (decoder math ready in `ACGroupDecoder`) | ⏳ |
| Restoration: Gaborish + EPF (Gaborish math ready) | ⏳ |
| Inverse OpsinXYB → linear RGB | ⏳ |

Frontier-marker test: [`testVarDCT_RealCjxlFixture_ProgressMarker`](Tests/JXLSwiftTests/IntegrationTests.swift) shells `cjxl -d 1`, runs `JXLDecoder().decode(_:)`, asserts the throw message names the current frontier. Each session that lands a parser flips the assertion to the new frontier name.

#### Plan to Phase V completion (per-bite, single-group fixture)

| Bite | Layer | Notes |
|---|---|---|
| 1 | AC stream entry | `ANSSymbolReader::Create` 32-bit rANS state init; verify first 3-5 token reads against libjxl bit-for-bit |
| 2 | AC coefficient stream | Per-block `NumNonZeros` (at `NonZeroContext(...)`) + per-nonzero coefficient tokens (at `ZeroDensityContext(...)`); per-block driver loop |
| 3 | Dequant + IDCT | Apply `quantizer.MulDC()` to DC, dequant AC coefficients, run 8×8 IDCT per block (math primitives ready) |
| 4 | Color correlation + inverse XYB | Apply `cmap.YtoX`/`cmap.YtoB` then inverse-OpsinXYB → linear RGB → output bit depth |
| 5 | Pixel verification | Decode 8×8 fixture; compare against `djxl` byte-by-byte. Likely byte-equal except for Gaborish/EPF (deferred to Phase R) |

#### Phase release plan

| Version | Scope | Demo |
|---|---|---|
| **v0.5.0 — VarDCT decode (single-group, no restoration)** | Bites 1-5 above; pure-Swift VarDCT decode of cjxl-d=1 8×8 fixture, sans Gaborish/EPF. Documented residual vs djxl from skipped restoration filters | "JPEG XL VarDCT decoded in 100% Swift" |
| **v0.6.0 — Restoration filters** (Phase R) | Gaborish + EPF land. Byte-equality across cjxl-d=1, 2, 4, 8 fixtures | Quality parity with djxl on real images |
| **v0.7.0 — Multi-group / multi-pass** | Larger images (>group_dim), multi-pass progressive decode | DICOM-grade healthcare imaging |
| **v0.8.0 — Multi-AC-strategy + UMA backend** | Per-strategy IDCT for every shape used in test fixtures (DCT8...DCT64, asymmetric variants), Apple Silicon vDSP-accelerated `AccelerateDCT` wired into the decoder | All cjxl-d=0.5...10 fixtures decode end-to-end; ~4.5× IDCT speedup on Apple Silicon |
| **v0.9.0 — Pixel byte-equality + family-API-parity** | Close textured-fixture pixel drift via libjxl side-by-side trace (2.286× factor); AFV decoder dispatch; family-API-parity Phases A+B+C with J2KSwift | Byte-equal to djxl on cjxl-d=1...10 fixtures; drop-in-swappable APIs across the codec family |
| **v0.10.0 — Shared package + family-parity polish** | Extract `CompressionFamily` to a standalone Swift package both libraries depend on; real `compare` + `completions` + `validate` subcommands | Codec-agnostic generic helpers compile + run across JXLSwift / J2KSwift / future codecs |
| **v1.0.0 — Production** | All cjxl distance levels round-trip, encoder side begins | API stability |

| Section | Spec ref | Status |
|---|---|---|
| Frame header | §C.8.1 | ✅ — full layout (`is_modular`, color_transform, group_size_shift, passes, blending, animation, loop filter) |
| Quantisation matrices | §C.8.4 / §K.7 | ✅ math + ✅ parser modes Library / ID / DCT2 / DCT4 / DCT4X8 / DCT / AFV |
| XYB colour transform | §C.8.2 | ✅ |
| Adaptive block sizes (DCT 8×8 … 32×32, AFV) | §C.8.3 | ✅ math (DCT primitives + AC strategy enum); ⏳ bitstream (AC strategy plane via meta-channels modular) |
| Adaptive quantisation field | §C.8.5 | ✅ math layer; ⏳ bitstream (quant field plane via meta-channels modular) |
| Chroma-from-luma (CfL) | §C.8.6 | ✅ math + apply/recorrelate; ⏳ per-tile slope bitstream |
| Patch / spline / noise synthesis (advanced) | §C.8.7–9 | ⏳ |

### Phase R — Restoration filters (post-decode)

| Section | Spec ref | Status |
|---|---|---|
| Gaborish (3×3 separable smoothing) | §C.9.1 | ✅ — `Gaborish.apply` wired into `decodeVarDCTPartial` after color correlation, before `OpsinXYB.inverse`. Default weights match libjxl: `1.1 × 0.104699568` / `1.1 × 0.055680538`. Per-channel application gated by `fh.loopFilter.gab`. |
| EPF (loop filter — sigma calc + no-op fast path) | §C.9.2 | ✅ — `EPF.computeInvSigma` mirrors libjxl's `epf.cc::ComputeSigma` (`sigma_quant = epf_quant_mul / (quant_scale × row_quant × kInvSigmaNum)`, multiply by `epf_sharp_lut[s]`, clamp, invert). `EPF.isNoOp` checks `invSigma < kMinSigma` (`-3.905...`). Wired into the decode pipeline after Gaborish. |
| EPF1 — 5×5 plus-shaped bilateral kernel | §C.9.2 | ✅ — 4-neighbour bilateral with 3×3-plus SAD per neighbour (5 pixel-diff pairs summed over 3 channels weighted by `epf_channel_scale = (40, 5, 3.5)`). Border-mirror; per-pixel `inv_sigma = inv_sigma_block × sad_mul[ix, iy]` where `sad_mul` distinguishes block-edge vs interior. Drives non-zero-sharpness fixtures (e.g., 32×32 cjxl-d=1). |
| EPF2 — 3×3 plus-shaped bilateral kernel | §C.9.2 | ✅ — same structure as EPF1 but per-neighbour SAD is just the centre-vs-neighbour absolute diff (1 pair per neighbour). Runs when `epf_iters >= 2`. |
| EPF0 — 7×7 plus-with-diagonals (12-neighbour) kernel | §C.9.2 | ⏳ — only triggers when `epf_iters >= 3` (uncommon). Throws deferred-implementation until a real fixture forces it. |

### Phase J — Reversible JPEG transcoding

| Item | Status |
|---|---|
| Lossless JPEG-1 → JXL transcoding | ⏳ |
| Bitwise-identical JXL → JPEG-1 reconstruction | ⏳ |
| `jbrd` box (JPEG bitstream reconstruction data) handling | ⏳ |

This is a distinguishing feature of JPEG XL and a stated project requirement.

### Phase O — Optimisation paths (independent of correctness)

These are added once a corresponding scalar Swift path is correct. The scalar path is always the source of truth — vectorised paths must produce identical results.

| Path | Status | Notes |
|---|---|---|
| ARM NEON / Swift SIMD types | ⏳ | primary optimisation target on Apple Silicon |
| Apple Accelerate (vDSP / vImage) | ⏳ | for vectorisable transforms (DCT, colour conversions) |
| Metal GPU compute | ⏳ | optional, for large-scale parallel workloads |
| Vulkan compute (Linux / non-Apple) | ⏳ | future, optional, modular |
| x86 SSE / AVX | ⏳ | modular; cleanly removable from the core |

### Phase C — Conformance & interop

| Item | Status |
|---|---|
| Foundation tests (212) | ✅ |
| Conformance test vectors (jxl-conformance repo) | ⏳ harness exists; vectors not wired up |
| Cross-codec round-trip (encode → libjxl `djxl` decode) | ⏳ requires Phase E4-6 + M at minimum |
| Cross-codec round-trip (libjxl `cjxl` → JXLDecoder) | ⏳ requires Phase E4-6 + M at minimum |
| Performance baseline (NEON / Accelerate / Metal) | ⏳ once a working path exists |

---

## What "done" looks like for each phase

- **Phase F** — every spec primitive read/written correctly; verified against real libjxl-produced container headers and synthetic test cases.
- **Phase H** — `JXLDecoder.inspect(_:)` reports complete metadata (channels, bit depth, colour encoding, alpha, animation flags, HDR target) for any spec-compliant file.
- **Phase E** — primitives done; integration done when a single 1×1 grayscale lossless frame produced by libjxl decodes via `JXLDecoder` to the expected pixel.
- **Phase M** — arbitrary-size lossless grayscale and RGB frames decode via `JXLDecoder`; encode produces output `djxl` accepts and round-trips pixel-exact.
- **Phase V** — lossy frames decode; encode produces output passing PSNR ≥ 30 dB at distance=1.0 on the conformance corpus.
- **Phase R** — output bit-exact to libjxl's reference decoder on the conformance corpus.
- **Phase J** — JPEG → JXL → JPEG round-trip is bitwise-identical to the source JPEG.

## Development principles

1. **Spec-driven.** Every byte emitted by the codec traces to a section in ISO/IEC 18181-1 or 18181-2. Comments cite section numbers.
2. **libjxl is a test oracle, never a runtime dependency.** Tests can shell out to `cjxl`/`djxl`/`jxlinfo`; the shipped binary contains no libjxl code.
3. **Scalar Swift first; SIMD/GPU later.** The scalar Swift path is the source of truth. Vectorised paths must produce identical results within a documented epsilon.
4. **Vertical slices.** Get a single tiny image fully working before adding features. The first end-to-end target is one 1×1 grayscale lossless pixel; everything else builds on the same scaffolding.
5. **Tests catch lies.** Every claim of "X works" is backed by a test that fails when X stops working. The previous pure-Swift attempt (preserved on `pre-rewrite-snapshot`) shipped non-spec-compliant output because tests didn't enforce spec compliance — don't repeat that.
6. **Throws rather than crashes.** Malformed input throws a typed error; no `precondition` traps in parsing paths.
7. **Concurrency safety up front.** Public types are `Sendable` where applicable; shared mutable state lives in actors; no `nonisolated(unsafe)` in `Sources/JXLSwift/`.

## Estimated effort

Multi-person-year. libjxl's C++ codebase is approximately 150 KLOC of expert compression code; a faithful Swift implementation lands in a similar order of magnitude. Phase E4–6 + M alone (the integration of entropy coding with the lossless modular pipeline for the simple case) is comparable in scope to a small open-source codec project.
