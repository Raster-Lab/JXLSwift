import XCTest
@testable import JXLSwift

/// Tests for NEONOps SIMD-accelerated operations.
///
/// These tests verify that the SIMD implementations in ``NEONOps`` produce
/// results matching the scalar reference implementations within acceptable
/// floating-point tolerance.
///
/// All tests run on every platform because ``NEONOps`` uses Swift's portable
/// SIMD types. On ARM64 these map to NEON registers; on x86-64 they map to
/// SSE/AVX equivalents.
final class NEONOpsTests: XCTestCase {

    // MARK: - Helpers

    /// Create a VarDCTEncoder for use in reference comparisons.
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

    /// Create a ModularEncoder for use in reference comparisons.
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

    /// Create a constant 8×8 block filled with the given value.
    private func constantBlock(_ value: Float) -> [[Float]] {
        [[Float]](
            repeating: [Float](repeating: value, count: 8),
            count: 8
        )
    }

    /// Create a gradient 8×8 block with values increasing from top-left.
    private func gradientBlock() -> [[Float]] {
        var block = [[Float]](
            repeating: [Float](repeating: 0, count: 8),
            count: 8
        )
        for y in 0..<8 {
            for x in 0..<8 {
                block[y][x] = Float(y * 8 + x) / 63.0
            }
        }
        return block
    }

    // MARK: - DCT Tests

    func testDCT2D_ConstantBlock_MatchesScalar() {
        let encoder = makeEncoder()
        let block = constantBlock(0.5)
        let neonResult = NEONOps.dct2D(block)
        let scalarResult = encoder.applyDCTScalar(block: block)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(
                    neonResult[y][x], scalarResult[y][x],
                    accuracy: 1e-4,
                    "DCT mismatch at [\(y)][\(x)]"
                )
            }
        }
    }

    func testDCT2D_GradientBlock_MatchesScalar() {
        let encoder = makeEncoder()
        let block = gradientBlock()
        let neonResult = NEONOps.dct2D(block)
        let scalarResult = encoder.applyDCTScalar(block: block)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(
                    neonResult[y][x], scalarResult[y][x],
                    accuracy: 1e-4,
                    "DCT mismatch at [\(y)][\(x)]"
                )
            }
        }
    }

    func testDCT2D_ZeroBlock_ProducesAllZeros() {
        let block = constantBlock(0)
        let result = NEONOps.dct2D(block)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(result[y][x], 0, accuracy: 1e-6)
            }
        }
    }

    func testIDCT2D_RoundTrip_ReconstructsWithinTolerance() {
        let block = gradientBlock()
        let dct = NEONOps.dct2D(block)
        let reconstructed = NEONOps.idct2D(dct)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(
                    reconstructed[y][x], block[y][x],
                    accuracy: 1e-4,
                    "IDCT round-trip mismatch at [\(y)][\(x)]"
                )
            }
        }
    }

    func testIDCT2D_MatchesScalar() {
        let encoder = makeEncoder()
        let block = gradientBlock()
        let dct = encoder.applyDCTScalar(block: block)

        let neonIDCT = NEONOps.idct2D(dct)
        let scalarIDCT = encoder.applyIDCTScalar(block: dct)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(
                    neonIDCT[y][x], scalarIDCT[y][x],
                    accuracy: 1e-4,
                    "IDCT mismatch at [\(y)][\(x)]"
                )
            }
        }
    }

    // MARK: - Colour Space Conversion Tests

    func testRGBToYCbCr_Black_ProducesExpectedValues() {
        let r: [Float] = [0, 0, 0, 0]
        let g: [Float] = [0, 0, 0, 0]
        let b: [Float] = [0, 0, 0, 0]

        let (y, cb, cr) = NEONOps.rgbToYCbCr(r: r, g: g, b: b)

        for i in 0..<4 {
            XCTAssertEqual(y[i], 0, accuracy: 1e-6)
            XCTAssertEqual(cb[i], 0.5, accuracy: 1e-6)
            XCTAssertEqual(cr[i], 0.5, accuracy: 1e-6)
        }
    }

    func testRGBToYCbCr_White_ProducesExpectedValues() {
        let r: [Float] = [1, 1, 1, 1]
        let g: [Float] = [1, 1, 1, 1]
        let b: [Float] = [1, 1, 1, 1]

        let (y, cb, cr) = NEONOps.rgbToYCbCr(r: r, g: g, b: b)

        for i in 0..<4 {
            XCTAssertEqual(y[i], 1.0, accuracy: 1e-4)
            XCTAssertEqual(cb[i], 0.5, accuracy: 1e-4)
            XCTAssertEqual(cr[i], 0.5, accuracy: 1e-4)
        }
    }

    func testRGBToYCbCr_NonMultipleOf4_HandlesScalarTail() {
        // 5 pixels: 4 via SIMD + 1 scalar
        let r: [Float] = [0.2, 0.4, 0.6, 0.8, 1.0]
        let g: [Float] = [0.1, 0.3, 0.5, 0.7, 0.9]
        let b: [Float] = [0.0, 0.2, 0.4, 0.6, 0.8]

        let (y, cb, cr) = NEONOps.rgbToYCbCr(r: r, g: g, b: b)

        // Verify all 5 results are reasonable
        for i in 0..<5 {
            XCTAssertTrue(y[i] >= 0 && y[i] <= 1, "Y[\(i)] out of range: \(y[i])")
            XCTAssertTrue(cb[i] >= 0 && cb[i] <= 1, "Cb[\(i)] out of range: \(cb[i])")
            XCTAssertTrue(cr[i] >= 0 && cr[i] <= 1, "Cr[\(i)] out of range: \(cr[i])")
        }
    }

    func testRGBToYCbCr_MatchesScalarConversion() {
        let r: [Float] = [0.25, 0.5, 0.75, 1.0, 0.1, 0.3, 0.7, 0.9]
        let g: [Float] = [0.3, 0.6, 0.2, 0.8, 0.4, 0.5, 0.1, 0.6]
        let b: [Float] = [0.1, 0.4, 0.9, 0.3, 0.7, 0.2, 0.8, 0.5]

        let (yN, cbN, crN) = NEONOps.rgbToYCbCr(r: r, g: g, b: b)

        // Compare with manual BT.601
        for i in 0..<r.count {
            let yScalar  =  0.299    * r[i] + 0.587    * g[i] + 0.114    * b[i]
            let cbScalar = -0.168736 * r[i] - 0.331264 * g[i] + 0.5      * b[i] + 0.5
            let crScalar =  0.5      * r[i] - 0.418688 * g[i] - 0.081312 * b[i] + 0.5

            XCTAssertEqual(yN[i], yScalar, accuracy: 1e-5, "Y[\(i)] mismatch")
            XCTAssertEqual(cbN[i], cbScalar, accuracy: 1e-5, "Cb[\(i)] mismatch")
            XCTAssertEqual(crN[i], crScalar, accuracy: 1e-5, "Cr[\(i)] mismatch")
        }
    }

    // MARK: - XYB Colour Space Tests

    func testRGBToXYB_Black_ProducesExpectedValues() {
        let r: [Float] = [0, 0, 0, 0]
        let g: [Float] = [0, 0, 0, 0]
        let b: [Float] = [0, 0, 0, 0]

        let (x, y, bOut) = NEONOps.rgbToXYB(r: r, g: g, b: b)

        // All channels should be near zero for black input
        for i in 0..<4 {
            XCTAssertEqual(x[i], 0, accuracy: 1e-4, "X[\(i)] should be ~0 for black")
            XCTAssertTrue(abs(y[i]) < 0.01, "Y[\(i)] should be near 0 for black: \(y[i])")
            XCTAssertTrue(abs(bOut[i]) < 0.01, "B[\(i)] should be near 0 for black: \(bOut[i])")
        }
    }

    func testRGBToXYB_MatchesScalarConversion() {
        let r: [Float] = [0.5, 0.3, 0.8, 0.1]
        let g: [Float] = [0.4, 0.6, 0.2, 0.9]
        let b: [Float] = [0.3, 0.1, 0.7, 0.5]

        let (xN, yN, bN) = NEONOps.rgbToXYB(r: r, g: g, b: b)

        // Compare with scalar reference
        let m = VarDCTEncoder.opsinAbsorbanceMatrix
        for i in 0..<4 {
            let lv = m[0] * r[i] + m[1] * g[i] + m[2] * b[i]
            let mv = m[3] * r[i] + m[4] * g[i] + m[5] * b[i]
            let sv = m[6] * r[i] + m[7] * g[i] + m[8] * b[i]
            let lp = VarDCTEncoder.opsinTransfer(lv)
            let mp = VarDCTEncoder.opsinTransfer(mv)
            let sp = VarDCTEncoder.opsinTransfer(sv)
            let xScalar = (lp - mp) * 0.5
            let yScalar = (lp + mp) * 0.5

            XCTAssertEqual(xN[i], xScalar, accuracy: 1e-5, "X[\(i)] mismatch")
            XCTAssertEqual(yN[i], yScalar, accuracy: 1e-5, "Y[\(i)] mismatch")
            XCTAssertEqual(bN[i], sp, accuracy: 1e-5, "B[\(i)] mismatch")
        }
    }

    func testXYBRoundTrip_MatchesWithinTolerance() {
        let r: [Float] = [0.5, 0.3, 0.8, 0.1]
        let g: [Float] = [0.4, 0.6, 0.2, 0.9]
        let b: [Float] = [0.3, 0.1, 0.7, 0.5]

        let (x, y, bXYB) = NEONOps.rgbToXYB(r: r, g: g, b: b)
        let (rOut, gOut, bOut) = NEONOps.xybToRGB(x: x, y: y, b: bXYB)

        for i in 0..<4 {
            XCTAssertEqual(rOut[i], r[i], accuracy: 1e-3,
                           "RGB→XYB→RGB round-trip R[\(i)] mismatch")
            XCTAssertEqual(gOut[i], g[i], accuracy: 1e-3,
                           "RGB→XYB→RGB round-trip G[\(i)] mismatch")
            XCTAssertEqual(bOut[i], b[i], accuracy: 1e-3,
                           "RGB→XYB→RGB round-trip B[\(i)] mismatch")
        }
    }

    func testXYBToRGB_NonMultipleOf4_HandlesScalarTail() {
        // 5 pixels: 4 via SIMD + 1 scalar
        let r: [Float] = [0.2, 0.4, 0.6, 0.8, 1.0]
        let g: [Float] = [0.1, 0.3, 0.5, 0.7, 0.9]
        let b: [Float] = [0.0, 0.2, 0.4, 0.6, 0.8]

        let (x, y, bXYB) = NEONOps.rgbToXYB(r: r, g: g, b: b)
        let (rOut, gOut, bOut) = NEONOps.xybToRGB(x: x, y: y, b: bXYB)

        for i in 0..<5 {
            XCTAssertEqual(rOut[i], r[i], accuracy: 1e-3,
                           "Round-trip R[\(i)] mismatch (scalar tail)")
            XCTAssertEqual(gOut[i], g[i], accuracy: 1e-3,
                           "Round-trip G[\(i)] mismatch (scalar tail)")
            XCTAssertEqual(bOut[i], b[i], accuracy: 1e-3,
                           "Round-trip B[\(i)] mismatch (scalar tail)")
        }
    }

    // MARK: - Quantisation Tests

    func testQuantize_MatchesScalar() {
        let encoder = makeEncoder(distance: 1.0)
        let block = gradientBlock()
        let qMatrix = encoder.generateQuantizationMatrix(channel: 0)

        let neonResult = NEONOps.quantize(block: block, qMatrix: qMatrix)
        let scalarResult = encoder.quantize(block: block, channel: 0)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(
                    neonResult[y][x], scalarResult[y][x],
                    "Quantize mismatch at [\(y)][\(x)]"
                )
            }
        }
    }

    func testQuantize_ZeroBlock_ProducesAllZeros() {
        let block = constantBlock(0)
        let qMatrix = [[Float]](
            repeating: [Float](repeating: 1.0, count: 8),
            count: 8
        )

        let result = NEONOps.quantize(block: block, qMatrix: qMatrix)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(result[y][x], 0)
            }
        }
    }

    func testQuantize_UnityMatrix_MatchesRounding() {
        var block = constantBlock(0)
        block[0][0] = 3.7
        block[0][1] = -2.3
        block[3][5] = 0.5

        let qMatrix = [[Float]](
            repeating: [Float](repeating: 1.0, count: 8),
            count: 8
        )

        let result = NEONOps.quantize(block: block, qMatrix: qMatrix)

        XCTAssertEqual(result[0][0], 4)  // round(3.7)
        XCTAssertEqual(result[0][1], -2) // round(-2.3)
        XCTAssertEqual(result[3][5], 1)  // round(0.5) = 1 (round away from zero)
    }

    // MARK: - Zigzag Scan Tests

    func testZigzagScan_CoversAll64Coefficients() {
        // Create block with unique values
        var block = [[Int16]](
            repeating: [Int16](repeating: 0, count: 8),
            count: 8
        )
        for y in 0..<8 {
            for x in 0..<8 {
                block[y][x] = Int16(y * 8 + x)
            }
        }

        let scanned = NEONOps.zigzagScan(block: block)

        XCTAssertEqual(scanned.count, 64)
        // All 64 values should be present exactly once
        let sorted = scanned.sorted()
        XCTAssertEqual(sorted, (0..<64).map { Int16($0) })
    }

    func testZigzagScan_FirstElementIsDC() {
        var block = [[Int16]](
            repeating: [Int16](repeating: 0, count: 8),
            count: 8
        )
        block[0][0] = 42
        let scanned = NEONOps.zigzagScan(block: block)
        XCTAssertEqual(scanned[0], 42)
    }

    func testZigzagScan_LastElementIsBottomRight() {
        var block = [[Int16]](
            repeating: [Int16](repeating: 0, count: 8),
            count: 8
        )
        block[7][7] = 99
        let scanned = NEONOps.zigzagScan(block: block)
        XCTAssertEqual(scanned[63], 99)
    }

    func testZigzagScan_MatchesVarDCTEncoder() {
        let encoder = makeEncoder()
        var block = [[Int16]](
            repeating: [Int16](repeating: 0, count: 8),
            count: 8
        )
        for y in 0..<8 {
            for x in 0..<8 {
                block[y][x] = Int16(y * 8 + x)
            }
        }

        let neonResult = NEONOps.zigzagScan(block: block)
        let scalarResult = encoder.zigzagScan(block: block)

        XCTAssertEqual(neonResult, scalarResult, "Zigzag scan order mismatch")
    }

    // MARK: - MED Prediction Tests

    func testPredictMED_SinglePixel_NoModification() {
        let data: [UInt16] = [42]
        let residuals = NEONOps.predictMED(data: data, width: 1, height: 1)
        XCTAssertEqual(residuals[0], 42) // First pixel: no prediction
    }

    func testPredictMED_FirstRow_PredictFromWest() {
        let data: [UInt16] = [10, 20, 30, 40]
        let residuals = NEONOps.predictMED(data: data, width: 4, height: 1)

        XCTAssertEqual(residuals[0], 10)        // First pixel
        XCTAssertEqual(residuals[1], 10)         // 20 - 10
        XCTAssertEqual(residuals[2], 10)         // 30 - 20
        XCTAssertEqual(residuals[3], 10)         // 40 - 30
    }

    func testPredictMED_FirstColumn_PredictFromNorth() {
        // 1 column, 4 rows
        let data: [UInt16] = [10, 20, 30, 40]
        let residuals = NEONOps.predictMED(data: data, width: 1, height: 4)

        XCTAssertEqual(residuals[0], 10)        // First pixel
        XCTAssertEqual(residuals[1], 10)         // 20 - 10
        XCTAssertEqual(residuals[2], 10)         // 30 - 20
        XCTAssertEqual(residuals[3], 10)         // 40 - 30
    }

    func testPredictMED_GeneralCase_MatchesScalar() {
        // 4×4 gradient image
        var data = [UInt16](repeating: 0, count: 16)
        for y in 0..<4 {
            for x in 0..<4 {
                data[y * 4 + x] = UInt16(y * 100 + x * 50)
            }
        }

        let neonResult = NEONOps.predictMED(data: data, width: 4, height: 4)

        // Compare with scalar MED
        let modEncoder = makeModularEncoder()
        for y in 0..<4 {
            for x in 0..<4 {
                let idx = y * 4 + x
                let actual = Int32(data[idx])
                let predicted = modEncoder.predictPixel(
                    data: data, x: x, y: y, width: 4, height: 4
                )
                let expectedResidual = actual - predicted
                XCTAssertEqual(
                    neonResult[idx], expectedResidual,
                    "MED prediction mismatch at (\(x), \(y))"
                )
            }
        }
    }

    func testPredictMED_LargerImage_SIMDAndScalarTail() {
        // 9×3: first row boundary + interior SIMD + scalar tail
        var data = [UInt16](repeating: 0, count: 27)
        for i in 0..<27 {
            data[i] = UInt16(i * 100 % 65536)
        }

        let neonResult = NEONOps.predictMED(data: data, width: 9, height: 3)

        let modEncoder = makeModularEncoder()
        for y in 0..<3 {
            for x in 0..<9 {
                let idx = y * 9 + x
                let actual = Int32(data[idx])
                let predicted = modEncoder.predictPixel(
                    data: data, x: x, y: y, width: 9, height: 3
                )
                let expectedResidual = actual - predicted
                XCTAssertEqual(
                    neonResult[idx], expectedResidual,
                    "MED mismatch at (\(x), \(y)): expected \(expectedResidual), got \(neonResult[idx])"
                )
            }
        }
    }

    func testPredictMED_ConstantImage_AllResidualZero() {
        // Constant image: all predictions should be exact → residuals = 0
        // except the first pixel
        let data = [UInt16](repeating: 100, count: 16)
        let residuals = NEONOps.predictMED(data: data, width: 4, height: 4)

        XCTAssertEqual(residuals[0], 100) // First pixel
        for i in 1..<16 {
            XCTAssertEqual(residuals[i], 0, "Residual[\(i)] should be 0 for constant image")
        }
    }

    // MARK: - RCT Tests

    func testForwardRCT_MatchesScalar() {
        let modEncoder = makeModularEncoder()
        let r: [UInt16] = [100, 200, 300, 400, 500]
        let g: [UInt16] = [150, 250, 350, 450, 550]
        let b: [UInt16] = [50, 100, 150, 200, 250]

        let (yN, coN, cgN) = NEONOps.forwardRCT(r: r, g: g, b: b)

        for i in 0..<r.count {
            let (yS, coS, cgS) = modEncoder.forwardRCT(
                r: Int32(r[i]), g: Int32(g[i]), b: Int32(b[i])
            )
            XCTAssertEqual(yN[i], yS, "Y[\(i)] mismatch")
            XCTAssertEqual(coN[i], coS, "Co[\(i)] mismatch")
            XCTAssertEqual(cgN[i], cgS, "Cg[\(i)] mismatch")
        }
    }

    func testRCTRoundTrip_PerfectReconstruction() {
        let r: [UInt16] = [100, 200, 300, 400, 500, 600, 700, 800]
        let g: [UInt16] = [150, 250, 350, 450, 550, 650, 750, 850]
        let b: [UInt16] = [50, 100, 150, 200, 250, 300, 350, 400]

        let (yOut, coOut, cgOut) = NEONOps.forwardRCT(r: r, g: g, b: b)
        let (rOut, gOut, bOut) = NEONOps.inverseRCT(y: yOut, co: coOut, cg: cgOut)

        for i in 0..<r.count {
            XCTAssertEqual(rOut[i], Int32(r[i]), "RCT round-trip R[\(i)] mismatch")
            XCTAssertEqual(gOut[i], Int32(g[i]), "RCT round-trip G[\(i)] mismatch")
            XCTAssertEqual(bOut[i], Int32(b[i]), "RCT round-trip B[\(i)] mismatch")
        }
    }

    func testForwardRCT_NonMultipleOf4_HandlesScalarTail() {
        // 7 pixels: 4 via SIMD + 3 scalar
        let r: [UInt16] = [10, 20, 30, 40, 50, 60, 70]
        let g: [UInt16] = [15, 25, 35, 45, 55, 65, 75]
        let b: [UInt16] = [5, 10, 15, 20, 25, 30, 35]

        let (yN, coN, cgN) = NEONOps.forwardRCT(r: r, g: g, b: b)
        let (rOut, gOut, bOut) = NEONOps.inverseRCT(y: yN, co: coN, cg: cgN)

        for i in 0..<r.count {
            XCTAssertEqual(rOut[i], Int32(r[i]), "Scalar tail R[\(i)]")
            XCTAssertEqual(gOut[i], Int32(g[i]), "Scalar tail G[\(i)]")
            XCTAssertEqual(bOut[i], Int32(b[i]), "Scalar tail B[\(i)]")
        }
    }

    // MARK: - Squeeze Transform Tests

    func testSqueezeHorizontal_MatchesScalar() {
        let modEncoder = makeModularEncoder()

        // 8×2 buffer
        var neonData: [Int32] = [10, 20, 30, 40, 50, 60, 70, 80,
                                  5, 15, 25, 35, 45, 55, 65, 75]
        var scalarData = neonData

        NEONOps.squeezeHorizontal(data: &neonData, regionW: 8, regionH: 2, stride: 8)
        modEncoder.squeezeHorizontal(data: &scalarData, regionW: 8, regionH: 2, stride: 8)

        XCTAssertEqual(neonData, scalarData, "Horizontal squeeze mismatch")
    }

    func testSqueezeVertical_MatchesScalar() {
        let modEncoder = makeModularEncoder()

        // 4×6 buffer
        var neonData: [Int32] = [
            10, 20, 30, 40,
            50, 60, 70, 80,
            15, 25, 35, 45,
            55, 65, 75, 85,
            12, 22, 32, 42,
            52, 62, 72, 82
        ]
        var scalarData = neonData

        NEONOps.squeezeVertical(data: &neonData, regionW: 4, regionH: 6, stride: 4)
        modEncoder.squeezeVertical(data: &scalarData, regionW: 4, regionH: 6, stride: 4)

        XCTAssertEqual(neonData, scalarData, "Vertical squeeze mismatch")
    }

    func testSqueezeHorizontal_OddWidth_MatchesScalar() {
        let modEncoder = makeModularEncoder()

        // 7×2 with stride 7 (odd width)
        var neonData: [Int32] = [10, 20, 30, 40, 50, 60, 70,
                                  5, 15, 25, 35, 45, 55, 65]
        var scalarData = neonData

        NEONOps.squeezeHorizontal(data: &neonData, regionW: 7, regionH: 2, stride: 7)
        modEncoder.squeezeHorizontal(data: &scalarData, regionW: 7, regionH: 2, stride: 7)

        XCTAssertEqual(neonData, scalarData, "Horizontal squeeze odd width mismatch")
    }

    func testSqueezeVertical_OddHeight_MatchesScalar() {
        let modEncoder = makeModularEncoder()

        // 4×5 (odd height)
        var neonData: [Int32] = [
            10, 20, 30, 40,
            50, 60, 70, 80,
            15, 25, 35, 45,
            55, 65, 75, 85,
            12, 22, 32, 42
        ]
        var scalarData = neonData

        NEONOps.squeezeVertical(data: &neonData, regionW: 4, regionH: 5, stride: 4)
        modEncoder.squeezeVertical(data: &scalarData, regionW: 4, regionH: 5, stride: 4)

        XCTAssertEqual(neonData, scalarData, "Vertical squeeze odd height mismatch")
    }

    // MARK: - Block Activity Tests

    func testBlockActivity_ConstantBlock_ReturnsZero() {
        let block = constantBlock(0.5)
        let activity = NEONOps.blockActivity(block)
        XCTAssertEqual(activity, 0, accuracy: 1e-6)
    }

    func testBlockActivity_MatchesScalar() {
        let encoder = makeEncoder()
        let block = gradientBlock()

        let neonActivity = NEONOps.blockActivity(block)
        let scalarActivity = encoder.computeBlockActivity(block: block)

        XCTAssertEqual(neonActivity, scalarActivity, accuracy: 1e-4,
                       "Block activity mismatch")
    }

    func testBlockActivity_NonNegative() {
        // Random-ish block
        var block = [[Float]](
            repeating: [Float](repeating: 0, count: 8),
            count: 8
        )
        for y in 0..<8 {
            for x in 0..<8 {
                block[y][x] = Float((y * 13 + x * 7) % 100) / 100.0
            }
        }
        XCTAssertGreaterThanOrEqual(NEONOps.blockActivity(block), 0)
    }

    // MARK: - Edge Case Tests

    func testRGBToYCbCr_EmptyInput_ReturnsEmpty() {
        let (y, cb, cr) = NEONOps.rgbToYCbCr(r: [], g: [], b: [])
        XCTAssertTrue(y.isEmpty)
        XCTAssertTrue(cb.isEmpty)
        XCTAssertTrue(cr.isEmpty)
    }

    func testRGBToXYB_EmptyInput_ReturnsEmpty() {
        let (x, y, b) = NEONOps.rgbToXYB(r: [], g: [], b: [])
        XCTAssertTrue(x.isEmpty)
        XCTAssertTrue(y.isEmpty)
        XCTAssertTrue(b.isEmpty)
    }

    func testRGBToYCbCr_SinglePixel_Correct() {
        let (y, cb, cr) = NEONOps.rgbToYCbCr(r: [0.5], g: [0.3], b: [0.1])

        let yExpected:  Float = 0.299 * 0.5 + 0.587 * 0.3 + 0.114 * 0.1
        let cbExpected: Float = -0.168736 * 0.5 - 0.331264 * 0.3 + 0.5 * 0.1 + 0.5
        let crExpected: Float = 0.5 * 0.5 - 0.418688 * 0.3 - 0.081312 * 0.1 + 0.5

        XCTAssertEqual(y[0], yExpected, accuracy: 1e-5)
        XCTAssertEqual(cb[0], cbExpected, accuracy: 1e-5)
        XCTAssertEqual(cr[0], crExpected, accuracy: 1e-5)
    }

    func testForwardRCT_ZeroInput_ReturnsZero() {
        let r: [UInt16] = [0, 0, 0, 0]
        let g: [UInt16] = [0, 0, 0, 0]
        let b: [UInt16] = [0, 0, 0, 0]

        let (y, co, cg) = NEONOps.forwardRCT(r: r, g: g, b: b)

        for i in 0..<4 {
            XCTAssertEqual(y[i], 0)
            XCTAssertEqual(co[i], 0)
            XCTAssertEqual(cg[i], 0)
        }
    }

    func testPredictMED_EmptyInput_ReturnsEmpty() {
        let residuals = NEONOps.predictMED(data: [], width: 0, height: 0)
        XCTAssertTrue(residuals.isEmpty)
    }

    // MARK: - DispatchBackend Integration

    func testDispatchBackend_NEONIsAvailableOnARM64() {
        #if arch(arm64)
        XCTAssertTrue(DispatchBackend.neon.isAvailable)
        #else
        XCTAssertFalse(DispatchBackend.neon.isAvailable)
        #endif
    }

    func testDispatchBackend_ScalarAlwaysAvailable() {
        XCTAssertTrue(DispatchBackend.scalar.isAvailable)
    }
}
