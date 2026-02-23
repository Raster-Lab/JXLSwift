import XCTest
@testable import JXLSwift

/// Tests for SSEOps (Intel x86-64 SSE2 SIMD) and AVXOps (AVX2 256-bit) operations.
///
/// These tests verify that:
/// - SSEOps produces results matching scalar reference implementations.
/// - AVXOps produces results matching SSEOps (wider vector, same result).
/// - Fallback paths work correctly on all architectures.
/// - Edge cases (empty input, odd widths, single pixels) are handled.
final class SSEOpsTests: XCTestCase {

    // MARK: - Helpers

    /// Create a VarDCTEncoder for scalar reference comparisons.
    private func makeEncoder(distance: Float = 1.0) -> VarDCTEncoder {
        VarDCTEncoder(
            hardware: HardwareCapabilities.detect(),
            options: EncodingOptions(
                mode: .lossy(quality: 90),
                effort: .squirrel,
                useHardwareAcceleration: false,
                useAccelerate: false
            ),
            distance: distance
        )
    }

    /// Create a ModularEncoder for scalar reference comparisons.
    private func makeModularEncoder() -> ModularEncoder {
        ModularEncoder(
            hardware: HardwareCapabilities.detect(),
            options: EncodingOptions(
                mode: .lossless,
                effort: .squirrel,
                useHardwareAcceleration: false,
                useAccelerate: false
            )
        )
    }

    /// 8×8 block filled with a constant value.
    private func constantBlock(_ value: Float) -> [[Float]] {
        [[Float]](repeating: [Float](repeating: value, count: 8), count: 8)
    }

    /// 8×8 gradient block with values increasing from top-left.
    private func gradientBlock() -> [[Float]] {
        var block = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        for y in 0..<8 {
            for x in 0..<8 { block[y][x] = Float(y * 8 + x) / 63.0 }
        }
        return block
    }

    // MARK: - SSE DCT Tests

    func testSSE_DCT2D_ConstantBlock_MatchesScalar() {
        let encoder = makeEncoder()
        let block = constantBlock(0.5)
        let sseResult    = SSEOps.dct2D(block)
        let scalarResult = encoder.applyDCTScalar(block: block)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(sseResult[y][x], scalarResult[y][x],
                               accuracy: 1e-4, "DCT mismatch at [\(y)][\(x)]")
            }
        }
    }

    func testSSE_DCT2D_GradientBlock_MatchesScalar() {
        let encoder = makeEncoder()
        let block = gradientBlock()
        let sseResult    = SSEOps.dct2D(block)
        let scalarResult = encoder.applyDCTScalar(block: block)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(sseResult[y][x], scalarResult[y][x],
                               accuracy: 1e-4, "DCT mismatch at [\(y)][\(x)]")
            }
        }
    }

    func testSSE_DCT2D_ZeroBlock_ProducesAllZeros() {
        let result = SSEOps.dct2D(constantBlock(0))
        for y in 0..<8 {
            for x in 0..<8 { XCTAssertEqual(result[y][x], 0, accuracy: 1e-6) }
        }
    }

    func testSSE_IDCT2D_RoundTrip_ReconstructsWithinTolerance() {
        let block         = gradientBlock()
        let dct           = SSEOps.dct2D(block)
        let reconstructed = SSEOps.idct2D(dct)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(reconstructed[y][x], block[y][x],
                               accuracy: 1e-4, "IDCT round-trip mismatch at [\(y)][\(x)]")
            }
        }
    }

    func testSSE_IDCT2D_MatchesScalar() {
        let encoder = makeEncoder()
        let block   = gradientBlock()
        let dct     = encoder.applyDCTScalar(block: block)

        let sseIDCT    = SSEOps.idct2D(dct)
        let scalarIDCT = encoder.applyIDCTScalar(block: dct)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(sseIDCT[y][x], scalarIDCT[y][x],
                               accuracy: 1e-4, "IDCT mismatch at [\(y)][\(x)]")
            }
        }
    }

    // MARK: - SSE Colour Space Conversion Tests

    func testSSE_RGBToYCbCr_Black_ProducesExpectedValues() {
        let (y, cb, cr) = SSEOps.rgbToYCbCr(r: [0, 0, 0, 0], g: [0, 0, 0, 0], b: [0, 0, 0, 0])
        for i in 0..<4 {
            XCTAssertEqual(y[i],  0,   accuracy: 1e-6)
            XCTAssertEqual(cb[i], 0.5, accuracy: 1e-6)
            XCTAssertEqual(cr[i], 0.5, accuracy: 1e-6)
        }
    }

    func testSSE_RGBToYCbCr_White_ProducesExpectedValues() {
        let (y, cb, cr) = SSEOps.rgbToYCbCr(r: [1, 1, 1, 1], g: [1, 1, 1, 1], b: [1, 1, 1, 1])
        for i in 0..<4 {
            XCTAssertEqual(y[i],  1.0, accuracy: 1e-4)
            XCTAssertEqual(cb[i], 0.5, accuracy: 1e-4)
            XCTAssertEqual(cr[i], 0.5, accuracy: 1e-4)
        }
    }

    func testSSE_RGBToYCbCr_MatchesBT601Scalar() {
        let r: [Float] = [0.25, 0.5, 0.75, 1.0, 0.1, 0.3, 0.7, 0.9]
        let g: [Float] = [0.3,  0.6, 0.2,  0.8, 0.4, 0.5, 0.1, 0.6]
        let b: [Float] = [0.1,  0.4, 0.9,  0.3, 0.7, 0.2, 0.8, 0.5]

        let (yN, cbN, crN) = SSEOps.rgbToYCbCr(r: r, g: g, b: b)

        for i in 0..<r.count {
            let yS  =  0.299    * r[i] + 0.587    * g[i] + 0.114    * b[i]
            let cbS = -0.168736 * r[i] - 0.331264 * g[i] + 0.5      * b[i] + 0.5
            let crS =  0.5      * r[i] - 0.418688 * g[i] - 0.081312 * b[i] + 0.5
            XCTAssertEqual(yN[i],  yS,  accuracy: 1e-5, "Y[\(i)] mismatch")
            XCTAssertEqual(cbN[i], cbS, accuracy: 1e-5, "Cb[\(i)] mismatch")
            XCTAssertEqual(crN[i], crS, accuracy: 1e-5, "Cr[\(i)] mismatch")
        }
    }

    func testSSE_RGBToYCbCr_NonMultipleOf4_HandlesScalarTail() {
        let r: [Float] = [0.2, 0.4, 0.6, 0.8, 1.0]
        let g: [Float] = [0.1, 0.3, 0.5, 0.7, 0.9]
        let b: [Float] = [0.0, 0.2, 0.4, 0.6, 0.8]
        let (y, cb, cr) = SSEOps.rgbToYCbCr(r: r, g: g, b: b)
        for i in 0..<5 {
            XCTAssertTrue(y[i]  >= 0 && y[i]  <= 1, "Y[\(i)] out of range")
            XCTAssertTrue(cb[i] >= 0 && cb[i] <= 1, "Cb[\(i)] out of range")
            XCTAssertTrue(cr[i] >= 0 && cr[i] <= 1, "Cr[\(i)] out of range")
        }
    }

    func testSSE_RGBToYCbCr_EmptyInput_ReturnsEmpty() {
        let (y, cb, cr) = SSEOps.rgbToYCbCr(r: [], g: [], b: [])
        XCTAssertTrue(y.isEmpty)
        XCTAssertTrue(cb.isEmpty)
        XCTAssertTrue(cr.isEmpty)
    }

    func testSSE_RGBToXYB_MatchesNEONOps() {
        let r: [Float] = [0.5, 0.3, 0.8, 0.1]
        let g: [Float] = [0.4, 0.6, 0.2, 0.9]
        let b: [Float] = [0.3, 0.1, 0.7, 0.5]

        let (xSSE, ySSE, bSSE) = SSEOps.rgbToXYB(r: r, g: g, b: b)
        let (xNEON, yNEON, bNEON) = NEONOps.rgbToXYB(r: r, g: g, b: b)

        for i in 0..<4 {
            XCTAssertEqual(xSSE[i], xNEON[i], accuracy: 1e-5, "X[\(i)] mismatch vs NEON")
            XCTAssertEqual(ySSE[i], yNEON[i], accuracy: 1e-5, "Y[\(i)] mismatch vs NEON")
            XCTAssertEqual(bSSE[i], bNEON[i], accuracy: 1e-5, "B[\(i)] mismatch vs NEON")
        }
    }

    func testSSE_XYBRoundTrip_MatchesWithinTolerance() {
        let r: [Float] = [0.5, 0.3, 0.8, 0.1]
        let g: [Float] = [0.4, 0.6, 0.2, 0.9]
        let b: [Float] = [0.3, 0.1, 0.7, 0.5]

        let (x, y, bXYB)     = SSEOps.rgbToXYB(r: r, g: g, b: b)
        let (rOut, gOut, bOut) = SSEOps.xybToRGB(x: x, y: y, b: bXYB)

        for i in 0..<4 {
            XCTAssertEqual(rOut[i], r[i], accuracy: 1e-3, "Round-trip R[\(i)]")
            XCTAssertEqual(gOut[i], g[i], accuracy: 1e-3, "Round-trip G[\(i)]")
            XCTAssertEqual(bOut[i], b[i], accuracy: 1e-3, "Round-trip B[\(i)]")
        }
    }

    // MARK: - SSE Quantisation Tests

    func testSSE_Quantize_MatchesScalar() {
        let encoder  = makeEncoder(distance: 1.0)
        let block    = gradientBlock()
        let qMatrix  = encoder.generateQuantizationMatrix(channel: 0)
        let sseResult    = SSEOps.quantize(block: block, qMatrix: qMatrix)
        let scalarResult = encoder.quantize(block: block, channel: 0)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(sseResult[y][x], scalarResult[y][x],
                               "Quantize mismatch at [\(y)][\(x)]")
            }
        }
    }

    func testSSE_Quantize_ZeroBlock_ProducesAllZeros() {
        let qMatrix = [[Float]](repeating: [Float](repeating: 1.0, count: 8), count: 8)
        let result  = SSEOps.quantize(block: constantBlock(0), qMatrix: qMatrix)
        for y in 0..<8 {
            for x in 0..<8 { XCTAssertEqual(result[y][x], 0) }
        }
    }

    func testSSE_Quantize_UnityMatrix_MatchesRounding() {
        var block = constantBlock(0)
        block[0][0] = 3.7
        block[0][1] = -2.3
        block[3][5] = 0.5
        let qMatrix = [[Float]](repeating: [Float](repeating: 1.0, count: 8), count: 8)
        let result  = SSEOps.quantize(block: block, qMatrix: qMatrix)
        XCTAssertEqual(result[0][0],  4)
        XCTAssertEqual(result[0][1], -2)
        XCTAssertEqual(result[3][5],  1)
    }

    // MARK: - SSE Zigzag Scan Tests

    func testSSE_ZigzagScan_CoversAll64Coefficients() {
        var block = [[Int16]](repeating: [Int16](repeating: 0, count: 8), count: 8)
        for y in 0..<8 { for x in 0..<8 { block[y][x] = Int16(y * 8 + x) } }
        let scanned = SSEOps.zigzagScan(block: block)
        XCTAssertEqual(scanned.count, 64)
        XCTAssertEqual(scanned.sorted(), (0..<64).map { Int16($0) })
    }

    func testSSE_ZigzagScan_FirstElementIsDC() {
        var block = [[Int16]](repeating: [Int16](repeating: 0, count: 8), count: 8)
        block[0][0] = 42
        XCTAssertEqual(SSEOps.zigzagScan(block: block)[0], 42)
    }

    func testSSE_ZigzagScan_LastElementIsBottomRight() {
        var block = [[Int16]](repeating: [Int16](repeating: 0, count: 8), count: 8)
        block[7][7] = 99
        XCTAssertEqual(SSEOps.zigzagScan(block: block)[63], 99)
    }

    func testSSE_ZigzagScan_MatchesNEONOps() {
        var block = [[Int16]](repeating: [Int16](repeating: 0, count: 8), count: 8)
        for y in 0..<8 { for x in 0..<8 { block[y][x] = Int16(y * 8 + x) } }
        XCTAssertEqual(SSEOps.zigzagScan(block: block), NEONOps.zigzagScan(block: block))
    }

    // MARK: - SSE MED Prediction Tests

    func testSSE_PredictMED_SinglePixel_NoModification() {
        let result = SSEOps.predictMED(data: [42], width: 1, height: 1)
        XCTAssertEqual(result[0], 42)
    }

    func testSSE_PredictMED_FirstRow_PredictFromWest() {
        let result = SSEOps.predictMED(data: [10, 20, 30, 40], width: 4, height: 1)
        XCTAssertEqual(result[0], 10)
        XCTAssertEqual(result[1], 10)
        XCTAssertEqual(result[2], 10)
        XCTAssertEqual(result[3], 10)
    }

    func testSSE_PredictMED_ConstantImage_AllResidualZero() {
        let data     = [UInt16](repeating: 100, count: 16)
        let residuals = SSEOps.predictMED(data: data, width: 4, height: 4)
        XCTAssertEqual(residuals[0], 100)
        for i in 1..<16 { XCTAssertEqual(residuals[i], 0, "Residual[\(i)] should be 0") }
    }

    func testSSE_PredictMED_MatchesScalar() {
        var data = [UInt16](repeating: 0, count: 16)
        for y in 0..<4 { for x in 0..<4 { data[y * 4 + x] = UInt16(y * 100 + x * 50) } }
        let sseResult    = SSEOps.predictMED(data: data, width: 4, height: 4)
        let modEncoder   = makeModularEncoder()
        for y in 0..<4 {
            for x in 0..<4 {
                let idx      = y * 4 + x
                let actual   = Int32(data[idx])
                let predicted = modEncoder.predictPixel(data: data, x: x, y: y, width: 4, height: 4)
                XCTAssertEqual(sseResult[idx], actual - predicted,
                               "MED mismatch at (\(x), \(y))")
            }
        }
    }

    func testSSE_PredictMED_EmptyInput_ReturnsEmpty() {
        XCTAssertTrue(SSEOps.predictMED(data: [], width: 0, height: 0).isEmpty)
    }

    func testSSE_PredictMED_OddWidth_HandlesScalarTail() {
        // 9 columns: interior SIMD groups + scalar tail
        var data = [UInt16](repeating: 0, count: 27)
        for i in 0..<27 { data[i] = UInt16(i * 100 % 65536) }
        let sseResult  = SSEOps.predictMED(data: data, width: 9, height: 3)
        let modEncoder = makeModularEncoder()
        for y in 0..<3 {
            for x in 0..<9 {
                let idx       = y * 9 + x
                let actual    = Int32(data[idx])
                let predicted = modEncoder.predictPixel(data: data, x: x, y: y, width: 9, height: 3)
                XCTAssertEqual(sseResult[idx], actual - predicted,
                               "MED mismatch at (\(x), \(y))")
            }
        }
    }

    // MARK: - SSE RCT Tests

    func testSSE_ForwardRCT_MatchesScalar() {
        let modEncoder = makeModularEncoder()
        let r: [UInt16] = [100, 200, 300, 400, 500]
        let g: [UInt16] = [150, 250, 350, 450, 550]
        let b: [UInt16] = [50,  100, 150, 200, 250]
        let (yN, coN, cgN) = SSEOps.forwardRCT(r: r, g: g, b: b)
        for i in 0..<r.count {
            let (yS, coS, cgS) = modEncoder.forwardRCT(r: Int32(r[i]), g: Int32(g[i]), b: Int32(b[i]))
            XCTAssertEqual(yN[i],  yS,  "Y[\(i)] mismatch")
            XCTAssertEqual(coN[i], coS, "Co[\(i)] mismatch")
            XCTAssertEqual(cgN[i], cgS, "Cg[\(i)] mismatch")
        }
    }

    func testSSE_RCTRoundTrip_PerfectReconstruction() {
        let r: [UInt16] = [100, 200, 300, 400, 500, 600, 700, 800]
        let g: [UInt16] = [150, 250, 350, 450, 550, 650, 750, 850]
        let b: [UInt16] = [50,  100, 150, 200, 250, 300, 350, 400]
        let (y, co, cg)      = SSEOps.forwardRCT(r: r, g: g, b: b)
        let (rOut, gOut, bOut) = SSEOps.inverseRCT(y: y, co: co, cg: cg)
        for i in 0..<r.count {
            XCTAssertEqual(rOut[i], Int32(r[i]), "Round-trip R[\(i)]")
            XCTAssertEqual(gOut[i], Int32(g[i]), "Round-trip G[\(i)]")
            XCTAssertEqual(bOut[i], Int32(b[i]), "Round-trip B[\(i)]")
        }
    }

    func testSSE_ForwardRCT_ZeroInput_ReturnsZero() {
        let (y, co, cg) = SSEOps.forwardRCT(
            r: [0, 0, 0, 0], g: [0, 0, 0, 0], b: [0, 0, 0, 0]
        )
        for i in 0..<4 {
            XCTAssertEqual(y[i],  0)
            XCTAssertEqual(co[i], 0)
            XCTAssertEqual(cg[i], 0)
        }
    }

    // MARK: - SSE Squeeze Transform Tests

    func testSSE_SqueezeHorizontal_MatchesScalar() {
        let modEncoder = makeModularEncoder()
        var sseData: [Int32]    = [10, 20, 30, 40, 50, 60, 70, 80,
                                    5, 15, 25, 35, 45, 55, 65, 75]
        var scalarData = sseData
        SSEOps.squeezeHorizontal(data: &sseData,    regionW: 8, regionH: 2, stride: 8)
        modEncoder.squeezeHorizontal(data: &scalarData, regionW: 8, regionH: 2, stride: 8)
        XCTAssertEqual(sseData, scalarData, "Horizontal squeeze mismatch")
    }

    func testSSE_SqueezeVertical_MatchesScalar() {
        let modEncoder = makeModularEncoder()
        var sseData: [Int32] = [10, 20, 30, 40,
                                 50, 60, 70, 80,
                                 15, 25, 35, 45,
                                 55, 65, 75, 85,
                                 12, 22, 32, 42,
                                 52, 62, 72, 82]
        var scalarData = sseData
        SSEOps.squeezeVertical(data: &sseData,    regionW: 4, regionH: 6, stride: 4)
        modEncoder.squeezeVertical(data: &scalarData, regionW: 4, regionH: 6, stride: 4)
        XCTAssertEqual(sseData, scalarData, "Vertical squeeze mismatch")
    }

    func testSSE_SqueezeHorizontal_OddWidth_MatchesScalar() {
        let modEncoder = makeModularEncoder()
        var sseData: [Int32]    = [10, 20, 30, 40, 50, 60, 70,
                                    5, 15, 25, 35, 45, 55, 65]
        var scalarData = sseData
        SSEOps.squeezeHorizontal(data: &sseData,    regionW: 7, regionH: 2, stride: 7)
        modEncoder.squeezeHorizontal(data: &scalarData, regionW: 7, regionH: 2, stride: 7)
        XCTAssertEqual(sseData, scalarData, "Horizontal squeeze odd-width mismatch")
    }

    // MARK: - SSE Block Activity Tests

    func testSSE_BlockActivity_ConstantBlock_ReturnsZero() {
        XCTAssertEqual(SSEOps.blockActivity(constantBlock(0.5)), 0, accuracy: 1e-6)
    }

    func testSSE_BlockActivity_MatchesScalar() {
        let encoder  = makeEncoder()
        let block    = gradientBlock()
        let sseVal   = SSEOps.blockActivity(block)
        let scalarVal = encoder.computeBlockActivity(block: block)
        XCTAssertEqual(sseVal, scalarVal, accuracy: 1e-4, "Block activity mismatch")
    }

    func testSSE_BlockActivity_NonNegative() {
        var block = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        for y in 0..<8 { for x in 0..<8 { block[y][x] = Float((y * 13 + x * 7) % 100) / 100.0 } }
        XCTAssertGreaterThanOrEqual(SSEOps.blockActivity(block), 0)
    }

    // MARK: - AVX2 Availability Tests

    func testAVX_IsAvailableOnlyOnX86_64() {
        #if arch(x86_64)
        // On x86_64 the result depends on CPU; just verify it compiles and is Bool
        let avx2 = AVXOps.isAVX2Available
        XCTAssertNotNil(avx2)
        #else
        XCTAssertFalse(AVXOps.isAVX2Available, "AVX2 must be unavailable on non-x86_64")
        #endif
    }

    // MARK: - AVX DCT Tests

    func testAVX_DCT2D_MatchesSSE() {
        let block    = gradientBlock()
        let sseResult = SSEOps.dct2D(block)
        let avxResult = AVXOps.dct2D(block)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(avxResult[y][x], sseResult[y][x],
                               accuracy: 1e-4, "AVX DCT mismatch at [\(y)][\(x)]")
            }
        }
    }

    func testAVX_IDCT2D_RoundTrip_MatchesSSE() {
        let block         = gradientBlock()
        let avxDCT        = AVXOps.dct2D(block)
        let avxIDCT       = AVXOps.idct2D(avxDCT)
        let sseIDCT       = SSEOps.idct2D(SSEOps.dct2D(block))
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(avxIDCT[y][x], sseIDCT[y][x],
                               accuracy: 1e-4, "AVX IDCT mismatch at [\(y)][\(x)]")
            }
        }
    }

    func testAVX_DCT2D_ZeroBlock_ProducesAllZeros() {
        let result = AVXOps.dct2D(constantBlock(0))
        for y in 0..<8 {
            for x in 0..<8 { XCTAssertEqual(result[y][x], 0, accuracy: 1e-6) }
        }
    }

    func testAVX_DCT2D_RoundTrip_ReconstructsWithinTolerance() {
        let block         = gradientBlock()
        let reconstructed = AVXOps.idct2D(AVXOps.dct2D(block))
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(reconstructed[y][x], block[y][x],
                               accuracy: 1e-4, "AVX DCT round-trip mismatch at [\(y)][\(x)]")
            }
        }
    }

    // MARK: - AVX Colour Space Conversion Tests

    func testAVX_RGBToYCbCr_MatchesSSE() {
        let r: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        let g: [Float] = [0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1]
        let b: [Float] = [0.5, 0.4, 0.3, 0.2, 0.1, 0.9, 0.8, 0.7]

        let (ySSE, cbSSE, crSSE) = SSEOps.rgbToYCbCr(r: r, g: g, b: b)
        let (yAVX, cbAVX, crAVX) = AVXOps.rgbToYCbCr(r: r, g: g, b: b)

        for i in 0..<8 {
            XCTAssertEqual(yAVX[i],  ySSE[i],  accuracy: 1e-5, "Y[\(i)] mismatch")
            XCTAssertEqual(cbAVX[i], cbSSE[i], accuracy: 1e-5, "Cb[\(i)] mismatch")
            XCTAssertEqual(crAVX[i], crSSE[i], accuracy: 1e-5, "Cr[\(i)] mismatch")
        }
    }

    func testAVX_RGBToYCbCr_8PixelSIMD_MatchesBT601() {
        let r: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        let g: [Float] = [0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1]
        let b: [Float] = [0.5, 0.4, 0.3, 0.2, 0.1, 0.9, 0.8, 0.7]

        let (y, cb, cr) = AVXOps.rgbToYCbCr(r: r, g: g, b: b)

        for i in 0..<8 {
            let yExpected  =  0.299    * r[i] + 0.587    * g[i] + 0.114    * b[i]
            let cbExpected = -0.168736 * r[i] - 0.331264 * g[i] + 0.5      * b[i] + 0.5
            let crExpected =  0.5      * r[i] - 0.418688 * g[i] - 0.081312 * b[i] + 0.5
            XCTAssertEqual(y[i],  yExpected,  accuracy: 1e-5, "Y[\(i)]")
            XCTAssertEqual(cb[i], cbExpected, accuracy: 1e-5, "Cb[\(i)]")
            XCTAssertEqual(cr[i], crExpected, accuracy: 1e-5, "Cr[\(i)]")
        }
    }

    func testAVX_RGBToYCbCr_NonMultipleOf8_HandlesScalarTail() {
        let r: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
        let g: [Float] = [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1]
        let b: [Float] = [0.5, 0.4, 0.3, 0.2, 0.1, 0.6, 0.7, 0.8, 0.9]

        let (y, cb, cr) = AVXOps.rgbToYCbCr(r: r, g: g, b: b)
        for i in 0..<9 {
            XCTAssertTrue(y[i]  >= 0 && y[i]  <= 1.1, "Y[\(i)] out of range: \(y[i])")
            XCTAssertTrue(cb[i] >= 0 && cb[i] <= 1,   "Cb[\(i)] out of range: \(cb[i])")
            XCTAssertTrue(cr[i] >= 0 && cr[i] <= 1,   "Cr[\(i)] out of range: \(cr[i])")
        }
    }

    func testAVX_RGBToYCbCr_EmptyInput_ReturnsEmpty() {
        let (y, cb, cr) = AVXOps.rgbToYCbCr(r: [], g: [], b: [])
        XCTAssertTrue(y.isEmpty)
        XCTAssertTrue(cb.isEmpty)
        XCTAssertTrue(cr.isEmpty)
    }

    // MARK: - AVX Block Activity Tests

    func testAVX_BlockActivity_MatchesSSE() {
        let block    = gradientBlock()
        let sseVal   = SSEOps.blockActivity(block)
        let avxVal   = AVXOps.blockActivity(block)
        XCTAssertEqual(avxVal, sseVal, accuracy: 1e-5, "AVX block activity mismatch vs SSE")
    }

    func testAVX_BlockActivity_ConstantBlock_ReturnsZero() {
        XCTAssertEqual(AVXOps.blockActivity(constantBlock(0.5)), 0, accuracy: 1e-6)
    }

    func testAVX_BlockActivity_NonNegative() {
        var block = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        for y in 0..<8 { for x in 0..<8 { block[y][x] = Float((y * 17 + x * 11) % 100) / 100.0 } }
        XCTAssertGreaterThanOrEqual(AVXOps.blockActivity(block), 0)
    }

    // MARK: - DispatchBackend Integration Tests

    func testDispatchBackend_SSE2AvailableOnX86_64() {
        #if arch(x86_64)
        XCTAssertTrue(DispatchBackend.sse2.isAvailable)
        XCTAssertTrue(DispatchBackend.avx2.isAvailable)
        #else
        XCTAssertFalse(DispatchBackend.sse2.isAvailable)
        XCTAssertFalse(DispatchBackend.avx2.isAvailable)
        #endif
    }

    func testDispatchBackend_ScalarAlwaysAvailable() {
        XCTAssertTrue(DispatchBackend.scalar.isAvailable)
    }

    func testDispatchBackend_CurrentOnX86WithoutAccelerate() {
        // On x86_64 without Accelerate, current should prefer AVX2
        #if arch(x86_64) && !canImport(Accelerate)
        let current = DispatchBackend.current
        XCTAssertEqual(current, .avx2)
        #endif
    }

    // MARK: - Architecture Detection Tests

    func testArchitecture_HasAVX2_IsConsistentWithDispatch() {
        let caps = HardwareCapabilities.detect()
        #if arch(x86_64)
        // hasAVX2 should match AVXOps.isAVX2Available
        XCTAssertEqual(caps.hasAVX2, AVXOps.isAVX2Available)
        #else
        XCTAssertFalse(caps.hasAVX2, "hasAVX2 must be false on non-x86_64")
        #endif
    }

    // MARK: - Edge Case Tests

    func testSSE_Quantize_AllOnesMatrix_PreservesRoundedValues() {
        var block = constantBlock(0)
        block[4][4] = 7.6
        block[2][3] = -3.3
        let qMatrix = [[Float]](repeating: [Float](repeating: 1.0, count: 8), count: 8)
        let result  = SSEOps.quantize(block: block, qMatrix: qMatrix)
        XCTAssertEqual(result[4][4],  8)
        XCTAssertEqual(result[2][3], -3)
    }

    func testSSE_RGBToXYB_EmptyInput_ReturnsEmpty() {
        let (x, y, b) = SSEOps.rgbToXYB(r: [], g: [], b: [])
        XCTAssertTrue(x.isEmpty)
        XCTAssertTrue(y.isEmpty)
        XCTAssertTrue(b.isEmpty)
    }

    func testSSE_InverseRCT_MatchesForwardRCT() {
        let r: [UInt16] = [10, 20, 30, 40, 50, 60, 70, 80]
        let g: [UInt16] = [15, 25, 35, 45, 55, 65, 75, 85]
        let b: [UInt16] = [ 5, 10, 15, 20, 25, 30, 35, 40]
        let (y, co, cg)      = SSEOps.forwardRCT(r: r, g: g, b: b)
        let (rOut, gOut, bOut) = SSEOps.inverseRCT(y: y, co: co, cg: cg)
        for i in 0..<8 {
            XCTAssertEqual(rOut[i], Int32(r[i]), "Scalar tail R[\(i)]")
            XCTAssertEqual(gOut[i], Int32(g[i]), "Scalar tail G[\(i)]")
            XCTAssertEqual(bOut[i], Int32(b[i]), "Scalar tail B[\(i)]")
        }
    }

    // MARK: - Performance Tests

    func testSSE_DCTPerformance_8x8Block() {
        let block = gradientBlock()
        measure {
            for _ in 0..<1000 {
                _ = SSEOps.dct2D(block)
            }
        }
    }

    func testAVX_DCTPerformance_8x8Block() {
        let block = gradientBlock()
        measure {
            for _ in 0..<1000 {
                _ = AVXOps.dct2D(block)
            }
        }
    }

    func testSSE_RGBToYCbCrPerformance_LargeArray() {
        let count = 256 * 256
        let r = [Float](repeating: 0.5, count: count)
        let g = [Float](repeating: 0.4, count: count)
        let b = [Float](repeating: 0.3, count: count)
        measure {
            _ = SSEOps.rgbToYCbCr(r: r, g: g, b: b)
        }
    }

    func testAVX_RGBToYCbCrPerformance_LargeArray() {
        let count = 256 * 256
        let r = [Float](repeating: 0.5, count: count)
        let g = [Float](repeating: 0.4, count: count)
        let b = [Float](repeating: 0.3, count: count)
        measure {
            _ = AVXOps.rgbToYCbCr(r: r, g: g, b: b)
        }
    }

    func testSSE_QuantizePerformance_8x8Block() {
        let encoder  = makeEncoder()
        let block    = gradientBlock()
        let qMatrix  = encoder.generateQuantizationMatrix(channel: 0)
        measure {
            for _ in 0..<1000 {
                _ = SSEOps.quantize(block: block, qMatrix: qMatrix)
            }
        }
    }
}
