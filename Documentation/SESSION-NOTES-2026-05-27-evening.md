# Autonomous session — 2026-05-27 (evening continuation)

Continued the Phase J drive after the PM session reached
"byte-identical reverse + CLI shipping". This evening pushed:
- Brotli compressed-body decoder (header + IC + distance + LZ77)
- Canonical kICC/kExif/kXMP marker templates
- EXIF JPEG byte-identical reverse
- 9-variant matrix integration test
- ICC limitation pin-down test
- `JXLDecoder.decodeToCoefficients` API scaffold

## TL;DR

Shipped 9 more commits (`v0.12.0gj` → `v0.12.0gr`) on top of the
afternoon's work. Phase J reverse direction now ships **byte-identical
for all common-case baseline JPEGs PLUS JPEGs with EXIF metadata**,
verified by a 9-variant matrix test covering sizes 16×16..128×128,
all sampling shapes (4:4:4 / 4:2:2 / 4:2:0), and special markers
(COM, EXIF, DRI/RST). CLI demonstrated working with byte-identical
`md5` round-trips on multiple JPEG variants up to 256×256.

## Commit trail (evening session)

```
f97b287 v0.12.0gr  JXLDecoder.decodeToCoefficients API scaffold +
                   CLI fallback path
8e1b6b0 v0.12.0gq  Docs refresh + ICC limitation pin-down
3b80638 v0.12.0gp  9-variant byte-identical reverse matrix test
708289c v0.12.0go  Docs refresh for v0.12.0gj→gn
de803f0 🎉🎉🎉 v0.12.0gn  Brotli compressed-body LZ77 loop +
                          EXIF JPEG byte-identical reverse
20751c6 v0.12.0gm  Brotli distance code decoder (RFC 7932 §4)
0f781ba v0.12.0gl  Brotli insert-and-copy command alphabet decoder
afce30c v0.12.0gk  Brotli compressed meta-block header
d8bb80e v0.12.0gj  Canonical kICC/kExif/kXMP marker templates +
                   brob-aware metadata extraction
```

## What landed

### Brotli compressed-body decoder

- `Brotli/BrotliCompressedMetaBlock.swift`: NBLTYPES + NPOSTFIX +
  NDIRECT + context modes + NTREES header reader.
- `Brotli/BrotliInsertCopy.swift`: 704-entry IC command LUT (direct
  port of `BrotliDecoderInitCmdLut`).
- `Brotli/BrotliDistance.swift`: distance LUT builder + ring buffer
  + short-code resolver.
- `Brotli/BrotliDecoder.swift`: full LZ77 reconstruction loop with
  literal insert + distance reuse + overlapping-copy support.
- Fixed simple-format Huffman length assignment — for NSYM=3 +
  treeSelect=1, `val[0]` and `val[1]` keep source order; only
  `val[2..3]` are sorted between themselves (matches
  `BrotliBuildSimpleHuffmanTable` in `c/dec/huffman.c`).

### Canonical metadata markers + container

- `Container/JXLContainer.swift`: `extractMetadataBox(type:from:in:)`
  helper handles direct boxes + `brob`-wrapped boxes (with Brotli
  decompression).
- `JPEG/JBRDBox.swift`: `JBRDBox.ExternalMetadata` struct +
  `distributeBrotliPayload(_:external:)` overload. Two-pass canonical
  marker fill for kICC (marker byte + length + "ICC_PROFILE\0" tag +
  sequence number + total count), kExif (marker byte + length +
  "Exif\0\0" tag + body from `external.exif` with 4-byte
  tiff_header_offset stripped), kXMP (marker byte + length + XMP
  namespace URL + body from `external.xmp`).

### CLI integration

- `JXLTool/Transcode.swift`: `--mode reverse` now extracts
  Exif/xml metadata boxes from the JXL container and threads them
  to `distributeBrotliPayload` for byte-identical EXIF/XMP marker
  recovery.
- Tries `JXLDecoder.decodeToCoefficients(_:)` first; falls back to
  `--source` gracefully when the autonomous decoder is unimplemented.

### Tests

9-variant matrix test (`testEndToEnd_ByteIdenticalMatrix_BaselineJPEGs`):

| Size      | Sampling  | Special marker      |
|-----------|-----------|---------------------|
| 16×16     | 4:2:0     | —                   |
| 16×16     | 4:4:4     | —                   |
| 16×16     | 4:2:2     | —                   |
| 32×32     | 4:2:0     | —                   |
| 64×64     | 4:2:0     | —                   |
| 128×128   | 4:2:0     | —                   |
| 16×16     | 4:2:0     | COM marker          |
| 16×16     | 4:2:0     | APP1 EXIF marker    |
| 64×64     | 4:2:0     | DRI/RST (restart=4) |

All 9 pass in ~1.3s total.

ICC limitation test (`testEndToEnd_ICCProfileJPEG_LimitationDocumented`):
`XCTSkip` documenting that ICC profile JPEGs need codestream ICC
extractor (Spec §C.3.4) before they can round-trip byte-identical.

## Live verification

```
$ jxl-tool transcode --mode reverse \
    --source /tmp/test-fixture-420-exif.jpg \
    /tmp/cjxl-exif-420.jxl /tmp/cli-exif-reconstructed.jpg
wrote 678 bytes to /tmp/cli-exif-reconstructed.jpg
byte-identical to source ✓

$ md5 /tmp/cli-exif-reconstructed.jpg /tmp/test-fixture-420-exif.jpg
MD5 (cli-exif-reconstructed.jpg) = 2fab542d94d9afac91372cfc0d8ac3bb
MD5 (test-fixture-420-exif.jpg)  = 2fab542d94d9afac91372cfc0d8ac3bb
```

## What's left

Each is a discrete future bite, well-documented with `XCTSkip`
pin-down or API stub:

1. **`JXLDecoder.decodeToCoefficients(_:)` body** (v0.12.0gr stub).
   Refactor `decodeVarDCTPartial` to factor out a shared inner
   function that returns coefficient state instead of running IDCT
   + color conv. The bitstream walk through line ~1435 already
   produces `dcValues` and `acBlocks` — just needs a new return
   path. **Removes the CLI's `--source` requirement.**
2. **Codestream ICC extractor** (Spec §C.3.4). Brotli-decompress
   the compressed ICC payload from the `useICC` color-encoding
   section, then splice via `external.icc` (already wired). Unlocks
   ICC profile JPEGs.
3. **Brotli static dictionary** (RFC 7932 §8). ~120KB embedded
   table + 121 transforms. Needed for streams that reference the
   dictionary (typically larger metadata payloads).
4. **Brotli NBLTYPES > 1 / NTREES > 1**. Block-length walker +
   context map decoder. Needed for streams with multiple block
   types or context-modeled trees.
5. **JXLDecoder 4:2:0 DC sub-image dims**. Known limitation — the
   existing decoder uses uniform `dcWidth × dcHeight` for all 3 DC
   channels but for subsampled inputs the chroma planes have
   smaller dims. Affects the coefficient decoder above.
6. **Progressive scan support** (SOF2). JPEG decoder rejects today.
   Substantial JPEG-side work: progressive Huffman decoder, multi-
   scan coefficient assembly, scan encoder for the reverse direction.

## Test totals

- **198 tests passing** in Phase J + Foundation suites
- **1 skipped** (ICC limitation pin-down)
- **0 failures**, 0 regressions across all 50 commits today
