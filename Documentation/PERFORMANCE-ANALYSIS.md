# Performance analysis — lossless path (v0.13.0)

A profiling-driven assessment of where the lossless codec spends its time, an
honest evaluation of **SIMD leverage**, and a prioritised, risk-assessed
optimisation roadmap. Measured on Apple Silicon (arm64), release build.
Throughput figures are JXLSwift's **own** numbers — no comparison against other
codecs (legal-exposure rule; see CLAUDE.md).

> **Headline finding:** the lossless codec is **entropy-coding + allocation
> bound**, not arithmetic-bound. The vectorisable arithmetic (predictor, RCT,
> property computation) is **< 5 % of runtime**, so pure SIMD on those loops
> cannot move the end-to-end needle. The real wins are in the bit-output
> primitive, the rANS encoder, and allocation/ARC pressure — all sequential or
> structural, not SIMD. This document records that so the bigger (attended)
> optimisation work can be greenlit with full data.

## Baseline (512×512 16-bit grayscale, 262 144 px — a CT/MR-like slice)

| Path | Per-pass | Throughput |
|---|---|---|
| Encode, effort 1 (lightning) | ~53 ms | ~5 Mpx/s |
| Encode, effort 3 (falcon) | ~0.56 s | ~0.4 Mpx/s |
| Encode, effort 7 (squirrel, **default**) | ~0.6 s | ~0.4 Mpx/s |
| Decode | ~22–31 ms | ~9–12 Mpx/s |

Two structural facts:
- **Encode cost climbs steeply with effort**, but **ratio plateaus around
  effort 5** for natural content (efforts 5/7/9 land at the same size here).
  So the default effort 7 buys little ratio over 5 at much higher cost — a
  *default-tuning* opportunity independent of any code change.
- **Decode is ~20× faster than default-effort encode** and already shortcuts
  single-leaf trees + skips the weighted predictor when unused.

## Profiling (sample-based, `sample` on the release binary)

**Encode hot self-weight (both effort 1 and 7):**
- `ANSTokenStreamWriter.finish` — the reverse **rANS** state machine + the
  forward refill/extra-bit emission. The single largest cost.
- `HybridUintConfig.encode` — per-token hybrid-uint split (already LZCNT-based,
  no `log2`; hot purely from call volume — millions of tokens).
- `BitWriter.write` — per-byte bit packing (an `append` + a bounds-checked
  subscript per byte).
- **ARC + malloc/free/`madvise`** — the largest *category* at effort 7
  (~6 %+ in retain/release alone, more in allocation): per-candidate buffers,
  `[Data]`/`[[UInt32]]` array churn, alias-table construction.
- `_platform_memmove` — `BitWriter`'s byte-buffer geometric growth.

**Decode:** dominated by the sequential per-pixel token read (rANS decode) +
neighbour-dependent prediction. The predictor's left-neighbour is the
*just-decoded* sample, so there is a true serial dependency along each row —
**the decode predictor is not vectorisable across pixels.**

## SIMD-leverage assessment (the honest answer)

| Candidate | Vectorisable? | End-to-end leverage |
|---|---|---|
| Encode gradient/MED residual (image known) | Yes (data-parallel over rows) | **Low** — residual arithmetic is < 5 % of encode |
| RCT (YCoCg-R) forward/inverse | Yes (whole-array integer) | **Low** — one pass vs per-token entropy; colour-only |
| Per-pixel property computation | Partly | **Low** — only for multi-leaf trees; small |
| Decode predictor | **No** — serial left-neighbour dependency | n/a |
| rANS encode/decode (`finish`/`readSymbol`) | **No** — state machine | n/a |
| `HybridUintConfig.encode` | Awkward (LZCNT + branch); batchable | Medium *if* the whole token pipeline is restructured |

**Conclusion:** SIMD/Accelerate on this codec is *infrastructure for the
future*, not where the current win is. A byte-exact SIMD RCT/residual path can
be added behind the scalar reference (the scalar path stays the source of
truth), but it will not produce a measurable end-to-end speedup until the
entropy/allocation costs that dominate are addressed first.

## Optimisation roadmap (prioritised, risk-assessed)

Every item must remain **byte-identical** to the current output (the djxl
byte-exact suite + the 2 867-image medical DICOM validation are the gate).

1. **Encoder allocation / redundant-work — partly done; the rest is the floor.**
   The effort-≥5 cost-gating constructs fresh `BitWriter` + `ANSTokenStreamWriter`
   + `AliasTable` (4096-slot scan) per candidate. **Done (applied below):** the
   full-image WP per-pixel pass that the WP single-context, activity-split, and
   greedy candidates each re-ran (~3×) is now computed once and shared. That gave
   only **~2.8 %** at effort 7 — the key lesson: even eliminating the dominant
   redundancy barely moves the needle, because the per-candidate **entropy
   encoding itself** (each candidate tree → its own rANS stream over all tokens)
   is the irreducible floor under byte-identity. **A larger win therefore needs**
   either *fewer candidates* (changes the chosen output/ratio — not byte-identical)
   or an *entropy-pipeline restructure* (pool/stream the rANS encode) — an
   attended effort, not incremental pooling.
2. **`ANSTokenStreamWriter.finish` tightening.** Pre-reserve `pending`
   (token count is known = w·h); shrink the per-token `Seg` buffer; emit
   extra-bits in tighter batches. Small, safe.
3. **SIMD/Accelerate RCT + encode-residual (infrastructure).** Add a Swift-SIMD
   path behind the scalar reference with a byte-identity equivalence test.
   Small end-to-end today; establishes the pattern + helps colour/large images.
4. **Default-effort tuning.** Ratio plateaus ~effort 5 for natural content;
   consider lowering the default or making the plateau-detection adaptive.

## Applied in v0.13.0 (byte-identical, suite + medical-validation verified)

- **Shared WP per-pixel pass (`wpGreedyPerPixel`).** The effort-≥4 activity-split
  and effort-≥7 greedy candidates each re-ran the same full-image weighted-predictor
  pass; it is now computed once in `buildSingleSection` and handed to both
  (`precomputed:` params; default nil keeps other callers self-computing).
  Byte-identical (full 695-test suite + CID22 + medical re-validation, 0
  failures); **~2.8 % faster at effort 7** (controlled A/B, 512² 16-bit:
  763 → 741 ms). Modest by design — see roadmap item 1 for why.
- **`BitWriter` UInt64-accumulator rewrite.** Replaced the per-bit-chunk
  `append` + bounds-checked subscript with a 64-bit accumulator that flushes
  whole bytes into the byte buffer. Emits the **identical** stream (verified
  byte-exact by the full 695-test djxl suite + the medical DICOM
  re-validation); `bitCount`/`partial` are preserved exactly, so cost-gating is
  unaffected. **Measured:** ~5 % faster on the effort-1 fast path; within noise
  at effort 7 (the default is entropy/allocation-bound, per above) — a modest,
  honest win on a cleaner primitive, not a headline. This was originally listed
  as an attended-only item; it was implemented + gate-verified because the gate
  catches any byte divergence.
- **`BitWriter(reservingBytes:)`** — optional pre-reservation of the byte
  buffer to avoid geometric-growth `memmove`s; semantically identical.

## How to reproduce

```
scripts/benchmark-lossless.sh <input.pnm>           # effort ladder
.build/release/jxl-tool benchmark --mode lossless --effort N -i img.pnm
# Profile:  run the above in a loop in the background, then `sample <pid> 10`.
```
