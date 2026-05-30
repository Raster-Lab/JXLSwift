// DCT2D — separable 2-D DCT-II / IDCT-II for the VarDCT sub-codec.
//
// **Status**: foundation. Implements the orthonormal type-II DCT for
// any power-of-two N × N block (N ∈ {2, 4, 8, 16, 32, 64, 128, 256}
// — all the square AC strategy sizes in JPEG XL). Asymmetric
// strategies (4×8, 8×4, 8×16, 16×8, etc.) cascade two 1-D DCTs of
// different lengths and live in `forward(_:width:height:)`.
//
// Spec reference: ISO/IEC 18181-1 §C.9. libjxl: `lib/jxl/dct-inl.h`,
// `lib/jxl/dct_scales.cc`. The direct (slow) reference form is the
// spec; libjxl's fast Loeffler/Ligtenberg/Moschytz scheme runs in
// 11 multiplies for length 8 — switching to the fast path is a
// future optimisation.
//
// **Convention**: input/output buffers are row-major `Float`
// arrays of length `N²`. The forward transform produces
// coefficients in libjxl's natural order — DC at index 0,
// frequency-major. Quantisation + scan-order remapping happens
// later.
//
// Mathematically:
//
//     X[k] = sum_{n=0..N-1} x[n] · cos((π/N) · (n + 0.5) · k) · α(k)
//     where α(0) = √(1/N), α(k>0) = √(2/N).
//
// 2-D == row-wise DCT of column-wise DCT (separable).

import Foundation

package enum DCT2D {

    /// Apply a square N×N type-II DCT in-place, where N is a
    /// power of two in `[2, 256]`.
    package static func forward(_ block: inout [Float], size n: Int) {
        precondition(isPowerOfTwo(n) && n >= 2 && n <= 256,
                     "size must be a power of two in [2, 256]")
        precondition(block.count == n * n,
                     "block must be exactly n*n samples (\(n * n))")
        let table = DCTBasis.table(forLength: n)
        applySeparable(&block, w: n, h: n, table: table)
    }

    /// Inverse of `forward(_:size:)`. Recovers original samples.
    package static func inverse(_ block: inout [Float], size n: Int) {
        precondition(isPowerOfTwo(n) && n >= 2 && n <= 256,
                     "size must be a power of two in [2, 256]")
        precondition(block.count == n * n,
                     "block must be exactly n*n samples (\(n * n))")
        let table = DCTBasis.table(forLength: n)
        applySeparableInverse(&block, w: n, h: n, table: table)
    }

    /// Apply a rectangular W×H DCT (W, H power-of-two, in `[2, 256]`,
    /// possibly different) — the separable cascade libjxl uses for
    /// asymmetric AC strategies (e.g. DCT4x8, DCT16x8).
    /// `block` is row-major length `w * h`.
    package static func forward(
        _ block: inout [Float], width w: Int, height h: Int
    ) {
        precondition(isPowerOfTwo(w) && w >= 2 && w <= 256,
                     "width must be a power of two in [2, 256]")
        precondition(isPowerOfTwo(h) && h >= 2 && h <= 256,
                     "height must be a power of two in [2, 256]")
        precondition(block.count == w * h,
                     "block must be exactly w*h samples (\(w * h))")
        applySeparable(
            &block, w: w, h: h,
            tableWidth: DCTBasis.table(forLength: w),
            tableHeight: DCTBasis.table(forLength: h)
        )
    }

    /// Inverse of `forward(_:width:height:)`.
    package static func inverse(
        _ block: inout [Float], width w: Int, height h: Int
    ) {
        precondition(isPowerOfTwo(w) && w >= 2 && w <= 256,
                     "width must be a power of two in [2, 256]")
        precondition(isPowerOfTwo(h) && h >= 2 && h <= 256,
                     "height must be a power of two in [2, 256]")
        precondition(block.count == w * h,
                     "block must be exactly w*h samples (\(w * h))")
        applySeparableInverse(
            &block, w: w, h: h,
            tableWidth: DCTBasis.table(forLength: w),
            tableHeight: DCTBasis.table(forLength: h)
        )
    }

    // MARK: - Backwards-compatible 8×8 entry points

    @available(*, deprecated, renamed: "forward(_:size:)",
               message: "Use forward(_:size:) for any square size")
    package static func forward8x8(_ block: inout [Float]) {
        forward(&block, size: 8)
    }

    @available(*, deprecated, renamed: "inverse(_:size:)",
               message: "Use inverse(_:size:) for any square size")
    package static func inverse8x8(_ block: inout [Float]) {
        inverse(&block, size: 8)
    }
}

// MARK: - Internals

/// Pre-computed `α(k) · cos((π/N)(n + 0.5)k)` matrix indexed by
/// `[k * N + n]`. Cached per length so the per-block work is just
/// matrix-vector products.
private enum DCTBasis {
    nonisolated(unsafe) private static var cache: [Int: [Float]] = [:]
    private static let lock = NSLock()

    static func table(forLength n: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if let t = cache[n] { return t }
        var t = [Float](repeating: 0, count: n * n)
        let nf = Float(n)
        for k in 0..<n {
            let alpha: Float = (k == 0) ? sqrtf(1 / nf) : sqrtf(2 / nf)
            for nn in 0..<n {
                let angle = (Float.pi / nf) * (Float(nn) + 0.5) * Float(k)
                t[k * n + nn] = alpha * cosf(angle)
            }
        }
        cache[n] = t
        return t
    }
}

@inline(__always)
private func isPowerOfTwo(_ n: Int) -> Bool {
    return n > 0 && (n & (n - 1)) == 0
}

private func applySeparable(
    _ block: inout [Float], w: Int, h: Int, table: [Float]
) {
    applySeparable(&block, w: w, h: h,
                   tableWidth: table, tableHeight: table)
}

private func applySeparableInverse(
    _ block: inout [Float], w: Int, h: Int, table: [Float]
) {
    applySeparableInverse(&block, w: w, h: h,
                          tableWidth: table, tableHeight: table)
}

/// Forward separable 2-D DCT: row-wise DCT of length `w`, then
/// column-wise DCT of length `h`.
private func applySeparable(
    _ block: inout [Float], w: Int, h: Int,
    tableWidth: [Float], tableHeight: [Float]
) {
    var temp = [Float](repeating: 0, count: w * h)
    // Row-wise: each row is `w` samples, transformed using `tableWidth`.
    for r in 0..<h {
        let rowStart = r * w
        for k in 0..<w {
            var s: Float = 0
            for n in 0..<w {
                s += block[rowStart + n] * tableWidth[k * w + n]
            }
            temp[rowStart + k] = s
        }
    }
    // Column-wise: each column is `h` samples, transformed using
    // `tableHeight`.
    for c in 0..<w {
        for k in 0..<h {
            var s: Float = 0
            for n in 0..<h {
                s += temp[n * w + c] * tableHeight[k * h + n]
            }
            block[k * w + c] = s
        }
    }
}

/// Inverse separable 2-D DCT (transpose of forward).
private func applySeparableInverse(
    _ block: inout [Float], w: Int, h: Int,
    tableWidth: [Float], tableHeight: [Float]
) {
    var temp = [Float](repeating: 0, count: w * h)
    // Column-wise inverse: synthesise samples from coefficients
    // along each column.
    for c in 0..<w {
        for n in 0..<h {
            var s: Float = 0
            for k in 0..<h {
                s += block[k * w + c] * tableHeight[k * h + n]
            }
            temp[n * w + c] = s
        }
    }
    // Row-wise inverse.
    for r in 0..<h {
        let rowStart = r * w
        for n in 0..<w {
            var s: Float = 0
            for k in 0..<w {
                s += temp[rowStart + k] * tableWidth[k * w + n]
            }
            block[rowStart + n] = s
        }
    }
}
