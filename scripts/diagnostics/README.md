# JXLSwift Diagnostic Scripts

Standalone numerical-reference tools for investigating pixel-accuracy
issues against `libjxl`. These scripts encode `libjxl`'s exact arithmetic
verbatim from its source, so they can be run independently of a full
`libjxl` build.

## `libjxl_reference_idct.cc`

Standalone C++ port of `libjxl`'s reference IDCT/DCT (`dct_for_test.h`)
plus the OpsinXYB forward transform with `libjxl`'s exact constants
(from `cms/opsin_params.h`) and the encoder's exact quantization
formula (from `enc_group.cc::QuantizeBlockAC`).

Build and run:

```bash
clang++ -std=c++17 -O2 \
  scripts/diagnostics/libjxl_reference_idct.cc \
  -o /tmp/libjxl_reference_idct
/tmp/libjxl_reference_idct
```

### Tests in this file

| Test | Validates |
|---|---|
| 1 | `IDCTSlow(DC=1)` produces all-1.0 output (DC=mean property). |
| 2 | `IDCTSlow(coef[0,1]=1)` — first horizontal frequency basis function. |
| 3 | `IDCTSlow(coef[1,0]=1)` — first vertical frequency basis function. |
| 4 | `DCTSlow(constant=1)` — DC=1, all AC=0. Verifies forward DC matches. |
| 5 | `DCTSlow(horizontal-x ramp)` — only horizontal AC frequencies non-zero. |
| 6 | `ComputeScaledDCT` (= DCTSlow without final transpose) — proves the bitstream layout is TRANSPOSED for ROWS≥COLS strategies. |
| 7 | `ComputeScaledDCT` on actual gradient Y values from our cjxl-d=1 fixture — predicts pre-quant coefficient values for direct comparison. |
| 8 | Full pipeline: `linear-RGB → libjxl-exact OpsinXYB → ComputeScaledDCT → encoder quantization`. Predicts the quantized integer that cjxl should emit in the bitstream, given libjxl's documented arithmetic. |

### Key findings (as of v0.9.0l)

Test 6 confirms the bitstream layout is TRANSPOSED for ROWS≥COLS
strategies. For a `pixels[y][x] = x` horizontal ramp:

```
Test 6: ComputeScaledDCT(horizontal ramp) — bitstream layout:
      3.5000     0.0000    -0.0000     0.0000     ...        // row 0 (DC + zeros)
     -2.2777    -0.0000     0.0000    -0.0000     ...        // row 1 (AC1)
     -0.0000    -0.0000     0.0000     0.0000     ...
     -0.2381    -0.0000    -0.0000    -0.0000     ...        // row 3 (AC3)
     ...
```

The horizontal AC values land in the **first column** (flat positions
8, 24, 40, 56) — the TRANSPOSED-layout signature. This matches our
`JXL_TRACE_AC=1` `col0` output.

Test 8 gives the predicted quantized integer for our gradient fixture's
Y AC at flat 8:

```
Test 8: predicted quantized Y AC at flat 8 = round(436.73 * -0.03747)
       = round(-16.366) = -16
       (cjxl emits -7 for our trace; ratio -16/-7 = 2.286)
```

**Empirical mismatch: 2.286× discrepancy.** cjxl emits ~2.3× SMALLER
quantized integers than libjxl's documented encoder formula
(`coef * weight * Scale * quant * qm_multiplier`) would predict.

This is the missing scaling factor blocking byte-equality close-out.
The factor 2.286 is not a clean known constant.

### What we ruled out via the standalone test

- **Inverse-Gaborish 5×5 sharpening** (`enc_gaborish.cc::GaborishInverse`).
  The encoder applies a butteraugli-calibrated 5×5 sharpening kernel
  to opsin pixels before DCT. We ported it (Symmetric5 layout) and
  added it to Test 8. Effect on AC: −0.0375 → −0.0394. Predicted
  quantized: −16 → −17. Direction wrong; magnitude tiny. **Not the
  2.286× source.**
- **Encoder OpsinXYB scaling.** `enc_xyb.cc::ComputePremulAbsorb` uses
  `intensity_target / 255` which is 1.0 for default fixtures.
- **`FindBestDequantMatrices` mode selection.** For default cparams
  (not `max_error_mode`, not `disable_perceptual_optimizations`),
  the encoder uses LIBRARY-default matrices.

### Still candidate

- **Encoder adaptive quantization field** — per-block `quant` scaling.
  The bitstream `qf=10` may already include this scaling, OR the
  encoder may use a higher effective `quant` internally before writing.
- A `qm_multiplier` variant in encoder (e.g., `enc_state->y_qm_multiplier`).
- Different distance-band metric in LIBRARY-mode `getQuantWeights`
  giving weight ≈ 245 instead of 560 for Y at [0,1].
- Forward-DCT-side scaling we haven't traced.

## What's NOT in these diagnostics

- A built `libjxl` binary with `printf` instrumentation. That requires
  populating libjxl's submodules (`third_party/highway`, etc.) and a
  full CMake build — not done from inside this repo.
- A way to extract intermediate values from the prebuilt
  `/opt/homebrew/bin/djxl`. The shipped Homebrew binary has no
  diagnostic / trace mode beyond `--verbose`.

The next concrete step for byte-equality close-out is to populate
libjxl submodules, build with `printf`s in `dec_group.cc::DequantBlock`
and `quant_weights.cc::ComputeQuantTable`, and compare runtime values
against ours via `JXL_TRACE_AC=1`. See
[Documentation/NEXT-STEP-libjxl-trace.md](../../Documentation/NEXT-STEP-libjxl-trace.md)
for the full handoff playbook.
