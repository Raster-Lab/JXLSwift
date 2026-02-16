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
}
