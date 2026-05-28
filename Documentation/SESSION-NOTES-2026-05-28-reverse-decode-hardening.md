# Reverse coefficient-decode hardening — 2026-05-28

Autonomous session. Goal: harden `JXLDecoder.decodeToCoefficients`
(the autonomous JPEG↔JXL reverse coefficient bridge) across image
sizes and chroma-sampling shapes, driven by a growing bit-exact
matrix test against cjxl `--lossless_jpeg=1` output.

## What shipped

| Commit | Summary |
|---|---|
| `v0.12.0gz` | Bit-exact reverse-decode matrix, 4:4:4 sizes 16→512. Found + fixed a `scaled_qtable` transpose in the CFL inverse (visible only ≥128×128). |
| `v0.12.0ha` | **Per-block DC context index.** Multi-AC-group frames (768/1024) regressed because the block context's `dc_idx` was hard-coded 0; cjxl emits a non-default `BlockCtxMap` with DC thresholds (`numDcCtxs>1`). Matrix now 16→1024. |
| `v0.12.0hb` | **Chroma-subsampled decode (4:2:0 / 4:2:2).** DC + AC planes now decoded at per-channel resolution; per-channel block-existence skip in the AC loop; capture hook samples chroma at the chroma grid; pixel-path `DequantDC` reads chroma at reduced res (crash fix). Matrix adds 4:2:0/4:2:2 rows incl. a 1024×1024 4:2:0 capstone. |
| `v0.12.0hc` | **🎉 Fully autonomous reverse transcode (JXL → JPEG, no `--source`).** New `JXLDecoder.decodeJPEGBridgeData` (coeffs + RAW quant table + chroma) and `JXLToJPEGAdapter.reconstruct(bridgeData:jbrd:)` (recovers quant values + sampling factors from the JXL). Wired into `jxl-tool transcode --mode reverse` — byte-identical with no source. Test `testEndToEnd_AutonomousReverseTranscode_NoSource` (4:4:4 + 4:2:0 + 4:2:2). |
| `v0.12.0hd` | **🎉 Codestream ICC extractor.** New `ICCStream` module (port of libjxl `icc_codec.cc`: enc_size + ANS + `UnpredictICC`). Fixed a load-bearing complex-prefix-code bug (repeat-code accumulation + Kraft-budget early stop) that the ICC's 523-symbol LZ77 code exposed — now correct for all large run-heavy prefix codes. ICC consumed in the header parse to keep TOC aligned; spliced back into the APP2 marker on reverse. ICC-profile JPEGs reverse byte-identically (library + CLI). Test `testEndToEnd_AutonomousReverseTranscode_ICCProfile`. |

## Milestone: autonomous reverse transcode

As of `v0.12.0hc` the JXL → JPEG reverse direction is **fully
autonomous and byte-identical** for baseline cjxl
`--lossless_jpeg=1` files — no reference to the source JPEG. Both
the library (`JXLDecoder.decodeJPEGBridgeData` +
`JXLToJPEGAdapter.reconstruct(bridgeData:jbrd:)`) and the CLI
(`jxl-tool transcode --mode reverse`) deliver it. The codestream
supplies coefficients + quant tables + chroma; the jbrd box
supplies marker order / Huffman / scan structure.

## State of the reverse coefficient decode

`JXLDecoder.decodeToCoefficients` is now **bit-exact** against the
JPEG-bridge reference for cjxl `--lossless_jpeg=1` across the full
matrix (`testEndToEnd_CjxlReverseDecode_BitExactMatrix`):

- **4:4:4**: 16, 32, 64, 128, 256, 512, 768, 1024.
- **4:2:0**: 16, 64, 256, 512, 1024.
- **4:2:2**: 16.

…composing all of: single- and multi-AC-group (1→16 groups),
non-default `BlockCtxMap` DC thresholds, CFL on (4:4:4) and the
CFL-off path (subsampled, where libjxl doesn't apply CFL), and the
RAW slot 0 quant-table modular sub-image (SpecialDistance LZ77 +
ModularStreamId, from the earlier `gv`/`gw` work).

Two standalone regression tests pin the CFL on/off coefficient
match at 16×16; the matrix covers the rest.

## Key libjxl references used

- `compressed_dc.cc::DequantDC` — per-block DC context bucket
  formula (`v0.12.0ha`).
- `frame_header.h::YCbCrChromaSubsampling` — `kHShift=[0,1,1,0]`,
  `kVShift=[0,1,0,1]`, `HShift(c)=maxhs-kHShift[mode(c)]`
  (`v0.12.0hb`).
- `dec_modular.cc::DecodeVarDCTDC` — per-channel DC plane shrink.
- `dec_group.cc::GetBlockFromBitstream::LoadBlock` — per-channel
  block-existence test for subsampled chroma.
- `dec_group.cc:386-400` + `chroma_from_luma.h` — CFL inverse
  (`v0.12.0gy`, transpose fix in `gz`).

## Remaining bites (not started — each a dedicated effort)

1. **Codestream ICC extractor** (Spec §C.3.4, libjxl
   `dec_icc_codec.cc`). A standalone predictive + ANS decoder for
   the compressed ICC profile in `ImageMetadata`. Needed mainly by
   the *container* jbrd byte-identical-reconstruction path, not by
   `decodeToCoefficients`. Unblocks
   `testEndToEnd_ICCProfileJPEG_LimitationDocumented` (currently
   `XCTSkip`). Medium size (~300 lines).
2. **Progressive JPEG (SOF2)**. The JPEG scan decoder is
   baseline-sequential only; progressive needs multi-scan spectral
   selection + successive approximation. Touches
   `JPEGCoefficientImage.decodeToCoefficients`.
3. **Brotli static dictionary** (RFC 7932 §8). ~120 KB embedded
   table + 121 transforms, for Brotli-compressed container boxes
   that reference the static dictionary. Multi-session.

## Notes for whoever picks this up

- The matrix test is the running pin-down of supported shapes —
  add a row when a new shape works; it prints a PASS/FAIL line per
  row up-front so a CI log shows exactly what regressed.
- Full subsampled *pixel* reconstruction (the `decode()` →
  RGB path) is still nearest-neighbour chroma upsampling only;
  `decodeToCoefficients` returns before that and is the in-scope,
  bit-exact path. Proper subsampled pixel upsampling is a separate
  bite if/when the full pixel decoder needs subsampling.
- Tests: 644 / 7 skipped / 0 failures on `swift test -c release`.
