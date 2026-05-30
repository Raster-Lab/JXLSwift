// WeightedPredictor — stateful per-pixel weighted predictor for the
// Modular sub-codec.
//
// ISO/IEC 18181-1 §C.7.5 / libjxl `lib/jxl/modular/encoding/
// context_predict.h::weighted::State`. The weighted predictor is a
// learned mixer of 4 sub-predictors:
//
//   sub[0] = W + NE - N
//   sub[1] = N - ((teN + teW + teNE) * p1C) >> 5
//   sub[2] = W - ((teN + teW + teNW) * p2C) >> 5
//   sub[3] = N - (teNW*p3Ca + teN*p3Cb + teNE*p3Cc + (NN-N)*p3Cd
//                 + (NW-W)*p3Ce) >> 5
//
// where `teX` is the *signed prediction error* at neighbour pixel X
// from this row (or the previous row, swapped via `y & 1`). The four
// predictions are combined via `WeightedAverage` using per-predictor
// weights derived from the running absolute-error tally `pred_errors`.
//
// **Per-pixel state** (kept across an entire channel decode):
//   • `predErrors[4][2 * (xsize+2)]` — per-sub-predictor running
//     absolute-error sums. Two rows; we toggle which row is "current"
//     via `y & 1`.
//   • `error[2 * (xsize+2)]` — signed (pred - actual) errors per pixel.
//   • `prediction[4]` — the four sub-predictor outputs for the most
//     recent pixel (read by `wpResult`).
//   • `pred` — the combined weighted prediction *before* shift-back.
//
// **Output of `predict(...)`** is the final scalar prediction at
// `(x, y)` — already shifted back from the kPredExtraBits=3 fixed-
// point representation. The caller adds the leaf's `predictorOffset`
// and the residual on top, then must call `update(actual:x:y:xsize:)`
// to fold the actual decoded pixel value into the running error
// estimates.
//
// **Property 15 (kWPProp)** is `max(|teW|, |teN|, |teNW|, |teNE|)` —
// the largest absolute prediction error seen at the four neighbours.
// `propertyValue(...)` returns it without advancing state, for the
// MA-tree decision pass.
//
// **Internal pixel-arithmetic width**: we use `Int64` throughout the
// weighted-predictor body — `pred * weights[i]` can multiply up to
// 14-bit predictions by 16-bit weights, so the safe accumulator type
// is at least 32 bits; libjxl uses `pixel_type_w = int64_t`. Match it.

import Foundation

/// Stateful weighted predictor matching libjxl `weighted::State`.
/// Construct once per channel, call `predict` then `update` per pixel
/// in row-major order. Mutating across calls (the running error
/// arrays evolve as pixels are decoded).
package struct WeightedPredictor: Sendable {
    package static let kPredExtraBits: Int = 3
    package static let kPredictionRound: Int64 = (Int64(1) << kPredExtraBits) >> 1 - 1
    package static let kNumPredictors: Int = 4

    /// 1 << 24 / (i + 1) for i in 0..<64 — division-avoidance LUT.
    package static let divLookup: [UInt32] = [
        16777216, 8388608, 5592405, 4194304, 3355443, 2796202, 2396745, 2097152,
        1864135,  1677721, 1525201, 1398101, 1290555, 1198372, 1118481, 1048576,
        986895,   932067,  883011,  838860,  798915,  762600,  729444,  699050,
        671088,   645277,  621378,  599186,  578524,  559240,  541200,  524288,
        508400,   493447,  479349,  466033,  453438,  441505,  430185,  419430,
        409200,   399457,  390167,  381300,  372827,  364722,  356962,  349525,
        342392,   335544,  328965,  322638,  316551,  310689,  305040,  299593,
        294337,   289262,  284359,  279620,  275036,  270600,  266305,  262144
    ]

    package let header: WeightedPredictorHeader
    private let stride: Int  // (xsize + 2) — per-row span in error/predErrors.
    private var predErrors: [[UInt32]]   // [4][2 * stride]
    private var error: [Int64]           // [2 * stride]
    private(set) package var prediction: [Int64]  // [4] — last-pixel sub-predictions.
    private(set) package var pred: Int64           // last combined pred (shifted-up domain).

    package init(header: WeightedPredictorHeader, xsize: Int) {
        self.header = header
        self.stride = xsize + 2
        let total = 2 * stride
        self.predErrors = Array(
            repeating: [UInt32](repeating: 0, count: total),
            count: WeightedPredictor.kNumPredictors
        )
        self.error = [Int64](repeating: 0, count: total)
        self.prediction = [Int64](repeating: 0, count: WeightedPredictor.kNumPredictors)
        self.pred = 0
    }

    /// Add `kPredExtraBits` of fractional precision (libjxl
    /// `AddBits(x) = x << 3`).
    @inline(__always)
    private static func addBits(_ x: Int64) -> Int64 { x &<< Int64(kPredExtraBits) }

    /// `4 + (maxweight << 24) / (x + 1)` approximation. Matches libjxl
    /// `ErrorWeight`.
    @inline(__always)
    private func errorWeight(_ x: UInt64, maxWeight: UInt32) -> UInt32 {
        // shift = floor_log2(x + 1) - 5; clamp to >= 0.
        let xp1 = x + 1
        let log2: Int = xp1 == 0 ? 0 : Int(63 - xp1.leadingZeroBitCount)
        let shift = max(0, log2 - 5)
        let lookupIdx = Int((x >> shift) & 0x3F)
        let div = WeightedPredictor.divLookup[lookupIdx]
        return 4 &+ ((maxWeight &* div) >> shift)
    }

    /// Combine four sub-predictions via per-predictor weights using
    /// libjxl's division-avoiding `WeightedAverage`.
    @inline(__always)
    private func weightedAverage(
        _ p: [Int64], _ wIn: (UInt32, UInt32, UInt32, UInt32)
    ) -> Int64 {
        var w = [wIn.0, wIn.1, wIn.2, wIn.3]
        var weightSum: UInt32 = 0
        for v in w { weightSum &+= v }
        // Spec / libjxl invariant: weightSum > 15 (each w[i] is 4..16).
        let logWeight: UInt32 = weightSum == 0 ? 0
            : UInt32(31 - weightSum.leadingZeroBitCount)
        weightSum = 0
        let shift = Int(logWeight) - 4
        for i in 0..<WeightedPredictor.kNumPredictors {
            w[i] = w[i] &>> UInt32(max(0, shift))
            weightSum &+= w[i]
        }
        var sum: Int64 = Int64(weightSum >> 1) &- 1
        for i in 0..<WeightedPredictor.kNumPredictors {
            sum &+= p[i] &* Int64(w[i])
        }
        let lookupIdx = Int(weightSum &- 1) & 0x3F
        let div = Int64(WeightedPredictor.divLookup[lookupIdx])
        return (sum &* div) >> 24
    }

    /// Compute property 15 (kWPProp) — the largest absolute error
    /// among the W, N, NW, NE neighbours. Returns 0 on the very
    /// first pixel where no neighbours have errors yet.
    package func propertyValue(x: Int, y: Int, xsize: Int) -> Int32 {
        let curRowOff  = (y & 1 == 1) ? 0 : stride
        let prevRowOff = (y & 1 == 1) ? stride : 0
        let posN  = prevRowOff + x
        let posNE = (x < xsize - 1) ? posN + 1 : posN
        let posNW = (x > 0) ? posN - 1 : posN
        let teW: Int64 = (x == 0) ? 0 : error[curRowOff + x - 1]
        let teN: Int64 = error[posN]
        let teNW: Int64 = error[posNW]
        let teNE: Int64 = error[posNE]
        var p: Int64 = teW
        if abs(teN)  > abs(p) { p = teN }
        if abs(teNW) > abs(p) { p = teNW }
        if abs(teNE) > abs(p) { p = teNE }
        return Int32(truncatingIfNeeded: p)
    }

    /// Compute the weighted-predictor output at `(x, y)`. Caller
    /// supplies the unshifted neighbour pixel values; this function
    /// internally applies `AddBits` (≪ 3) and shifts back at the end.
    /// **Mutates** `prediction[]` and `pred` for the next `update`.
    package mutating func predict(
        x: Int, y: Int, xsize: Int,
        n: Int32, w: Int32, ne: Int32, nw: Int32, nn: Int32
    ) -> Int32 {
        let curRowOff  = (y & 1 == 1) ? 0 : stride
        let prevRowOff = (y & 1 == 1) ? stride : 0
        let posN  = prevRowOff + x
        let posNE = (x < xsize - 1) ? posN + 1 : posN
        let posNW = (x > 0) ? posN - 1 : posN

        // Compute weights from per-predictor running error.
        let weights: (UInt32, UInt32, UInt32, UInt32) = (
            errorWeight(
                UInt64(predErrors[0][posN])
                &+ UInt64(predErrors[0][posNE])
                &+ UInt64(predErrors[0][posNW]),
                maxWeight: header.weights.0
            ),
            errorWeight(
                UInt64(predErrors[1][posN])
                &+ UInt64(predErrors[1][posNE])
                &+ UInt64(predErrors[1][posNW]),
                maxWeight: header.weights.1
            ),
            errorWeight(
                UInt64(predErrors[2][posN])
                &+ UInt64(predErrors[2][posNE])
                &+ UInt64(predErrors[2][posNW]),
                maxWeight: header.weights.2
            ),
            errorWeight(
                UInt64(predErrors[3][posN])
                &+ UInt64(predErrors[3][posNE])
                &+ UInt64(predErrors[3][posNW]),
                maxWeight: header.weights.3
            )
        )

        let nB = WeightedPredictor.addBits(Int64(n))
        let wB = WeightedPredictor.addBits(Int64(w))
        let neB = WeightedPredictor.addBits(Int64(ne))
        let nwB = WeightedPredictor.addBits(Int64(nw))
        let nnB = WeightedPredictor.addBits(Int64(nn))

        let teW: Int64 = (x == 0) ? 0 : error[curRowOff + x - 1]
        let teN: Int64 = error[posN]
        let teNW: Int64 = error[posNW]
        let sumWN: Int64 = teN &+ teW
        let teNE: Int64 = error[posNE]

        prediction[0] = wB &+ neB &- nB
        prediction[1] = nB &- (((sumWN &+ teNE) &* Int64(header.p1C)) &>> 5)
        prediction[2] = wB &- (((sumWN &+ teNW) &* Int64(header.p2C)) &>> 5)
        prediction[3] = nB &- ((teNW &* Int64(header.p3Ca)
                              &+ teN  &* Int64(header.p3Cb)
                              &+ teNE &* Int64(header.p3Cc)
                              &+ (nnB &- nB) &* Int64(header.p3Cd)
                              &+ (nwB &- wB) &* Int64(header.p3Ce)) &>> 5)

        pred = weightedAverage(prediction, weights)

        // If all three errors agree in sign, skip clamping.
        let mixed = (teN ^ teW) | (teN ^ teNW)
        if mixed > 0 {
            let shifted = (pred &+ WeightedPredictor.kPredictionRound)
                              &>> Int64(WeightedPredictor.kPredExtraBits)
            return Int32(truncatingIfNeeded: shifted)
        }
        // Else clamp to [min(W, NE, N), max(W, NE, N)].
        let mx = max(wB, max(neB, nB))
        let mn = min(wB, min(neB, nB))
        if pred > mx { pred = mx }
        if pred < mn { pred = mn }
        let shifted = (pred &+ WeightedPredictor.kPredictionRound)
                          &>> Int64(WeightedPredictor.kPredExtraBits)
        return Int32(truncatingIfNeeded: shifted)
    }

    /// Fold the actual decoded pixel value into the running per-row
    /// error arrays. **Must** be called after `predict` for every
    /// pixel in scan order — the prediction at `(x, y+1)` depends on
    /// the errors recorded at row y.
    package mutating func update(actual: Int32, x: Int, y: Int, xsize: Int) {
        let curRowOff = (y & 1 == 1) ? 0 : stride
        let prevRowOff = (y & 1 == 1) ? stride : 0
        let valShifted = WeightedPredictor.addBits(Int64(actual))
        error[curRowOff + x] = pred &- valShifted
        for i in 0..<WeightedPredictor.kNumPredictors {
            let diff = abs(prediction[i] &- valShifted)
            let err = UInt32(truncatingIfNeeded:
                (diff &+ WeightedPredictor.kPredictionRound)
                    &>> Int64(WeightedPredictor.kPredExtraBits))
            // For predicting next row.
            predErrors[i][curRowOff + x] = err
            // Add error on this pixel to the position of NE in next row
            // (which is the E neighbour in the *current* row of the
            // already-shifted layout — see the libjxl comment).
            if x + 1 < stride {
                predErrors[i][prevRowOff + x + 1] &+= err
            }
        }
    }
}
