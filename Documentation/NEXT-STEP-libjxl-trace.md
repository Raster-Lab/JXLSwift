# Next Step: libjxl Side-by-Side Trace for Byte-Equality

**Audience:** Engineer picking up the v0.9.0 byte-equality close-out.
**Prerequisite reading:** [v0.9.0-pixel-accuracy-investigation.md](v0.9.0-pixel-accuracy-investigation.md)

The investigation through bites v0.9.0c → v0.9.0i has reduced the residual textured-fixture pixel drift to a single, well-characterised AC-dequant scaling discrepancy. Closing it cleanly requires a libjxl side-by-side trace — the only diagnostic step we haven't been able to run from inside this repo.

## What we already know

- DC + OpsinXYB pipeline is byte-equal to djxl within ±1 byte on uniform fixtures (`testVarDCT_UniformBlock_DjxlByteDiff`).
- `Interpolate` + `GetQuantWeights` in our code are arithmetically identical to libjxl's source (verified by direct source comparison).
- LIBRARY-mode quant defaults are *not* pre-multiplied by 64; only DCT-mode bitstream-decoded params apply `params->distance_bands[c][0] *= 64.0f` (verified by libjxl source).
- `bDmMultiplier = 1.0` is structurally correct for default `bQmScale = 2`.
- `kInvDCQuant`, channel iteration order `{1, 0, 2}`, AC `prev` flag, CFL pipeline structure / formula / constants, `AdjustQuantBias` formula — all verified correct.

## What we don't know

For a horizontal R-ramp 8×8 cjxl-d=1 fixture, our trace shows quantised AC integers (X = -17 at [0,1], Y = -7 at [0,1], B = 0). Our pipeline produces pixel 0 R = 156 (= DC mean — AC contribution effectively zero). djxl produces pixel 0 R = 100. **What djxl's intermediate AC dequant values are for the same input bitstream is unknown.**

## How to make progress

### Step 1 — Build instrumented libjxl

Build libjxl 0.11.2 (the version cjxl/djxl ship at) with verbose tracing in `dec_group.cc::DequantBlock`. Suggested probe points:

1. After `AdjustQuantBias` on Y / X / B channel quantised integers — print the post-bias float.
2. After `Mul(quantized_adj, dequant_matrix[k])` — print the per-coefficient float.
3. After the per-channel `inv_global_scale * x_dm_multiplier` etc. — print the final dequantised float that feeds IDCT.
4. The DequantBlock entry-state values: `dequant_matrix[c][k]` for c ∈ {X, Y, B}, k = 0 (DC), 1 (AC[0,1]), 2 (AC[0,2]). Print the actual `1/weight` values libjxl uses.

Existing libjxl trace infrastructure: search for `JXL_VERBOSE` macros, or use a forked branch with `printf` statements.

### Step 2 — Run on the gradient fixture

```bash
djxl_instrumented \
  /tmp/vdt_grad_horiz.jxl \
  /tmp/grad_horiz_djxl.ppm 2> djxl_trace.log
```

The .jxl is what `testVarDCT_GradientBlock_DjxlByteDiff` writes to `NSTemporaryDirectory()`. Or regenerate it inline:

```bash
cjxl gradient_8x8_R_ramp.ppm gradient.jxl -d 1
```

Where `gradient_8x8_R_ramp.ppm` has R = 100 + x·16, G = B = 128 for an 8×8 block.

### Step 3 — Diff against our trace

Run our trace:

```bash
JXL_TRACE_AC=1 swift test -c release \
  --filter testVarDCT_GradientBlock_DjxlByteDiff 2> our_trace.log
```

Compare `dequant_matrix[c][1]` (the inverse-weight at position [0,1]) between djxl and our `qweights[c*64+1]` (we print this directly under `JXL_TRACE_AC=1`). The expected outcome:

- If `our_qweights[c*64+1] == 1 / djxl_dequant_matrix[c][1]` exactly → bug is post-dequant (in IDCT, CFL, OpsinXYB, or sRGB).
- If they differ by a clean factor (e.g., ×64 on some channels but not others; or per-coefficient varying factors) → bug is in `getQuantWeights` interpolation or seed loading.

### Likely outcomes (in priority order)

1. **`scaledForBitstream(×64)` is wrong for LIBRARY-mode but the empirical-fix-by-removal would also break SWEEP per-pixel diffs.** Most likely there's a *second* missing factor. Suspect candidates: `kAcStrategyMul`, encoder-side `ScaleForOpsinShift`, or a `1/N` factor that propagates from the IDCT convention into the encoder's quantisation choice. The libjxl trace will pin which specific coefficient values diverge and rule these in/out.

2. **A subtly different `DequantMatrices::Decode` initialisation path.** libjxl might apply intensity_target normalisation or per-strategy multipliers before storing into `table[]`. Even though source inspection didn't find one, runtime values may reveal a hidden factor.

3. **A channel-storage or AC iteration-order subtlety.** The existing experiment ruled out X/Y band swap, but a subtler permutation (e.g., per-block-context channel reordering) could still be present.

## Why we can't do this from inside this repo

- libjxl is git-cloned to `/tmp/libjxl-src` historically (see ROADMAP) but submodules are empty in checked-out form; full build is ~10 min.
- WebFetch lookups against GitHub source are spotty — they answer scoped questions about specific functions but can't capture the full runtime context (constants, conditional branches, all parameter values at the call site).
- An instrumented libjxl produces *concrete numbers* per coefficient that we can compare against ours byte-for-byte. WebFetch can only confirm structure.

## Tests already in place

The diagnostic infrastructure for this work is shipped:

- `JXL_TRACE_AC=1 swift test --filter testVarDCT_GradientBlock_DjxlByteDiff` — dumps quantised AC ints + dequantised float values + qweights + scale factors for the first block. The output is the input format the libjxl trace should match.
- `testVarDCT_UniformBlock_DjxlByteDiff` — pins the DC-only case (already byte-equal).
- `testVarDCT_GradientBlock_DjxlByteDiff` — three single-axis gradient samples (horiz / vert / diag).
- `testVarDCT_SWEEP_DjxlByteDiffReport` — five cjxl-distance fixtures (d=0.5, 1.0, 2.0, 5.0, 10) for regression tracking.

## Effort estimate

- Building instrumented libjxl: 30–60 min (one-time).
- Running and diffing traces: 10–15 min.
- Identifying the specific factor and applying the fix: depends on what's found, 1–4 hours.
- Re-running full SWEEP byte-diff measurement to confirm net improvement: 5 min.

**Total: 1–6 hours focused work** with a clean diagnostic outcome at the end.
