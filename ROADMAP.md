# JXLSwift Roadmap

This document maps ISO/IEC 18181 spec sections to JXLSwift implementation status. Honest accounting — what works, what's stubbed, what's not started.

**Today's status: foundation only.** A `.jxl` file's container and SizeHeader can be parsed; the actual codec layer (Modular tree, VarDCT, rANS) is not implemented. Calling `JXLEncoder.encode` or `JXLDecoder.decode` throws `.notImplemented`.

For users who need a working JXL pipeline today, switch to the `libjxl-backend` branch — that's the libjxl-backed implementation that this branch is replacing.

---

## Implementation phases

### Phase F — Foundation ✅ DONE

| Section | Spec ref | Status | Notes |
|---|---|---|---|
| Bitstream primitives (LSB-first) | ISO/IEC 18181-1 §2.4 | ✅ | `BitReader`, `BitWriter`, throw on EOF |
| `U32(d0, d1, d2, d3)` | §C.2.4 | ✅ | round-trip tested |
| `U64()` | §C.2.5 | ✅ | round-trip tested across all 4 selectors |
| `Enum()` | §C.2.6 | ✅ | reader path; writer is a small follow-up |
| ISOBMFF container parse / build | ISO/IEC 18181-2 | ✅ | `ftyp`, `jxlc`, `jxlp` (split), naked codestream |
| Codestream signature `FF 0A` | §C.3.1 | ✅ | constant + helpers |
| `SizeHeader` (xsize / ysize) | §C.3.2 | ✅ | small + large + aspect-ratio shortcuts; verified against real cjxl-produced files |

### Phase H — Image headers (codestream pre-pixel) ✅ DONE (read + write + round-trip)

| Section | Spec ref | Status | Verified by |
|---|---|---|---|
| `ImageMetadata` | §C.3.3 | ✅ read + write | round-trip tests for grayscale-medical, RGBA16, orientation, animation, float-HDR cases |
| `ColorEncoding` | §C.3.4 | ✅ read + write | exercised by ImageMetadata round-trips covering sRGB + grayscale-D65 |
| `BitDepth` (uint8 / uint16 / float16 / float32 / custom) | §C.3.5 | ✅ read + write | direct round-trip tests for 8/10/12/16-bit unsigned + 16/32-bit float |
| `ToneMapping` (HDR) | §C.3.6 | ✅ read + write | float-HDR round-trip; intensity target preserved within half-float precision |
| `ExtraChannelInfo` (alpha, depth, thermal, …) | §C.3.7 | ✅ read + write | RGBA16 round-trip; alpha-associated bit verified |
| `Animation` header | §C.3.8 | ✅ read + write | animation round-trip (1000/1001 tps, loops=0) |
| Preview frame info | §C.3.9 | ✅ read + write (uses SizeHeader) | exercised through the extra-fields branch |
| ICC profile box (compressed) | §C.4 | ⏳ not yet | needs Brotli or pre-defined ICC tables |

### Phase E — Entropy coding

| Section | Spec ref | Status | Verified by |
|---|---|---|---|
| Hybrid uint encoding | §C.5 | ✅ encode + decode | round-trip on every value 0…255 with default config + power-of-two boundary values 1…2³¹ + sweep over (split, msb, lsb) configs + hand-derived spec-formula vectors |
| HybridUintConfig serialisation (read/write the 3 params) | §C.5.1 | ⏳ deferred until distributions land — config is parsed per-distribution, not standalone |
| Prefix codes (canonical Huffman) | §C.6.2 | ✅ encode + decode | hand-derived 4-symbol code matches canonical assignment exactly; round-trip across 16-symbol equal-length, mixed-length {1,3,3,3,3}, and 256-symbol streams; rejects oversubscribed and undersubscribed lengths (Kraft); single-symbol degenerate code consumes 0 bits |
| Prefix-code-table serialisation (the bitstream encoding of the per-symbol lengths array) | §C.6.2.1 | ⏳ |
| rANS distributions | §C.6.3 | ⏳ |
| Histogram clustering | §C.6.4 | ⏳ |
| LZ77 hybrid | §C.6.5 | ⏳ |

### Phase M — Modular (lossless) sub-codec

| Section | Spec ref | Status |
|---|---|---|
| Modular tree (MA-tree) | §C.7.4 | ⏳ |
| Predictors (W, N, NW, MED, …) | §C.7.5 | ⏳ |
| Squeeze (multi-resolution) | §C.7.6 | ⏳ |
| RCT (reversible colour transform) | §C.7.7 | ⏳ |
| Channel grouping & sub-bitstream | §C.7.2 | ⏳ |

### Phase V — VarDCT (lossy) sub-codec

| Section | Spec ref | Status |
|---|---|---|
| Frame header | §C.8.1 | ⏳ |
| XYB color transform | §C.8.2 | ⏳ |
| Adaptive block sizes (DCT 8×8 … 32×32, AFV) | §C.8.3 | ⏳ |
| Quantisation matrices | §C.8.4 | ⏳ |
| Adaptive quantisation field | §C.8.5 | ⏳ |
| Chroma-from-luma (CfL) | §C.8.6 | ⏳ |
| Patch / spline / noise synthesis (advanced) | §C.8.7-9 | ⏳ |

### Phase R — Restoration filters (post-decode)

| Section | Spec ref | Status |
|---|---|---|
| Edge-preserving filter (Gabor) | §C.9.1 | ⏳ |
| EPF (loop filter) | §C.9.2 | ⏳ |

### Phase C — Conformance & interop

| Item | Status |
|---|---|
| Foundation tests (16) | ✅ pass against real `cjxl`-produced files |
| Conformance test vectors (jxl-conformance repo) | ⏳ harness exists; vectors not wired up |
| Cross-codec round-trip (encode → `djxl` decode) | ⏳ requires Phase E + M at minimum |
| Cross-codec round-trip (encode `cjxl` → JXLDecoder) | ⏳ requires Phase E + M at minimum |
| Performance baseline | ⏳ once a working path exists |

---

## What "done" looks like for each phase

- **Phase F (foundation)** — can read/write any spec primitive correctly; verified by unit tests + parsing real libjxl-produced container headers.
- **Phase H (image headers)** — `JXLDecoder.inspect(_:)` reports complete metadata (channels, bit depth, color encoding, alpha, animation flags) for any spec-compliant file.
- **Phase E (entropy coding)** — can decode a single 1×1 grayscale lossless frame produced by libjxl. Round-trip via `cjxl` → `JXLDecoder.decodeAll` returns the expected single pixel.
- **Phase M (Modular)** — can decode arbitrary-size lossless grayscale frames produced by libjxl. Encode path: produces output `djxl` accepts, with the lossless contract holding pixel-exact.
- **Phase V (VarDCT)** — can decode lossy frames produced by libjxl. Encode path: produces output passing PSNR ≥ 30 dB at distance=1.0 on the conformance corpus.
- **Phase R (restoration filters)** — output bit-exact to libjxl's reference decoder on the standard conformance test suite.

## Development principles

1. **Spec-driven.** Every byte we emit must be traceable to a section in ISO/IEC 18181-1 or 18181-2. Comments cite section numbers.
2. **libjxl as test oracle.** `cjxl`/`djxl`/`jxlinfo` are development tools used to validate output, not runtime dependencies. They never ship in the binary.
3. **Vertical slices.** Get a single tiny image fully working before adding features. The first end-to-end target is *one 1×1 grayscale lossless pixel*; everything else builds on the same scaffolding.
4. **Tests catch lies.** Every claim of "X works" is backed by a test that fails if X stops working. The previous pure-Swift attempt failed because it claimed v1.0.0 status without conformance verification — this branch will only claim what's tested.
5. **Throws rather than crashes.** Malformed input throws a typed error; no `precondition` traps in parsing paths.

## Estimated effort

This is multi-person-year work. The libjxl C++ codebase is approximately 150 KLOC of expert compression code; a faithful Swift implementation should land in a similar order of magnitude. Phase E + M alone (lossless modular encode/decode for the simple case) is comparable in scope to a small open-source codec project.

The existing `libjxl-backend` branch remains available as a working implementation while the pure-Swift path is developed. Users who need JXL today use that branch; users who want to contribute pure-Swift work should pick a phase and submit PRs against `main`.
