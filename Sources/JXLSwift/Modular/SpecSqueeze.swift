// SpecSqueeze — inverse Squeeze (un-squeeze) for paired LL + HL
// Modular channels.
//
// ISO/IEC 18181-1 §C.7.6 / libjxl `lib/jxl/modular/transform/
// squeeze.cc::InvHSqueeze` and `InvVSqueeze`. Each forward Squeeze
// step splits a source channel into:
//   • a low-pass (LL) channel of half the source width or height,
//     holding `avg = (l + r) / 2`-style averages
//   • a high-pass (HL/HF) channel of the same size, holding the
//     residual `diff = l - r` *minus* the SmoothTendency prediction
//
// The inverse re-pairs them: for each LL position, recover the
// SmoothTendency, add it to the residual, then split into `(l, r)`:
//
//     diff = residual + SmoothTendency(left, avg, next_avg)
//     A = avg + (diff / 2)             ← left of the recovered pair
//     B = A - diff                     ← right of the recovered pair
//
// where `left` is the previously-restored output pixel just to the
// left (or `avg` for the first column), `next_avg` is the LL
// neighbour to the right (or `avg` for the last LL column).
//
// The combined output is `LL.width + HL.width` pixels wide
// (horizontal squeeze) or `LL.height + HL.height` rows tall
// (vertical squeeze).
//
// **`SmoothTendency`** (from libjxl `squeeze.h`): a small smoothing
// predictor that estimates `l - r` from the surrounding LL averages.
// Required for byte-exact decode against djxl. See the spec
// reference at the end of this file.

import Foundation

public enum SpecSqueezeError: Error, Sendable {
    case mismatchedHeight
    case mismatchedWidth
    case channelOutOfRange(c: Int, residualC: Int, channels: Int)
    case sizeMismatch(expected: (Int, Int), got: (Int, Int))
}

public enum SpecSqueeze {

    /// libjxl `SmoothTendency`. Returns the predicted `l - r` for an
    /// LL position whose left output is `B`, current LL is `a`, and
    /// next LL is `n`. The prediction is only non-zero when the
    /// three values are monotonic (B ≤ a ≤ n or B ≥ a ≥ n) — that's
    /// the "smooth area" condition.
    @inline(__always)
    public static func smoothTendency(B: Int64, a: Int64, n: Int64) -> Int64 {
        var diff: Int64 = 0
        if B >= a && a >= n {
            diff = (4 &* B &- 3 &* n &- a &+ 6) / 12
            if diff &- (diff & 1) > 2 &* (B &- a) {
                diff = 2 &* (B &- a) &+ 1
            }
            if diff &+ (diff & 1) > 2 &* (a &- n) {
                diff = 2 &* (a &- n)
            }
        } else if B <= a && a <= n {
            diff = (4 &* B &- 3 &* n &- a &- 6) / 12
            if diff &+ (diff & 1) < 2 &* (B &- a) {
                diff = 2 &* (B &- a) &- 1
            }
            if diff &- (diff & 1) < 2 &* (a &- n) {
                diff = 2 &* (a &- n)
            }
        }
        return diff
    }

    /// Inverse horizontal Squeeze: combine `ll` (low-pass) +
    /// `residual` (high-pass) into a full-resolution row buffer of
    /// width `ll.width + residual.width`. Heights must match.
    public static func inverseHorizontal(
        ll: ModularChannel, residual: ModularChannel
    ) throws -> ModularChannel {
        guard ll.height == residual.height else {
            throw SpecSqueezeError.mismatchedHeight
        }
        // libjxl: chin.w == DivCeil(chin.w + chin_residual.w, 2).
        // i.e. ll.width is the ceil-half — so output width = ll + res.
        let outW = ll.width + residual.width
        let outH = ll.height
        var out = ModularChannel(
            width: outW, height: outH,
            hshift: max(0, ll.hshift &- 1), vshift: ll.vshift
        )
        if residual.height == 0 {
            return out  // empty short-circuit
        }
        for y in 0..<outH {
            for x in 0..<residual.width {
                let avg = Int64(ll.pixels[y * ll.width + x])
                let nextAvg = (x + 1 < ll.width)
                    ? Int64(ll.pixels[y * ll.width + x + 1])
                    : avg
                let left: Int64 = (x > 0)
                    ? Int64(out.pixels[y * outW + (x << 1) - 1])
                    : avg
                let diffMinusTendency = Int64(residual.pixels[y * residual.width + x])
                let tendency = smoothTendency(B: left, a: avg, n: nextAvg)
                let diff = diffMinusTendency &+ tendency
                let A = avg &+ (diff / 2)
                out.pixels[y * outW + (x << 1)] = Int32(truncatingIfNeeded: A)
                let B = A &- diff
                out.pixels[y * outW + (x << 1) + 1] = Int32(truncatingIfNeeded: B)
            }
            // Odd-tail: last LL slot copies through.
            if outW & 1 == 1 {
                out.pixels[y * outW + outW - 1] =
                    ll.pixels[y * ll.width + ll.width - 1]
            }
        }
        return out
    }

    /// Inverse vertical Squeeze: combine `ll` (top half) +
    /// `residual` (bottom half) into a full-resolution buffer of
    /// height `ll.height + residual.height`. Widths must match.
    public static func inverseVertical(
        ll: ModularChannel, residual: ModularChannel
    ) throws -> ModularChannel {
        guard ll.width == residual.width else {
            throw SpecSqueezeError.mismatchedWidth
        }
        let outW = ll.width
        let outH = ll.height + residual.height
        var out = ModularChannel(
            width: outW, height: outH,
            hshift: ll.hshift, vshift: max(0, ll.vshift &- 1)
        )
        if residual.width == 0 {
            return out
        }
        for y in 0..<residual.height {
            for x in 0..<outW {
                let avg = Int64(ll.pixels[y * ll.width + x])
                let nextAvg = (y + 1 < ll.height)
                    ? Int64(ll.pixels[(y + 1) * ll.width + x])
                    : avg
                let top: Int64 = (y > 0)
                    ? Int64(out.pixels[((y << 1) - 1) * outW + x])
                    : avg
                let diffMinusTendency = Int64(residual.pixels[y * residual.width + x])
                let tendency = smoothTendency(B: top, a: avg, n: nextAvg)
                let diff = diffMinusTendency &+ tendency
                let A = avg &+ (diff / 2)
                out.pixels[(y << 1) * outW + x] = Int32(truncatingIfNeeded: A)
                let B = A &- diff
                out.pixels[((y << 1) + 1) * outW + x] = Int32(truncatingIfNeeded: B)
            }
        }
        // Odd-tail: last LL row copies through.
        if outH & 1 == 1 {
            for x in 0..<outW {
                out.pixels[(outH - 1) * outW + x] =
                    ll.pixels[(ll.height - 1) * ll.width + x]
            }
        }
        return out
    }
}
