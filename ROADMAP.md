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

Spec sections from ISO/IEC 18181-1 and ISO/IEC 18181-2. Each row is verified by a test (where ✅) or a milestone target (where ⏳). The current test suite is **206 / 206 passing** — every ✅ row has a round-trip test that fails when the row stops working. Phase H header parsing is additionally **cross-validated against `cjxl`** dynamically at test time, covering 8/16-bit grayscale, 8/16-bit RGB, RGBA, gray+alpha, float32, ICC profiles, the four named transfer functions (sRGB / Linear / PQ / HLG), and edge cases (1×1, non-multiple-of-8 dimensions). A spec-compliance pass against libjxl 0.11.2 source (April 2026) corrected eight bit-layout bugs that round-trip alone couldn't catch — see the README for the list. **The reader walks eleven spec layers deep** into a real cjxl-emitted Modular lossless file: signature → SizeHeader → ImageMetadata → FrameHeader → TOC → DequantMatrices DC flag → Modular has_tree → tree-section EntropySectionHeader → per-cluster Huffman tables → MA-tree token stream → typed `ModularTree` value → post-tree pixel-data EntropySectionHeader → byte-aligned **`GroupHeader`**. Per-channel pixel residual decoding (apply transforms + walk tree per pixel using computed properties + predictor application) is the next milestone.

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
| Token stream (HybridUint-decoded reads) | libjxl `ANSSymbolReader::ReadHybridUint` | ✅ prefix-code path | `TokenStreamReader.readToken(context:from:)` walks `contextMap[ctx]` → `huffmanTables[cluster].decode` → `uintConfigs[cluster].decode(token)`. Cross-validation against the cjxl-emitted Modular MA-tree (8 layers deep — signature → … → token stream → tree decode) succeeds and verifies the binary-tree invariant `leaves = splits + 1`. ANS-mode rANS state integration and LZ77 length-token expansion remain stubbed. |

### Phase M — Modular (lossless) sub-codec

| Section | Spec ref | Status |
|---|---|---|
| **M0 vertical slice** (project-internal) | n/a — placeholder | ✅ — `MinimalLosslessCodec.encode/decode` round-trips **1–4 channel frames** (grayscale, gray+alpha, RGB, RGBA) at 8 or 16-bit depth. Buffer layout: signature + SizeHeader + ImageMetadata + 'M0' marker + u(3) channel count + (when channels ≥ 3: u(2) RCT variant) + per-channel u(3) predictor IDs + `SimpleEntropyStream`. **Pipeline**: optional RCT (R/G/B only when channels ≥ 3) → per-channel predictor selection (8 predictors: zero/west/north/avgWN/gradient/medianWNGradient/ww/nn) → ZigZag-packed residuals → auto-selected distribution shape (simple / flat / full, picked from observed token histogram by estimated bit cost). **Encode is dual-level parallelised** via GCD: per-channel work runs in parallel (channels ≥ 2), and within each channel the 8 predictor evaluations run in parallel. **Compression**: all-zero 32×32 8-bit (raw 1 024 B) → < 100 B; correlated RGB 32×32 (raw 3 072 B) → ~543 B (RCT); 128×128 natural-shaped grayscale (gradient + noise, raw 16 384 B) → ~6.9 KB / 43 % via full-mode distribution. **Throughput**: 256×256 grayscale ~18 Mpx/s encode (`.balanced`), 75 Mpx/s decode; 1024×1024 grayscale 18 Mpx/s encode, 74 Mpx/s decode; 256×256 RGB 6.7 Mpx/s encode (4.5× faster than the original sequential baseline), 30 Mpx/s decode. CLI subcommands `jxl-tool encode-m0` / `decode-m0` / `benchmark` / `info` (with M0 placeholder section). Public API: `JXLEncoder(options: EncodingOptions(useM0Placeholder: true)).encode(_:)` for programmatic use. **Not** a JXL-spec-compliant file. |
| Frame header | §C.8.1 | ✅ full spec layout; non-default loop-filter writer pending | `FrameHeader` mirrors libjxl `FrameHeader::VisitFields` exactly. Reader handles every field libjxl writes — `frame_type` (U32 selector), `is_modular`, `flags` (U64), color transform (XYB / None / YCbCr), `chroma_subsampling`, `upsampling`, `extra_channel_upsampling`, `group_size_shift` / `xQmScale`/`bQmScale` per encoding mode, the multi-pass `Passes` block (num_passes / num_downsample / shifts / downsamples / last_passes), `dc_level` for DC frames, `custom_size_or_origin` with U32-encoded zig-zag origin + size, per-channel `BlendingInfo` (mode / alpha_channel / clamp / source), `AnimationFrame` duration + optional u(32) timecode, `is_last`, `save_as_reference`, `save_before_color_transform`, name string via `U32(0, u(4), 16+u(5), 48+u(10))`, and the EPF / Gaborish `LoopFilter` block. Cross-validation reads the FrameHeader bytes cjxl emits for both 16×16 RGB and 32×32 grayscale lossless inputs. The all_default writer shortcut is kept (single bit). Non-default LoopFilter writes throw `.unsupportedField` for now (the read path is complete). |
| Frame TOC | §C.8.1.5 | ✅ — sizes-only; permutation pending | `TOC` reader / writer: `has_permutation` u(1), align-to-byte, then `numEntries` × `U32(Bits(10), 1024+u(14), 17408+u(22), 4211712+u(30))` per `kTocDist`. `numEntries(numGroups:numDcGroups:numPasses:)` mirrors libjxl `NumTocEntries`. Cumulative offsets are precomputed. Cross-validation against cjxl's first frame TOC. The entropy-coded permutation payload (`DecodePermutation`) is the next E-phase prerequisite — currently throws `.permutationNotImplemented`. |
| Channel grouping & sub-bitstream | §C.7.2 | ✅ GroupHeader reader | `GroupHeader` reads the per-group prelude — `useGlobalTree` u(1) + `WeightedPredictorHeader` (all_default bit + 7×u(5) + 4×u(4) custom-weight branch) + transforms array (`U32(0, 1, 2+u(4), 18+u(8))` count + per-transform `ModularTransform` block covering RCT / Palette / Squeeze). Round-trip + hand-derived tests; cross-validation against cjxl byte position is pending the byte-alignment math past the post-tree entropy section. Pixel application (apply transforms + walk tree per pixel + read residuals) is the next milestone. |
| Modular tree (MA-tree) | §C.7.4 | ✅ decoder | `ModularTree.decode` reconstructs a typed `[ModularTreeNode]` from a token stream over the 6 tree-decision contexts (`kSplitValContext`, `kPropertyContext`, `kPredictorContext`, `kOffsetContext`, `kMultiplierLogContext`, `kMultiplierBitsContext`). Validates the multiplier constraint `mul_bits < (1 << (31 - mul_log)) - 1` per libjxl. Cross-validation against cjxl-emitted lossless frames asserts the complete-binary-tree invariant. **Encoder is pending**; pixel-reconstruction (apply tree → predictor → residual per pixel) is the next milestone. |
| Predictors (W, N, NW, MED, gradient, WW, NN) + ZigZag signed pack | §C.7.5 | ✅ — pure-math primitives. `Predictor` enum (zero/west/north/avgWN/gradient/medianWNGradient/ww/nn) with edge-fallback `Neighbourhood` reads (now carrying second-order WW/NN values); `PredictorID` u(3)-tag enum for serialisation; `ZigZag` enum for signed↔unsigned residual packing. Round-trip tested on hand-computed values, edge cases, full Int32 boundaries, predict-encode-decode loops, and period-2-column patterns where WW gives perfect prediction. The Self predictor (cross-channel) and per-pixel adaptive selection via the MA-tree (§C.7.4) are pending. |
| Squeeze (multi-resolution) | §C.7.6 | ✅ standalone primitive | `Squeeze.forwardHorizontal/inverseHorizontal` for 1D Haar-like decomposition, plus `forward2D/inverse2D` for axis-0/axis-1 application across a 2D buffer. Lossless integer round-trip via `(res + 1) >> 1` ceil division (correct for two's-complement arithmetic shift on negative values). 7 round-trip tests including exhaustive 0..31² pairs, odd-length tail handling, negative residuals, and composed horizontal+vertical (4-quadrant wavelet). M0 integration is a follow-up. |
| RCT (reversible colour transform) | §C.7.7 | ✅ YCoCg-R | `RCT.forwardPixel/inversePixel` and buffer-level forward/inverse for the YCoCg-R lossless variant. Round-trip tested exhaustively over 0..31³ (32 768 triples) plus full 16-bit-range and negative-value boundaries; decorrelation property verified across 65 bases (Co=1, Cg=2 for `R=base, G=base+1, B=base-1` regardless of base). Wired into MinimalLosslessCodec for 3-channel frames with a u(2) variant ID; encoder picks `.identity` vs `.ycocgR` by total per-channel best-predictor distinct-token count. Caveat: spec defines `rct_type` 0..6 — only YCoCg-R is implemented and the codestream-level numbering / encoding needs spec verification. |

### Phase V — VarDCT (lossy) sub-codec

| Section | Spec ref | Status |
|---|---|---|
| Frame header | §C.8.1 | ⏳ |
| XYB colour transform | §C.8.2 | ⏳ |
| Adaptive block sizes (DCT 8×8 … 32×32, AFV) | §C.8.3 | ⏳ |
| Quantisation matrices | §C.8.4 | ⏳ |
| Adaptive quantisation field | §C.8.5 | ⏳ |
| Chroma-from-luma (CfL) | §C.8.6 | ⏳ |
| Patch / spline / noise synthesis (advanced) | §C.8.7–9 | ⏳ |

### Phase R — Restoration filters (post-decode)

| Section | Spec ref | Status |
|---|---|---|
| Edge-preserving filter (Gabor) | §C.9.1 | ⏳ |
| EPF (loop filter) | §C.9.2 | ⏳ |

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
| Foundation tests (206) | ✅ |
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
