# Autonomous session — 2026-05-27 (late evening continuation)

Continued from the evening session's `v0.12.0gu` (autonomous
`JXLDecoder.decodeToCoefficients`). This session shipped the
**SpecialDistance LZ77 remap** that unblocks decoding cjxl-emitted
RAW slot 0 quant matrices.

## TL;DR

Shipped `v0.12.0gv` — one focused commit that fixes a subtle
LZ77 distance-interpretation bug in `TokenStreamReader`. Before
the fix, our reader applied the simpler "decoded + 1" rule to
LZ77 distances for *all* call sites; libjxl applies a 120-entry
2D-pattern LUT (`SpecialDistance`) to modular sub-image readers
when `distance_multiplier > 0`. The bug only surfaced for
cjxl-emitted RAW slot 0 quant matrices, where decoded-247 became
248 instead of the correct 128 (= 247 + 1 − 120), tripping
`lz77InvalidDistance(distance: 248, historySize: 128)`.

Threading the multiplier through fixed it; a focused regression
test pins the behaviour down so it can't silently regress.

## Commit trail

```
064bdec v0.12.0gv  SpecialDistance LZ77 remap for modular sub-images
```

## Files touched

```
CHANGELOG.md                                     | +62
Sources/JXLSwift/Codec/JXLDecoder.swift          | +42 -3
Sources/JXLSwift/Entropy/TokenStreamReader.swift | +83 -7
Sources/JXLSwift/Modular/ModularSubImage.swift   |  +8 -2
Sources/JXLSwift/VarDCT/QuantEncoding.swift      |  +9 -2
Tests/JXLSwiftTests/JPEGTests.swift              | +94
```

## What the fix does

`TokenStreamReader.beginLZ77Copy` now reads the raw HybridUint
distance value (no eager `+1`) and applies libjxl's
`ReadHybridUintClusteredInlined` logic:

- `distanceMultiplier == 0` (TOC permutation / context-map / tree
  streams): unchanged `decoded + 1` rule.
- `distanceMultiplier > 0` AND raw < 120: index the 120-entry
  `kSpecialDistancesLUT` (WebP-lossless inheritance) and compute
  `max(1, rowOffset + multiplier × colOffset)`. The LUT is shared
  with libjxl byte-for-byte.
- `distanceMultiplier > 0` AND raw ≥ 120: `raw + 1 − 120`.

Threaded `distanceMultiplier` into four modular sub-image
callers: `QuantEncoding.swift` (RAW slot), `ModularSubImage.swift`
(embedded sub-image), and three places in `JXLDecoder.swift`
(LfGlobal single-section, multi-section global, per-group AC).
Each passes the widest channel width across the channels that
reader services — mirroring libjxl's
`DecodeModular::distance_multiplier` computation
(`modular/encoding/encoding.cc:566-580`).

## Regression test

`testEndToEnd_CjxlReverseDecode_NoLZ77DistanceError` in
`JPEGTests.swift / JXLToJPEGAdapterTests`. Round-trips
`ppm → cjpeg → cjxl --lossless_jpeg=1` and asserts the resulting
JXL bytes do **not** throw `TokenStreamReaderError.lz77InvalidDistance`
when fed to `JXLDecoder.decodeToCoefficients`. Later-stage decode
errors are tolerated; only the LZ77 regression fails the test.

## Test status

```
swift test -c release
642 tests / 7 skipped / 0 failures (40 s)
```

## What this unblocks

Decoding past the **DequantMatrices section** on cjxl-emitted JXL
frames. The next observable failure point moves several hundred
bits further into the decode (see below).

## Next bite: outOfBounds at RAW slot 0 token (6,2,2)

After the SpecialDistance fix, decoding a 16×16 4:4:4 cjxl
`--lossless_jpeg=1` JXL surfaces a different error inside the
modular sub-image RAW slot 0 decode:

```
notImplemented("VarDCT decode: DequantMatrices slot 0
  QuantEncoding read failed: rawDecodeFailed(
    \"decodeAllChannels: tokenAtPosition(
       x: 6, y: 2, channel: 2,
       inner: TokenStreamReaderError.bitstream(
                outOfBounds(needed: 16, remaining: 2)))\"))
```

Position (6, 2, 2) = the 150th token of the 192-token 8×8×3
quant-matrix sub-image. JXL file is 695 bytes (≈ 5560 bits);
RAW decode starts at bit 700 (logged via `JXL_TRACE=1`); we
exhaust the bitstream with 2 bits remaining at token 150.

The "needed: 16" smells like ANS state renormalisation
(`state_ = (state_ << 16u) | PeekFixedBits<16>()`) — the rANS
decoder needs 16 bits but has only 2. Possible root causes,
in rough probability order:

1. **Section bounds**. The RAW slot 0 modular sub-image isn't
   actually full-codestream-bounded; libjxl's per-slot decode
   may have its own length-prefix or bound we're missing.
2. **Squeeze / meta-channel transform**. Although `transforms.isEmpty`
   currently passes for cjxl fixtures, a deeper `wp_header` field
   might mean cjxl pre-shuffles channels before our decode iterates
   them.
3. **HybridUint nbits mis-sizing**. If our `decode()` consumes more
   extra bits than the encoder wrote, we'd exhaust bits faster than
   expected.

That's the next session's bite.

## Updated todo on exit

```
[done] v0.12.0gs — DequantMatricesAC non-default driver
[done] v0.12.0gt — RAW local-tree path
[done] v0.12.0gu — JXLDecoder.decodeToCoefficients
[done] v0.12.0gv — SpecialDistance LZ77 remap

[next] outOfBounds at RAW slot 0 token (6,2,2) — ANS state /
       section-end accounting. Investigate libjxl's per-slot
       RAW bounding, then ANS renorm vs HybridUint nbits sizing.

[deferred] AC strategy plane overflow (4:2:0)
[deferred] Brotli static dictionary (RFC 7932 §8)
[deferred] Codestream ICC extractor (Spec §C.3.4)
[deferred] Progressive scan support (SOF2)
```
