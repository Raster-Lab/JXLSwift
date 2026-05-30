// ModularProperties — the 16 pixel-context features the Modular
// MA-tree branches on.
//
// ISO/IEC 18181-1 §C.7.4 (libjxl `lib/jxl/modular/encoding/context_predict.h`,
// `Predict<mode>`). When the encoder builds an MA-tree it picks one
// of these 16 values (or one of the per-channel "extra" reference
// values, not modelled here yet) at each decision node and tests
// whether the pixel's value is `≤ splitVal`.
//
// **Property indices (matching libjxl):**
//
//   0  static channel index (passed in)
//   1  static group_id (passed in)
//   2  y (row)
//   3  x (column)
//   4  abs(top)
//   5  abs(left)
//   6  top
//   7  left
//   8  left − abs(top)         (local gradient — subtle, see below)
//   9  left + top − topleft    (ClampedGradient input — kGradientProp)
//   10 left − topleft           (FFV1)
//   11 topleft − top            (FFV1)
//   12 top − topright           (FFV1)
//   13 top − toptop             (FFV1)
//   14 left − leftleft          (FFV1)
//   15 weighted predictor's property (kWPProp)
//
// Property 15 (the weighted-predictor error) requires libjxl's stateful
// weighted predictor (`WeightedPredictor`). Callers pass its value via
// `wpProperty`; the per-pixel decode loop sources it from
// `WeightedPredictor.propertyValue(...)`, so trees branching on property
// 15 decode correctly (the lossless encoder's activity-split and
// multi-property MA-trees depend on it). Pass 0 only when no WP state is
// active. NOTE: properties 8 and 11 (and the untested 6,7,13,14) have not
// been reconciled byte-for-byte with libjxl — see `SpecModularEncoder`'s
// greedy property whitelist `{4,5,9,10,12,15}`.
//
// **v1.0 decision (deliberate limitation):** widening that whitelist is a
// *ratio* lever, not a correctness gap — the verified set already yields a
// complete, `djxl`-byte-exact lossless encoder. Reconciling the remaining
// slots requires matching libjxl's exact property emission ORDER (a
// slot-ordering mismatch, not a per-slot arithmetic tweak — a prior
// `p[8] = left − |top|` experiment desynced `djxl` and was reverted), and
// libjxl source is intentionally absent (CLAUDE.md constraint 4), so the
// target formulas can only be reverse-engineered empirically via `djxl`.
// Deferred to a post-1.0 ticket; it does NOT block v1.0.0.

import Foundation

/// Compute the 16 standard Modular properties for a pixel at `(x, y)`,
/// given its neighbour values. Caller passes `staticChannel` (0 for
/// the first colour channel, 1 for the second, etc.) and `groupId`
/// (the per-frame group index — typically 0 for a single-group
/// image). Pass 0 for missing neighbours (caller handles
/// out-of-range).
///
/// Properties 0–14 are computed exactly per libjxl. Property 15
/// (weighted-predictor output) is sourced from `wpProperty` — pass
/// the value `WeightedPredictor.propertyValue(...)` returns for the
/// current pixel, or `0` when no WP state machine is active.
package func computeModularProperties(
    staticChannel: Int32, groupId: Int32,
    x: Int32, y: Int32,
    top: Int32, left: Int32,
    topLeft: Int32, topRight: Int32,
    leftLeft: Int32, topTop: Int32,
    wpProperty: Int32 = 0
) -> [Int32] {
    var p = [Int32](repeating: 0, count: 16)
    fillModularProperties(
        into: &p,
        staticChannel: staticChannel, groupId: groupId,
        x: x, y: y, top: top, left: left,
        topLeft: topLeft, topRight: topRight,
        leftLeft: leftLeft, topTop: topTop,
        wpProperty: wpProperty
    )
    return p
}

/// In-place fill of a 16-element properties buffer. Used by the
/// per-pixel decode loop to avoid re-allocating a fresh `[Int32]`
/// 16M times for a 4096² image — a measurable hot spot.
@inline(__always)
package func fillModularProperties(
    into p: inout [Int32],
    staticChannel: Int32, groupId: Int32,
    x: Int32, y: Int32,
    top: Int32, left: Int32,
    topLeft: Int32, topRight: Int32,
    leftLeft: Int32, topTop: Int32,
    wpProperty: Int32 = 0
) {
    p[0] = staticChannel
    p[1] = groupId
    p[2] = y
    p[3] = x
    p[4] = top < 0 ? (0 &- top) : top          // |top|
    p[5] = left < 0 ? (0 &- left) : left       // |left|
    p[6] = top
    p[7] = left
    p[8] = left &- top
    p[9] = left &+ top &- topLeft
    p[10] = left &- topLeft
    p[11] = topLeft &- top
    p[12] = top &- topRight
    p[13] = top &- topTop
    p[14] = left &- leftLeft
    p[15] = wpProperty
}

