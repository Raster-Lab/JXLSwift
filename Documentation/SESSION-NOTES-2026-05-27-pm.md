# Autonomous session continuation — 2026-05-27 (PM)

Continued the autonomous Phase J work after the first session reached
"coefficient-identical reverse direction + Brotli & jbrd scaffolds".
This continuation drove to **byte-identical JXL → JPEG reconstruction**.

## TL;DR

Shipped 9 more commits (`v0.12.0g8` → `v0.12.0gf`) that closed the
byte-identical reverse direction for the common-case JPEG (small
APP0, no large EXIF/XMP/ICC, no DRI). A real cjpeg 4:2:0 fixture and
a real cjxl-emitted jbrd payload now reconstruct to a JPEG that
matches the source **byte-for-byte**.

## Commit trail (PM session)

```
45254ee v0.12.0gf  Docs refresh — CHANGELOG / STATUS / PHASE-J / ROADMAP
0db490e 🎉 v0.12.0ge JXLToJPEGAdapter.reconstruct + byte-identical E2E
79324fd v0.12.0gd  JBRDBox.distributeBrotliPayload + JFIF integration
6da5e12 v0.12.0gc  Diagnostic — real cjxl jbrd uses uncompressed Brotli
6beffe6 v0.12.0gb  BrotliBitReader.readVarLenU8 (RFC 7932 §9.2 NBLTYPES)
676ca75 v0.12.0ga  BrotliDecoder shell + uncompressed meta-block path
83687f9 v0.12.0g9  JBRDBoxWriter (full Bundle walk, reader inverse)
2a722c0 v0.12.0g8  JBRDBoxReader.read full Bundle walk
```

(Plus this session-notes doc, the morning session notes, and an
in-progress `v0.12.0g7` Bundle-reader partial from the AM session.)

## What landed

### Brotli decoder (uncompressed path)

`Sources/JXLSwift/Brotli/`:

- **BrotliDecoder.swift** (v0.12.0ga) — top-level decoder shell:
  - `BrotliDecoder.decode(_:expectedOutputSize:)` and a
    `BitReader`-consuming variant for jbrd-driven callers.
  - Reads stream header (WBITS) → meta-block loop → dispatches on
    `isLastEmpty` / `isUncompressed` / compressed-body.
  - **Uncompressed path**: byte-align + bulk copy via
    `appendRawMarker`-style direct buffer append.
  - **Compressed path**: throws `BrotliError.notImplemented` cleanly
    with descriptive message naming the missing RFC 7932 layers.
- **BrotliBitReader.readVarLenU8** (v0.12.0gb) — RFC 7932 §9.2
  variable-length integer in `[1, 256]` for NBLTYPES. 5 unit tests
  covering NSYM=0 through NSYM=7 (max value 256).

### JBRD Bundle (full read/write)

- **JBRDBoxReader.read** (v0.12.0g7 → g8) — full
  `JPEGData::VisitFields` Bundle walk. Reads:
  - `is_gray` + marker_order loop
  - app/com marker types and 16-bit lengths
  - quant tables (precision/index/is_last)
  - component type (kGray/kYCbCr/kRGB/kCustom) + canonical ids
  - Huffman codes (counts × 17, values × N including EOI sentinel)
    with EOI-sentinel-presence + duplicate + DC-range validation
  - scan info (Ss/Se/Ah/Al + per-component bindings)
  - restart_interval (if any DRI marker present)
  - reset_points + extra_zero_runs per scan (with block-index delta)
  - inter_marker_data sizes
  - tail_data length (4,260,096-byte cap enforced)
  - has_zero_padding_bit + padding_bits
  - Marker-order validation cross-check (DHT before SOS)
- **JBRDBoxWriter.write** (v0.12.0g9) — mirror of the reader using
  the same U32 distributions. `Equatable` conformance added to all
  JBRD types for round-trip verification.
- **JBRDBox.distributeBrotliPayload** (v0.12.0gd) — fills
  appData/comData/interMarkerData/tailData slots from the decoded
  Brotli output. Verified on real cjxl payload: JFIF magic recovers
  at offset 3..8 of appData[0].
- Real-payload diagnostic (v0.12.0gc): the cjxl 4:2:0 reference's
  trailing Brotli stream is 21 bytes → 17 bytes decompressed,
  encoded as uncompressed meta-block. **No compressed-Brotli
  support needed for this case.**

### Reverse bridge integration

- **JXLToJPEGAdapter.reconstruct(coefficients:jbrd:colorTransform:)**
  (v0.12.0ge) — full marker-order walk:
  - SOI emitted first (libjxl convention excludes it from markerOrder).
  - APPn / COM: splice `appData[i]` / `comData[i]` directly (these
    already contain the marker byte at index 0).
  - DQT: group consecutive quant tables until `isLast`, emit as one
    segment.
  - DRI: 6-byte `0xFF 0xDD 00 04 hi lo`.
  - SOFn: emit from coefficients + frameComponents.
  - DHT: group up to `isLast` per marker; **decrement the highest
    non-zero bit-length count** to undo libjxl's EOI-sentinel
    bumping (this was the final byte-identicality fix).
  - SOS: scan header + entropy via `JPEGScanEncoder` driven by the
    jbrd's Huffman tables + restart_interval.
  - 0xFF intermarker: splice `interMarkerData[i]`.
  - EOI + optional `tailData`.

## Pin-down test

`testEndToEnd_ByteIdenticalReconstruct_RealCjxlPayload`:

```swift
let originalJPG = try Data(contentsOf: ".../test-fixture-420.jpg")
let jbrdPayload = try Data(contentsOf: ".../cjxl-ref-420.jbrd")

var r = BitReader(jbrdPayload)
var box = try JBRDBoxReader.read(from: &r)
let brotliBytes = jbrdPayload.suffix(from: (r.position + 7) / 8)
let decoded = try BrotliDecoder.decode(Data(brotliBytes))
try box.distributeBrotliPayload(decoded)

// Splice quant values + sampling factors from the source JPEG
// (these come from the JXL frame in a real workflow).
let originalCoeffs = try JPEGDecoder.decodeToCoefficients(originalJPG)
// ... populate box.quant[*].values and box.components[*] sampling ...

let planes = try originalCoeffs.toJXLCoefficientPlanes()
let jxlPlanes = planes.remappedForJXLBridge(colorTransform: .ycbcr)

let rebuilt = try JXLToJPEGAdapter.reconstruct(
    coefficients: jxlPlanes, jbrd: box, colorTransform: .ycbcr)

XCTAssertEqual(rebuilt, originalJPG)   // byte-for-byte ✓
```

## What's left for full coverage

1. **Brotli compressed-body path** — needed for JPEGs with large
   EXIF/XMP/ICC metadata that Brotli encodes compressed (vs the
   uncompressed format used for tiny payloads). Multi-session work:
   - NBLTYPES_L / NBLTYPES_I / NBLTYPES_D block-type metadata
   - NPOSTFIX + NDIRECT
   - Context maps (CMAPL + CMAPD)
   - Literal / insert-and-copy / distance prefix trees
   - Static dictionary (~120KB + 121 transforms, RFC 7932 §8)
   - LZ77 reconstruction loop
2. **Canonical app-marker templates** — `JBRDBox.distributeBrotliPayload`
   currently surfaces `kICC` / `kExif` / `kXMP` markers as
   `notImplemented`. libjxl `dec_jpeg_data.cc:74-80` rewrites the
   marker prefix with the well-known tag (`ICC_PROFILE\0`/`Exif\0\0`/
   XMP namespace URL) before filling the rest from Brotli output.
3. **Progressive scan support** in `JPEGScanEncoder` (currently
   baseline-sequential only).
4. **CLI**: `jxl transcode --mode reverse` wiring. Needs (a) JXL
   container parser to find the `jbrd` box, (b) JXL frame decode to
   recover coefficient planes, (c) shape detection. Most pieces are
   in place from the forward direction.

## Test totals

**185 tests passing in Phase J suites** (Brotli 23 + JBRD 5 +
JPEGBlockEncoder 10 + JPEGFoundation 138 + JXLToJPEGAdapter 8 +
related). 0 regressions across the whole drive.

## Files added/modified

Added:
- `Sources/JXLSwift/Brotli/BrotliDecoder.swift`
- `Sources/JXLSwift/Brotli/BrotliBitReader.swift` (updated)
- `Sources/JXLSwift/JPEG/JBRDBox.swift` (Bundle walk + writer +
  distributeBrotliPayload)
- `Sources/JXLSwift/JPEG/JXLToJPEGAdapter.swift` (reconstruct
  implementation)
- `Documentation/SESSION-NOTES-2026-05-27-pm.md` (this file)

Modified:
- `Tests/JXLSwiftTests/BrotliTests.swift` (decoder + VarLenU8 tests)
- `Tests/JXLSwiftTests/JPEGTests.swift` (JBRD + byte-identical E2E)
- `CHANGELOG.md`, `Documentation/STATUS-2026-05.md`,
  `Documentation/PHASE-J-COEFFICIENT-BRIDGE.md`, `ROADMAP.md`
