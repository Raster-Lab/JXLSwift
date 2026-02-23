/// Intel AVX2 256-bit SIMD Acceleration
///
/// Provides 8-wide vectorised implementations of encoding hot paths using
/// `SIMD8<Float>` that maps to YMM registers (256-bit) on x86-64 processors
/// that support AVX2.
///
/// On non-x86-64 platforms, or on x86-64 processors without AVX2 support,
/// every function falls back to the equivalent SSEOps 4-wide implementation
/// transparently.
///
/// # Register Mapping
/// ```
/// SIMD8<Float>  → x86-64 + AVX2: YMMn (256-bit, VMULPS/VADDPS)
/// SIMD8<Float>  → x86-64 no-AVX2 / non-x86: falls through to SSEOps
/// ```
///
/// # AVX2 Availability
/// Use `AVXOps.isAVX2Available` to query runtime AVX2 support before
/// calling the 8-wide paths explicitly. The functions themselves check
/// availability and fall back automatically.

import Foundation

// MARK: - AVXOps Namespace

/// AVX2-accelerated operations for Intel/AMD x86-64 processors with AVX2 support.
///
/// All public functions fall back to `SSEOps` (4-wide) when AVX2 is not
/// available, and to scalar when not on x86-64.
public enum AVXOps {

    // MARK: - AVX2 Availability

    /// Whether AVX2 is available on the current processor at runtime.
    ///
    /// Returns `true` only on x86-64 with confirmed AVX2 support.
    /// Use this to selectively invoke the 8-wide paths.
    public static var isAVX2Available: Bool {
        #if arch(x86_64)
        return HardwareCapabilities.shared.hasAVX2
        #else
        return false
        #endif
    }

    // MARK: - DCT Basis Tables

    /// Precomputed 1-D DCT-II basis matrix for N = 8 (shared with SSEOps).
    static let dctBasis: [[Float]] = SSEOps.dctBasis

    /// Precomputed 1-D IDCT basis matrix for N = 8 (shared with SSEOps).
    static let idctBasis: [[Float]] = SSEOps.idctBasis

    // MARK: - 8-Wide DCT Operations

    /// Apply a forward 2-D DCT-II to an 8×8 block using AVX2-accelerated
    /// 1-D transforms with 8-wide `SIMD8<Float>` row processing.
    ///
    /// Each row's dot product is computed using a single `SIMD8<Float>`
    /// multiply (256-bit VMULPS) instead of two 128-bit MULPS, halving
    /// the number of multiply instructions.
    ///
    /// Falls back to `SSEOps.dct2D` when AVX2 is unavailable, and to
    /// a scalar path on non-x86-64 platforms.
    ///
    /// - Parameter block: 8×8 spatial-domain pixel values.
    /// - Returns: 8×8 frequency-domain DCT coefficients.
    public static func dct2D(_ block: [[Float]]) -> [[Float]] {
        #if arch(x86_64)
        guard isAVX2Available else { return SSEOps.dct2D(block) }

        // Step 1: 1-D DCT on each row using SIMD8 dot products
        var temp = [[Float]](
            repeating: [Float](repeating: 0, count: 8),
            count: 8
        )
        for y in 0..<8 {
            let rowVec = SIMD8<Float>(
                block[y][0], block[y][1], block[y][2], block[y][3],
                block[y][4], block[y][5], block[y][6], block[y][7]
            )
            for u in 0..<8 {
                let basisVec = SIMD8<Float>(
                    dctBasis[u][0], dctBasis[u][1], dctBasis[u][2], dctBasis[u][3],
                    dctBasis[u][4], dctBasis[u][5], dctBasis[u][6], dctBasis[u][7]
                )
                temp[y][u] = dotProduct8avx(rowVec, basisVec)
            }
        }

        // Step 2: 1-D DCT on each column (gather + SIMD8 dot product)
        var result = [[Float]](
            repeating: [Float](repeating: 0, count: 8),
            count: 8
        )
        for x in 0..<8 {
            let colVec = SIMD8<Float>(
                temp[0][x], temp[1][x], temp[2][x], temp[3][x],
                temp[4][x], temp[5][x], temp[6][x], temp[7][x]
            )
            for v in 0..<8 {
                let basisVec = SIMD8<Float>(
                    dctBasis[v][0], dctBasis[v][1], dctBasis[v][2], dctBasis[v][3],
                    dctBasis[v][4], dctBasis[v][5], dctBasis[v][6], dctBasis[v][7]
                )
                result[v][x] = dotProduct8avx(colVec, basisVec)
            }
        }
        return result
        #else
        return SSEOps.dct2D(block)
        #endif
    }

    /// Apply an inverse 2-D DCT (DCT-III) to an 8×8 block using AVX2
    /// 8-wide row processing.
    ///
    /// Falls back to `SSEOps.idct2D` when AVX2 is unavailable.
    ///
    /// - Parameter block: 8×8 frequency-domain coefficients.
    /// - Returns: 8×8 spatial-domain pixel values.
    public static func idct2D(_ block: [[Float]]) -> [[Float]] {
        #if arch(x86_64)
        guard isAVX2Available else { return SSEOps.idct2D(block) }

        var temp = [[Float]](
            repeating: [Float](repeating: 0, count: 8),
            count: 8
        )
        for v in 0..<8 {
            let rowVec = SIMD8<Float>(
                block[v][0], block[v][1], block[v][2], block[v][3],
                block[v][4], block[v][5], block[v][6], block[v][7]
            )
            for x in 0..<8 {
                let basisVec = SIMD8<Float>(
                    idctBasis[x][0], idctBasis[x][1], idctBasis[x][2], idctBasis[x][3],
                    idctBasis[x][4], idctBasis[x][5], idctBasis[x][6], idctBasis[x][7]
                )
                temp[v][x] = dotProduct8avx(rowVec, basisVec)
            }
        }

        var result = [[Float]](
            repeating: [Float](repeating: 0, count: 8),
            count: 8
        )
        for u in 0..<8 {
            let colVec = SIMD8<Float>(
                temp[0][u], temp[1][u], temp[2][u], temp[3][u],
                temp[4][u], temp[5][u], temp[6][u], temp[7][u]
            )
            for y in 0..<8 {
                let basisVec = SIMD8<Float>(
                    idctBasis[y][0], idctBasis[y][1], idctBasis[y][2], idctBasis[y][3],
                    idctBasis[y][4], idctBasis[y][5], idctBasis[y][6], idctBasis[y][7]
                )
                result[y][u] = dotProduct8avx(colVec, basisVec)
            }
        }
        return result
        #else
        return SSEOps.idct2D(block)
        #endif
    }

    // MARK: - 8-Wide Colour Space Conversion

    /// Convert R, G, B float arrays to Y, Cb, Cr processing 8 pixels at a
    /// time with AVX2 256-bit `SIMD8<Float>` operations (two 128-bit SSE
    /// lanes simultaneously).
    ///
    /// Falls back to `SSEOps.rgbToYCbCr` when AVX2 is unavailable.
    ///
    /// - Parameters:
    ///   - r: Red channel values in [0, 1].
    ///   - g: Green channel values in [0, 1].
    ///   - b: Blue channel values in [0, 1].
    /// - Returns: Tuple of (Y, Cb, Cr) arrays.
    public static func rgbToYCbCr(
        r: [Float], g: [Float], b: [Float]
    ) -> (y: [Float], cb: [Float], cr: [Float]) {
        #if arch(x86_64)
        guard isAVX2Available else { return SSEOps.rgbToYCbCr(r: r, g: g, b: b) }

        let count = r.count
        precondition(g.count == count && b.count == count)

        var yOut  = [Float](repeating: 0, count: count)
        var cbOut = [Float](repeating: 0, count: count)
        var crOut = [Float](repeating: 0, count: count)

        // BT.601 coefficients — broadcast to 8-wide
        let kr   = SIMD8<Float>(repeating:  0.299)
        let kg   = SIMD8<Float>(repeating:  0.587)
        let kb   = SIMD8<Float>(repeating:  0.114)
        let kcbr = SIMD8<Float>(repeating: -0.168736)
        let kcbg = SIMD8<Float>(repeating: -0.331264)
        let kcbb = SIMD8<Float>(repeating:  0.5)
        let kcrr = SIMD8<Float>(repeating:  0.5)
        let kcrg = SIMD8<Float>(repeating: -0.418688)
        let kcrb = SIMD8<Float>(repeating: -0.081312)
        let off  = SIMD8<Float>(repeating:  0.5)

        let simdCount = count / 8 * 8
        var i = 0
        while i < simdCount {
            let rv = SIMD8<Float>(
                r[i], r[i+1], r[i+2], r[i+3], r[i+4], r[i+5], r[i+6], r[i+7]
            )
            let gv = SIMD8<Float>(
                g[i], g[i+1], g[i+2], g[i+3], g[i+4], g[i+5], g[i+6], g[i+7]
            )
            let bv = SIMD8<Float>(
                b[i], b[i+1], b[i+2], b[i+3], b[i+4], b[i+5], b[i+6], b[i+7]
            )

            let yv  = kr * rv + kg * gv + kb * bv
            let cbv = kcbr * rv + kcbg * gv + kcbb * bv + off
            let crv = kcrr * rv + kcrg * gv + kcrb * bv + off

            for j in 0..<8 {
                yOut[i+j]  = yv[j]
                cbOut[i+j] = cbv[j]
                crOut[i+j] = crv[j]
            }
            i += 8
        }
        // Scalar tail (< 8 pixels)
        while i < count {
            let rv = r[i]; let gv = g[i]; let bv = b[i]
            yOut[i]  =  0.299    * rv + 0.587    * gv + 0.114    * bv
            cbOut[i] = -0.168736 * rv - 0.331264 * gv + 0.5      * bv + 0.5
            crOut[i] =  0.5      * rv - 0.418688 * gv - 0.081312 * bv + 0.5
            i += 1
        }
        return (yOut, cbOut, crOut)
        #else
        return SSEOps.rgbToYCbCr(r: r, g: g, b: b)
        #endif
    }

    // MARK: - 8-Wide Block Activity

    /// Compute block activity (variance) using AVX2 8-wide sum and
    /// sum-of-squares processing (one SIMD8 load per row).
    ///
    /// Falls back to `SSEOps.blockActivity` when AVX2 is unavailable.
    ///
    /// - Parameter block: 8×8 spatial-domain pixel values.
    /// - Returns: Variance of the pixel values (≥ 0).
    public static func blockActivity(_ block: [[Float]]) -> Float {
        #if arch(x86_64)
        guard isAVX2Available else { return SSEOps.blockActivity(block) }

        var sumVec   = SIMD8<Float>.zero
        var sumSqVec = SIMD8<Float>.zero

        for y in 0..<8 {
            let row = SIMD8<Float>(
                block[y][0], block[y][1], block[y][2], block[y][3],
                block[y][4], block[y][5], block[y][6], block[y][7]
            )
            sumVec   = sumVec   + row
            sumSqVec = sumSqVec + row * row
        }

        // Horizontal reduce
        var sum:   Float = 0
        var sumSq: Float = 0
        for j in 0..<8 {
            sum   += sumVec[j]
            sumSq += sumSqVec[j]
        }
        let n: Float = 64
        return max(0, sumSq / n - (sum / n) * (sum / n))
        #else
        return SSEOps.blockActivity(block)
        #endif
    }

    // MARK: - Private Helpers

    /// AVX2 dot product for 8-element float arrays using a single
    /// `SIMD8<Float>` multiply followed by horizontal reduction.
    ///
    /// Maps to one `VMULPS ymm` (256-bit) instruction on AVX2-capable
    /// processors, replacing the two-vector approach of `SSEOps.dotProduct8`.
    @inline(__always)
    private static func dotProduct8avx(_ a: SIMD8<Float>, _ b: SIMD8<Float>) -> Float {
        let prod = a * b
        // Horizontal sum via two SIMD4 additions + scalar reduce
        let lo = SIMD4<Float>(prod[0], prod[1], prod[2], prod[3])
        let hi = SIMD4<Float>(prod[4], prod[5], prod[6], prod[7])
        let sum4 = lo + hi
        return sum4[0] + sum4[1] + sum4[2] + sum4[3]
    }
}
