// Squeeze — multi-resolution Haar-like decomposition for the
// Modular sub-codec.
//
// ISO/IEC 18181-1 §C.7.6. For each axis, pairs of pixels (l, r)
// are split into:
//
//     avg = (l + r) >> 1     (floor division by 2)
//     res = l - r
//
// The result is rearranged so the first half of the row holds the
// `avg` (low-pass) values and the second half holds the `res`
// (high-pass) residuals. The decomposition is exactly invertible:
// `l = avg + ceil(res/2)`, `r = l - res`. (Implemented as
// `(res + 1) >> 1` which gives `ceil(res/2)` for both signs in
// two's-complement arithmetic.)
//
// On natural images the LL band (avg of avg) carries the smooth
// low-frequency content (excellent compression by prediction),
// while the HL/LH/HH bands carry small-magnitude high-frequency
// detail (excellent compression by entropy coding). Composing
// horizontal+vertical squeeze produces JXL's classic four-quadrant
// wavelet decomposition; recursive application gives multi-level
// resolutions for progressive decoding.
//
// This file ships the **1D primitive** (forward + inverse) plus
// the 2D split. Per-channel application + integration into the
// M0 pipeline is a follow-up.

import Foundation

package enum Squeeze {

    /// Forward 1D Haar squeeze on `row`. Pairs of adjacent values
    /// `(a[2i], a[2i+1])` are replaced with `(avg, res)`; output
    /// layout puts all `avg` values in the first half of the
    /// returned array and all `res` values in the second half. If
    /// the input length is odd, the last value passes through
    /// unchanged at index `n/2` (as the last LL slot before the
    /// HH section).
    package static func forwardHorizontal(_ row: [Int32]) -> [Int32] {
        let n = row.count
        let halfPairs = n / 2          // number of (l, r) pairs
        let llCount = (n + 1) / 2      // size of low-pass section (= halfPairs + odd-tail)
        var out = [Int32](repeating: 0, count: n)
        for i in 0..<halfPairs {
            let l = row[2 * i]
            let r = row[2 * i + 1]
            let avg = (l &+ r) &>> 1
            let res = l &- r
            out[i] = avg
            out[llCount + i] = res
        }
        if n % 2 == 1 {
            // Odd-length row: last element passes through into the
            // last LL slot (immediately before the residual section).
            out[halfPairs] = row[n - 1]
        }
        return out
    }

    /// Inverse of `forwardHorizontal`. `(avg, res)` → `(l, r)`.
    package static func inverseHorizontal(_ row: [Int32]) -> [Int32] {
        let n = row.count
        let halfPairs = n / 2
        let llCount = (n + 1) / 2
        var out = [Int32](repeating: 0, count: n)
        for i in 0..<halfPairs {
            let avg = row[i]
            let res = row[llCount + i]
            let l = avg &+ ((res &+ 1) &>> 1)
            let r = l &- res
            out[2 * i] = l
            out[2 * i + 1] = r
        }
        if n % 2 == 1 {
            // Recover odd tail from the last LL slot.
            out[n - 1] = row[halfPairs]
        }
        return out
    }

    /// Forward 1D Haar squeeze on a 2D buffer along the given axis.
    /// `axis = 0` squeezes each row horizontally; `axis = 1`
    /// squeezes each column vertically.
    package static func forward2D(
        _ buf: [Int32], width: Int, height: Int, axis: Int
    ) -> [Int32] {
        precondition(buf.count == width * height,
                     "Squeeze.forward2D: buffer size mismatch")
        switch axis {
        case 0:
            // Horizontal: process each row independently.
            var out = [Int32](repeating: 0, count: buf.count)
            for y in 0..<height {
                let rowStart = y * width
                let row = Array(buf[rowStart..<(rowStart + width)])
                let squeezed = forwardHorizontal(row)
                for x in 0..<width {
                    out[rowStart + x] = squeezed[x]
                }
            }
            return out
        case 1:
            // Vertical: extract each column, squeeze, write back.
            var out = [Int32](repeating: 0, count: buf.count)
            for x in 0..<width {
                var col = [Int32](repeating: 0, count: height)
                for y in 0..<height { col[y] = buf[y * width + x] }
                let squeezed = forwardHorizontal(col)  // 1D works on any axis
                for y in 0..<height { out[y * width + x] = squeezed[y] }
            }
            return out
        default:
            preconditionFailure("axis must be 0 (horizontal) or 1 (vertical)")
        }
    }

    /// Inverse of `forward2D`.
    package static func inverse2D(
        _ buf: [Int32], width: Int, height: Int, axis: Int
    ) -> [Int32] {
        precondition(buf.count == width * height,
                     "Squeeze.inverse2D: buffer size mismatch")
        switch axis {
        case 0:
            var out = [Int32](repeating: 0, count: buf.count)
            for y in 0..<height {
                let rowStart = y * width
                let row = Array(buf[rowStart..<(rowStart + width)])
                let unsqueezed = inverseHorizontal(row)
                for x in 0..<width {
                    out[rowStart + x] = unsqueezed[x]
                }
            }
            return out
        case 1:
            var out = [Int32](repeating: 0, count: buf.count)
            for x in 0..<width {
                var col = [Int32](repeating: 0, count: height)
                for y in 0..<height { col[y] = buf[y * width + x] }
                let unsqueezed = inverseHorizontal(col)
                for y in 0..<height { out[y * width + x] = unsqueezed[y] }
            }
            return out
        default:
            preconditionFailure("axis must be 0 (horizontal) or 1 (vertical)")
        }
    }
}
