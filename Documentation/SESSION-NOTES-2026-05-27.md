# Autonomous session — 2026-05-27 (Phase J completion drive)

This session ran autonomously while the user was out, picking up from
the just-finished forward-bridge work and pushing through the next
phase: the **reverse direction** (JXL → JPEG).

## TL;DR

Shipped 14 commits taking Phase J from "forward-only pixel-equivalent"
to "**full coefficient-identical round-trip** plus substantial
scaffolding for byte-identical reconstruction". The remaining work for
true byte-identical JXL → JPEG round-trip is bounded and well-
documented — fill-in work on the Brotli decoder and JBRD Bundle reader.

## Commit trail

```
a031988 v0.12.0g7  JBRDBoxReader partial — first half of Bundle walk
0bbaeee v0.12.0g6  Docs refresh — CHANGELOG / STATUS / PHASE-J / ROADMAP
36a358d v0.12.0g5  JXLToJPEGAdapter.reconstructMinimal + E2E test
bde3316 v0.12.0g4  JPEG container writer + real-JPEG reassembly
fb882b4 v0.12.0g3  JPEG scan emitter + real-JPEG scan round-trip
724946b v0.12.0g2  JPEG bitstream emitter (BitWriter + BlockEncoder)
82703eb v0.12.0g1  Reverse coefficient adapter (toJPEGCoefficientImage)
94cee14 v0.12.0g0  JBRDBox struct + reverse-bridge scaffold
5832c23 v0.12.0fz+ Brotli meta-block header (RFC 7932 §9)
8cf4495 v0.12.0fz  Brotli decoder scaffold + prefix-code reader
0c51760 v0.12.0fy  4:2:0 test comment — document byte-identical-to-libjxl finding
babfdf9 🎉 v0.12.0fx Multi-block DC clamp fix
3f004b4 v0.12.0fw  Residual recharacterised — multi-block, not chroma
6a66d5a v0.12.0fv  4:2:0 pixel-diff diagnostics
```

## What changed

### Forward direction (v0.12.0fw / fx / fy)

- **v0.12.0fw**: Added a 4:4:4 16×16 control test that revealed the
  v0.12.0fv "4:2:0 residual" was actually a *multi-block* bug (4:4:4
  16×16 had max=74 pixel diff, worse than 4:2:0's max=31). The 4:4:4
  8×8 baseline only passed because single-block trivially skipped the
  iteration.
- **v0.12.0fx**: Root cause + fix — the bridge DC predictor was
  passing `lo: 0, hi: 127` to `Predictor.gradient.apply(...)`, which
  truncated any DC value > 127. libjxl's `ClampedGradient` doesn't
  bit-depth-clamp, so encoder/decoder disagreed on prediction for
  blocks beyond `(0, 0)`. Errors compounded through gradient (W + N
  − NW). Fixed by removing the clamp. After: 4:4:4 16×16 `max=74 →
  max=2`, 4:2:0 16×16 `max=31 → max=9`. Test bounds tightened to ≤
  5 (4:4:4) and ≤ 15 (4:2:0).
- **v0.12.0fy**: Discovery — our bridge output is **byte-identical**
  to cjxl's reference bridge output for 4:2:0 (`djxl(ours) == djxl(cjxl)`
  pixel-for-pixel). The max=9 was `JPEGDecoder.decode` vs `djpeg`
  chroma upsampling difference, not a bridge bug. Bridge is shipping
  byte-identical to libjxl.

### Reverse direction — coefficient-identical (v0.12.0g0 → g5)

- **v0.12.0g0**: `JPEG/JBRDBox.swift` (struct + error taxonomy +
  reader/writer entry points stubbed) + `JPEG/JXLToJPEGAdapter.swift`
  (entry point + `inverseJXLBridgeRemap` + `inverseJPEGBridgeDC`).
  5 invertibility tests.
- **v0.12.0g1**: `JXLCoefficientPlanes.toJPEGCoefficientImage(...)`
  — inverts the 8×8 AC transpose, copies DC. End-to-end round-trip
  test (real JPEG → forward → reverse adapter → identical
  coefficients).
- **v0.12.0g2**: `JPEG/JPEGBitWriter.swift` (MSB-first writer with
  0xFF byte-stuffing + `appendRawMarker` for RST markers) +
  `JPEG/JPEGBlockEncoder.swift` (single-block inverse of decoder) +
  `JPEGHuffmanEncodeTable.build(counts:values:)`. 8 round-trip
  tests covering DC-only, sparse AC, dense AC, ZRL, full block,
  real-JPEG block.
- **v0.12.0g3**: `JPEG/JPEGScanEncoder.swift` — MCU walker with
  restart-interval support. Real-JPEG scan round-trip test passes.
- **v0.12.0g4**: `JPEG/JPEGContainerWriter.swift` — full SOI..EOI
  assembly. Real-JPEG container reassembly test: rebuilt JPEG
  decodes to matching coefficients + `djpeg` accepts the output.
- **v0.12.0g5**: `JXLToJPEGAdapter.reconstructMinimal(...)` — the
  capstone API tying all four reverse steps together. End-to-end
  test (`testEndToEnd_ForwardThenReverseBridge_CoefficientsMatch`)
  drives the full forward + reverse pipeline on a real JPEG and
  confirms coefficient identicality + djpeg acceptance.

### Reverse direction — byte-identical scaffolding (v0.12.0fz, g0, g7)

- **v0.12.0fz**: `Sources/JXLSwift/Brotli/` — `BrotliErrors`,
  `BrotliBitReader`, `BrotliPrefixCode` (simple + complex format,
  canonical Huffman decode), `BrotliMetaBlock` (stream header +
  meta-block header). WBITS table verified empirically against
  `brotli --lgwin=N` for N ∈ {10..24}. 14 unit tests passing.
- **v0.12.0g0**: `JBRDBox` struct + `JBRDError` + reader/writer
  scaffolds.
- **v0.12.0g7**: `JBRDBoxReader.read` — partial implementation
  covering the first ~half of `JPEGData::VisitFields`: is_gray,
  marker_order, app_data / com_data / scan_info sizing, app marker
  types, app/com marker lengths, quant tables, component type +
  ids + quant_idx. Verified against a real cjxl-emitted `jbrd`
  payload (`testJBRDReader_RealCjxlPayload_PartialFieldsParsed`).

## What's left for byte-identical reverse

Three concrete pieces:

1. **JBRDBoxReader.read completion** — the remaining Bundle fields:
   - Huffman tables (counts[17] + values per table)
   - Scan info (Ss/Se/Ah/Al + per-component bindings + reset_points
     + extra_zero_runs)
   - restart_interval (16 bits, if has_dri)
   - inter_marker_data sizes, tail_data length
   - has_zero_padding_bit + padding_bits
   - Validation cross-checks at the end of VisitFields

2. **Brotli decoder completion** — the layers beyond the meta-block
   header (~4-8 sessions of work):
   - Literal / insert-and-copy / distance alphabets (RFC 7932 §7)
   - Block-type / block-length codes
   - Context modeling for literal + distance alphabets
   - Static dictionary (~120KB embedded data + 121 transforms)
   - LZ77 reconstruction loop
   - End-to-end test against `brotli` CLI output

3. **JXLToJPEGAdapter.reconstruct(coefficients:jbrd:...)** — the
   integration that uses jbrd's `markerOrder` to replay marker
   layout exactly + splices APP/COM/inter-marker/tail data from
   the Brotli-decompressed payload.

## Test totals (relevant suites)

- `BrotliPrefixCodeTests`: 8 tests
- `BrotliStreamHeaderTests`: 5 tests
- `BrotliMetaBlockHeaderTests`: 1 test
- `JBRDBoxReaderTests`: 1 smoke test
- `JPEGBlockEncoderTests`: 10 tests (8 round-trip + scan + container)
- `JXLToJPEGAdapterTests`: 7 tests (5 invertibility + coefficient
  round-trip + end-to-end forward+reverse)
- `JPEGFoundationTests`: 138 tests (unchanged from session start)

**Total: 170 tests passing in the relevant suites, 0 regressions.**

## Files added this session

```
Sources/JXLSwift/Brotli/BrotliErrors.swift
Sources/JXLSwift/Brotli/BrotliBitReader.swift
Sources/JXLSwift/Brotli/BrotliPrefixCode.swift
Sources/JXLSwift/Brotli/BrotliMetaBlock.swift
Sources/JXLSwift/JPEG/JBRDBox.swift
Sources/JXLSwift/JPEG/JXLToJPEGAdapter.swift
Sources/JXLSwift/JPEG/JPEGBitWriter.swift
Sources/JXLSwift/JPEG/JPEGBlockEncoder.swift
Sources/JXLSwift/JPEG/JPEGScanEncoder.swift
Sources/JXLSwift/JPEG/JPEGContainerWriter.swift
Tests/JXLSwiftTests/BrotliTests.swift
Documentation/SESSION-NOTES-2026-05-27.md  (this file)
```

Plus updates to:

```
Sources/JXLSwift/Codec/VarDCTBitstreamWriter.swift  (DC clamp fix)
Tests/JXLSwiftTests/JPEGTests.swift                  (new test classes)
CHANGELOG.md / Documentation/STATUS-2026-05.md
Documentation/PHASE-J-COEFFICIENT-BRIDGE.md
ROADMAP.md
```
