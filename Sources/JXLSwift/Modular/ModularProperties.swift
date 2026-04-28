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
//   15 weighted predictor's property (kWPProp — NOT YET COMPUTED)
//
// Property 15 (the weighted-predictor property) requires running
// libjxl's stateful weighted predictor over the row — that's its
// own machine. We currently emit 0 for property 15; a tree that
// branches on it will pick the wrong leaf. Most cjxl-emitted trees
// for typical content do NOT use property 15, so this is usually
// harmless for read-only inspection of cjxl files.

import Foundation

/// Compute the 16 standard Modular properties for a pixel at `(x, y)`,
/// given its neighbour values. Caller passes `staticChannel` (0 for
/// the first colour channel, 1 for the second, etc.) and `groupId`
/// (the per-frame group index — typically 0 for a single-group
/// image). Pass 0 for missing neighbours (caller handles
/// out-of-range).
///
/// Properties 0–14 are computed exactly per libjxl. Property 15
/// (weighted-predictor output) is **not yet computed** — set to 0
/// here. Trees that don't branch on property 15 (the common case
/// for cjxl-emitted modular lossless) decode unaffected.
public func computeModularProperties(
    staticChannel: Int32, groupId: Int32,
    x: Int32, y: Int32,
    top: Int32, left: Int32,
    topLeft: Int32, topRight: Int32,
    leftLeft: Int32, topTop: Int32
) -> [Int32] {
    var p = [Int32](repeating: 0, count: 16)
    p[0] = staticChannel
    p[1] = groupId
    p[2] = y
    p[3] = x
    p[4] = top < 0 ? (0 &- top) : top          // |top|
    p[5] = left < 0 ? (0 &- left) : left       // |left|
    p[6] = top
    p[7] = left
    // Property 8 is computed *after* property 5 was set, then libjxl
    // does `(*p)[offset] = left - (*p)[offset + 1]` and increments —
    // i.e. property 8 = left - top (since property 9 below is
    // overwritten on the same iteration). Our encoding mirrors that.
    p[8] = left &- top
    p[9] = left &+ top &- topLeft
    // FFV1-style differential properties.
    p[10] = left &- topLeft
    p[11] = topLeft &- top
    p[12] = top &- topRight
    p[13] = top &- topTop
    p[14] = left &- leftLeft
    // Property 15 (weighted predictor) — placeholder zero. Real
    // pixel decoding for trees that branch on it requires the
    // weighted-predictor state machine; not yet implemented.
    p[15] = 0
    return p
}

