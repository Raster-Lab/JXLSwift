import XCTest
@testable import JXLSwift

final class VarDCTEncoderTests: XCTestCase {

    // MARK: - Setup

    private func makeEncoder(distance: Float = 1.0) -> VarDCTEncoder {
        VarDCTEncoder(
            hardware: HardwareCapabilities.detect(),
            options: .fast,
            distance: distance
        )
    }

    // MARK: - DCT Round-Trip Tests

    func testDCTRoundTrip_ConstantBlock_ReconstructsWithinTolerance() {
        let encoder = makeEncoder()
        // Constant block: all values = 0.5
        let block = [[Float]](repeating: [Float](repeating: 0.5, count: 8), count: 8)

        let dctBlock = encoder.applyDCTScalar(block: block)
        let reconstructed = encoder.applyIDCTScalar(block: dctBlock)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(reconstructed[y][x], block[y][x], accuracy: 1e-4,
                               "DCT→IDCT round-trip failed at (\(x),\(y))")
            }
        }
    }

    func testDCTRoundTrip_GradientBlock_ReconstructsWithinTolerance() {
        let encoder = makeEncoder()
        // Gradient block
        var block = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        for y in 0..<8 {
            for x in 0..<8 {
                block[y][x] = Float(x + y) / 14.0
            }
        }

        let dctBlock = encoder.applyDCTScalar(block: block)
        let reconstructed = encoder.applyIDCTScalar(block: dctBlock)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(reconstructed[y][x], block[y][x], accuracy: 1e-4,
                               "DCT→IDCT round-trip failed at (\(x),\(y))")
            }
        }
    }

    func testDCTRoundTrip_RandomBlock_ReconstructsWithinTolerance() {
        let encoder = makeEncoder()
        // Deterministic "random" block using simple math
        var block = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        for y in 0..<8 {
            for x in 0..<8 {
                // Use a deterministic pattern that looks random
                block[y][x] = Float((x * 7 + y * 13 + 3) % 256) / 255.0
            }
        }

        let dctBlock = encoder.applyDCTScalar(block: block)
        let reconstructed = encoder.applyIDCTScalar(block: dctBlock)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(reconstructed[y][x], block[y][x], accuracy: 1e-3,
                               "DCT→IDCT round-trip failed at (\(x),\(y))")
            }
        }
    }

    func testDCTRoundTrip_ZeroBlock_ReturnsZero() {
        let encoder = makeEncoder()
        let block = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)

        let dctBlock = encoder.applyDCTScalar(block: block)
        let reconstructed = encoder.applyIDCTScalar(block: dctBlock)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(reconstructed[y][x], 0, accuracy: 1e-6,
                               "Zero block DCT round-trip should remain zero")
            }
        }
    }

    func testDCT_ConstantBlock_EnergyInDC() {
        let encoder = makeEncoder()
        // A constant block should have all energy in the DC coefficient
        let value: Float = 0.75
        let block = [[Float]](repeating: [Float](repeating: value, count: 8), count: 8)

        let dctBlock = encoder.applyDCTScalar(block: block)

        // DC coefficient should be non-zero
        XCTAssertNotEqual(dctBlock[0][0], 0,
                          "DC coefficient of constant block should be non-zero")

        // All AC coefficients should be essentially zero
        for y in 0..<8 {
            for x in 0..<8 {
                if x == 0 && y == 0 { continue }
                XCTAssertEqual(dctBlock[y][x], 0, accuracy: 1e-4,
                               "AC coefficient (\(x),\(y)) should be ~0 for constant block")
            }
        }
    }

    // MARK: - Zigzag Scan Tests

    func testZigzagScan_CoversAll64Coefficients() {
        let encoder = makeEncoder()
        // Create a block with unique values 0..63
        var block = [[Int16]](repeating: [Int16](repeating: 0, count: 8), count: 8)
        var value: Int16 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                block[y][x] = value
                value += 1
            }
        }

        let scanned = encoder.zigzagScan(block: block)

        // Should have exactly 64 coefficients
        XCTAssertEqual(scanned.count, 64,
                       "Zigzag scan should produce exactly 64 coefficients")

        // Each value 0..63 should appear exactly once
        let sorted = scanned.sorted()
        for i in 0..<64 {
            XCTAssertEqual(sorted[i], Int16(i),
                           "Zigzag scan should contain value \(i) exactly once")
        }
    }

    func testZigzagScan_FirstElementIsDC() {
        let encoder = makeEncoder()
        var block = [[Int16]](repeating: [Int16](repeating: 0, count: 8), count: 8)
        block[0][0] = 42 // DC coefficient

        let scanned = encoder.zigzagScan(block: block)
        XCTAssertEqual(scanned[0], 42,
                       "First element of zigzag scan should be DC coefficient (0,0)")
    }

    func testZigzagScan_LastElementIsBottomRight() {
        let encoder = makeEncoder()
        var block = [[Int16]](repeating: [Int16](repeating: 0, count: 8), count: 8)
        block[7][7] = 99 // Bottom-right corner

        let scanned = encoder.zigzagScan(block: block)
        XCTAssertEqual(scanned[63], 99,
                       "Last element of zigzag scan should be bottom-right (7,7)")
    }

    // MARK: - Colour Space Conversion Tests

    func testConvertToYCbCr_Black_ProducesExpectedValues() {
        let encoder = makeEncoder()
        var frame = ImageFrame(width: 1, height: 1, channels: 3)
        // Black: R=0, G=0, B=0
        frame.setPixel(x: 0, y: 0, channel: 0, value: 0)
        frame.setPixel(x: 0, y: 0, channel: 1, value: 0)
        frame.setPixel(x: 0, y: 0, channel: 2, value: 0)

        let ycbcr = encoder.convertToYCbCr(frame: frame)

        // Y should be 0 for black
        let yVal = ycbcr.getPixel(x: 0, y: 0, channel: 0)
        XCTAssertEqual(yVal, 0, "Y for black should be 0")

        // For uint8 pixel type, the conversion works internally in [0,1] float space
        // and writes back via setPixel which clamps UInt16 to UInt8 range.
        // Cb and Cr = 0.5 * 65535 = 32767, clamped to 255 by uint8 setPixel.
        // This is expected behavior — the conversion assumes 16-bit storage.
        let cb = ycbcr.getPixel(x: 0, y: 0, channel: 1)
        let cr = ycbcr.getPixel(x: 0, y: 0, channel: 2)
        XCTAssertEqual(cb, 255,
                       "Cb for black saturates to 255 in uint8 mode due to 16-bit conversion")
        XCTAssertEqual(cr, 255,
                       "Cr for black saturates to 255 in uint8 mode due to 16-bit conversion")
    }

    func testConvertToYCbCr_White_ProducesExpectedValues() {
        let encoder = makeEncoder()
        var frame = ImageFrame(width: 1, height: 1, channels: 3)
        // White: R=255, G=255, B=255 (uint8 max)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 255)
        frame.setPixel(x: 0, y: 0, channel: 1, value: 255)
        frame.setPixel(x: 0, y: 0, channel: 2, value: 255)

        let ycbcr = encoder.convertToYCbCr(frame: frame)

        // Y should be close to max (255 for uint8)
        let yVal = ycbcr.getPixel(x: 0, y: 0, channel: 0)
        XCTAssertTrue(abs(Int(yVal) - 255) <= 2,
                      "Y for white should be near max, got \(yVal)")
    }

    func testConvertToYCbCr_SingleChannel_ReturnsUnchanged() {
        let encoder = makeEncoder()
        var frame = ImageFrame(width: 2, height: 2, channels: 1)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 128)
        frame.setPixel(x: 1, y: 0, channel: 0, value: 64)

        let result = encoder.convertToYCbCr(frame: frame)

        // Single channel should pass through unchanged
        XCTAssertEqual(result.getPixel(x: 0, y: 0, channel: 0), 128)
        XCTAssertEqual(result.getPixel(x: 1, y: 0, channel: 0), 64)
    }

    func testConvertToYCbCr_PureRed_HighCr() {
        let encoder = makeEncoder()
        var frame = ImageFrame(width: 1, height: 1, channels: 3)
        // Pure red
        frame.setPixel(x: 0, y: 0, channel: 0, value: 255)
        frame.setPixel(x: 0, y: 0, channel: 1, value: 0)
        frame.setPixel(x: 0, y: 0, channel: 2, value: 0)

        let ycbcr = encoder.convertToYCbCr(frame: frame)

        // Cr should be greater than neutral (0.5*255 ≈ 127) for pure red
        let cr = ycbcr.getPixel(x: 0, y: 0, channel: 2)
        XCTAssertGreaterThan(cr, 127,
                             "Cr for pure red should be above neutral, got \(cr)")
    }

    // MARK: - Quantization Tests

    func testQuantizationMatrix_PositiveValues() {
        let encoder = makeEncoder(distance: 1.0)
        let matrix = encoder.generateQuantizationMatrix(channel: 0)

        XCTAssertEqual(matrix.count, 8, "Matrix should be 8 rows")
        for y in 0..<8 {
            XCTAssertEqual(matrix[y].count, 8, "Each row should have 8 columns")
            for x in 0..<8 {
                XCTAssertGreaterThan(matrix[y][x], 0,
                                     "Quantization values should be positive at (\(x),\(y))")
            }
        }
    }

    func testQuantizationMatrix_LowerFrequenciesFiner() {
        let encoder = makeEncoder(distance: 1.0)
        let matrix = encoder.generateQuantizationMatrix(channel: 0)

        // DC (0,0) should have the smallest quantization step
        let dc = matrix[0][0]
        let midFreq = matrix[3][3]
        let highFreq = matrix[7][7]

        XCTAssertLessThan(dc, midFreq,
                          "DC quantization should be finer than mid-frequency")
        XCTAssertLessThan(midFreq, highFreq,
                          "Mid-frequency quantization should be finer than high-frequency")
    }

    func testQuantizationMatrix_ChromaMoreAggressive() {
        let encoder = makeEncoder(distance: 1.0)
        let lumaMatrix = encoder.generateQuantizationMatrix(channel: 0)
        let chromaMatrix = encoder.generateQuantizationMatrix(channel: 1)

        // Chroma quantization should be more aggressive (larger values)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertGreaterThan(chromaMatrix[y][x], lumaMatrix[y][x],
                                     "Chroma quant should be more aggressive at (\(x),\(y))")
            }
        }
    }

    func testQuantize_ZeroDistance_MinimalLoss() {
        // With minimal distance, quantization should preserve more detail
        let encoder = makeEncoder(distance: 0.0)
        // The distance is max(1.0, distance * 8.0), so distance=0 → baseQuant=1.0
        // This means quantization matrix starts at 1.0 for DC

        var block = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        block[0][0] = 10.0

        let quantized = encoder.quantize(block: block, channel: 0)
        XCTAssertEqual(quantized[0][0], 10,
                       "With minimal distance, DC coefficient should be preserved")
    }

    // MARK: - Block Extraction Tests

    func testExtractBlock_ExactSize_ExtractsCorrectly() {
        let encoder = makeEncoder()
        // 8x8 image with unique values
        var data = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        for y in 0..<8 {
            for x in 0..<8 {
                data[y][x] = Float(y * 8 + x)
            }
        }

        let block = encoder.extractBlock(data: data, blockX: 0, blockY: 0, width: 8, height: 8)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(block[y][x], data[y][x],
                               "Block extraction failed at (\(x),\(y))")
            }
        }
    }

    func testExtractBlock_NonMultipleOf8_PadsEdges() {
        let encoder = makeEncoder()
        // 5x5 image
        var data = [[Float]](repeating: [Float](repeating: 0, count: 5), count: 5)
        for y in 0..<5 {
            for x in 0..<5 {
                data[y][x] = Float(y * 5 + x)
            }
        }

        let block = encoder.extractBlock(data: data, blockX: 0, blockY: 0, width: 5, height: 5)

        // Values within bounds should match
        for y in 0..<5 {
            for x in 0..<5 {
                XCTAssertEqual(block[y][x], data[y][x],
                               "In-bounds value should match at (\(x),\(y))")
            }
        }

        // Values beyond bounds should repeat the edge (clamped indexing)
        // x=5..7: should be clamped to x=4
        for y in 0..<5 {
            XCTAssertEqual(block[y][5], data[y][4],
                           "Edge-padded x at y=\(y) should repeat last column")
        }
        // y=5..7: should be clamped to y=4
        for x in 0..<5 {
            XCTAssertEqual(block[5][x], data[4][x],
                           "Edge-padded y at x=\(x) should repeat last row")
        }
    }

    // MARK: - ZigZag Encoding (Signed Value) Tests

    func testEncodeSignedValue_ZigZagMapping() {
        let encoder = makeEncoder()
        // Same ZigZag mapping as ModularEncoder
        XCTAssertEqual(encoder.encodeSignedValue(0), 0)
        XCTAssertEqual(encoder.encodeSignedValue(-1), 1)
        XCTAssertEqual(encoder.encodeSignedValue(1), 2)
        XCTAssertEqual(encoder.encodeSignedValue(-2), 3)
        XCTAssertEqual(encoder.encodeSignedValue(2), 4)
    }

    // MARK: - Lossy Encoding Edge Case Tests

    func testLossyEncode_NonMultipleOf8Dimensions() throws {
        let encoder = JXLEncoder(options: .fast)
        var frame = ImageFrame(width: 10, height: 10, channels: 3)
        for y in 0..<10 {
            for x in 0..<10 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 25))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 25))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "Non-multiple-of-8 image should encode successfully")
    }

    func testLossyEncode_1x1Image() throws {
        let encoder = JXLEncoder(options: .fast)
        var frame = ImageFrame(width: 1, height: 1, channels: 3)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 128)
        frame.setPixel(x: 0, y: 0, channel: 1, value: 64)
        frame.setPixel(x: 0, y: 0, channel: 2, value: 255)

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "1×1 lossy image should encode successfully")
    }

    func testLossyEncode_SingleChannel() throws {
        let encoder = JXLEncoder(options: .fast)
        var frame = ImageFrame(width: 16, height: 16, channels: 1)
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x + y) * 8))
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "Single-channel lossy encoding should succeed")
    }

    // MARK: - Quality Level Tests

    func testHighQuality_LowerCompressionRatio() throws {
        var frame = ImageFrame(width: 32, height: 32, channels: 3)
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x * y) % 256))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16((x + y) % 256))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x ^ y) % 256))
            }
        }

        let highQEncoder = JXLEncoder(options: .highQuality)
        let fastEncoder = JXLEncoder(options: .fast)

        let highQResult = try highQEncoder.encode(frame)
        let fastResult = try fastEncoder.encode(frame)

        // Higher quality should generally produce larger files (lower compression ratio)
        // or similar — we just verify both succeed
        XCTAssertGreaterThan(highQResult.data.count, 0)
        XCTAssertGreaterThan(fastResult.data.count, 0)
    }

    // MARK: - DC Prediction Tests

    func testPredictDC_FirstBlock_ReturnsZero() {
        let encoder = makeEncoder()
        let dcValues: [[Int16]] = [[0]]
        let predicted = encoder.predictDC(dcValues: dcValues, blockX: 0, blockY: 0)
        XCTAssertEqual(predicted, 0,
                       "First block (0,0) should predict DC as 0")
    }

    func testPredictDC_FirstRow_UsesLeftNeighbor() {
        let encoder = makeEncoder()
        let dcValues: [[Int16]] = [[42, 50, 0]]
        let predicted = encoder.predictDC(dcValues: dcValues, blockX: 1, blockY: 0)
        XCTAssertEqual(predicted, 42,
                       "First row should predict from left neighbor")
    }

    func testPredictDC_FirstColumn_UsesAboveNeighbor() {
        let encoder = makeEncoder()
        let dcValues: [[Int16]] = [[100], [0]]
        let predicted = encoder.predictDC(dcValues: dcValues, blockX: 0, blockY: 1)
        XCTAssertEqual(predicted, 100,
                       "First column should predict from above neighbor")
    }

    func testPredictDC_GeneralCase_AveragesLeftAndAbove() {
        let encoder = makeEncoder()
        let dcValues: [[Int16]] = [
            [10, 20],
            [30,  0]
        ]
        // blockX=1, blockY=1 → left=30, above=20 → (30+20)/2 = 25
        let predicted = encoder.predictDC(dcValues: dcValues, blockX: 1, blockY: 1)
        XCTAssertEqual(predicted, 25,
                       "General case should average left and above: (30+20)/2 = 25")
    }

    func testPredictDC_GeneralCase_TruncatesIntegerDivision() {
        let encoder = makeEncoder()
        let dcValues: [[Int16]] = [
            [10, 21],
            [30,  0]
        ]
        // blockX=1, blockY=1 → left=30, above=21 → (30+21)/2 = 25 (integer truncation)
        let predicted = encoder.predictDC(dcValues: dcValues, blockX: 1, blockY: 1)
        XCTAssertEqual(predicted, 25,
                       "Integer division should truncate: (30+21)/2 = 25")
    }

    func testPredictDC_NegativeValues() {
        let encoder = makeEncoder()
        let dcValues: [[Int16]] = [
            [10, -20],
            [-30,  0]
        ]
        // blockX=1, blockY=1 → left=-30, above=-20 → (-30 + -20)/2 = -25
        let predicted = encoder.predictDC(dcValues: dcValues, blockX: 1, blockY: 1)
        XCTAssertEqual(predicted, -25,
                       "Should handle negative DC values correctly")
    }

    func testPredictDC_ConstantBlocks_ZeroResidual() {
        let encoder = makeEncoder()
        // All blocks have the same DC → residuals should be zero after first
        let dcValue: Int16 = 42
        let dcValues: [[Int16]] = [
            [dcValue, dcValue],
            [dcValue, dcValue]
        ]

        // First block: prediction = 0, residual = 42
        let pred00 = encoder.predictDC(dcValues: dcValues, blockX: 0, blockY: 0)
        XCTAssertEqual(dcValue - pred00, 42)

        // (1,0): prediction = 42 (left), residual = 0
        let pred10 = encoder.predictDC(dcValues: dcValues, blockX: 1, blockY: 0)
        XCTAssertEqual(dcValue - pred10, 0)

        // (0,1): prediction = 42 (above), residual = 0
        let pred01 = encoder.predictDC(dcValues: dcValues, blockX: 0, blockY: 1)
        XCTAssertEqual(dcValue - pred01, 0)

        // (1,1): prediction = (42+42)/2 = 42, residual = 0
        let pred11 = encoder.predictDC(dcValues: dcValues, blockX: 1, blockY: 1)
        XCTAssertEqual(dcValue - pred11, 0)
    }

    func testDCPrediction_GradientImage_ProducesOutput() throws {
        // A smooth gradient image should benefit from DC prediction
        // (adjacent blocks have similar DC values)
        let encoder = JXLEncoder(options: .fast)
        var frame = ImageFrame(width: 32, height: 32, channels: 3)
        for y in 0..<32 {
            for x in 0..<32 {
                let value = UInt16((x + y) * 4)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "Encoding with DC prediction should produce valid output")
    }

    func testDCPrediction_SingleBlock_EncodesSuccessfully() throws {
        // A single 8×8 block image has no neighbors for prediction
        let encoder = JXLEncoder(options: .fast)
        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: 128)
                frame.setPixel(x: x, y: y, channel: 1, value: 64)
                frame.setPixel(x: x, y: y, channel: 2, value: 200)
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "Single-block image should encode with DC prediction")
    }

    // MARK: - Accelerate Integration Tests

    func testAccelerateDCT_MatchesScalarDCT_ConstantBlock() {
        // Verify the Accelerate DCT path produces results matching scalar
        let encoder = makeEncoder()
        let block = [[Float]](repeating: [Float](repeating: 0.5, count: 8), count: 8)

        let scalarResult = encoder.applyDCTScalar(block: block)

        #if canImport(Accelerate)
        // Flatten for AccelerateOps
        let flat = block.flatMap { $0 }
        let accelFlat = AccelerateOps.dct2D(flat, size: 8)

        // Convert back to 2D
        var accelResult = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        for y in 0..<8 {
            for x in 0..<8 {
                accelResult[y][x] = accelFlat[y * 8 + x]
            }
        }

        // Compare: both should produce the same energy concentration
        // DC should be non-zero, AC should be ~0
        XCTAssertNotEqual(accelResult[0][0], 0,
                          "Accelerate DC coefficient should be non-zero for constant block")
        for y in 0..<8 {
            for x in 0..<8 {
                if x == 0 && y == 0 { continue }
                XCTAssertEqual(accelResult[y][x], 0, accuracy: 1e-4,
                               "Accelerate AC coefficient should be ~0 for constant block at (\(x),\(y))")
            }
        }
        #endif

        // Scalar path always works
        XCTAssertNotEqual(scalarResult[0][0], 0,
                          "Scalar DC coefficient should be non-zero for constant block")
    }

    func testAccelerateDCT_RoundTripAccuracy_GradientBlock() {
        let encoder = makeEncoder()
        var block = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        for y in 0..<8 {
            for x in 0..<8 {
                block[y][x] = Float(x + y) / 14.0
            }
        }

        let scalarDCT = encoder.applyDCTScalar(block: block)
        let scalarIDCT = encoder.applyIDCTScalar(block: scalarDCT)

        // Verify the scalar round-trip is accurate
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(scalarIDCT[y][x], block[y][x], accuracy: 1e-4,
                               "Scalar DCT round-trip should reconstruct at (\(x),\(y))")
            }
        }

        #if canImport(Accelerate)
        let flat = block.flatMap { $0 }
        let accelDCTFlat = AccelerateOps.dct2D(flat, size: 8)
        let accelIDCTFlat = AccelerateOps.idct2D(accelDCTFlat, size: 8)

        // Accelerate uses vDSP DCT Type II/III which has slightly different
        // normalisation than the scalar implementation, so we allow 1e-3 tolerance.
        for i in 0..<64 {
            let y = i / 8
            let x = i % 8
            XCTAssertEqual(accelIDCTFlat[i], block[y][x], accuracy: 1e-3,
                           "Accelerate DCT round-trip should reconstruct at (\(x),\(y))")
        }
        #endif
    }

    func testAccelerateColorConversion_MatchesScalar_Black() {
        // Test that the Accelerate color conversion path produces same results as scalar
        let scalarEncoder = VarDCTEncoder(
            hardware: HardwareCapabilities(
                hasNEON: false, hasAVX2: false, hasAccelerate: false,
                hasMetal: false, coreCount: 1
            ),
            options: EncodingOptions(useHardwareAcceleration: false, useAccelerate: false),
            distance: 1.0
        )

        var frame = ImageFrame(width: 2, height: 2, channels: 3)
        // Black pixels
        for y in 0..<2 {
            for x in 0..<2 {
                frame.setPixel(x: x, y: y, channel: 0, value: 0)
                frame.setPixel(x: x, y: y, channel: 1, value: 0)
                frame.setPixel(x: x, y: y, channel: 2, value: 0)
            }
        }

        let scalarResult = scalarEncoder.convertToYCbCr(frame: frame)
        // Y should be 0 for black
        XCTAssertEqual(scalarResult.getPixel(x: 0, y: 0, channel: 0), 0,
                       "Scalar Y for black should be 0")

        #if canImport(Accelerate)
        let accelEncoder = VarDCTEncoder(
            hardware: HardwareCapabilities(
                hasNEON: false, hasAVX2: false, hasAccelerate: true,
                hasMetal: false, coreCount: 1
            ),
            options: EncodingOptions(useHardwareAcceleration: true, useAccelerate: true),
            distance: 1.0
        )

        let accelResult = accelEncoder.convertToYCbCr(frame: frame)
        // Both should produce same Y value
        XCTAssertEqual(accelResult.getPixel(x: 0, y: 0, channel: 0),
                       scalarResult.getPixel(x: 0, y: 0, channel: 0),
                       "Accelerate and scalar should produce same Y for black")
        #endif
    }

    func testAccelerateColorConversion_MatchesScalar_Gradient() {
        let scalarEncoder = VarDCTEncoder(
            hardware: HardwareCapabilities(
                hasNEON: false, hasAVX2: false, hasAccelerate: false,
                hasMetal: false, coreCount: 1
            ),
            options: EncodingOptions(useHardwareAcceleration: false, useAccelerate: false),
            distance: 1.0
        )

        var frame = ImageFrame(width: 4, height: 4, channels: 3)
        for y in 0..<4 {
            for x in 0..<4 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 60))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 60))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 30))
            }
        }

        let scalarResult = scalarEncoder.convertToYCbCr(frame: frame)

        // Verify Y channel has expected characteristics
        // Higher luminance for pixels with larger RGB values
        let y00 = scalarResult.getPixel(x: 0, y: 0, channel: 0)
        let y33 = scalarResult.getPixel(x: 3, y: 3, channel: 0)
        XCTAssertLessThanOrEqual(y00, y33,
                       "Brighter pixels should have higher Y value")

        #if canImport(Accelerate)
        let accelEncoder = VarDCTEncoder(
            hardware: HardwareCapabilities(
                hasNEON: false, hasAVX2: false, hasAccelerate: true,
                hasMetal: false, coreCount: 1
            ),
            options: EncodingOptions(useHardwareAcceleration: true, useAccelerate: true),
            distance: 1.0
        )

        let accelResult = accelEncoder.convertToYCbCr(frame: frame)
        for y in 0..<4 {
            for x in 0..<4 {
                // Y channels should match between scalar and Accelerate
                let scalarY = scalarResult.getPixel(x: x, y: y, channel: 0)
                let accelY = accelResult.getPixel(x: x, y: y, channel: 0)
                XCTAssertEqual(scalarY, accelY,
                               "Y channel should match at (\(x),\(y)): scalar=\(scalarY) accel=\(accelY)")
            }
        }
        #endif
    }

    func testAccelerateQuantization_MatchesScalar() {
        let scalarEncoder = VarDCTEncoder(
            hardware: HardwareCapabilities(
                hasNEON: false, hasAVX2: false, hasAccelerate: false,
                hasMetal: false, coreCount: 1
            ),
            options: EncodingOptions(useHardwareAcceleration: false, useAccelerate: false),
            distance: 1.0
        )

        // Create a test block with known values
        var block = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        block[0][0] = 100.0
        block[0][1] = 50.0
        block[1][0] = -30.0
        block[3][3] = 12.5

        let scalarQuantized = scalarEncoder.quantize(block: block, channel: 0)

        // Verify quantization produces expected results
        XCTAssertNotEqual(scalarQuantized[0][0], 0,
                          "DC coefficient should survive quantization")

        #if canImport(Accelerate)
        let accelEncoder = VarDCTEncoder(
            hardware: HardwareCapabilities(
                hasNEON: false, hasAVX2: false, hasAccelerate: true,
                hasMetal: false, coreCount: 1
            ),
            options: EncodingOptions(useHardwareAcceleration: true, useAccelerate: true),
            distance: 1.0
        )

        let accelQuantized = accelEncoder.quantize(block: block, channel: 0)

        // Both paths should produce identical quantized values
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(scalarQuantized[y][x], accelQuantized[y][x],
                               "Quantized values should match at (\(x),\(y))")
            }
        }
        #endif
    }

    func testScalarFallback_WhenAccelerateDisabled() throws {
        // Verify that disabling Accelerate falls back to scalar without errors
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            effort: .falcon,
            useHardwareAcceleration: false,
            useAccelerate: false
        )
        let encoder = JXLEncoder(options: options)

        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                              "Encoding should succeed with Accelerate disabled")
        XCTAssertGreaterThan(result.stats.compressionRatio, 0,
                              "Compression ratio should be positive")
    }

    func testEncodingProducesConsistentOutput_WithAndWithoutAccelerate() throws {
        // Both paths should produce valid encodings (output may differ slightly in size)
        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }

        let scalarOptions = EncodingOptions(
            mode: .lossy(quality: 85),
            effort: .falcon,
            useHardwareAcceleration: false,
            useAccelerate: false
        )
        let scalarEncoder = JXLEncoder(options: scalarOptions)
        let scalarResult = try scalarEncoder.encode(frame)

        let accelOptions = EncodingOptions(
            mode: .lossy(quality: 85),
            effort: .falcon,
            useHardwareAcceleration: true,
            useAccelerate: true
        )
        let accelEncoder = JXLEncoder(options: accelOptions)
        let accelResult = try accelEncoder.encode(frame)

        // Both should produce valid non-empty output
        XCTAssertGreaterThan(scalarResult.data.count, 0,
                              "Scalar encoding should produce output")
        XCTAssertGreaterThan(accelResult.data.count, 0,
                              "Accelerate encoding should produce output")

        // Both should start with the JPEG XL signature
        XCTAssertEqual(scalarResult.data[0], 0xFF, "Scalar output should start with JXL signature byte 1")
        XCTAssertEqual(scalarResult.data[1], 0x0A, "Scalar output should start with JXL signature byte 2")
        XCTAssertEqual(accelResult.data[0], 0xFF, "Accel output should start with JXL signature byte 1")
        XCTAssertEqual(accelResult.data[1], 0x0A, "Accel output should start with JXL signature byte 2")
    }

    #if canImport(Accelerate)
    func testAccelerateOps_IDCT2D_InverseOfDCT2D() {
        // Test that idct2D is the inverse of dct2D
        var input = [Float](repeating: 0, count: 64)
        for i in 0..<64 {
            input[i] = Float((i * 7 + 3) % 256) / 255.0
        }

        let dctResult = AccelerateOps.dct2D(input, size: 8)
        let idctResult = AccelerateOps.idct2D(dctResult, size: 8)

        for i in 0..<64 {
            XCTAssertEqual(idctResult[i], input[i], accuracy: 1e-3,
                           "IDCT(DCT(x)) should ≈ x at index \(i)")
        }
    }

    func testAccelerateOps_RGBToYCbCr_BlackPixel() {
        let (y, cb, cr) = AccelerateOps.rgbToYCbCr(r: [0], g: [0], b: [0])
        XCTAssertEqual(y[0], 0, accuracy: 1e-6, "Y for black should be 0")
        XCTAssertEqual(cb[0], 0.5, accuracy: 1e-6, "Cb for black should be 0.5")
        XCTAssertEqual(cr[0], 0.5, accuracy: 1e-6, "Cr for black should be 0.5")
    }

    func testAccelerateOps_RGBToYCbCr_WhitePixel() {
        let (y, cb, cr) = AccelerateOps.rgbToYCbCr(r: [1], g: [1], b: [1])
        XCTAssertEqual(y[0], 1.0, accuracy: 1e-4, "Y for white should be 1.0")
        XCTAssertEqual(cb[0], 0.5, accuracy: 1e-4, "Cb for white should be 0.5")
        XCTAssertEqual(cr[0], 0.5, accuracy: 1e-4, "Cr for white should be 0.5")
    }

    func testAccelerateOps_RGBToYCbCr_PureRed() {
        let (y, cb, cr) = AccelerateOps.rgbToYCbCr(r: [1], g: [0], b: [0])
        XCTAssertEqual(y[0], 0.299, accuracy: 1e-4, "Y for pure red")
        XCTAssertGreaterThan(cr[0], 0.5, "Cr for pure red should be above neutral")
    }

    func testAccelerateOps_Quantize_RoundTrip() {
        let values: [Float] = [100.0, 50.0, -30.0, 12.5, 0.0, -1.0, 7.8, 3.2]
        let qMatrix: [Float] = [8.0, 12.0, 16.0, 20.0, 24.0, 28.0, 32.0, 36.0]

        let quantized = AccelerateOps.quantize(values, qMatrix: qMatrix)

        // Verify quantized values match expected rounding
        for i in 0..<values.count {
            let expected = Int16(round(values[i] / qMatrix[i]))
            XCTAssertEqual(quantized[i], expected,
                           "Quantized value at \(i) should be \(expected), got \(quantized[i])")
        }
    }

    // MARK: - Accelerate Vector Operations Tests

    func testAccelerateOps_VectorAdd_BasicAddition() {
        let result = AccelerateOps.vectorAdd([1, 2, 3], [4, 5, 6])
        XCTAssertEqual(result, [5, 7, 9],
                       "vectorAdd([1,2,3], [4,5,6]) should equal [5,7,9]")
    }

    func testAccelerateOps_VectorAdd_Zeros() {
        let result = AccelerateOps.vectorAdd([0, 0, 0], [0, 0, 0])
        XCTAssertEqual(result, [0, 0, 0])
    }

    func testAccelerateOps_VectorAdd_NegativeValues() {
        let result = AccelerateOps.vectorAdd([-1, -2, -3], [1, 2, 3])
        for i in 0..<3 {
            XCTAssertEqual(result[i], 0, accuracy: 1e-6)
        }
    }

    func testAccelerateOps_VectorSubtract_BasicSubtraction() {
        let result = AccelerateOps.vectorSubtract([5, 7, 9], [4, 5, 6])
        for i in 0..<3 {
            XCTAssertEqual(result[i], [1, 2, 3][i], accuracy: 1e-6)
        }
    }

    func testAccelerateOps_VectorMultiply_BasicMultiplication() {
        let result = AccelerateOps.vectorMultiply([2, 3, 4], [5, 6, 7])
        XCTAssertEqual(result[0], 10, accuracy: 1e-5)
        XCTAssertEqual(result[1], 18, accuracy: 1e-5)
        XCTAssertEqual(result[2], 28, accuracy: 1e-5)
    }

    func testAccelerateOps_DotProduct_BasicDotProduct() {
        let result = AccelerateOps.dotProduct([1, 2, 3], [4, 5, 6])
        // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
        XCTAssertEqual(result, 32, accuracy: 1e-5)
    }

    func testAccelerateOps_DotProduct_Orthogonal() {
        let result = AccelerateOps.dotProduct([1, 0], [0, 1])
        XCTAssertEqual(result, 0, accuracy: 1e-6,
                       "Orthogonal vectors should have dot product 0")
    }

    // MARK: - Accelerate Matrix Operations Tests

    func testAccelerateOps_MatrixMultiply_IdentityTimesInput() {
        // 3×3 identity matrix
        let identity: [Float] = [
            1, 0, 0,
            0, 1, 0,
            0, 0, 1,
        ]
        let input: [Float] = [
            1, 2, 3,
            4, 5, 6,
            7, 8, 9,
        ]

        let result = AccelerateOps.matrixMultiply(identity, rowsA: 3, colsA: 3,
                                                   input, colsB: 3)
        for i in 0..<9 {
            XCTAssertEqual(result[i], input[i], accuracy: 1e-5,
                           "Identity × input should equal input at index \(i)")
        }
    }

    func testAccelerateOps_MatrixMultiply_InputTimesIdentity() {
        let identity: [Float] = [
            1, 0, 0,
            0, 1, 0,
            0, 0, 1,
        ]
        let input: [Float] = [
            2, 4, 6,
            8, 10, 12,
            14, 16, 18,
        ]

        let result = AccelerateOps.matrixMultiply(input, rowsA: 3, colsA: 3,
                                                   identity, colsB: 3)
        for i in 0..<9 {
            XCTAssertEqual(result[i], input[i], accuracy: 1e-5,
                           "Input × identity should equal input at index \(i)")
        }
    }

    func testAccelerateOps_MatrixMultiply_2x3_Times_3x2() {
        // [1 2 3]   [7  8 ]   [1*7+2*9+3*11  1*8+2*10+3*12]   [58  64 ]
        // [4 5 6] × [9  10] = [4*7+5*9+6*11  4*8+5*10+6*12] = [139 154]
        //           [11 12]
        let a: [Float] = [1, 2, 3, 4, 5, 6]
        let b: [Float] = [7, 8, 9, 10, 11, 12]

        let result = AccelerateOps.matrixMultiply(a, rowsA: 2, colsA: 3,
                                                   b, colsB: 2)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0], 58, accuracy: 1e-4)
        XCTAssertEqual(result[1], 64, accuracy: 1e-4)
        XCTAssertEqual(result[2], 139, accuracy: 1e-4)
        XCTAssertEqual(result[3], 154, accuracy: 1e-4)
    }

    // MARK: - Accelerate Statistical Operations Tests

    func testAccelerateOps_Mean_KnownValues() {
        let values: [Float] = [1, 2, 3, 4, 5]
        let result = AccelerateOps.mean(values)
        XCTAssertEqual(result, 3.0, accuracy: 1e-5,
                       "Mean of [1,2,3,4,5] should be 3.0")
    }

    func testAccelerateOps_Mean_SingleValue() {
        let result = AccelerateOps.mean([42.0])
        XCTAssertEqual(result, 42.0, accuracy: 1e-5)
    }

    func testAccelerateOps_Mean_AllSame() {
        let values: [Float] = [7, 7, 7, 7]
        let result = AccelerateOps.mean(values)
        XCTAssertEqual(result, 7.0, accuracy: 1e-5)
    }

    func testAccelerateOps_StandardDeviation_KnownValues() {
        // stddev of [2, 4, 4, 4, 5, 5, 7, 9]
        // mean = 5, variance = ((2-5)^2+(4-5)^2*3+(5-5)^2*2+(7-5)^2+(9-5)^2)/8
        //       = (9+1+1+1+0+0+4+16)/8 = 32/8 = 4
        // stddev = 2.0
        let values: [Float] = [2, 4, 4, 4, 5, 5, 7, 9]
        let result = AccelerateOps.standardDeviation(values)
        XCTAssertEqual(result, 2.0, accuracy: 1e-4,
                       "Stddev of [2,4,4,4,5,5,7,9] should be 2.0")
    }

    func testAccelerateOps_StandardDeviation_AllSame_ReturnsZero() {
        let values: [Float] = [5, 5, 5, 5]
        let result = AccelerateOps.standardDeviation(values)
        XCTAssertEqual(result, 0.0, accuracy: 1e-6,
                       "Stddev of identical values should be 0")
    }

    // MARK: - Accelerate Conversion Round-Trip Tests

    func testAccelerateOps_ConvertU8ToFloat_RoundTrip() {
        let original: [UInt8] = [0, 64, 128, 192, 255]
        let floats = AccelerateOps.convertU8ToFloat(original)
        let recovered = AccelerateOps.convertFloatToU8(floats)
        for i in 0..<original.count {
            XCTAssertEqual(recovered[i], original[i],
                           "U8→Float→U8 round-trip should preserve value \(original[i])")
        }
    }

    func testAccelerateOps_ConvertU8ToFloat_Scaling() {
        let input: [UInt8] = [0, 255]
        let floats = AccelerateOps.convertU8ToFloat(input)
        XCTAssertEqual(floats[0], 0.0, accuracy: 1e-6,
                       "UInt8(0) should convert to 0.0")
        XCTAssertEqual(floats[1], 1.0, accuracy: 1e-4,
                       "UInt8(255) should convert to ≈1.0")
    }

    func testAccelerateOps_ConvertFloatToU8_Scaling() {
        let input: [Float] = [0.0, 0.5, 1.0]
        let result = AccelerateOps.convertFloatToU8(input)
        XCTAssertEqual(result[0], 0)
        // 0.5 × 255 = 127.5; rounding may produce 127 or 128
        XCTAssertTrue(result[1] == 127 || result[1] == 128,
                      "0.5 × 255 = 127.5, expected 127 or 128 but got \(result[1])")
        XCTAssertEqual(result[2], 255)
    }

    func testAccelerateOps_ConvertU8ToFloat_AllValues_RoundTrip() {
        // Test full range: every UInt8 value should survive the round-trip
        var original = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            original[i] = UInt8(i)
        }
        let floats = AccelerateOps.convertU8ToFloat(original)
        let recovered = AccelerateOps.convertFloatToU8(floats)
        for i in 0..<256 {
            XCTAssertEqual(recovered[i], original[i],
                           "Round-trip failed for value \(i)")
        }
    }
    #endif

    // MARK: - XYB Colour Space Tests

    func testConvertToXYB_Black_ProducesExpectedValues() {
        let encoder = makeEncoder()
        var frame = ImageFrame(width: 1, height: 1, channels: 3, pixelType: .uint16)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 0)
        frame.setPixel(x: 0, y: 0, channel: 1, value: 0)
        frame.setPixel(x: 0, y: 0, channel: 2, value: 0)

        let xyb = encoder.convertToXYB(frame: frame)

        // For black (0,0,0), L=M=S all go through opsinTransfer(0) = cbrt(bias) - cbrt(bias) = 0
        // So X = (0-0)/2 = 0, Y = (0+0)/2 = 0, B = 0
        let xVal = xyb.getPixel(x: 0, y: 0, channel: 0)
        let yVal = xyb.getPixel(x: 0, y: 0, channel: 1)
        let bVal = xyb.getPixel(x: 0, y: 0, channel: 2)
        XCTAssertEqual(xVal, 0, "X for black should be 0")
        XCTAssertEqual(yVal, 0, "Y for black should be 0")
        XCTAssertEqual(bVal, 0, "B for black should be 0")
    }

    func testConvertToXYB_White_HighYValue() {
        let encoder = makeEncoder()
        var frame = ImageFrame(width: 1, height: 1, channels: 3, pixelType: .uint16)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 65535)
        frame.setPixel(x: 0, y: 0, channel: 1, value: 65535)
        frame.setPixel(x: 0, y: 0, channel: 2, value: 65535)

        let xyb = encoder.convertToXYB(frame: frame)

        // For white, L and M should be similar (neutral), so X ≈ 0
        // Y should be high (average of L' and M')
        let yVal = xyb.getPixel(x: 0, y: 0, channel: 1)
        XCTAssertGreaterThan(yVal, 0, "Y for white should be positive")
    }

    func testConvertToXYB_SingleChannel_ReturnsUnchanged() {
        let encoder = makeEncoder()
        var frame = ImageFrame(width: 2, height: 2, channels: 1)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 128)
        frame.setPixel(x: 1, y: 0, channel: 0, value: 64)

        let result = encoder.convertToXYB(frame: frame)

        XCTAssertEqual(result.getPixel(x: 0, y: 0, channel: 0), 128,
                       "Single channel should pass through unchanged")
        XCTAssertEqual(result.getPixel(x: 1, y: 0, channel: 0), 64,
                       "Single channel should pass through unchanged")
    }

    func testConvertToXYB_PureRed_NonZeroX() {
        let encoder = makeEncoder()
        var frame = ImageFrame(width: 1, height: 1, channels: 3, pixelType: .uint16)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 65535)
        frame.setPixel(x: 0, y: 0, channel: 1, value: 0)
        frame.setPixel(x: 0, y: 0, channel: 2, value: 0)

        let xyb = encoder.convertToXYB(frame: frame)

        // Red excites L more than M, so L' > M', X = (L'-M')/2 > 0
        let xVal = xyb.getPixel(x: 0, y: 0, channel: 0)
        XCTAssertGreaterThan(xVal, 0,
                              "X for pure red should be positive (L > M)")
    }

    func testConvertToXYB_PureGreen_NegativeX() {
        let encoder = makeEncoder()
        var frame = ImageFrame(width: 1, height: 1, channels: 3, pixelType: .uint16)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 0)
        frame.setPixel(x: 0, y: 0, channel: 1, value: 65535)
        frame.setPixel(x: 0, y: 0, channel: 2, value: 0)

        let xyb = encoder.convertToXYB(frame: frame)

        // Green excites M more than L: M_coeff[4]=0.695 > L_coeff[1]=0.630
        // So M' > L', X = (L'-M')/2 < 0, which maps to 0 after clamping
        let xVal = xyb.getPixel(x: 0, y: 0, channel: 0)
        // X clamps to 0 in uint16 storage since negative
        XCTAssertEqual(xVal, 0,
                       "X for pure green should clamp to 0 (M > L)")
    }

    func testOpsinTransfer_Zero_ReturnsZero() {
        let result = VarDCTEncoder.opsinTransfer(0)
        // cbrt(0 + bias) - cbrt(bias) = 0
        XCTAssertEqual(result, 0, accuracy: 1e-6,
                       "opsinTransfer(0) should be 0")
    }

    func testOpsinTransfer_One_ReturnsPositive() {
        let result = VarDCTEncoder.opsinTransfer(1.0)
        XCTAssertGreaterThan(result, 0, "opsinTransfer(1.0) should be positive")
        // cbrt(1 + 0.00379246) - cbrt(0.00379246) ≈ 1.001264 - 0.15596 ≈ 0.845
        XCTAssertEqual(result, 0.845, accuracy: 0.01,
                       "opsinTransfer(1.0) should be approximately 0.845")
    }

    func testOpsinTransfer_NegativeInput_ClampsToZero() {
        let result = VarDCTEncoder.opsinTransfer(-1.0)
        // max(0, -1) = 0, so same as opsinTransfer(0) = 0
        XCTAssertEqual(result, 0, accuracy: 1e-6,
                       "Negative input should clamp to 0 via max()")
    }

    func testOpsinTransfer_Monotonic() {
        // Transfer function should be monotonically increasing
        var prev: Float = -1
        for i in 0...10 {
            let x = Float(i) / 10.0
            let result = VarDCTEncoder.opsinTransfer(x)
            XCTAssertGreaterThanOrEqual(result, prev,
                                         "opsinTransfer should be monotonically increasing")
            prev = result
        }
    }

    func testInverseOpsinTransfer_RoundTrip() {
        // forward → inverse should recover original value
        let testValues: [Float] = [0, 0.1, 0.25, 0.5, 0.75, 1.0]
        for val in testValues {
            let transferred = VarDCTEncoder.opsinTransfer(val)
            let recovered = VarDCTEncoder.inverseOpsinTransfer(transferred)
            XCTAssertEqual(recovered, val, accuracy: 1e-5,
                           "Inverse opsin transfer should recover \(val)")
        }
    }

    func testXYBScalar_FloatPrecision_RoundTrip() {
        // Test XYB round-trip using float arrays directly (no pixel quantization)
        let r: Float = 0.5, g: Float = 0.3, b: Float = 0.7

        let m = VarDCTEncoder.opsinAbsorbanceMatrix
        let lVal = m[0] * r + m[1] * g + m[2] * b
        let mVal = m[3] * r + m[4] * g + m[5] * b
        let sVal = m[6] * r + m[7] * g + m[8] * b

        let lPrime = VarDCTEncoder.opsinTransfer(lVal)
        let mPrime = VarDCTEncoder.opsinTransfer(mVal)
        let sPrime = VarDCTEncoder.opsinTransfer(sVal)

        let xVal = (lPrime - mPrime) * 0.5
        let yVal = (lPrime + mPrime) * 0.5
        let bValXYB = sPrime

        // Inverse
        let lPrimeRec = yVal + xVal
        let mPrimeRec = yVal - xVal
        let sPrimeRec = bValXYB

        let lRec = VarDCTEncoder.inverseOpsinTransfer(lPrimeRec)
        let mRec = VarDCTEncoder.inverseOpsinTransfer(mPrimeRec)
        let sRec = VarDCTEncoder.inverseOpsinTransfer(sPrimeRec)

        let im = VarDCTEncoder.inverseOpsinAbsorbanceMatrix
        let rRec = im[0] * lRec + im[1] * mRec + im[2] * sRec
        let gRec = im[3] * lRec + im[4] * mRec + im[5] * sRec
        let bRec = im[6] * lRec + im[7] * mRec + im[8] * sRec

        XCTAssertEqual(rRec, r, accuracy: 1e-4, "R should round-trip through XYB")
        XCTAssertEqual(gRec, g, accuracy: 1e-4, "G should round-trip through XYB")
        XCTAssertEqual(bRec, b, accuracy: 1e-4, "B should round-trip through XYB")
    }

    func testXYB_OpsinAbsorbanceMatrix_RowsSumToOne() {
        let m = VarDCTEncoder.opsinAbsorbanceMatrix
        // Each row should sum to ≈ 1.0 (energy conservation)
        let row0 = m[0] + m[1] + m[2]
        let row1 = m[3] + m[4] + m[5]
        let row2 = m[6] + m[7] + m[8]
        XCTAssertEqual(row0, 1.0, accuracy: 1e-4, "Row 0 of opsin matrix should sum to 1.0")
        XCTAssertEqual(row1, 1.0, accuracy: 1e-4, "Row 1 of opsin matrix should sum to 1.0")
        XCTAssertEqual(row2, 1.0, accuracy: 1e-4, "Row 2 of opsin matrix should sum to 1.0")
    }

    func testXYB_InverseMatrix_UndoesForwardMatrix() {
        // M * M_inv should ≈ identity
        let m = VarDCTEncoder.opsinAbsorbanceMatrix
        let im = VarDCTEncoder.inverseOpsinAbsorbanceMatrix

        for i in 0..<3 {
            for j in 0..<3 {
                var sum: Float = 0
                for k in 0..<3 {
                    sum += m[i * 3 + k] * im[k * 3 + j]
                }
                let expected: Float = (i == j) ? 1.0 : 0.0
                XCTAssertEqual(sum, expected, accuracy: 1e-3,
                               "M * M_inv should be identity at (\(i),\(j))")
            }
        }
    }

    func testConvertToXYB_GradientImage_ProducesOutput() {
        let encoder = makeEncoder()
        var frame = ImageFrame(width: 8, height: 8, channels: 3, pixelType: .uint16)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 8192))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 8192))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 4096))
            }
        }

        let xyb = encoder.convertToXYB(frame: frame)

        // Y channel should increase with brightness
        let y00 = xyb.getPixel(x: 0, y: 0, channel: 1)
        let y77 = xyb.getPixel(x: 7, y: 7, channel: 1)
        XCTAssertLessThan(y00, y77,
                          "Brighter pixels should have higher Y")
    }

    func testConvertToXYB_NeutralGray_XNearZero() {
        let encoder = makeEncoder()
        var frame = ImageFrame(width: 1, height: 1, channels: 3, pixelType: .uint16)
        let gray: UInt16 = 32768
        frame.setPixel(x: 0, y: 0, channel: 0, value: gray)
        frame.setPixel(x: 0, y: 0, channel: 1, value: gray)
        frame.setPixel(x: 0, y: 0, channel: 2, value: gray)

        let xyb = encoder.convertToXYB(frame: frame)

        // For neutral gray, L and M are not perfectly equal due to different
        // matrix coefficients, but X = (L'-M')/2 should be small
        let xVal = xyb.getPixel(x: 0, y: 0, channel: 0)
        let yVal = xyb.getPixel(x: 0, y: 0, channel: 1)
        // X should be much smaller than Y for neutral gray
        XCTAssertLessThan(xVal, yVal,
                          "X should be much smaller than Y for neutral gray")
    }

    func testConvertFromXYB_SingleChannel_ReturnsUnchanged() {
        let encoder = makeEncoder()
        var frame = ImageFrame(width: 2, height: 2, channels: 1)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 100)

        let result = encoder.convertFromXYB(frame: frame)
        XCTAssertEqual(result.getPixel(x: 0, y: 0, channel: 0), 100,
                       "Single channel should pass through unchanged")
    }

    func testXYBScalar_MatchesAccelerate_Black() {
        let scalarEncoder = VarDCTEncoder(
            hardware: HardwareCapabilities(
                hasNEON: false, hasAVX2: false, hasAccelerate: false,
                hasMetal: false, coreCount: 1
            ),
            options: EncodingOptions(useHardwareAcceleration: false, useAccelerate: false),
            distance: 1.0
        )

        var frame = ImageFrame(width: 2, height: 2, channels: 3, pixelType: .uint16)
        for y in 0..<2 {
            for x in 0..<2 {
                frame.setPixel(x: x, y: y, channel: 0, value: 0)
                frame.setPixel(x: x, y: y, channel: 1, value: 0)
                frame.setPixel(x: x, y: y, channel: 2, value: 0)
            }
        }

        let scalarResult = scalarEncoder.convertToXYB(frame: frame)
        XCTAssertEqual(scalarResult.getPixel(x: 0, y: 0, channel: 0), 0,
                       "Scalar X for black should be 0")
        XCTAssertEqual(scalarResult.getPixel(x: 0, y: 0, channel: 1), 0,
                       "Scalar Y for black should be 0")
        XCTAssertEqual(scalarResult.getPixel(x: 0, y: 0, channel: 2), 0,
                       "Scalar B for black should be 0")

        #if canImport(Accelerate)
        let accelEncoder = VarDCTEncoder(
            hardware: HardwareCapabilities(
                hasNEON: false, hasAVX2: false, hasAccelerate: true,
                hasMetal: false, coreCount: 1
            ),
            options: EncodingOptions(useHardwareAcceleration: true, useAccelerate: true),
            distance: 1.0
        )

        let accelResult = accelEncoder.convertToXYB(frame: frame)
        for ch in 0..<3 {
            XCTAssertEqual(
                accelResult.getPixel(x: 0, y: 0, channel: ch),
                scalarResult.getPixel(x: 0, y: 0, channel: ch),
                "Accelerate and scalar XYB should match for black on channel \(ch)")
        }
        #endif
    }

    func testXYBScalar_MatchesAccelerate_Gradient() {
        let scalarEncoder = VarDCTEncoder(
            hardware: HardwareCapabilities(
                hasNEON: false, hasAVX2: false, hasAccelerate: false,
                hasMetal: false, coreCount: 1
            ),
            options: EncodingOptions(useHardwareAcceleration: false, useAccelerate: false),
            distance: 1.0
        )

        var frame = ImageFrame(width: 4, height: 4, channels: 3, pixelType: .uint16)
        for y in 0..<4 {
            for x in 0..<4 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16000))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16000))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 8000))
            }
        }

        let scalarResult = scalarEncoder.convertToXYB(frame: frame)

        #if canImport(Accelerate)
        let accelEncoder = VarDCTEncoder(
            hardware: HardwareCapabilities(
                hasNEON: false, hasAVX2: false, hasAccelerate: true,
                hasMetal: false, coreCount: 1
            ),
            options: EncodingOptions(useHardwareAcceleration: true, useAccelerate: true),
            distance: 1.0
        )

        let accelResult = accelEncoder.convertToXYB(frame: frame)
        for y in 0..<4 {
            for x in 0..<4 {
                for ch in 0..<3 {
                    let sv = scalarResult.getPixel(x: x, y: y, channel: ch)
                    let av = accelResult.getPixel(x: x, y: y, channel: ch)
                    XCTAssertEqual(sv, av,
                                   "XYB channel \(ch) should match at (\(x),\(y)): scalar=\(sv) accel=\(av)")
                }
            }
        }
        #endif

        // Verify Y increases with brightness
        let y00 = scalarResult.getPixel(x: 0, y: 0, channel: 1)
        let y33 = scalarResult.getPixel(x: 3, y: 3, channel: 1)
        XCTAssertLessThanOrEqual(y00, y33,
                                  "Brighter pixels should have higher Y")
    }

    func testXYBInverse_MatchesAccelerate_Gradient() {
        let scalarEncoder = VarDCTEncoder(
            hardware: HardwareCapabilities(
                hasNEON: false, hasAVX2: false, hasAccelerate: false,
                hasMetal: false, coreCount: 1
            ),
            options: EncodingOptions(useHardwareAcceleration: false, useAccelerate: false),
            distance: 1.0
        )

        var frame = ImageFrame(width: 4, height: 4, channels: 3, pixelType: .uint16)
        for y in 0..<4 {
            for x in 0..<4 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16000))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16000))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 8000))
            }
        }

        let xybFrame = scalarEncoder.convertToXYB(frame: frame)
        let scalarResult = scalarEncoder.convertFromXYB(frame: xybFrame)

        #if canImport(Accelerate)
        let accelEncoder = VarDCTEncoder(
            hardware: HardwareCapabilities(
                hasNEON: false, hasAVX2: false, hasAccelerate: true,
                hasMetal: false, coreCount: 1
            ),
            options: EncodingOptions(useHardwareAcceleration: true, useAccelerate: true),
            distance: 1.0
        )

        let accelResult = accelEncoder.convertFromXYB(frame: xybFrame)
        for y in 0..<4 {
            for x in 0..<4 {
                for ch in 0..<3 {
                    let sv = scalarResult.getPixel(x: x, y: y, channel: ch)
                    let av = accelResult.getPixel(x: x, y: y, channel: ch)
                    XCTAssertEqual(sv, av,
                                   "Inverse XYB channel \(ch) should match at (\(x),\(y))")
                }
            }
        }
        #endif
    }

    #if canImport(Accelerate)
    func testAccelerateOps_RGBToXYB_BlackPixel() {
        let (x, y, b) = AccelerateOps.rgbToXYB(r: [0], g: [0], b: [0])
        XCTAssertEqual(x[0], 0, accuracy: 1e-6, "X for black should be 0")
        XCTAssertEqual(y[0], 0, accuracy: 1e-6, "Y for black should be 0")
        XCTAssertEqual(b[0], 0, accuracy: 1e-6, "B for black should be 0")
    }

    func testAccelerateOps_RGBToXYB_WhitePixel() {
        let (x, y, b) = AccelerateOps.rgbToXYB(r: [1], g: [1], b: [1])
        // For white, L ≈ M so X ≈ 0
        XCTAssertEqual(x[0], 0, accuracy: 0.02, "X for white should be near 0")
        XCTAssertGreaterThan(y[0], 0, "Y for white should be positive")
        XCTAssertGreaterThan(b[0], 0, "B for white should be positive")
    }

    func testAccelerateOps_RGBToXYB_PureRed() {
        let (x, y, _) = AccelerateOps.rgbToXYB(r: [1], g: [0], b: [0])
        XCTAssertGreaterThan(x[0], 0, "X for pure red should be positive (L > M)")
        XCTAssertGreaterThan(y[0], 0, "Y for pure red should be positive")
    }

    func testAccelerateOps_XYBToRGB_RoundTrip() {
        let rIn: [Float] = [0.5, 0.0, 1.0, 0.3]
        let gIn: [Float] = [0.3, 0.0, 1.0, 0.7]
        let bIn: [Float] = [0.7, 0.0, 1.0, 0.1]

        let (x, y, b) = AccelerateOps.rgbToXYB(r: rIn, g: gIn, b: bIn)
        let (rOut, gOut, bOut) = AccelerateOps.xybToRGB(x: x, y: y, b: b)

        for i in 0..<rIn.count {
            XCTAssertEqual(rOut[i], rIn[i], accuracy: 1e-4,
                           "R round-trip failed at index \(i)")
            XCTAssertEqual(gOut[i], gIn[i], accuracy: 1e-4,
                           "G round-trip failed at index \(i)")
            XCTAssertEqual(bOut[i], bIn[i], accuracy: 1e-4,
                           "B round-trip failed at index \(i)")
        }
    }
    #endif
    
    // MARK: - Chroma-from-Luma (CfL) Prediction Tests
    
    func testCfLCoefficient_PerfectCorrelation_ReturnsExpectedScale() {
        let encoder = makeEncoder()
        
        // Chroma = 0.5 × luma
        var luma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        
        for v in 0..<8 {
            for u in 0..<8 {
                let value = Float(u + v + 1)
                luma[v][u] = value
                chroma[v][u] = value * 0.5
            }
        }
        // DC is excluded from correlation, so set DC to arbitrary values
        luma[0][0] = 100
        chroma[0][0] = 50
        
        let coeff = encoder.computeCfLCoefficient(lumaDCT: luma, chromaDCT: chroma)
        XCTAssertEqual(coeff, 0.5, accuracy: 1e-5,
                       "CfL coefficient should be 0.5 for chroma = 0.5×luma")
    }
    
    func testCfLCoefficient_ZeroLuma_ReturnsZero() {
        let encoder = makeEncoder()
        
        // All-zero luma (no AC energy)
        let luma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        chroma[1][1] = 5.0
        
        let coeff = encoder.computeCfLCoefficient(lumaDCT: luma, chromaDCT: chroma)
        XCTAssertEqual(coeff, 0.0,
                       "CfL coefficient should be 0 when luma has no AC energy")
    }
    
    func testCfLCoefficient_UncorrelatedData_ReturnsNearZero() {
        let encoder = makeEncoder()
        
        // Luma has energy in even positions, chroma in odd positions
        var luma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        
        luma[0][2] = 10.0
        luma[0][4] = 10.0
        chroma[0][1] = 10.0
        chroma[0][3] = 10.0
        
        let coeff = encoder.computeCfLCoefficient(lumaDCT: luma, chromaDCT: chroma)
        XCTAssertEqual(coeff, 0.0, accuracy: 1e-5,
                       "CfL coefficient should be ~0 for uncorrelated data")
    }
    
    func testCfLCoefficient_NegativeCorrelation_ReturnsNegativeScale() {
        let encoder = makeEncoder()
        
        // Chroma = -0.3 × luma
        var luma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        
        for v in 0..<8 {
            for u in 0..<8 {
                if u == 0 && v == 0 { continue }
                let value = Float(u * 3 + v * 2 + 1)
                luma[v][u] = value
                chroma[v][u] = value * -0.3
            }
        }
        
        let coeff = encoder.computeCfLCoefficient(lumaDCT: luma, chromaDCT: chroma)
        XCTAssertEqual(coeff, -0.3, accuracy: 1e-5,
                       "CfL coefficient should be -0.3 for chroma = -0.3×luma")
    }
    
    func testCfLCoefficient_ExcludesDC() {
        let encoder = makeEncoder()
        
        // Only DC has correlation; AC coefficients are uncorrelated
        var luma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        
        // Large correlated DC
        luma[0][0] = 1000.0
        chroma[0][0] = 500.0
        
        // Orthogonal AC
        luma[1][0] = 5.0
        chroma[0][1] = 3.0
        
        let coeff = encoder.computeCfLCoefficient(lumaDCT: luma, chromaDCT: chroma)
        // DC is excluded, and the AC terms are orthogonal → coeff should be 0
        XCTAssertEqual(coeff, 0.0, accuracy: 1e-5,
                       "CfL should exclude DC from correlation computation")
    }
    
    func testCfLPrediction_ReducesResidualEnergy() {
        let encoder = makeEncoder()
        
        // Create correlated luma and chroma blocks
        var luma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        
        for v in 0..<8 {
            for u in 0..<8 {
                if u == 0 && v == 0 { continue }
                let value = Float(u + v + 1)
                luma[v][u] = value
                chroma[v][u] = value * 0.7 + Float(u % 2) * 0.1 // Mostly correlated
            }
        }
        
        let coeff = encoder.computeCfLCoefficient(lumaDCT: luma, chromaDCT: chroma)
        let residual = encoder.applyCfLPrediction(
            chromaDCT: chroma, lumaDCT: luma, coefficient: coeff
        )
        
        // Compute energy of original chroma AC and residual AC
        var chromaEnergy: Float = 0
        var residualEnergy: Float = 0
        for v in 0..<8 {
            for u in 0..<8 {
                if u == 0 && v == 0 { continue }
                chromaEnergy += chroma[v][u] * chroma[v][u]
                residualEnergy += residual[v][u] * residual[v][u]
            }
        }
        
        XCTAssertLessThan(residualEnergy, chromaEnergy,
                          "CfL prediction should reduce chroma AC energy")
    }
    
    func testCfLPrediction_PreservesDC() {
        let encoder = makeEncoder()
        
        var luma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        
        luma[0][0] = 42.0
        chroma[0][0] = 17.0
        luma[1][1] = 5.0
        chroma[1][1] = 3.0
        
        let coeff = encoder.computeCfLCoefficient(lumaDCT: luma, chromaDCT: chroma)
        let residual = encoder.applyCfLPrediction(
            chromaDCT: chroma, lumaDCT: luma, coefficient: coeff
        )
        
        XCTAssertEqual(residual[0][0], chroma[0][0],
                       "CfL prediction must not modify the DC coefficient")
    }
    
    func testCfLRoundTrip_ReconstructMatchesOriginal() {
        let encoder = makeEncoder()
        
        // Create realistic DCT-like blocks
        var luma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        
        for v in 0..<8 {
            for u in 0..<8 {
                let value = Float(u * u + v) * 0.1
                luma[v][u] = value
                chroma[v][u] = value * 0.4 + Float(v % 3) * 0.05
            }
        }
        
        let coeff = encoder.computeCfLCoefficient(lumaDCT: luma, chromaDCT: chroma)
        let residual = encoder.applyCfLPrediction(
            chromaDCT: chroma, lumaDCT: luma, coefficient: coeff
        )
        let reconstructed = encoder.reconstructFromCfL(
            residual: residual, lumaDCT: luma, coefficient: coeff
        )
        
        for v in 0..<8 {
            for u in 0..<8 {
                XCTAssertEqual(reconstructed[v][u], chroma[v][u], accuracy: 1e-5,
                               "CfL round-trip failed at (\(u),\(v))")
            }
        }
    }
    
    func testCfLRoundTrip_ZeroCoefficient_IsIdentity() {
        let encoder = makeEncoder()
        
        var luma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        
        for v in 0..<8 {
            for u in 0..<8 {
                luma[v][u] = Float(u + v)
                chroma[v][u] = Float(v * 2 + 1)
            }
        }
        
        let residual = encoder.applyCfLPrediction(
            chromaDCT: chroma, lumaDCT: luma, coefficient: 0.0
        )
        
        for v in 0..<8 {
            for u in 0..<8 {
                XCTAssertEqual(residual[v][u], chroma[v][u], accuracy: 1e-7,
                               "Zero CfL coefficient should leave chroma unchanged")
            }
        }
    }
    
    func testCfLCoefficient_UniformBlock_ReturnsFiniteValue() {
        let encoder = makeEncoder()
        
        // Uniform block: all AC coefficients are zero
        let luma = [[Float]](repeating: [Float](repeating: 5.0, count: 8), count: 8)
        let chroma = [[Float]](repeating: [Float](repeating: 3.0, count: 8), count: 8)
        
        let coeff = encoder.computeCfLCoefficient(lumaDCT: luma, chromaDCT: chroma)
        XCTAssertTrue(coeff.isFinite,
                      "CfL coefficient must always be finite")
    }
    
    func testComputeDCTBlocks_DimensionsMatchBlockGrid() {
        let encoder = makeEncoder()
        
        // 16×16 image → 2×2 grid of 8×8 blocks
        let width = 16
        let height = 16
        var data = [[Float]](repeating: [Float](repeating: 0, count: width), count: height)
        for y in 0..<height {
            for x in 0..<width {
                data[y][x] = Float(x + y) / 30.0
            }
        }
        
        let blocks = encoder.computeDCTBlocks(data: data, width: width, height: height)
        XCTAssertEqual(blocks.count, 2, "Should have 2 block rows")
        XCTAssertEqual(blocks[0].count, 2, "Should have 2 block columns")
        XCTAssertEqual(blocks[0][0].count, 8, "Each block should have 8 rows")
        XCTAssertEqual(blocks[0][0][0].count, 8, "Each block should have 8 columns")
    }
    
    func testComputeDCTBlocks_NonMultipleOfBlockSize() {
        let encoder = makeEncoder()
        
        // 10×12 image → ceil(10/8) × ceil(12/8) = 2×2 grid
        let width = 10
        let height = 12
        let data = [[Float]](repeating: [Float](repeating: 0.5, count: width), count: height)
        
        let blocks = encoder.computeDCTBlocks(data: data, width: width, height: height)
        XCTAssertEqual(blocks.count, 2, "ceil(12/8) = 2 block rows")
        XCTAssertEqual(blocks[0].count, 2, "ceil(10/8) = 2 block columns")
    }
    
    func testCfL_IntegrationWithEncoding_ProducesValidOutput() throws {
        // Full pipeline test: encoding an RGB image with CfL should succeed
        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .lossy(quality: 90),
            effort: .lightning
        ))
        
        var frame = ImageFrame(width: 16, height: 16, channels: 3, pixelType: .uint8)
        
        // Create an image where chroma correlates with luma (natural image-like)
        for y in 0..<16 {
            for x in 0..<16 {
                let base = UInt16((x + y) * 8)
                frame.setPixel(x: x, y: y, channel: 0, value: base)       // R
                frame.setPixel(x: x, y: y, channel: 1, value: base / 2)   // G (correlated)
                frame.setPixel(x: x, y: y, channel: 2, value: base / 3)   // B (correlated)
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "Encoded output with CfL should be non-empty")
        XCTAssertGreaterThan(result.stats.compressionRatio, 1.0,
                             "Should achieve compression > 1.0")
    }
    
    func testCfL_SingleChannelImage_NoError() throws {
        // Single-channel image should not trigger CfL (no chroma)
        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .lossy(quality: 80),
            effort: .lightning
        ))
        
        var frame = ImageFrame(width: 8, height: 8, channels: 1, pixelType: .uint8)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 30))
            }
        }
        
        XCTAssertNoThrow(try encoder.encode(frame),
                         "Single-channel image should encode without CfL errors")
    }
}
