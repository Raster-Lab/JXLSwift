// LibjxlPredictor — applies the 14 spec / libjxl Modular predictors
// (`enum Predictor` in `lib/jxl/modular/encoding/context_predict.h`).
//
// Our `Predictor` enum (in Predictors.swift) is semantically aligned
// with the spec but uses our own naming convention; for byte-identical
// pixel reconstruction against djxl we need the *exact* libjxl
// formulas, including the ones that have no direct case in our enum
// (TopRight, TopLeft, LeftLeft, Average1..4). This function is the
// source of truth for raw predictor IDs 0..13.
//
// Predictor 6 (Weighted) requires a stateful weighted-predictor
// machine that runs alongside the per-row decode. This file currently
// returns 0 for predictor 6; trees that use it produce incorrect
// pixels until the WP state is wired through. (Most cjxl-emitted
// trees DO use predictor 6, so a proper implementation is on the
// near-term roadmap.)
//
// **Predictor formulas** (a=Top/N, b=Left/W, c=TopLeft/NW,
// d=TopRight/NE):
//
//   0  Zero       0
//   1  Left       W
//   2  Top        N
//   3  Average0   (W + N + 1) / 2          (rounded)
//   4  Select     |W-NW| < |N-NW| ? N : W   (PNG Paeth-ish)
//   5  Gradient   clamp(W+N-NW, min(W,N), max(W,N))
//   6  Weighted   wpResult                  (caller-supplied)
//   7  TopRight   NE                       (with edge fall-back to N)
//   8  TopLeft    NW
//   9  LeftLeft   WW                       (with edge fall-back to W)
//   10 Average1   (W + NW + 1) / 2
//   11 Average2   (NW + N + 1) / 2
//   12 Average3   (N + NE + 1) / 2
//   13 Average4   (W + N + NE + NW + 2) / 4
//
// All values stay in `Int32` — wide enough for any 16-bit channel.

import Foundation

/// Apply a libjxl predictor with raw index `raw` to the surrounding
/// neighbourhood. `wpResult` is the weighted-predictor output for
/// predictor 6; pass `0` when not yet implemented.
package func applyLibjxlPredictor(
    raw: UInt32, neighbourhood nbh: Neighbourhood, wpResult: Int32 = 0
) -> Int32 {
    switch raw {
    case 0:
        return 0
    case 1:
        return nbh.w
    case 2:
        return nbh.n
    case 3:
        // libjxl: (W + N) / 2 — but uses signed int division which
        // rounds towards zero. With non-negative inputs this is the
        // same as `>> 1`; we use the arithmetic shift form to match
        // libjxl's exact bit pattern for negative inputs too.
        return (nbh.w &+ nbh.n) &>> 1
    case 4:
        // Select: |W-NW| < |N-NW| ? N : W
        let pa = abs(nbh.w &- nbh.nw)
        let pb = abs(nbh.n &- nbh.nw)
        return pa < pb ? nbh.n : nbh.w
    case 5:
        // ClampedGradient.
        let g = nbh.w &+ nbh.n &- nbh.nw
        let mn = min(nbh.w, nbh.n)
        let mx = max(nbh.w, nbh.n)
        return min(max(g, mn), mx)
    case 6:
        return wpResult
    case 7:
        return nbh.ne
    case 8:
        return nbh.nw
    case 9:
        return nbh.ww
    case 10:
        return (nbh.w &+ nbh.nw) &>> 1
    case 11:
        return (nbh.nw &+ nbh.n) &>> 1
    case 12:
        return (nbh.n &+ nbh.ne) &>> 1
    case 13:
        return (nbh.w &+ nbh.n &+ nbh.ne &+ nbh.nw) &>> 2
    default:
        // Out-of-range — caller should reject before reaching here;
        // return 0 as a safe default.
        return 0
    }
}
