# ICC + progressive JPEG reverse — 2026-05-28 (continued)

Continuation of the reverse-transcode session. After the autonomous
reverse pipeline landed (`hc`), this stretch closed the two
remaining real-world JPEG gaps: ICC colour profiles and progressive
(SOF2) JPEGs. Both now reverse **byte-for-byte from the JXL alone**.

## What shipped

| Commit | Summary |
|---|---|
| `v0.12.0hd` | **Codestream ICC extractor.** New `ICCStream` module (port of libjxl `icc_codec.cc`: enc_size + ANS + `UnpredictICC`). Plus a load-bearing complex-prefix-code fix (repeat-code accumulation + Kraft-budget early stop) the ICC's 523-symbol LZ77 code exposed — now correct for all large run-heavy prefix codes. ICC consumed during the header parse (keeps TOC aligned) and spliced back into the APP2 marker on reverse. |
| `v0.12.0he` | **Progressive JPEG (SOF2).** New `JPEGScanEncoder.encodeProgressive` — all four entropy modes (DC first/refine, AC first/refine incl. EOB-run + correction-bit handling). `JXLToJPEGAdapter` routes SOF2 scans through it and scopes per-scan Huffman tables to the DHTs defined before each scan. |

## State of the reverse transcode

`jxl-tool transcode --mode reverse in.jxl out.jpg` (and the library
`decodeJPEGBridgeData` + `reconstruct(bridgeData:jbrd:)`) now
reconstruct the source JPEG byte-identically — no `--source` — for:

- **Baseline and progressive** (SOF0 and SOF2).
- **4:4:4, 4:2:0, 4:2:2** chroma sampling.
- **ICC colour profiles** (APP2, recovered from the codestream).
- **EXIF / XMP metadata** (via the `brob` container boxes).

…across image sizes up to at least 1024×1024 (multi-AC-group).

## Two notable bugs found + fixed this stretch

1. **Complex prefix-code repeat accumulation** (`v0.12.0hd`). Our
   `dec_huffman`-equivalent length decoder used a naive
   `count = 3 + extra` for repeat codes (16/17) and read all
   `alphabetSize` lengths instead of stopping at the Kraft budget.
   Correct only for short, run-free codes; the ICC's 523-symbol
   LZ77 prefix code (long zero-runs) broke it. Reimplemented to
   mirror libjxl `ReadHuffmanCodeLengths` exactly (repeat
   accumulation `rep = (rep − 2) << extra_bits; rep += delta + 3`,
   2^15 `space` budget, zero-fill tail). Latent for every other
   prefix section — now correct for all of them.

2. **Progressive AC-refinement correction-bit ordering**
   (`v0.12.0he`). The buffered correction bits for already-nonzero
   coeffs must be emitted **after** the run/size symbol + sign, not
   before, and any pending EOB run is flushed at block start (not
   lazily mid-coef). The first draft flushed before the symbol — it
   passed the sparse chroma AC-refine scans but failed the dense
   luma AC-refine scan. Found by byte-diffing the reconstructed JPEG
   against the cjpeg source (the divergence pinpointed the exact
   scan).

## Remaining bite — ✅ DONE (`v0.12.0hf`)

- **Brotli static dictionary** (RFC 7932 §8) — **shipped.** Large
  Brotli-compressed metadata (multi-KB EXIF/XMP/ICC or comments) now
  reverses byte-for-byte. The 122 784-byte word blob is embedded
  (base64, zero runtime deps), with all 121 transforms and the
  dictionary-copy path wired into the LZ77 decoder. Two latent
  Brotli-decoder bugs surfaced and were fixed: the complex
  prefix-code repeat accumulation (`<< extraBits` after `− 2`, not
  `− 3`) + Kraft `space` early-stop, and the distance ring-buffer
  roll (per-branch push: copy pushes, dictionary only compensates,
  implicit nets zero). Validated transform-by-transform against
  libbrotli and end-to-end via the `brotli` CLI + a `bigcom`
  reverse-transcode case.

There is no longer a known real-world JPEG class the reverse
transcode cannot reconstruct from the JXL alone. The next decoder
bite, if a stream needs it, is Brotli **NBLTYPES > 1 / NTREES > 1**
(multi-block-type + context-map metablocks) — currently surfaced as
a clean `notImplemented` rather than a silent miss.

## Tests

647 / 7 skipped / 0 failures on `swift test -c release`. New
coverage: `testEndToEnd_AutonomousReverseTranscode_ICCProfile`,
`testEndToEnd_AutonomousReverseTranscode_Progressive`.
