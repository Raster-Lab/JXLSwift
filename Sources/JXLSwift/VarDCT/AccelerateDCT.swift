// AccelerateDCT — UMA-friendly forward + inverse DCT backed by
// Apple's Accelerate framework (vDSP).
//
// **Design intent**: leverage Apple Silicon's Unified Memory
// Architecture so a future VarDCT encoder can operate on the same
// `[Float]` buffers the decoder reads/writes — no host↔device
// copies, no pinned memory, no driver round-trips. vDSP routines
// dispatch onto NEON SIMD on the CPU, which shares the same DRAM
// pool with everything else on Apple Silicon. (Metal compute lands
// later as a separate backend; the contract for both is identical
// `[Float]` in / `[Float]` out, so a caller can swap backends
// without restructuring.)
//
// **Status**: square N×N where N ∈ {8, 16, 32}. Byte-equivalent to
// `LibjxlDCT.dct2D` / `LibjxlIDCT.idct2D` (the scalar reference)
// within float epsilon — pinned by tests. Not yet wired into the
// encoder (which is currently lossless-Modular only); ships as a
// standalone backend so the future VarDCT encoder can opt in.
//
// **Apple-only**: gated on `#if canImport(Accelerate)`. The fallback
// (call the scalar `LibjxlDCT` / `LibjxlIDCT` directly) is what
// callers should use on Linux / Windows.
//
// libjxl: no direct equivalent — libjxl's optimised path is the
// Loeffler recursion in `dct-inl.h`, not Accelerate. This file is
// JXLSwift-specific UMA infrastructure.

import Foundation

#if canImport(Accelerate)
import Accelerate

public enum AccelerateDCT {

    /// Per-N cache of the precomputed forward DCT matrix
    /// (`M_fwd[u, y] = α(u) · cos((y+0.5)·u·π/N) · √2/N`).
    /// First call for each N pays the matrix build; subsequent calls
    /// reuse. Indexed `[N: matrix]`. Thread-safe via `NSLock`.
    nonisolated(unsafe) private static var fwdMatrixCache: [Int: [Float]] = [:]
    nonisolated(unsafe) private static var invMatrixCache: [Int: [Float]] = [:]
    private static let cacheLock = NSLock()

    @inline(__always)
    private static func alpha(_ u: Int) -> Float {
        return u == 0 ? 0.7071067811865475 : 1.0
    }

    /// Build `M_fwd` for forward DCT-N (matches `LibjxlDCT.dct1D`'s
    /// matrix). Returns row-major N×N: `out[u * N + y]`.
    private static func buildForwardMatrix(N: Int) -> [Float] {
        let nf = Float(N)
        let scale: Float = 1.4142135623730951 / nf
        var m = [Float](repeating: 0, count: N * N)
        for u in 0..<N {
            for y in 0..<N {
                let angle = (Float(y) + 0.5) * Float(u) * .pi / nf
                m[u * N + y] = alpha(u) * cosf(angle) * scale
            }
        }
        return m
    }

    /// Build `M_inv` for inverse DCT-N (matches `LibjxlIDCT.idct1D`'s
    /// matrix). Returns row-major N×N: `out[u * N + y]`.
    private static func buildInverseMatrix(N: Int) -> [Float] {
        let nf = Float(N)
        let scale: Float = 1.4142135623730951
        var m = [Float](repeating: 0, count: N * N)
        for u in 0..<N {
            for y in 0..<N {
                let angle = (Float(u) + 0.5) * Float(y) * .pi / nf
                m[u * N + y] = alpha(y) * cosf(angle) * scale
            }
        }
        return m
    }

    /// Lazily fetch (or build) the forward DCT-N matrix.
    private static func forwardMatrix(N: Int) -> [Float] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let m = fwdMatrixCache[N] { return m }
        let m = buildForwardMatrix(N: N)
        fwdMatrixCache[N] = m
        return m
    }

    /// Lazily fetch (or build) the inverse DCT-N matrix.
    private static func inverseMatrix(N: Int) -> [Float] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let m = invMatrixCache[N] { return m }
        let m = buildInverseMatrix(N: N)
        invMatrixCache[N] = m
        return m
    }

    /// 2-D forward DCT (libjxl scaled-DCT convention), N×N square,
    /// in-place on `block` (row-major `N*N` floats). Equivalent to
    /// `LibjxlDCT.dct2D(_:size:N)` — verified by tests within float
    /// epsilon — but uses `vDSP_mmul` for the two matrix-multiplies
    /// + one transpose, dispatching onto NEON via Accelerate.
    ///
    /// Two passes:
    ///   1. `block_after = M_fwd * block^T` (row IDCT applied to all
    ///      columns simultaneously via `vDSP_mmul(M_fwd, block^T)`).
    ///   2. transpose, then same again.
    ///
    /// We re-derive the final layout by carrying the `block` shape
    /// through transposes so the output ends up in row-major order
    /// matching `LibjxlDCT.dct2D`.
    public static func dct2D(_ block: inout [Float], size N: Int) {
        precondition(block.count == N * N, "block must be N*N")
        let M = forwardMatrix(N: N)
        var temp = [Float](repeating: 0, count: N * N)
        // Pass 1: temp = M * block^T (or equivalent).
        // LibjxlDCT.dct2D logic: row IDCT (`block[u*N+x]` per col x),
        // transpose, row IDCT, transpose. See LibjxlDCT.swift for
        // the exact pre/post transpose dance — we mirror it here.
        // First: input block[u*N+x] for u ∈ [0,N), x ∈ [0,N). The
        // `dct1D(N, M, input)` body computes
        //     out[M*u+x] = sum_y matrix[N*u+y] * in[M*y+x]
        // i.e. `out = matrix * in` viewing `in` as N rows × M cols.
        // For `LibjxlDCT.dct2D` first pass M=N, in=block, out=temp.
        // That's `temp = matrix * block` as N×N matrix product.
        // vDSP_mmul: `C = A * B` for A (P×M), B (M×N), C (P×N) row-major.
        block.withUnsafeMutableBufferPointer { blkBuf in
            temp.withUnsafeMutableBufferPointer { tmpBuf in
                M.withUnsafeBufferPointer { mBuf in
                    vDSP_mmul(
                        mBuf.baseAddress!, 1,
                        blkBuf.baseAddress!, 1,
                        tmpBuf.baseAddress!, 1,
                        vDSP_Length(N), vDSP_Length(N), vDSP_Length(N)
                    )
                }
            }
        }
        // Transpose temp → block.
        block.withUnsafeMutableBufferPointer { blkBuf in
            temp.withUnsafeBufferPointer { tmpBuf in
                vDSP_mtrans(
                    tmpBuf.baseAddress!, 1,
                    blkBuf.baseAddress!, 1,
                    vDSP_Length(N), vDSP_Length(N)
                )
            }
        }
        // Pass 2: temp = M * block.
        block.withUnsafeMutableBufferPointer { blkBuf in
            temp.withUnsafeMutableBufferPointer { tmpBuf in
                M.withUnsafeBufferPointer { mBuf in
                    vDSP_mmul(
                        mBuf.baseAddress!, 1,
                        blkBuf.baseAddress!, 1,
                        tmpBuf.baseAddress!, 1,
                        vDSP_Length(N), vDSP_Length(N), vDSP_Length(N)
                    )
                }
            }
        }
        // Final transpose temp → block to restore output layout.
        block.withUnsafeMutableBufferPointer { blkBuf in
            temp.withUnsafeBufferPointer { tmpBuf in
                vDSP_mtrans(
                    tmpBuf.baseAddress!, 1,
                    blkBuf.baseAddress!, 1,
                    vDSP_Length(N), vDSP_Length(N)
                )
            }
        }
    }

    /// 2-D inverse DCT, N×N square. Equivalent to
    /// `LibjxlIDCT.idct2D(_:size:N)` — same vDSP_mmul + transpose
    /// pipeline as `dct2D` but with the inverse matrix.
    public static func idct2D(_ block: inout [Float], size N: Int) {
        precondition(block.count == N * N, "block must be N*N")
        let M = inverseMatrix(N: N)
        var temp = [Float](repeating: 0, count: N * N)
        block.withUnsafeMutableBufferPointer { blkBuf in
            temp.withUnsafeMutableBufferPointer { tmpBuf in
                M.withUnsafeBufferPointer { mBuf in
                    vDSP_mmul(
                        mBuf.baseAddress!, 1,
                        blkBuf.baseAddress!, 1,
                        tmpBuf.baseAddress!, 1,
                        vDSP_Length(N), vDSP_Length(N), vDSP_Length(N)
                    )
                }
            }
        }
        block.withUnsafeMutableBufferPointer { blkBuf in
            temp.withUnsafeBufferPointer { tmpBuf in
                vDSP_mtrans(
                    tmpBuf.baseAddress!, 1,
                    blkBuf.baseAddress!, 1,
                    vDSP_Length(N), vDSP_Length(N)
                )
            }
        }
        block.withUnsafeMutableBufferPointer { blkBuf in
            temp.withUnsafeMutableBufferPointer { tmpBuf in
                M.withUnsafeBufferPointer { mBuf in
                    vDSP_mmul(
                        mBuf.baseAddress!, 1,
                        blkBuf.baseAddress!, 1,
                        tmpBuf.baseAddress!, 1,
                        vDSP_Length(N), vDSP_Length(N), vDSP_Length(N)
                    )
                }
            }
        }
        block.withUnsafeMutableBufferPointer { blkBuf in
            temp.withUnsafeBufferPointer { tmpBuf in
                vDSP_mtrans(
                    tmpBuf.baseAddress!, 1,
                    blkBuf.baseAddress!, 1,
                    vDSP_Length(N), vDSP_Length(N)
                )
            }
        }
    }
}

#else  // !canImport(Accelerate)

/// Non-Apple platforms fall through to the scalar `LibjxlDCT` /
/// `LibjxlIDCT` implementations — the source-of-truth path. Same
/// signature so call sites don't need to fork on the platform.
public enum AccelerateDCT {
    public static func dct2D(_ block: inout [Float], size N: Int) {
        LibjxlDCT.dct2D(&block, size: N)
    }
    public static func idct2D(_ block: inout [Float], size N: Int) {
        LibjxlIDCT.idct2D(&block, size: N)
    }
}

#endif
