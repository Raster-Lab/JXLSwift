import XCTest
@testable import JXLSwift

/// Tests for the VarDCT decoder: dequantisation, inverse DCT,
/// inverse CfL prediction, YCbCr→RGB conversion, block decoding,
/// and full encode→decode round-trips.
final class VarDCTDecoderTests: XCTestCase {

    // MARK: - Helpers

    /// Create a simple gradient frame.
    private func makeGradientFrame(
        width: Int, height: Int, channels: Int = 3
    ) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: channels
        )
        for c in 0..<channels {
            for y in 0..<height {
                for x in 0..<width {
                    let value = UInt16((x * 3 + y * 7 + c * 31) % 256)
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }
        return frame
    }

    /// Create a constant-colour frame.
    private func makeConstantFrame(
        width: Int, height: Int, channels: Int = 3,
        value: UInt16 = 128
    ) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: channels
        )
        for c in 0..<channels {
            for y in 0..<height {
                for x in 0..<width {
                    frame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }
        return frame
    }

    /// Compute PSNR between two frames.
    private func computePSNR(_ a: ImageFrame, _ b: ImageFrame) -> Double {
        var mse: Double = 0
        var count = 0
        for c in 0..<min(a.channels, b.channels) {
            for y in 0..<min(a.height, b.height) {
                for x in 0..<min(a.width, b.width) {
                    let av = Double(a.getPixel(x: x, y: y, channel: c))
                    let bv = Double(b.getPixel(x: x, y: y, channel: c))
                    mse += (av - bv) * (av - bv)
                    count += 1
                }
            }
        }
        guard count > 0 else { return 0 }
        mse /= Double(count)
        guard mse > 0 else { return 100 } // Perfect match
        let maxVal = 255.0
        return 10 * log10(maxVal * maxVal / mse)
    }

    private func makeDecoder() -> VarDCTDecoder {
        VarDCTDecoder(hardware: HardwareCapabilities.detect())
    }

    private func makeEncoder(
        distance: Float = 1.0,
        adaptive: Bool = true,
        useANS: Bool = false
    ) -> VarDCTEncoder {
        var options = EncodingOptions.fast
        options.adaptiveQuantization = adaptive
        options.useANS = useANS
        return VarDCTEncoder(
            hardware: HardwareCapabilities.detect(),
            options: options,
            distance: distance
        )
    }

    // MARK: - ZigZag Inverse Tests

    func testInverseZigzag_AllZeros_ReturnsZeroBlock() {
        let decoder = makeDecoder()
        let coefficients = [Int16](repeating: 0, count: 64)
        let block = decoder.inverseZigzag(coefficients: coefficients)

        XCTAssertEqual(block.count, 8)
        for row in block {
            XCTAssertEqual(row.count, 8)
            for val in row {
                XCTAssertEqual(val, 0)
            }
        }
    }

    func testInverseZigzag_DCOnly_PlacedAtTopLeft() {
        let decoder = makeDecoder()
        var coefficients = [Int16](repeating: 0, count: 64)
        coefficients[0] = 42
        let block = decoder.inverseZigzag(coefficients: coefficients)
        XCTAssertEqual(block[0][0], 42)
    }

    func testInverseZigzag_RoundTrip_MatchesEncoder() {
        let decoder = makeDecoder()
        let encoder = makeEncoder()

        var block = [[Int16]](
            repeating: [Int16](repeating: 0, count: 8), count: 8
        )
        for y in 0..<8 {
            for x in 0..<8 {
                block[y][x] = Int16((y * 8 + x) % 127)
            }
        }

        // Encoder zigzag scan → decoder inverse zigzag
        let scanned = encoder.zigzagScan(block: block)
        let recovered = decoder.inverseZigzag(coefficients: scanned)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(
                    recovered[y][x], block[y][x],
                    "Mismatch at (\(x), \(y))"
                )
            }
        }
    }

    // MARK: - Dequantisation Tests

    func testDequantize_InverseOfQuantize() {
        let decoder = makeDecoder()
        let encoder = makeEncoder(distance: 2.0)

        var dctBlock = [[Float]](
            repeating: [Float](repeating: 0, count: 8), count: 8
        )
        for y in 0..<8 {
            for x in 0..<8 {
                dctBlock[y][x] = Float(x + y) * 10.0
            }
        }

        let qMatrix = encoder.generateQuantizationMatrix(
            channel: 0, activity: 1.0, distance: 2.0
        )
        let quantized = encoder.quantize(
            block: dctBlock, channel: 0, activity: 1.0, distance: 2.0
        )

        let dequantized = decoder.dequantize(block: quantized, qMatrix: qMatrix)

        // Dequantized should be approximately the original
        for y in 0..<8 {
            for x in 0..<8 {
                // Tolerance is qMatrix value / 2 (rounding error)
                let tolerance = qMatrix[y][x] / 2.0
                XCTAssertEqual(
                    dequantized[y][x], dctBlock[y][x],
                    accuracy: tolerance,
                    "Dequant mismatch at (\(x), \(y))"
                )
            }
        }
    }

    func testQuantizationMatrix_MatchesEncoder() {
        let decoder = makeDecoder()
        let encoder = makeEncoder(distance: 1.5)

        let decoderMatrix = decoder.generateQuantizationMatrix(
            channel: 0, activity: 1.0, distance: 1.5
        )
        let encoderMatrix = encoder.generateQuantizationMatrix(
            channel: 0, activity: 1.0, distance: 1.5
        )

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(
                    decoderMatrix[y][x], encoderMatrix[y][x],
                    accuracy: 1e-6,
                    "QMatrix mismatch at (\(x), \(y))"
                )
            }
        }
    }

    func testQuantizationMatrix_ChromaMoreAggressive() {
        let decoder = makeDecoder()
        let lumaMatrix = decoder.generateQuantizationMatrix(
            channel: 0, activity: 1.0, distance: 1.0
        )
        let chromaMatrix = decoder.generateQuantizationMatrix(
            channel: 1, activity: 1.0, distance: 1.0
        )

        // Chroma should be 1.5× luma
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(
                    chromaMatrix[y][x], lumaMatrix[y][x] * 1.5,
                    accuracy: 1e-6
                )
            }
        }
    }

    // MARK: - Inverse DCT Tests

    func testIDCT_ConstantBlock_ReconstructsUniformValue() {
        let decoder = makeDecoder()
        let encoder = makeEncoder()

        let block = [[Float]](
            repeating: [Float](repeating: 0.5, count: 8), count: 8
        )
        let dctBlock = encoder.applyDCTScalar(block: block)
        let spatial = decoder.applyIDCTScalar(block: dctBlock)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(
                    spatial[y][x], 0.5, accuracy: 1e-4,
                    "IDCT mismatch at (\(x), \(y))"
                )
            }
        }
    }

    func testIDCT_GradientBlock_Reconstructs() {
        let decoder = makeDecoder()
        let encoder = makeEncoder()

        var block = [[Float]](
            repeating: [Float](repeating: 0, count: 8), count: 8
        )
        for y in 0..<8 {
            for x in 0..<8 {
                block[y][x] = Float(x + y) / 14.0
            }
        }

        let dctBlock = encoder.applyDCTScalar(block: block)
        let spatial = decoder.applyIDCTScalar(block: dctBlock)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(
                    spatial[y][x], block[y][x], accuracy: 1e-4,
                    "IDCT round-trip failed at (\(x), \(y))"
                )
            }
        }
    }

    // MARK: - CfL Reconstruction Tests

    func testReconstructFromCfL_UndoesPrediction() {
        let decoder = makeDecoder()
        let encoder = makeEncoder()

        // Create luma and chroma DCT blocks
        var lumaDCT = [[Float]](
            repeating: [Float](repeating: 0, count: 8), count: 8
        )
        var chromaDCT = [[Float]](
            repeating: [Float](repeating: 0, count: 8), count: 8
        )
        for v in 0..<8 {
            for u in 0..<8 {
                lumaDCT[v][u] = Float(u + v) * 0.1
                chromaDCT[v][u] = Float(u + v) * 0.05
            }
        }

        let cflCoeff = encoder.computeCfLCoefficient(
            lumaDCT: lumaDCT, chromaDCT: chromaDCT
        )
        let residual = encoder.applyCfLPrediction(
            chromaDCT: chromaDCT, lumaDCT: lumaDCT, coefficient: cflCoeff
        )
        let reconstructed = decoder.reconstructFromCfL(
            residual: residual, lumaDCT: lumaDCT, coefficient: cflCoeff
        )

        // DC is preserved (not affected by CfL)
        XCTAssertEqual(
            reconstructed[0][0], chromaDCT[0][0], accuracy: 1e-5
        )

        // AC coefficients should match original
        for v in 0..<8 {
            for u in 0..<8 {
                XCTAssertEqual(
                    reconstructed[v][u], chromaDCT[v][u], accuracy: 1e-4,
                    "CfL round-trip failed at (\(u), \(v))"
                )
            }
        }
    }

    // MARK: - YCbCr Conversion Tests

    func testConvertFromYCbCr_NeutralGrey() {
        let decoder = makeDecoder()

        // Neutral grey in unnormalized YCbCr for uint8:
        // Y=128, Cb=128 (centred), Cr=128 (centred)
        var frame = ImageFrame(
            width: 2, height: 2, channels: 3
        )
        let yVal: UInt16 = 128
        let cbVal: UInt16 = 128 // offset = 128 → actual chroma = 0
        let crVal: UInt16 = 128
        for y in 0..<2 {
            for x in 0..<2 {
                frame.setPixel(x: x, y: y, channel: 0, value: yVal)
                frame.setPixel(x: x, y: y, channel: 1, value: cbVal)
                frame.setPixel(x: x, y: y, channel: 2, value: crVal)
            }
        }

        let rgb = decoder.convertFromYCbCr(frame: frame)
        // For neutral grey, R ≈ G ≈ B ≈ Y
        for y in 0..<2 {
            for x in 0..<2 {
                let r = rgb.getPixel(x: x, y: y, channel: 0)
                let g = rgb.getPixel(x: x, y: y, channel: 1)
                let b = rgb.getPixel(x: x, y: y, channel: 2)
                XCTAssertEqual(Double(r), Double(yVal), accuracy: 5)
                XCTAssertEqual(Double(g), Double(yVal), accuracy: 5)
                XCTAssertEqual(Double(b), Double(yVal), accuracy: 5)
            }
        }
    }

    func testConvertFromYCbCr_SingleChannel_ReturnsUnchanged() {
        let decoder = makeDecoder()
        var frame = ImageFrame(
            width: 2, height: 2, channels: 1
        )
        frame.setPixel(x: 0, y: 0, channel: 0, value: 128)
        let result = decoder.convertFromYCbCr(frame: frame)
        XCTAssertEqual(result.getPixel(x: 0, y: 0, channel: 0), 128)
    }

    // MARK: - DC Prediction Tests

    func testPredictDC_FirstBlock_ReturnsZero() {
        let decoder = makeDecoder()
        let dcValues = [[Int16]](
            repeating: [Int16](repeating: 0, count: 4), count: 4
        )
        let predicted = decoder.predictDC(
            dcValues: dcValues, blockX: 0, blockY: 0
        )
        XCTAssertEqual(predicted, 0)
    }

    func testPredictDC_LeftNeighbor() {
        let decoder = makeDecoder()
        var dcValues = [[Int16]](
            repeating: [Int16](repeating: 0, count: 4), count: 4
        )
        dcValues[0][0] = 10
        let predicted = decoder.predictDC(
            dcValues: dcValues, blockX: 1, blockY: 0
        )
        XCTAssertEqual(predicted, 10)
    }

    func testPredictDC_AboveNeighbor() {
        let decoder = makeDecoder()
        var dcValues = [[Int16]](
            repeating: [Int16](repeating: 0, count: 4), count: 4
        )
        dcValues[0][0] = 20
        let predicted = decoder.predictDC(
            dcValues: dcValues, blockX: 0, blockY: 1
        )
        XCTAssertEqual(predicted, 20)
    }

    func testPredictDC_BothNeighbors_Average() {
        let decoder = makeDecoder()
        var dcValues = [[Int16]](
            repeating: [Int16](repeating: 0, count: 4), count: 4
        )
        dcValues[0][1] = 10
        dcValues[1][0] = 20
        let predicted = decoder.predictDC(
            dcValues: dcValues, blockX: 1, blockY: 1
        )
        XCTAssertEqual(predicted, 15) // (10 + 20) / 2
    }

    // MARK: - ZigZag Value Decoding Tests

    func testDecodeSignedValue_Zero() {
        let decoder = makeDecoder()
        XCTAssertEqual(decoder.decodeSignedValue(0), 0)
    }

    func testDecodeSignedValue_Positive() {
        let decoder = makeDecoder()
        XCTAssertEqual(decoder.decodeSignedValue(2), 1)
        XCTAssertEqual(decoder.decodeSignedValue(4), 2)
        XCTAssertEqual(decoder.decodeSignedValue(6), 3)
    }

    func testDecodeSignedValue_Negative() {
        let decoder = makeDecoder()
        XCTAssertEqual(decoder.decodeSignedValue(1), -1)
        XCTAssertEqual(decoder.decodeSignedValue(3), -2)
        XCTAssertEqual(decoder.decodeSignedValue(5), -3)
    }

    func testDecodeSignedValue_RoundTrip() {
        let decoder = makeDecoder()
        let encoder = makeEncoder()

        for value: Int32 in -50...50 {
            let encoded = encoder.encodeSignedValue(value)
            let decoded = decoder.decodeSignedValue(encoded)
            XCTAssertEqual(decoded, value, "Round-trip failed for \(value)")
        }
    }

    // MARK: - Full Encode → Decode Round-Trip Tests

    func testRoundTrip_ConstantImage_8x8() throws {
        let original = makeConstantFrame(width: 8, height: 8, value: 128)

        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .distance(1.0),
            effort: .falcon,
            adaptiveQuantization: false,
            useANS: false
        ))
        let encoded = try encoder.encode(original)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
        XCTAssertEqual(decoded.channels, 3)

        let psnr = computePSNR(original, decoded)
        XCTAssertGreaterThan(psnr, 20, "PSNR too low: \(psnr) dB")
    }

    func testRoundTrip_GradientImage_16x16() throws {
        let original = makeGradientFrame(width: 16, height: 16)

        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .distance(1.0),
            effort: .falcon,
            adaptiveQuantization: false,
            useANS: false
        ))
        let encoded = try encoder.encode(original)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        XCTAssertEqual(decoded.width, 16)
        XCTAssertEqual(decoded.height, 16)
        XCTAssertEqual(decoded.channels, 3)

        let psnr = computePSNR(original, decoded)
        XCTAssertGreaterThan(psnr, 20, "PSNR too low: \(psnr) dB")
    }

    func testRoundTrip_NonMultipleOf8_Dimensions() throws {
        let original = makeGradientFrame(width: 10, height: 14)

        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .distance(1.0),
            effort: .falcon,
            adaptiveQuantization: false,
            useANS: false
        ))
        let encoded = try encoder.encode(original)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        XCTAssertEqual(decoded.width, 10)
        XCTAssertEqual(decoded.height, 14)
    }

    func testRoundTrip_WithAdaptiveQuantization() throws {
        let original = makeGradientFrame(width: 16, height: 16)

        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .distance(1.0),
            effort: .falcon,
            adaptiveQuantization: true,
            useANS: false
        ))
        let encoded = try encoder.encode(original)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        XCTAssertEqual(decoded.width, 16)
        XCTAssertEqual(decoded.height, 16)

        let psnr = computePSNR(original, decoded)
        XCTAssertGreaterThan(psnr, 15, "PSNR too low: \(psnr) dB")
    }

    func testRoundTrip_WithANS() throws {
        let original = makeGradientFrame(width: 16, height: 16)

        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .distance(1.0),
            effort: .falcon,
            adaptiveQuantization: false,
            useANS: true
        ))
        let encoded = try encoder.encode(original)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        XCTAssertEqual(decoded.width, 16)
        XCTAssertEqual(decoded.height, 16)

        let psnr = computePSNR(original, decoded)
        XCTAssertGreaterThan(psnr, 15, "PSNR too low: \(psnr) dB")
    }

    func testRoundTrip_LowDistance_HighQuality() throws {
        let original = makeGradientFrame(width: 8, height: 8)

        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .distance(0.5),
            effort: .falcon,
            adaptiveQuantization: false,
            useANS: false
        ))
        let encoded = try encoder.encode(original)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        let psnr = computePSNR(original, decoded)
        // Lower distance → higher quality → higher PSNR
        XCTAssertGreaterThan(psnr, 25, "PSNR too low for low distance: \(psnr) dB")
    }

    func testRoundTrip_SingleChannel() throws {
        let original = makeConstantFrame(
            width: 8, height: 8, channels: 1, value: 100
        )

        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .distance(1.0),
            effort: .falcon,
            adaptiveQuantization: false,
            useANS: false
        ))
        let encoded = try encoder.encode(original)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
        XCTAssertEqual(decoded.channels, 1)
    }

    // MARK: - Decoder Dispatch Tests

    func testDecoder_DetectsVarDCTMode() throws {
        let original = makeGradientFrame(width: 8, height: 8)

        // Encode as lossy (VarDCT)
        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .distance(1.0),
            effort: .falcon,
            adaptiveQuantization: false,
            useANS: false
        ))
        let encoded = try encoder.encode(original)

        // The decoder should detect VarDCT mode and decode successfully
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
    }

    func testDecoder_StillDecodesModular() throws {
        let original = makeGradientFrame(width: 8, height: 8)

        // Encode as lossless (Modular)
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(original)

        // The decoder should still handle Modular mode
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)

        // Lossless should be pixel-perfect
        for c in 0..<original.channels {
            for y in 0..<original.height {
                for x in 0..<original.width {
                    XCTAssertEqual(
                        original.getPixel(x: x, y: y, channel: c),
                        decoded.getPixel(x: x, y: y, channel: c),
                        "Pixel mismatch at (\(x),\(y)) ch\(c)"
                    )
                }
            }
        }
    }

    // MARK: - Error Handling Tests

    func testDecoder_TruncatedData_ThrowsError() {
        let decoder = JXLDecoder()
        let data = Data([0xFF, 0x0A]) // Only signature, no header

        XCTAssertThrowsError(try decoder.decode(data)) { error in
            XCTAssertTrue(error is DecoderError)
        }
    }

    func testVarDCTDecoder_InvalidMode_ThrowsError() {
        let decoder = makeDecoder()
        // First bit = 1 (Modular), not VarDCT
        let data = Data([0x80])

        XCTAssertThrowsError(
            try decoder.decode(
                data: data, width: 8, height: 8, channels: 3
            )
        ) { error in
            XCTAssertTrue(error is VarDCTDecoderError)
        }
    }

    func testVarDCTDecoder_TruncatedHeader_ThrowsError() {
        let decoder = makeDecoder()
        // VarDCT mode bit + padding but no distance/flags
        let data = Data([0x00, 0x00])

        XCTAssertThrowsError(
            try decoder.decode(
                data: data, width: 8, height: 8, channels: 3
            )
        ) { error in
            XCTAssertTrue(error is VarDCTDecoderError)
        }
    }

    // MARK: - Larger Image Tests

    func testRoundTrip_32x32_GoodQuality() throws {
        let original = makeGradientFrame(width: 32, height: 32)

        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .distance(1.0),
            effort: .falcon,
            adaptiveQuantization: true,
            useANS: false
        ))
        let encoded = try encoder.encode(original)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        XCTAssertEqual(decoded.width, 32)
        XCTAssertEqual(decoded.height, 32)

        let psnr = computePSNR(original, decoded)
        XCTAssertGreaterThan(psnr, 15, "PSNR too low: \(psnr) dB")
    }
}
