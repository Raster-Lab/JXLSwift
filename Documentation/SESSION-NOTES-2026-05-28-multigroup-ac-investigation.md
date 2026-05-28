# 1024×1024 multi-AC-group decode bug — investigation notes

**Date:** 2026-05-28. **Status:** localized, not fixed. Matrix test
(`testEndToEnd_CjxlReverseDecode_BitExactMatrix`) is capped at
512×512 (all green); 1024×1024 is the next bite.

## Symptom

`JXLDecoder.decodeToCoefficients` on a cjxl `--lossless_jpeg=1`
1024×1024 4:4:4 JXL produces wrong AC coefficients. Two
manifestations depending on content:

- **High-AC content** (wrapping gradient `(50+x*3)%256`,
  60 histogram clusters): silent — `dcMM=0 acMM=108544`
  (~3.4% of AC slots wrong). All three channels affected
  (perCh ≈ [38816, 32352, 37376]); the Y channel (no CFL)
  is wrong from block 0, so it is **not** a CFL issue. Block 0's
  Y plane decodes all-zero where the JPEG had `[0,-4,…,-3,…]`.
- **Low-AC content** (genuinely smooth gradient, 5 clusters):
  hard error — `AC group 15 block (112,127) … outOfBounds(needed:
  16, remaining: 0)`.

## What's ruled out

1. **The cjxl JXL is valid.** `djxl g1024.jxl out.jpg` reconstructs
   the original JPEG **byte-identically**. The bug is on our decode
   side, not the test's "expected" reference.
2. **Not the TOC permutation.** Both 512 (7 TOC entries) and 1024
   (19 entries) have `hasPermutation=false`. 256 and below are
   single-section (`entries=1`).
3. **Not the AC strategy plane.** Trace shows all blocks are
   `strategy 0` (DCT8) first-blocks — 16384 for 1024×1024. No
   phantom multi-block strategies skipping blocks.
4. **Not the histogram selector.** `num_histograms=1` for every
   size (the `1 + ReadBits(CeilLog2Nonzero(num_groups))` read
   returns 0). `histo_selector_bits = 0`, so no per-group selector
   bits. The `nhBits` read is correct (2 bits for 512, 4 for 1024).
5. **Not the coefficient order.** `used_orders=1` (custom DCT8
   order) for 64×64 → 512×512, all bit-exact. The order only
   affects coefficient *placement*, not bit *count*, so it can't
   cause the over-read.
6. **Not pure cluster count.** A 256×256 noise fixture (15
   clusters, single AC group) decodes bit-exact. 512×512 (44
   clusters, 4 groups) is bit-exact.
7. **Not pure group count alone** — but group count is necessary:
   the bug only appears with 16 AC groups (4×4 grid). 4 groups
   (512) is fine.
8. **The per-group seeks are correct.** Per-group trace shows each
   AC group is seeked to its TOC section byte offset, and offsets
   are contiguous (group g's section end == group g+1's start).

## The actual mechanism (localized)

Instrumented each AC group's decode-end byte position vs. its TOC
section-end byte. For the smooth1024 fixture:

```
ACgrp 10: seek 7164  sectionEnd 7288  decode ended 7290  (+2 over)
ACgrp 11: seek 7288  sectionEnd 7408  decode ended 7416  (+8 over)
ACgrp 12: seek 7408  sectionEnd 7526  decode ended 7526  (ok)
ACgrp 13: seek 7526  sectionEnd 7618  decode ended 7618  (ok)
ACgrp 14: seek 7618  sectionEnd 7732  decode ended 7746  (+14 over)
ACgrp 15: seek 7732  sectionEnd 7854  → outOfBounds (EOF)
```

So **specific groups (10, 11, 14) over-read their section** — the
per-block AC decode consumes *more bits than the block actually
holds*. Each group re-seeks, so the over-reads don't corrupt the
next group's *start*, but they corrupt that group's decoded
*values* and eventually group 15 runs off the end of the file.

The bit count in AC decode is driven by `nzeros` (then `nzeros`
coefficient tokens via the zero-density loop). An over-read means
`nzeros` decoded too large, or the zero-density loop read extra
tokens. Since placement (coeff order) is ruled out, the fault is
in **how many tokens we read**, i.e. the `nzeros` value or the
zero-density context routing.

## Leading hypothesis

The bug correlates with **cluster count > 44** (512 has 44 and
works; 1024 has 60 and fails) combined with **16 groups**. The
over-reading groups (10, 11, 14) hold content whose contexts route
to the higher-numbered clusters (45–60) that only exist in the
1024 codebook. Most likely culprits, in priority order:

1. **AC histogram codebook decode for many clusters.** A
   distribution for some cluster in 45–60 is decoded wrong, so
   `nzeros`/zero-density tokens routed there decode to the wrong
   value → over-read. Check `MultiClusterCodebook.read` and the
   ANS distribution decode for the 45th+ cluster.
2. **Context-map (clustering) decode for ~60 clusters.** The
   7425-entry AC context map → 60 clusters is entropy-coded
   (possibly MTF + LZ77). If a context routes to the wrong
   cluster, the histogram is wrong. Note: this LZ77 path uses
   `distance_multiplier = 0` (no SpecialDistance), distinct from
   the modular-sub-image LZ77 fixed in v0.12.0gv. Verify the
   context-map LZ77/MTF for large maps.
3. **A specific HybridUint token** whose extra-bit count is
   mis-sized only for the value ranges that appear in these groups.

## How to reproduce / next steps

Fixtures (regenerate if `/tmp` is cleared):

```bash
# smooth (5 clusters, hard EOF error at group 15)
python3 -c "... linear gradient r=(x*255)//1024 ..." > /tmp/smooth1024.ppm
cjpeg -outfile /tmp/smooth1024.jpg -q 75 -baseline -sample 1x1,1x1,1x1 /tmp/smooth1024.ppm
cjxl --lossless_jpeg=1 /tmp/smooth1024.jpg /tmp/smooth1024.jxl
```

The fastest crack is a **token-level diff against libjxl**: build
djxl with `JXL_DEBUG_V` (or add a print in `dec_group.cc`
`DecodeACVarBlock`) dumping `(group, bx, by, c, nzeros)` for the
first over-reading group (group 10 of smooth1024), and compare to
our `ACDecoder.decodeBlock` `nzeros` for the same block. The first
block where `nzeros` diverges pins the fault to (1) the histogram
for that block's cluster, or (2) the cluster routing.

The diagnostic traces used in this investigation (TOC dump,
per-group seek/end, per-channel mismatch, Y-block dump) were
reverted to keep the tree clean — re-add from this file's
description as needed.

## Why this is lower-priority than it looks

The JPEG→JXL bridge's real use case is typical photo/medical-image
sizes that are usually ≤ a few AC groups, and the bug needs ≥16 AC
groups (≥ ~1025 px on the short side, since 4 groups at 512 works).
Common-case reverse transcode (≤512 px, or any size via the
brob/jbrd container path that doesn't use VarDCT coefficient
decode) is unaffected. Worth fixing for completeness, but it
doesn't block the bridge's primary path.
