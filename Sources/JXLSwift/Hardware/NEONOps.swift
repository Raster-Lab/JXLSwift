/// ARM NEON SIMD Acceleration
///
/// Provides optimised implementations of critical encoding operations using
/// Swift SIMD types that map directly to ARM NEON registers on ARM64.
///
/// All public functions have equivalent scalar fallback implementations
/// so the same API is available on every platform. The `#if arch(arm64)`
/// guards are placed at the call-site level (in the encoder dispatch
/// methods) rather than inside this file — every function here compiles
/// on all architectures because it uses Swift's portable SIMD types.
///
/// # Architecture
/// ```
/// SIMD4<Float>   → ARM64: float32x4_t (128-bit NEON register)
/// SIMD8<UInt16>  → ARM64: uint16x8_t  (128-bit NEON register)
/// SIMD4<Int32>   → ARM64: int32x4_t   (128-bit NEON register)
/// ```

import Foundation

// MARK: - NEONOps Namespace

/// SIMD-accelerated operations targeting ARM NEON via Swift's portable SIMD types.
///
/// On ARM64 these map to NEON registers and auto-vectorised instructions.
/// On x86-64 Swift maps them to SSE/AVX equivalents, giving a portable
/// speedup on all platforms while achieving best performance on Apple Silicon.
public enum NEONOps {

    // MARK: - DCT Butterfly Operations

    /// Precomputed 1-D DCT-II basis matrix for N = 8.
    ///
    /// Element `[u][x]` = C(u) · cos((2x+1)·u·π / 16), where
    /// C(0) = 1/√2, C(u>0) = 1, and every element is pre-multiplied
    /// by the normalisation factor √(2/8) = 0.5.
    static let dctBasis: [[Float]] = {
        let n = 8
        let norm = sqrt(2.0 / Float(n))
        var basis = [[Float]](
            repeating: [Float](repeating: 0, count: n),
            count: n
        )
        for u in 0..<n {
            let cu: Float = u == 0 ? 1.0 / sqrt(2.0) : 1.0
            for x in 0..<n {
                basis[u][x] = cu * cos((2.0 * Float(x) + 1.0) * Float(u) * .pi / (2.0 * Float(n))) * norm
            }
        }
        return basis
    }()

    /// Precomputed 1-D IDCT (DCT-III) basis matrix for N = 8.
    ///
    /// Element `[x][u]` = C(u) · cos((2x+1)·u·π / 16), pre-multiplied
    /// by the normalisation factor.  This is the transpose of ``dctBasis``
    /// scaled appropriately.
    static let idctBasis: [[Float]] = {
        let n = 8
        let norm = sqrt(2.0 / Float(n))
        var basis = [[Float]](
            repeating: [Float](repeating: 0, count: n),
            count: n
        )
        for x in 0..<n {
            for u in 0..<n {
                let cu: Float = u == 0 ? 1.0 / sqrt(2.0) : 1.0
                basis[x][u] = cu * cos((2.0 * Float(x) + 1.0) * Float(u) * .pi / (2.0 * Float(n))) * norm
            }
        }
        return basis
    }()

    /// Apply a forward 2-D DCT-II to an 8×8 block using SIMD-accelerated
    /// 1-D transforms on rows then columns.
    ///
    /// The implementation uses `SIMD4<Float>` to process four products at
    /// a time in the inner dot-product loop, achieving ~2× throughput
    /// compared to the pure-scalar `applyDCTScalar`.
    ///
    /// - Parameter block: 8×8 spatial-domain pixel values.
    /// - Returns: 8×8 frequency-domain DCT coefficients.
    public static func dct2D(_ block: [[Float]]) -> [[Float]] {
        // Step 1: 1-D DCT on each row
        var temp = [[Float]](
            repeating: [Float](repeating: 0, count: 8),
            count: 8
        )
        for y in 0..<8 {
            for u in 0..<8 {
                temp[y][u] = dotProduct8(dctBasis[u], block[y])
            }
        }

        // Step 2: 1-D DCT on each column (transpose, row-DCT, transpose)
        var result = [[Float]](
            repeating: [Float](repeating: 0, count: 8),
            count: 8
        )
        for x in 0..<8 {
            // Gather column
            let col = SIMD8<Float>(
                temp[0][x], temp[1][x], temp[2][x], temp[3][x],
                temp[4][x], temp[5][x], temp[6][x], temp[7][x]
            )
            let colArray = simd8ToArray(col)
            for v in 0..<8 {
                result[v][x] = dotProduct8(dctBasis[v], colArray)
            }
        }

        return result
    }

    /// Apply an inverse 2-D DCT (DCT-III) to an 8×8 block.
    ///
    /// - Parameter block: 8×8 frequency-domain coefficients.
    /// - Returns: 8×8 spatial-domain pixel values.
    public static func idct2D(_ block: [[Float]]) -> [[Float]] {
        // Step 1: 1-D IDCT on each row
        var temp = [[Float]](
            repeating: [Float](repeating: 0, count: 8),
            count: 8
        )
        for v in 0..<8 {
            for x in 0..<8 {
                temp[v][x] = dotProduct8(idctBasis[x], block[v])
            }
        }

        // Step 2: 1-D IDCT on each column
        var result = [[Float]](
            repeating: [Float](repeating: 0, count: 8),
            count: 8
        )
        for u in 0..<8 {
            let col = SIMD8<Float>(
                temp[0][u], temp[1][u], temp[2][u], temp[3][u],
                temp[4][u], temp[5][u], temp[6][u], temp[7][u]
            )
            let colArray = simd8ToArray(col)
            for y in 0..<8 {
                result[y][u] = dotProduct8(idctBasis[y], colArray)
            }
        }

        return result
    }

    // MARK: - Colour Space Conversion

    /// Convert separate R, G, B float arrays to Y, Cb, Cr using BT.601
    /// coefficients, processing 4 pixels at a time with SIMD.
    ///
    /// - Parameters:
    ///   - r: Red channel values in [0, 1].
    ///   - g: Green channel values in [0, 1].
    ///   - b: Blue channel values in [0, 1].
    /// - Returns: Tuple of (Y, Cb, Cr) arrays.
    public static func rgbToYCbCr(
        r: [Float], g: [Float], b: [Float]
    ) -> (y: [Float], cb: [Float], cr: [Float]) {
        let count = r.count
        precondition(g.count == count && b.count == count)

        var yOut  = [Float](repeating: 0, count: count)
        var cbOut = [Float](repeating: 0, count: count)
        var crOut = [Float](repeating: 0, count: count)

        // BT.601 coefficients as SIMD constants
        let kr  = SIMD4<Float>(repeating:  0.299)
        let kg  = SIMD4<Float>(repeating:  0.587)
        let kb  = SIMD4<Float>(repeating:  0.114)

        let kcbr = SIMD4<Float>(repeating: -0.168736)
        let kcbg = SIMD4<Float>(repeating: -0.331264)
        let kcbb = SIMD4<Float>(repeating:  0.5)

        let kcrr = SIMD4<Float>(repeating:  0.5)
        let kcrg = SIMD4<Float>(repeating: -0.418688)
        let kcrb = SIMD4<Float>(repeating: -0.081312)

        let offset = SIMD4<Float>(repeating: 0.5)

        let simdCount = count / 4 * 4
        var i = 0

        while i < simdCount {
            let rv = SIMD4<Float>(r[i], r[i+1], r[i+2], r[i+3])
            let gv = SIMD4<Float>(g[i], g[i+1], g[i+2], g[i+3])
            let bv = SIMD4<Float>(b[i], b[i+1], b[i+2], b[i+3])

            // Y  = kr·R + kg·G + kb·B
            let yv = kr * rv + kg * gv + kb * bv
            // Cb = kcbr·R + kcbg·G + kcbb·B + 0.5
            let cbv = kcbr * rv + kcbg * gv + kcbb * bv + offset
            // Cr = kcrr·R + kcrg·G + kcrb·B + 0.5
            let crv = kcrr * rv + kcrg * gv + kcrb * bv + offset

            yOut[i]   = yv[0]; yOut[i+1]  = yv[1]; yOut[i+2]  = yv[2]; yOut[i+3]  = yv[3]
            cbOut[i]  = cbv[0]; cbOut[i+1] = cbv[1]; cbOut[i+2] = cbv[2]; cbOut[i+3] = cbv[3]
            crOut[i]  = crv[0]; crOut[i+1] = crv[1]; crOut[i+2] = crv[2]; crOut[i+3] = crv[3]

            i += 4
        }

        // Scalar tail for remaining pixels
        while i < count {
            let rv = r[i]; let gv = g[i]; let bv = b[i]
            yOut[i]  =  0.299    * rv + 0.587    * gv + 0.114    * bv
            cbOut[i] = -0.168736 * rv - 0.331264 * gv + 0.5      * bv + 0.5
            crOut[i] =  0.5      * rv - 0.418688 * gv - 0.081312 * bv + 0.5
            i += 1
        }

        return (yOut, cbOut, crOut)
    }

    /// Convert separate R, G, B float arrays to XYB colour space
    /// using SIMD-accelerated matrix multiply and cube-root transfer.
    ///
    /// - Parameters:
    ///   - r: Red channel values in [0, 1].
    ///   - g: Green channel values in [0, 1].
    ///   - b: Blue channel values in [0, 1].
    /// - Returns: Tuple of (X, Y, B) arrays.
    public static func rgbToXYB(
        r: [Float], g: [Float], b: [Float]
    ) -> (x: [Float], y: [Float], b: [Float]) {
        let count = r.count
        precondition(g.count == count && b.count == count)

        let m = VarDCTEncoder.opsinAbsorbanceMatrix

        // SIMD matrix row constants
        let m0 = SIMD4<Float>(repeating: m[0])
        let m1 = SIMD4<Float>(repeating: m[1])
        let m2 = SIMD4<Float>(repeating: m[2])
        let m3 = SIMD4<Float>(repeating: m[3])
        let m4 = SIMD4<Float>(repeating: m[4])
        let m5 = SIMD4<Float>(repeating: m[5])
        let m6 = SIMD4<Float>(repeating: m[6])
        let m7 = SIMD4<Float>(repeating: m[7])
        let m8 = SIMD4<Float>(repeating: m[8])

        var xOut = [Float](repeating: 0, count: count)
        var yOut = [Float](repeating: 0, count: count)
        var bOut = [Float](repeating: 0, count: count)

        let simdCount = count / 4 * 4
        var i = 0

        while i < simdCount {
            let rv = SIMD4<Float>(r[i], r[i+1], r[i+2], r[i+3])
            let gv = SIMD4<Float>(g[i], g[i+1], g[i+2], g[i+3])
            let bv = SIMD4<Float>(b[i], b[i+1], b[i+2], b[i+3])

            // LMS = matrix × RGB
            let lv = m0 * rv + m1 * gv + m2 * bv
            let mv = m3 * rv + m4 * gv + m5 * bv
            let sv = m6 * rv + m7 * gv + m8 * bv

            // Opsin transfer (element-wise cube root, must be scalar)
            for j in 0..<4 {
                let lp = VarDCTEncoder.opsinTransfer(lv[j])
                let mp = VarDCTEncoder.opsinTransfer(mv[j])
                let sp = VarDCTEncoder.opsinTransfer(sv[j])
                xOut[i+j] = (lp - mp) * 0.5
                yOut[i+j] = (lp + mp) * 0.5
                bOut[i+j] = sp
            }
            i += 4
        }

        // Scalar tail
        while i < count {
            let lv = m[0] * r[i] + m[1] * g[i] + m[2] * b[i]
            let mv = m[3] * r[i] + m[4] * g[i] + m[5] * b[i]
            let sv = m[6] * r[i] + m[7] * g[i] + m[8] * b[i]
            let lp = VarDCTEncoder.opsinTransfer(lv)
            let mp = VarDCTEncoder.opsinTransfer(mv)
            let sp = VarDCTEncoder.opsinTransfer(sv)
            xOut[i] = (lp - mp) * 0.5
            yOut[i] = (lp + mp) * 0.5
            bOut[i] = sp
            i += 1
        }

        return (xOut, yOut, bOut)
    }

    /// Convert XYB colour space back to linear RGB using SIMD.
    ///
    /// - Parameters:
    ///   - x: X channel values.
    ///   - y: Y channel values.
    ///   - b: B channel values.
    /// - Returns: Tuple of (R, G, B) linear channel arrays.
    public static func xybToRGB(
        x: [Float], y: [Float], b: [Float]
    ) -> (r: [Float], g: [Float], b: [Float]) {
        let count = x.count
        precondition(y.count == count && b.count == count)

        let im = VarDCTEncoder.inverseOpsinAbsorbanceMatrix

        var rOut = [Float](repeating: 0, count: count)
        var gOut = [Float](repeating: 0, count: count)
        var bOut = [Float](repeating: 0, count: count)

        let im0 = SIMD4<Float>(repeating: im[0])
        let im1 = SIMD4<Float>(repeating: im[1])
        let im2 = SIMD4<Float>(repeating: im[2])
        let im3 = SIMD4<Float>(repeating: im[3])
        let im4 = SIMD4<Float>(repeating: im[4])
        let im5 = SIMD4<Float>(repeating: im[5])
        let im6 = SIMD4<Float>(repeating: im[6])
        let im7 = SIMD4<Float>(repeating: im[7])
        let im8 = SIMD4<Float>(repeating: im[8])

        let simdCount = count / 4 * 4
        var i = 0

        while i < simdCount {
            // XYB → L'M'S'
            var lPrime = SIMD4<Float>.zero
            var mPrime = SIMD4<Float>.zero
            for j in 0..<4 {
                lPrime[j] = y[i+j] + x[i+j]
                mPrime[j] = y[i+j] - x[i+j]
            }

            // Inverse opsin transfer (scalar, then SIMD matrix)
            var lv = SIMD4<Float>.zero
            var mv = SIMD4<Float>.zero
            var sv = SIMD4<Float>.zero
            for j in 0..<4 {
                lv[j] = VarDCTEncoder.inverseOpsinTransfer(lPrime[j])
                mv[j] = VarDCTEncoder.inverseOpsinTransfer(mPrime[j])
                sv[j] = VarDCTEncoder.inverseOpsinTransfer(b[i+j])
            }

            // LMS → RGB via inverse matrix (SIMD multiply-add)
            let rv = im0 * lv + im1 * mv + im2 * sv
            let gv = im3 * lv + im4 * mv + im5 * sv
            let bv = im6 * lv + im7 * mv + im8 * sv

            for j in 0..<4 {
                rOut[i+j] = rv[j]
                gOut[i+j] = gv[j]
                bOut[i+j] = bv[j]
            }
            i += 4
        }

        // Scalar tail
        while i < count {
            let lp = y[i] + x[i]
            let mp = y[i] - x[i]
            let lv = VarDCTEncoder.inverseOpsinTransfer(lp)
            let mv = VarDCTEncoder.inverseOpsinTransfer(mp)
            let sv = VarDCTEncoder.inverseOpsinTransfer(b[i])
            rOut[i] = im[0] * lv + im[1] * mv + im[2] * sv
            gOut[i] = im[3] * lv + im[4] * mv + im[5] * sv
            bOut[i] = im[6] * lv + im[7] * mv + im[8] * sv
            i += 1
        }

        return (rOut, gOut, bOut)
    }

    // MARK: - Quantisation

    /// Quantise an 8×8 block using SIMD-accelerated division and rounding.
    ///
    /// Processes 4 coefficients at a time using `SIMD4<Float>`.
    ///
    /// - Parameters:
    ///   - block: 8×8 DCT coefficients.
    ///   - qMatrix: 8×8 quantisation step sizes.
    /// - Returns: 8×8 quantised coefficients as `Int16`.
    public static func quantize(block: [[Float]], qMatrix: [[Float]]) -> [[Int16]] {
        var result = [[Int16]](
            repeating: [Int16](repeating: 0, count: 8),
            count: 8
        )

        for y in 0..<8 {
            // Process 4 elements at a time (two SIMD passes per row)
            let bLo = SIMD4<Float>(block[y][0], block[y][1], block[y][2], block[y][3])
            let qLo = SIMD4<Float>(qMatrix[y][0], qMatrix[y][1], qMatrix[y][2], qMatrix[y][3])
            let rLo = bLo / qLo

            let bHi = SIMD4<Float>(block[y][4], block[y][5], block[y][6], block[y][7])
            let qHi = SIMD4<Float>(qMatrix[y][4], qMatrix[y][5], qMatrix[y][6], qMatrix[y][7])
            let rHi = bHi / qHi

            // Round and convert to Int16
            for j in 0..<4 {
                result[y][j]   = Int16(rLo[j].rounded(.toNearestOrAwayFromZero))
                result[y][j+4] = Int16(rHi[j].rounded(.toNearestOrAwayFromZero))
            }
        }

        return result
    }

    // MARK: - Zigzag Reordering

    /// Precomputed zigzag scan order for 8×8 blocks.
    ///
    /// Each element is `(row, col)`.
    static let zigzagOrder: [(Int, Int)] = [
        (0,0), (0,1), (1,0), (2,0), (1,1), (0,2), (0,3), (1,2),
        (2,1), (3,0), (4,0), (3,1), (2,2), (1,3), (0,4), (0,5),
        (1,4), (2,3), (3,2), (4,1), (5,0), (6,0), (5,1), (4,2),
        (3,3), (2,4), (1,5), (0,6), (0,7), (1,6), (2,5), (3,4),
        (4,3), (5,2), (6,1), (7,0), (7,1), (6,2), (5,3), (4,4),
        (3,5), (2,6), (1,7), (2,7), (3,6), (4,5), (5,4), (6,3),
        (7,2), (7,3), (6,4), (5,5), (4,6), (3,7), (4,7), (5,6),
        (6,5), (7,4), (7,5), (6,6), (5,7), (6,7), (7,6), (7,7)
    ]

    /// Precomputed flat index lookup for zigzag scanning.
    ///
    /// `zigzagFlatIndex[i]` gives the flat index `row * 8 + col` for
    /// position `i` in zigzag order, enabling a gather from a
    /// contiguous buffer.
    static let zigzagFlatIndex: [Int] = zigzagOrder.map { $0.0 * 8 + $0.1 }

    /// Zigzag-scan an 8×8 block of `Int16` coefficients into a flat array.
    ///
    /// Uses a precomputed flat-index table for efficient gather. On ARM64
    /// the compiler can auto-vectorise the gather loop.
    ///
    /// - Parameter block: 8×8 quantised coefficient block.
    /// - Returns: 64-element array in zigzag order.
    public static func zigzagScan(block: [[Int16]]) -> [Int16] {
        // Flatten block for indexed gather
        let flat = block.flatMap { $0 }
        return zigzagFlatIndex.map { flat[$0] }
    }

    // MARK: - MED Pixel Prediction

    /// Apply the Median Edge Detector (MED) predictor to an entire row
    /// using SIMD-accelerated 4-wide processing.
    ///
    /// For interior pixels (x > 0, y > 0) the MED predictor computes
    /// `clamp(N + W - NW)` using `SIMD4<Int32>` arithmetic. Boundary
    /// pixels fall back to the standard scalar rules.
    ///
    /// - Parameters:
    ///   - data: Original pixel values for the channel (row-major).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    /// - Returns: Array of signed residuals (actual − predicted).
    public static func predictMED(
        data: [UInt16], width: Int, height: Int
    ) -> [Int32] {
        var residuals = [Int32](repeating: 0, count: data.count)
        let maxVal = SIMD4<Int32>(repeating: 65535)
        let zero4 = SIMD4<Int32>.zero

        for y in 0..<height {
            let rowStart = y * width

            // First pixel of each row: boundary case
            if y == 0 {
                // First row: predict from West
                residuals[0] = Int32(data[0])
                for x in 1..<width {
                    let w = Int32(data[rowStart + x - 1])
                    residuals[rowStart + x] = Int32(data[rowStart + x]) - w
                }
            } else {
                // First column: predict from North
                let n = Int32(data[(y - 1) * width])
                residuals[rowStart] = Int32(data[rowStart]) - n

                // Interior pixels: SIMD 4-wide MED
                var x = 1
                let simdEnd = 1 + ((width - 1) / 4) * 4

                // Only use SIMD when we have full groups of 4
                let safeSimdEnd = min(simdEnd, width - 3)

                while x < safeSimdEnd {
                    // Load N, W, NW neighbours
                    let nv = SIMD4<Int32>(
                        Int32(data[(y-1) * width + x]),
                        Int32(data[(y-1) * width + x+1]),
                        Int32(data[(y-1) * width + x+2]),
                        Int32(data[(y-1) * width + x+3])
                    )
                    let wv = SIMD4<Int32>(
                        Int32(data[rowStart + x-1]),
                        Int32(data[rowStart + x]),
                        Int32(data[rowStart + x+1]),
                        Int32(data[rowStart + x+2])
                    )
                    let nwv = SIMD4<Int32>(
                        Int32(data[(y-1) * width + x-1]),
                        Int32(data[(y-1) * width + x]),
                        Int32(data[(y-1) * width + x+1]),
                        Int32(data[(y-1) * width + x+2])
                    )

                    // MED: clamp(N + W - NW, 0, 65535)
                    // Wrapping operators (&+, &-) are used because Swift SIMD
                    // types require them for integer arithmetic. Overflow is not
                    // possible here since all source values fit in UInt16 and the
                    // intermediate sum N + W - NW fits comfortably in Int32.
                    let gradient = nv &+ wv &- nwv
                    let clamped = pointwiseMin(pointwiseMax(gradient, zero4), maxVal)

                    // Actual pixel values
                    let actual = SIMD4<Int32>(
                        Int32(data[rowStart + x]),
                        Int32(data[rowStart + x+1]),
                        Int32(data[rowStart + x+2]),
                        Int32(data[rowStart + x+3])
                    )

                    let res = actual &- clamped
                    residuals[rowStart + x]   = res[0]
                    residuals[rowStart + x+1] = res[1]
                    residuals[rowStart + x+2] = res[2]
                    residuals[rowStart + x+3] = res[3]

                    x += 4
                }

                // Scalar tail for remaining pixels
                while x < width {
                    let n = Int32(data[(y-1) * width + x])
                    let w = Int32(data[rowStart + x - 1])
                    let nw = Int32(data[(y-1) * width + x - 1])
                    let gradient = n + w - nw
                    let predicted = max(0, min(65535, gradient))
                    residuals[rowStart + x] = Int32(data[rowStart + x]) - predicted
                    x += 1
                }
            }
        }

        return residuals
    }

    // MARK: - Reversible Colour Transform (RCT)

    /// Apply forward RCT (YCoCg-R) to three channels using SIMD-accelerated
    /// 4-wide processing.
    ///
    /// - Parameters:
    ///   - rChannel: Red channel values.
    ///   - gChannel: Green channel values.
    ///   - bChannel: Blue channel values.
    /// - Returns: Tuple of (Y, Co, Cg) channel arrays, where Co and Cg
    ///   are signed values (not yet offset by 32768).
    public static func forwardRCT(
        r rChannel: [UInt16], g gChannel: [UInt16], b bChannel: [UInt16]
    ) -> (y: [Int32], co: [Int32], cg: [Int32]) {
        let count = rChannel.count
        precondition(gChannel.count == count && bChannel.count == count)

        var yOut  = [Int32](repeating: 0, count: count)
        var coOut = [Int32](repeating: 0, count: count)
        var cgOut = [Int32](repeating: 0, count: count)

        let simdCount = count / 4 * 4
        var i = 0

        while i < simdCount {
            let rv = SIMD4<Int32>(
                Int32(rChannel[i]), Int32(rChannel[i+1]),
                Int32(rChannel[i+2]), Int32(rChannel[i+3])
            )
            let gv = SIMD4<Int32>(
                Int32(gChannel[i]), Int32(gChannel[i+1]),
                Int32(gChannel[i+2]), Int32(gChannel[i+3])
            )
            let bv = SIMD4<Int32>(
                Int32(bChannel[i]), Int32(bChannel[i+1]),
                Int32(bChannel[i+2]), Int32(bChannel[i+3])
            )

            // co = r - b
            let co = rv &- bv
            // t = b + (co >> 1)
            let t = bv &+ simdArithmeticShiftRight(co)
            // cg = g - t
            let cg = gv &- t
            // y = t + (cg >> 1)
            let y = t &+ simdArithmeticShiftRight(cg)

            for j in 0..<4 {
                yOut[i+j]  = y[j]
                coOut[i+j] = co[j]
                cgOut[i+j] = cg[j]
            }
            i += 4
        }

        // Scalar tail
        while i < count {
            let rv = Int32(rChannel[i])
            let gv = Int32(gChannel[i])
            let bv = Int32(bChannel[i])
            let co = rv - bv
            let t  = bv + (co >> 1)
            let cg = gv - t
            let y  = t + (cg >> 1)
            yOut[i]  = y
            coOut[i] = co
            cgOut[i] = cg
            i += 1
        }

        return (yOut, coOut, cgOut)
    }

    /// Apply inverse RCT (YCoCg-R) to three channels using SIMD.
    ///
    /// - Parameters:
    ///   - yChannel: Y channel values.
    ///   - coChannel: Co channel values (signed).
    ///   - cgChannel: Cg channel values (signed).
    /// - Returns: Tuple of (R, G, B) channel arrays.
    public static func inverseRCT(
        y yChannel: [Int32], co coChannel: [Int32], cg cgChannel: [Int32]
    ) -> (r: [Int32], g: [Int32], b: [Int32]) {
        let count = yChannel.count
        precondition(coChannel.count == count && cgChannel.count == count)

        var rOut = [Int32](repeating: 0, count: count)
        var gOut = [Int32](repeating: 0, count: count)
        var bOut = [Int32](repeating: 0, count: count)

        let simdCount = count / 4 * 4
        var i = 0

        while i < simdCount {
            let yv = SIMD4<Int32>(
                yChannel[i], yChannel[i+1], yChannel[i+2], yChannel[i+3]
            )
            let cov = SIMD4<Int32>(
                coChannel[i], coChannel[i+1], coChannel[i+2], coChannel[i+3]
            )
            let cgv = SIMD4<Int32>(
                cgChannel[i], cgChannel[i+1], cgChannel[i+2], cgChannel[i+3]
            )

            // t = y - (cg >> 1)
            let t = yv &- simdArithmeticShiftRight(cgv)
            // g = cg + t
            let g = cgv &+ t
            // b = t - (co >> 1)
            let b = t &- simdArithmeticShiftRight(cov)
            // r = co + b
            let r = cov &+ b

            for j in 0..<4 {
                rOut[i+j] = r[j]
                gOut[i+j] = g[j]
                bOut[i+j] = b[j]
            }
            i += 4
        }

        // Scalar tail
        while i < count {
            let t = yChannel[i] - (cgChannel[i] >> 1)
            let g = cgChannel[i] + t
            let b = t - (coChannel[i] >> 1)
            let r = coChannel[i] + b
            rOut[i] = r
            gOut[i] = g
            bOut[i] = b
            i += 1
        }

        return (rOut, gOut, bOut)
    }

    // MARK: - Squeeze Transform

    /// Forward horizontal squeeze on a sub-region using SIMD-accelerated
    /// pair processing.
    ///
    /// Processes 4 even/odd pairs at a time (8 elements) using
    /// `SIMD4<Int32>` for the average and difference computations.
    ///
    /// - Parameters:
    ///   - data: Buffer to squeeze in-place.
    ///   - regionW: Active region width.
    ///   - regionH: Active region height.
    ///   - stride: Row stride of the underlying buffer.
    public static func squeezeHorizontal(
        data: inout [Int32], regionW: Int, regionH: Int, stride bufStride: Int
    ) {
        let lowW = (regionW + 1) / 2
        var row = [Int32](repeating: 0, count: regionW)

        for y in 0..<regionH {
            let rowBase = y * bufStride

            var x = 0
            let pairCount = (regionW - 1) / 2  // number of complete pairs
            let simdPairs = pairCount / 4 * 4

            // SIMD 4-pair processing
            var p = 0
            while p < simdPairs {
                let baseIdx = p * 2
                let even = SIMD4<Int32>(
                    data[rowBase + baseIdx],
                    data[rowBase + baseIdx + 2],
                    data[rowBase + baseIdx + 4],
                    data[rowBase + baseIdx + 6]
                )
                let odd = SIMD4<Int32>(
                    data[rowBase + baseIdx + 1],
                    data[rowBase + baseIdx + 3],
                    data[rowBase + baseIdx + 5],
                    data[rowBase + baseIdx + 7]
                )

                let sum = even &+ odd
                // Floor division towards -∞
                var avg = SIMD4<Int32>.zero
                for j in 0..<4 {
                    if sum[j] >= 0 {
                        avg[j] = sum[j] / 2
                    } else {
                        avg[j] = (sum[j] - 1) / 2
                    }
                }
                let diff = even &- odd

                for j in 0..<4 {
                    row[p + j]        = avg[j]
                    row[lowW + p + j] = diff[j]
                }
                p += 4
            }

            // Scalar remaining pairs
            x = p * 2
            while x < regionW - 1 {
                let even = data[rowBase + x]
                let odd  = data[rowBase + x + 1]
                let sum = even + odd
                let avg: Int32
                if sum >= 0 {
                    avg = sum / 2
                } else {
                    avg = (sum - 1) / 2
                }
                let diff = even - odd
                row[x / 2]        = avg
                row[lowW + x / 2] = diff
                x += 2
            }

            // Trailing odd column
            if regionW % 2 == 1 {
                row[lowW - 1] = data[rowBase + regionW - 1]
            }

            // Write back
            for x2 in 0..<regionW {
                data[rowBase + x2] = row[x2]
            }
        }
    }

    /// Forward vertical squeeze on a sub-region using SIMD-accelerated
    /// processing of 4 columns simultaneously.
    ///
    /// - Parameters:
    ///   - data: Buffer to squeeze in-place.
    ///   - regionW: Active region width.
    ///   - regionH: Active region height.
    ///   - stride: Row stride of the underlying buffer.
    public static func squeezeVertical(
        data: inout [Int32], regionW: Int, regionH: Int, stride bufStride: Int
    ) {
        let lowH = (regionH + 1) / 2

        // Process 4 columns at a time using temporary column storage
        let simdCols = regionW / 4 * 4
        var x = 0

        // Temporary buffers for 4 columns at a time
        var cols = [[Int32]](
            repeating: [Int32](repeating: 0, count: regionH),
            count: 4
        )

        while x < simdCols {
            // Read 4 columns into temporary storage
            for j in 0..<4 {
                for y in 0..<regionH {
                    cols[j][y] = data[y * bufStride + x + j]
                }
            }

            // Process pairs with SIMD
            for y in Swift.stride(from: 0, to: regionH - 1, by: 2) {
                let even = SIMD4<Int32>(cols[0][y], cols[1][y], cols[2][y], cols[3][y])
                let odd = SIMD4<Int32>(cols[0][y+1], cols[1][y+1], cols[2][y+1], cols[3][y+1])

                let sum = even &+ odd
                var avg = SIMD4<Int32>.zero
                for j in 0..<4 {
                    if sum[j] >= 0 {
                        avg[j] = sum[j] / 2
                    } else {
                        avg[j] = (sum[j] - 1) / 2
                    }
                }
                let diff = even &- odd

                let avgRow = (y / 2) * bufStride
                let diffRow = (lowH + y / 2) * bufStride

                for j in 0..<4 {
                    data[avgRow + x + j]  = avg[j]
                    data[diffRow + x + j] = diff[j]
                }
            }

            // Trailing odd row
            if regionH % 2 == 1 {
                let dstRow = (lowH - 1) * bufStride
                for j in 0..<4 {
                    data[dstRow + x + j] = cols[j][regionH - 1]
                }
            }
            x += 4
        }

        // Scalar remaining columns
        while x < regionW {
            var col = [Int32](repeating: 0, count: regionH)
            for y in 0..<regionH {
                col[y] = data[y * bufStride + x]
            }

            var out = [Int32](repeating: 0, count: regionH)
            for y in Swift.stride(from: 0, to: regionH - 1, by: 2) {
                let even = col[y]
                let odd  = col[y + 1]
                let sum = even + odd
                let avg: Int32
                if sum >= 0 {
                    avg = sum / 2
                } else {
                    avg = (sum - 1) / 2
                }
                out[y / 2]        = avg
                out[lowH + y / 2] = even - odd
            }
            if regionH % 2 == 1 {
                out[lowH - 1] = col[regionH - 1]
            }

            for y in 0..<regionH {
                data[y * bufStride + x] = out[y]
            }
            x += 1
        }
    }

    // MARK: - Block Activity

    /// Compute block activity (variance) using SIMD-accelerated sum
    /// and sum-of-squares computation.
    ///
    /// - Parameter block: 8×8 spatial-domain pixel values.
    /// - Returns: Variance of the pixel values (≥ 0).
    public static func blockActivity(_ block: [[Float]]) -> Float {
        var sumVec = SIMD4<Float>.zero
        var sumSqVec = SIMD4<Float>.zero

        for y in 0..<8 {
            let lo = SIMD4<Float>(block[y][0], block[y][1], block[y][2], block[y][3])
            let hi = SIMD4<Float>(block[y][4], block[y][5], block[y][6], block[y][7])
            sumVec = sumVec + lo + hi
            sumSqVec = sumSqVec + lo * lo + hi * hi
        }

        let sum = sumVec[0] + sumVec[1] + sumVec[2] + sumVec[3]
        let sumSq = sumSqVec[0] + sumSqVec[1] + sumSqVec[2] + sumSqVec[3]

        let n: Float = 64
        let mean = sum / n
        let variance = sumSq / n - mean * mean
        return max(0, variance)
    }

    // MARK: - Private Helpers

    /// SIMD-accelerated dot product for 8-element float arrays.
    ///
    /// Uses two `SIMD4<Float>` multiply-add operations.
    @inline(__always)
    private static func dotProduct8(_ a: [Float], _ b: [Float]) -> Float {
        let aLo = SIMD4<Float>(a[0], a[1], a[2], a[3])
        let bLo = SIMD4<Float>(b[0], b[1], b[2], b[3])
        let aHi = SIMD4<Float>(a[4], a[5], a[6], a[7])
        let bHi = SIMD4<Float>(b[4], b[5], b[6], b[7])

        let prod = aLo * bLo + aHi * bHi
        return prod[0] + prod[1] + prod[2] + prod[3]
    }

    /// Convert a `SIMD8<Float>` to an 8-element array.
    @inline(__always)
    private static func simd8ToArray(_ v: SIMD8<Float>) -> [Float] {
        [v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]]
    }

    /// Arithmetic right shift by 1 for `SIMD4<Int32>`.
    ///
    /// Swift's `>>` on `SIMD4<Int32>` is an arithmetic shift, preserving
    /// the sign bit, which matches the C `>> 1` behaviour used in the
    /// YCoCg-R lifting steps.
    @inline(__always)
    private static func simdArithmeticShiftRight(_ v: SIMD4<Int32>) -> SIMD4<Int32> {
        v &>> SIMD4<Int32>(repeating: 1)
    }

    /// Element-wise minimum of two `SIMD4<Int32>` vectors.
    @inline(__always)
    private static func pointwiseMin(
        _ a: SIMD4<Int32>, _ b: SIMD4<Int32>
    ) -> SIMD4<Int32> {
        a.replacing(with: b, where: a .> b)
    }

    /// Element-wise maximum of two `SIMD4<Int32>` vectors.
    @inline(__always)
    private static func pointwiseMax(
        _ a: SIMD4<Int32>, _ b: SIMD4<Int32>
    ) -> SIMD4<Int32> {
        a.replacing(with: b, where: a .< b)
    }
}
