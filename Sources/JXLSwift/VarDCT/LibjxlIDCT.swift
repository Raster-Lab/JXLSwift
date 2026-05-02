// LibjxlIDCT — direct port of libjxl's reference IDCTSlow from
// `lib/jxl/dct_for_test.h`. Unoptimised matrix-vector form;
// libjxl's own test suite verifies it's byte-equivalent to their
// optimised Loeffler-style IDCT (`dct-inl.h::IDCT1DImpl`).
//
// Inverts libjxl's "scaled DCT" (`ComputeScaledDCT<R, C>`) byte-
// for-byte — for `F[0,0] = c` and zero elsewhere, all pixels
// equal `c` ("DC = mean" property libjxl preserves with no bridge).
//
// The 1-D matrix:
//
//     M_inv[u, y] = α(y) · cos((u + 0.5) · y · π/N) · √2
//     where α(0) = 1/√2, α(y > 0) = 1
//
// `M_inv = M_fwd^T` where `M_fwd[u, y] = α(u) · cos((y+0.5) · u·π/N) · √2/N`.
// Round-trip: `M_inv · M_fwd = I` (verified algebraically via the
// standard DCT-II orthonormality identity
// `sum_y α(y)² · cos((u+0.5)y π/N) · cos((u'+0.5)y π/N) = (N/2)·δ(u,u')`).
//
// 2-D wraps the 1-D primitive: row IDCT → transpose → row IDCT →
// transpose. Matches libjxl's `IDCTSlow<N>` exactly.
//
// **Status**: square N×N where N ∈ {2, 4, 8, 16, 32}. Asymmetric
// extensions trivial (just pass different N for row vs column pass).
//
// Spec reference: ISO/IEC 18181-1 §C.9. libjxl: `lib/jxl/dct_for_test.h`.

import Foundation

public enum LibjxlIDCT {

    @inline(__always)
    private static func alpha(_ u: Int) -> Float {
        return u == 0 ? 0.7071067811865475 : 1.0
    }

    /// libjxl `dct_for_test.h::IDCT1D<N, M>` — apply 1-D IDCT-N
    /// to `M` parallel "channels" (columns). Block layout:
    /// `block[u * M + x]` for u ∈ [0, N), x ∈ [0, M). Each column
    /// (fixed `x`) is a length-N coefficient sequence. Output is
    /// in the same layout (length-N pixel column per `x`).
    ///
    /// The 1-D matrix `M_inv[u, y] = α(y) · cos((u+0.5)yπ/N) · √2`
    /// is rebuilt on every call (matches libjxl's reference; an
    /// optimised version would cache per-N).
    public static func idct1D(
        N: Int, M: Int, input: [Float]
    ) -> [Float] {
        precondition(input.count == N * M)
        let scale: Float = 1.4142135623730951  // √2
        var matrix = [Float](repeating: 0, count: N * N)
        // Build M_inv[u, y] = α(y) · cos((u+0.5)yπ/N) · √2.
        // libjxl stores it transposed of M_fwd: matrix[N*y + u]
        // but we use the (u, y) indexing in the multiply below
        // so store as matrix[N*u + y] for convenience.
        let nf = Float(N)
        for u in 0..<N {
            for y in 0..<N {
                let angle = (Float(u) + 0.5) * Float(y) * .pi / nf
                matrix[N * u + y] = alpha(y) * cosf(angle) * scale
            }
        }
        var output = [Float](repeating: 0, count: N * M)
        for x in 0..<M {
            for u in 0..<N {
                var sum: Float = 0
                for y in 0..<N {
                    sum += matrix[N * u + y] * input[M * y + x]
                }
                output[M * u + x] = sum
            }
        }
        return output
    }

    /// libjxl `dct_for_test.h::IDCTSlow<N>` — 2-D N×N IDCT applied
    /// in-place to `block` (row-major, length N*N). Inverts libjxl's
    /// scaled forward DCT byte-for-byte.
    public static func idct2D(_ block: inout [Float], size N: Int) {
        idct2D(&block, rows: N, cols: N)
    }

    /// libjxl-convention 2-D IDCT for asymmetric (rows × cols)
    /// blocks. Mirrors `IDCTSlow` extended with separate N for each
    /// axis. `block` is row-major `rows * cols` floats; output is
    /// row-major in the same shape (each pass is a 1-D IDCT along
    /// one axis, with a transpose between passes).
    public static func idct2D(
        _ block: inout [Float], rows R: Int, cols C: Int
    ) {
        precondition(block.count == R * C)
        // Row IDCT-C: block layout block[u * C + x] where u ∈ [0,R)
        // is the row, x ∈ [0,C) the column. We treat each ROW as a
        // length-C coefficient sequence; idct1D needs block layout
        // block[u*M + x] for u ∈ [0, N=C), x ∈ [0, M=R). That means
        // we must FIRST transpose block (to make it C rows × R cols
        // = column-major-of-original).
        var transposed = [Float](repeating: 0, count: R * C)
        for u in 0..<R {
            for x in 0..<C {
                transposed[x * R + u] = block[u * C + x]
            }
        }
        // Now transposed[u' * R + x'] for u' ∈ [0, C) and x' ∈ [0, R).
        // Apply IDCT-C with M=R: 1-D IDCT-C on each "column" of length C.
        var temp = idct1D(N: C, M: R, input: transposed)
        // temp[u * R + x] for u ∈ [0, C), x ∈ [0, R).
        // Now apply IDCT-R with M=C. Need temp re-laid as
        // temp_for_pass2[u * C + x] for u ∈ [0, R), x ∈ [0, C).
        // That's a transpose of temp.
        var temp2 = [Float](repeating: 0, count: R * C)
        for u in 0..<C {
            for x in 0..<R {
                temp2[x * C + u] = temp[u * R + x]
            }
        }
        // Apply IDCT-R with M=C.
        let temp3 = idct1D(N: R, M: C, input: temp2)
        // temp3[u * C + x] for u ∈ [0, R), x ∈ [0, C). Already in
        // row-major output shape (R rows × C cols).
        block = temp3
    }
}

/// libjxl `dct_for_test.h::DCTSlow<N>` — direct port of libjxl's
/// reference forward DCT, used here only for tests / round-trip
/// verification of `LibjxlIDCT`.
public enum LibjxlDCT {

    @inline(__always)
    private static func alpha(_ u: Int) -> Float {
        return u == 0 ? 0.7071067811865475 : 1.0
    }

    /// libjxl `dct_for_test.h::DCT1D<N, M>` — apply 1-D forward
    /// DCT-N to M parallel columns. Same layout as `LibjxlIDCT.idct1D`.
    public static func dct1D(
        N: Int, M: Int, input: [Float]
    ) -> [Float] {
        precondition(input.count == N * M)
        let nf = Float(N)
        let scale: Float = 1.4142135623730951 / nf  // √2 / N
        var matrix = [Float](repeating: 0, count: N * N)
        for u in 0..<N {
            for y in 0..<N {
                let angle = (Float(y) + 0.5) * Float(u) * .pi / nf
                matrix[N * u + y] = alpha(u) * cosf(angle) * scale
            }
        }
        var output = [Float](repeating: 0, count: N * M)
        for x in 0..<M {
            for u in 0..<N {
                var sum: Float = 0
                for y in 0..<N {
                    sum += matrix[N * u + y] * input[M * y + x]
                }
                output[M * u + x] = sum
            }
        }
        return output
    }

    /// 2-D forward DCT in libjxl's "scaled DCT" convention.
    public static func dct2D(_ block: inout [Float], size N: Int) {
        dct2D(&block, rows: N, cols: N)
    }

    /// Asymmetric forward DCT — same axis layout as `LibjxlIDCT.idct2D`.
    public static func dct2D(
        _ block: inout [Float], rows R: Int, cols C: Int
    ) {
        precondition(block.count == R * C)
        var transposed = [Float](repeating: 0, count: R * C)
        for u in 0..<R {
            for x in 0..<C {
                transposed[x * R + u] = block[u * C + x]
            }
        }
        var temp = dct1D(N: C, M: R, input: transposed)
        var temp2 = [Float](repeating: 0, count: R * C)
        for u in 0..<C {
            for x in 0..<R {
                temp2[x * C + u] = temp[u * R + x]
            }
        }
        let temp3 = dct1D(N: R, M: C, input: temp2)
        block = temp3
    }
}
