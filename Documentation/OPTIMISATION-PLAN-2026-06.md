# Optimisation plan — June 2026 (v1.0.1 baseline)

> ## Outcome (2026-06-12, branch `optimisation-2026-06`)
>
> Phases 0–5 executed; every speed change byte-identical until the
> Phase-4 wave (one commit, djxl-validated). Measured on the 512×512
> 16-bit CT-like reference unless noted (quiet machine, Apple Silicon):
>
> | Metric | v1.0.1 | now | Δ |
> |---|---|---|---|
> | Encode, default effort 7 | 538 ms | **76 ms** | **7.1×** |
> | Encode, effort 1 | ~49 ms | 23.8 ms | 2.1× |
> | Encode, effort 9 (best ratio) | 542 ms | 212 ms | 2.6× — and smaller files |
> | Best ratio (e9 vs old e7/9) | 223 723 B | 222 857 B | −0.4 % gray, **−8.7 % RGB16** |
> | Decode 512² | ~23.5 ms | ~21 ms | −10 % |
> | 2080² encode e4 / decode | 1 714 / 427 ms | 1 149 / **84 ms** | 1.5× / **4.5×** |
> | 64-slice CT stack, default (batch) | ~34 s | **1.7 s** | **~20×** |
> | Test-suite gate | ~70 s | 21 s | 3.3× |
>
> Phase 3 (JXLPerfC C port): **deferred with grounds** — see the decision
> note in the Phase 3 section. Remaining follow-ups: learner
> presort+partition (1.2 step 2), multi-group WP-pass dedup (now
> wall-clock-mooted by per-rect parallelism), property-whitelist widening
> + per-leaf predictors + per-context hybrid-uint (4.3, needs
> `fillModularProperties`↔libjxl reconciliation), forward RCT (4.4),
> LZ77 (4.5), `decode()` triple header parse (5.3).

A prioritised, risk-assessed optimisation plan for the lossless codec, built from
(a) a fresh re-profile of v1.0.1 on Apple Silicon and (b) a deep audit of every
subsystem with each finding adversarially verified against the actual code.
Supersedes the roadmap section of [PERFORMANCE-ANALYSIS.md](PERFORMANCE-ANALYSIS.md)
(the analysis there remains correct for effort ≤ 5; see "What changed" below).

Throughput figures are JXLSwift's **own** numbers only (legal-exposure rule, CLAUDE.md).

## Fresh baseline (v1.0.1, release, Apple Silicon; 512×512 16-bit synthetic CT-like)

| Effort | Encode/pass | Ratio | Decode/pass |
|---|---|---|---|
| 1 (and 2–3) | 47.9 ms | 47.0 % | ~23 ms |
| 5 (and 4–6) | 225 ms | 42.4 % | ~28 ms |
| 7 (default; and 8–9) | 538 ms | **42.2 %** | ~28 ms |

- 2048×2048 (64 groups): encode e5 2.9 s, decode 455 ms — **fully single-threaded**;
  peak memory footprint ~287 MB for an 8 MB source (~36×).
- The effort ladder has only **three real rungs** (1–3, 4–6, 7–9): the only effort
  gates in the codebase are `>= 4` (activity split) and `>= 7` (greedy MA-tree).
- Effort 7 costs **2.4× effort 5 for 0.2 pp of ratio**; effort 9 buys nothing over 7.

## What changed vs the v0.13 analysis

A fresh `sample` profile at **effort 7** shows a hot spot the v0.13 doc did not record:

| Effort 7 self-weight | share | Effort 5 self-weight | share |
|---|---|---|---|
| **Swift stable sort** (`_merge` + `_stableSortImpl`) | **~48 %** | `ANSTokenStreamWriter.finish` | ~23 % |
| `ANSTokenStreamWriter.finish` | ~10 % | `HybridUintConfig.encode` | ~12 % |
| `HybridUintConfig.encode` | ~5 % | `BitWriter.write` | ~9 % |
| `BitWriter.write` | ~4 % | sort | ~8 % |
| ARC + malloc + memmove/madvise | ~11 % | ARC + malloc + memmove/madvise | ~16 % |
| | | WeightedPredictor (predict/update) | ~8 % |

The sort lives in the greedy MA-tree learner: `computeBest`
([SpecModularEncoder.swift:1906–1911](../Sources/JXLSwift/Codec/SpecModularEncoder.swift))
allocates and **fully sorts a fresh `[Int64]` per (tree-node × candidate-property)** —
~90 sorts of up to 256 K elements per effort-7 encode. At effort ≤ 5 the v0.13
picture stands unchanged: entropy emission ≈ half the time, ARC/malloc next.

Two corrections the audit surfaced:

1. **A 512×512 slice is ONE group, not four** — `buildSections` picks
   `groupSizeShift = 2` (groupDim 512). Group-level parallelism contributes
   *nothing* to the 512² medical hot path; the levers there are candidate-level
   concurrency and file-level batch parallelism.
2. **The "djxl rejects >8-cluster context maps" comment is stale** — the comment at
   SpecModularEncoder.swift:2099–2104 justifying the `maxLeaves: 8` cap is
   contradicted by the project's own E5 record (full-path context maps
   djxl-byte-verified for 16/18/26 clusters). The ratio ceiling at high effort is
   self-imposed.

One idea was **refuted** during verification and should not be attempted: removing
"per-token ARC" from `finish()`'s reverse loop. Disassembly of the release binary
shows the loop already compiles to straight-line code with **zero**
retain/release — the ARC/malloc profile category lives in per-candidate buffer
churn and table construction, not the token loop. (The surviving piece —
reciprocal-multiply division — is folded into the C-path item below.)

## The plan

Every byte-identical item is gated by the ~695-test djxl-byte-exact suite + the
medical validation corpus. Bytes-changing items (Phase 4) are gated by round-trip
+ djxl decodability + ratio measurement instead, and re-baseline the byte gates —
so the byte-identical phases land **first**, the bytes-changing wave lands **last,
as one release**.

### Phase 0 — Make the gates fast (do first; multiplies everything else)

| # | Item | Cx | Why |
|---|---|---|---|
| 0.1 | `swift test -c release --parallel` (split the monolithic IntegrationTests class so the parallelism unit is finer); fix `make test` running debug mode | S | The 70 s suite gates every change below; ~Ncores wall-time cut |
| 0.2 | `multiprocessing.Pool` in `scripts/medical-dicom-validate.py` (per-worker scratch subdirs) | S | 2 867 images × 3 subprocesses, currently strictly serial |
| 0.3 | Diagnostic A/B: `-Ounchecked -enforce-exclusivity=unchecked` through `benchmark-lossless.sh` — **never shipped** (unsafeFlags would break URL-consumability) | S | Puts a hard number on total safety-check share; calibrates the honest ceiling of the C port before committing to it |

### Phase 1 — Byte-identical single-thread encode speed

| # | Item | Cx | Expected |
|---|---|---|---|
| 1.1 | **Cost-gating redesign: tokenise once, analytic candidate sizes.** `assembleMultiContextSection` currently entropy-encodes every candidate's full token stream **3×** (Huffman trial, rANS trial, winner re-encode) and runs `HybridUintConfig.encode` **4×** per value. Huffman cost is exactly `Σ histo[c][t]·codeLen[c][t] + Σ extraNBits` (stateless); rANS cost is `32 + 16·numRefills + Σ extraNBits` (bare reverse state loop, no emission). Tokenise once into reusable SoA buffers `(cluster,symbol,extraBits,extraNBits)`; encode only the winner. Selection order and tie-breaks preserved bit-for-bit. *Subsumes* the separate closed-form-Huffman, bit-blit-reuse, and throwaway-BitWriter findings — implement as one redesign. | M | Largest single-thread lever at every effort: finish/writeToken passes 3→1 per candidate, HybridUint 4→1 per value. Targets the e5-profile majority share |
| 1.2 | **Greedy-tree learner sort fix** (effort ≥ 7 only). Step 1: replace `packed.sort()` with an LSD radix sort on the packed 64-bit keys + hoisted scratch reused across (node, property) — drop-in, the sweep consumes equal-key runs atomically so splits are identical. Step 2 (if still hot): presort each property once at the root, then stably partition index orders down the tree (no re-sorting below root). | S→M | ~48 % of effort-7 samples are this sort. Also the prerequisite that makes Phase 4's tree expansion (4.2) affordable |
| 1.3 | Hygiene batch (single shared fixes — three analysts each flagged the same code): `ANSTokenStreamWriter` pending-buffer reservation + segs-array removal + ~12 B/token packing; `WeightedPredictor` per-pixel array literal in `weightedAverage` + nested `[[UInt32]]` error rows → flat buffers (hot at e≤5: ~8 % WP self-weight); multi-group path's 3 redundant full-image WP passes + 4 redundant rect copies (apply the v0.13 single-section dedup) | S | A few % each at the relevant effort; cheap, safe |
| 1.4 | **Decode:** 64-bit lookahead BitReader (replaces per-byte `Data`-subscript reads on every renorm), flatten per-token dispatch in `TokenStreamReader.readToken`/`ANSStreamDecoder.readSymbol` (hoist loop-invariant optionals/config lookups), fix multi-group stitch COW copy per (group, channel), replace `assembleImageFrame`'s per-sample escaping closure | M | Decode is the per-token chain; plausible 10–25 % on 9–12 Mpx/s. Decode-only, pixels-identical gate |

### Phase 2 — Parallelism (byte-identical; after 1.1 so we don't parallelise work that's being deleted)

| # | Item | Cx | Expected |
|---|---|---|---|
| 2.1 | **`jxl batch` file-level parallelism.** The Sendability precondition in Batch.swift's comment is already met (`JXLEncoder`/`JXLDecoder` are Sendable structs); bounded TaskGroup, index-ordered result collection for deterministic logs/JSON | S | The dominant CT-stack lever: 2 867 slices ≈ 29 min → ~4 min on 8 P-cores |
| 2.2 | **Candidate-DAG concurrency in `buildSingleSection`** (the 512² hot path — one group, so this is the only in-image parallelism available). The candidate ladder is a shallow DAG: gradient ∥ WP ∥ wpGreedyPerPixel; then threshold candidates ∥ greedy tree; within each, Huffman ∥ rANS trials. async-let/TaskGroup, fixed-index collection, today's exact comparison order | M | Overlaps whatever trial work survives 1.1; critical path → longest single candidate |
| 2.3 | Per-group parallel encode emission + parallel per-group modular decode (multi-group frames only, >512 px; TOC assembly order fixed) | M | Near-linear on 2048²+ plates (64 groups at 2048², currently 2.9 s serial) |
| 2.4 | Promote `MinimalLosslessCodec`'s proven ordered `parallelMap` as the shared deterministic-parallelism primitive; make the async encode/decode overloads actually concurrent | S | Foundation for 2.1–2.3 |

### Phase 3 — C hot path (JXLPerfC; after Phases 1–2, re-profile first)

> **DECISION (2026-06-12, post-Phase-1/2 re-profile): deferred.** The
> entropy floor this targeted no longer exists: after the analytic
> cost-gating redesign, `ANSTokenStreamWriter.finish` fell from the top
> profile entry to ~3 % of busy samples (one winner emission per section
> instead of 3× trials), and the e7 profile is now dominated by the
> greedy-tree **learner** (radix sort + sweep) — a Swift algorithmic
> problem whose next lever is the presort+partition step of 1.2, not a C
> boundary. The `-Ounchecked` A/B bounds total remaining safety-check
> overhead at ~9 % (e5) / ~22 % (e1). A C port would buy a fraction of
> that for L-complexity dual-path maintenance. The `JXLPerfC` scaffolding
> stays in place; revisit only if a future profile shows a stable
> single-function hot floor the gate can't reach in Swift.

| # | Item | Cx | Notes |
|---|---|---|---|
| 3.1 | `jxlperf_rans_section_finish`: one batched C call per section (reverse rANS + interleaved emission + accumulator BitWriter) over the SoA token buffers from 1.1 — which are exactly the C-boundary layout. Flat cluster tables built once per codebook (`freq`/`cum`/`slot_for_residue` flattened; reciprocal-multiply division). Then `jxlperf_hybrid_tokenize_batch`; `jxlperf_prefix_emit_batch` only if still hot | L | Strictly batch (one call per 65 K–262 K tokens; per-token bridging would regress). Swift scalar path stays source of truth; per-function byte-equivalence tests + full gates. **Scope check:** Phase 1.1 removes ⅔ of the passes this would accelerate and the 0.3 A/B bounds the win — re-profile before building; if the post-Phase-1 floor is small, shrink or skip |

### Phase 4 — Ratio + retune (bytes-changing wave; ship as ONE release)

| # | Item | Cx | Expected |
|---|---|---|---|
| 4.1 | **Default-effort retune.** Move the greedy-tree gate from ≥ 7 to ≥ 8, or default to effort 5 — at the measured plateau (42.4 % vs 42.2 %), default callers currently pay 2.4× for 0.2 pp. Make the dead rungs (2–3, 5–6, 8–9) mean something or document the three-rung reality. Check J2KSwift preset parity before renaming anything | S | 2.4× default-path latency, zero code-path changes |
| 4.2 | **Lift the MA-tree leaf cap (8 → 32–64 at e7, more at e9)** + encode-side histogram clustering so codebook overhead doesn't eat the gain. First step is a one-line cap raise behind a djxl round-trip test to confirm the stale-comment finding. The single biggest structural ratio gap; 8 contexts cannot separate air/soft-tissue/bone/edge regimes | M | Plausibly 5–15 % on CT/MR at high effort; emission cost per pixel unchanged. Needs 1.2 first (node count multiplies the learner's sort load) |
| 4.3 | Per-leaf predictor selection (leaves currently hard-code WP); widen the learner's property whitelist (6 of 16+); per-context hybrid-uint configs (frozen at raw4 today); enable the greedy candidate on > 4 Mpx frames (silently dropped today — exactly the large medical plates) | M | Incremental ratio at e7+; the > 4 Mpx fix directly serves large slices |
| 4.4 | Forward RCT (YCoCg-R) on RGB encode; emit Palette (decode side already implemented) | S–M | General-content ratio; minor for grayscale medical |
| 4.5 | Encode-side LZ77 | L | Defer — lowest verified value for the medical corpus |

### Phase 5 — Footprint + secondary paths (opportunistic)

| # | Item | Cx | Why |
|---|---|---|---|
| 5.1 | Fuse encode ingestion (interleaved bytes → `[UInt16]` → `[Int32]` is three live full-image copies); make the existing `package` planar-16-bit entry points public (J2KSwift parity check on naming) | S | ~1.5 GB peak-RSS cut at the 16384² supported max; DICOM callers skip the interleave round-trip |
| 5.2 | JPEG transcode bit-serial Huffman: 64-bit lookahead reader (stuffing/RST-aware), 8-bit Huffman lookahead table, accumulator writer; dedupe the two `decodeSymbol` copies | M | Dominant cost of a shipped feature; gated by the byte-identical reconstruction suite |
| 5.3 | `decode()` parses container+headers 3× and the global tree 2× per call; per-token scratch trims in the greedy learner | S | Cheap cleanups, low individual impact |

## Expected end state (512×512 16-bit reference, honest estimates)

| Metric | Today | After 1–2 (Swift-only) | Notes |
|---|---|---|---|
| Encode, default effort | 538 ms | **≪ 100 ms wall** | 4.1 retune (→ ~225 ms) + 1.1 (→ ~½) + 2.2 overlap; without retune, 1.1+1.2 alone put e7 near ~200 ms single-thread |
| Encode, effort 5 single-thread | 225 ms | ~100–130 ms | 1.1 dominates; Phase 3 attacks the remainder |
| CT stack (2 867 slices) | ~29 min | **~2–4 min** | 2.1 batch parallelism × per-image gains |
| Decode | ~28 ms | ~21–25 ms | 1.4; plus 2.3 on large frames |
| 2048² encode (e5) | 2.9 s | ~0.4–0.7 s | 1.1 + 2.3 (64 groups across cores) |
| Ratio at high effort | 42.2 % | −5–15 % file size (Phase 4) | medical content, tree expansion |

## Sequencing rules (from the audit's conflict analysis)

1. Phase 0 first — it multiplies iteration speed for everything else.
2. 1.1 **before** 2.2 (don't parallelise trial encodes that 1.1 deletes).
3. 1.1 subsumes three smaller findings (closed-form Huffman costing, winner
   bit-blit, throwaway trial BitWriters) — one redesign, not four patches.
4. The `finish()` Swift tightening (1.3) is reference-path cleanup; don't
   double-count its win with 3.1, which replaces that path on the fast route.
5. WeightedPredictor and BitReader fixes are shared encode/decode code — single
   fixes, applied once.
6. All byte-identical work (Phases 1–3) lands and is measured **before** the
   bytes-changing wave (Phase 4), which re-baselines every byte-exact gate once.
