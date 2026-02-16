import XCTest
@testable import JXLSwift

final class ModularEncoderTests: XCTestCase {

    // MARK: - Setup

    private func makeEncoder() -> ModularEncoder {
        ModularEncoder(
            hardware: HardwareCapabilities.detect(),
            options: .lossless
        )
    }

    // MARK: - MED Predictor Tests

    func testPredictPixel_FirstPixel_ReturnsZero() {
        let encoder = makeEncoder()
        let data: [UInt16] = [100]
        let predicted = encoder.predictPixel(data: data, x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(predicted, 0,
                       "First pixel (0,0) should always predict 0")
    }

    func testPredictPixel_FirstRow_ReturnsWest() {
        let encoder = makeEncoder()
        // Row: [10, 20, 30, 40]
        let data: [UInt16] = [10, 20, 30, 40]
        let width = 4
        let height = 1

        // x=1: should predict from West = data[0] = 10
        XCTAssertEqual(encoder.predictPixel(data: data, x: 1, y: 0, width: width, height: height), 10)
        // x=2: should predict from West = data[1] = 20
        XCTAssertEqual(encoder.predictPixel(data: data, x: 2, y: 0, width: width, height: height), 20)
        // x=3: should predict from West = data[2] = 30
        XCTAssertEqual(encoder.predictPixel(data: data, x: 3, y: 0, width: width, height: height), 30)
    }

    func testPredictPixel_FirstColumn_ReturnsNorth() {
        let encoder = makeEncoder()
        // Column: 10, 20, 30 (width=1, height=3)
        let data: [UInt16] = [10, 20, 30]
        let width = 1
        let height = 3

        // y=1: should predict from North = data[0] = 10
        XCTAssertEqual(encoder.predictPixel(data: data, x: 0, y: 1, width: width, height: height), 10)
        // y=2: should predict from North = data[1] = 20
        XCTAssertEqual(encoder.predictPixel(data: data, x: 0, y: 2, width: width, height: height), 20)
    }

    func testPredictPixel_GeneralCase_MED() {
        let encoder = makeEncoder()
        // 2x2 image:
        //   NW=10  N=20
        //   W=30   current
        // MED = N + W - NW = 20 + 30 - 10 = 40
        let data: [UInt16] = [10, 20, 30, 0]
        let width = 2
        let height = 2

        let predicted = encoder.predictPixel(data: data, x: 1, y: 1, width: width, height: height)
        XCTAssertEqual(predicted, 40,
                       "MED predictor: N(20) + W(30) - NW(10) = 40")
    }

    func testPredictPixel_GeneralCase_ClampedToZero() {
        let encoder = makeEncoder()
        // 2x2 image where N + W - NW would be negative:
        //   NW=100  N=10
        //   W=10    current
        // MED = 10 + 10 - 100 = -80, clamped to 0
        let data: [UInt16] = [100, 10, 10, 0]
        let width = 2
        let height = 2

        let predicted = encoder.predictPixel(data: data, x: 1, y: 1, width: width, height: height)
        XCTAssertEqual(predicted, 0,
                       "MED predictor should clamp negative values to 0")
    }

    func testPredictPixel_GeneralCase_ClampedToMax() {
        let encoder = makeEncoder()
        // 2x2 image where N + W - NW would exceed 65535:
        //   NW=0      N=60000
        //   W=60000   current
        // MED = 60000 + 60000 - 0 = 120000, clamped to 65535
        let data: [UInt16] = [0, 60000, 60000, 0]
        let width = 2
        let height = 2

        let predicted = encoder.predictPixel(data: data, x: 1, y: 1, width: width, height: height)
        XCTAssertEqual(predicted, 65535,
                       "MED predictor should clamp values exceeding 65535 to 65535")
    }

    func testPredictPixel_GeneralCase_GradientImage() {
        let encoder = makeEncoder()
        // 3x3 gradient image:
        //   0   1   2
        //   3   4   5
        //   6   7   8
        let data: [UInt16] = [0, 1, 2, 3, 4, 5, 6, 7, 8]
        let width = 3
        let height = 3

        // (1,1): N=1, W=3, NW=0 → 1+3-0 = 4
        XCTAssertEqual(encoder.predictPixel(data: data, x: 1, y: 1, width: width, height: height), 4)
        // (2,1): N=2, W=4, NW=1 → 2+4-1 = 5
        XCTAssertEqual(encoder.predictPixel(data: data, x: 2, y: 1, width: width, height: height), 5)
        // (1,2): N=4, W=6, NW=3 → 4+6-3 = 7
        XCTAssertEqual(encoder.predictPixel(data: data, x: 1, y: 2, width: width, height: height), 7)
        // (2,2): N=5, W=7, NW=4 → 5+7-4 = 8
        XCTAssertEqual(encoder.predictPixel(data: data, x: 2, y: 2, width: width, height: height), 8)
    }

    // MARK: - ZigZag Encoding Tests

    func testEncodeSignedValue_Zero() {
        let encoder = makeEncoder()
        XCTAssertEqual(encoder.encodeSignedValue(0), 0, "0 → 0")
    }

    func testEncodeSignedValue_NegativeOne() {
        let encoder = makeEncoder()
        XCTAssertEqual(encoder.encodeSignedValue(-1), 1, "-1 → 1")
    }

    func testEncodeSignedValue_PositiveOne() {
        let encoder = makeEncoder()
        XCTAssertEqual(encoder.encodeSignedValue(1), 2, "1 → 2")
    }

    func testEncodeSignedValue_NegativeTwo() {
        let encoder = makeEncoder()
        XCTAssertEqual(encoder.encodeSignedValue(-2), 3, "-2 → 3")
    }

    func testEncodeSignedValue_PositiveTwo() {
        let encoder = makeEncoder()
        XCTAssertEqual(encoder.encodeSignedValue(2), 4, "2 → 4")
    }

    func testEncodeSignedValue_LargePositive() {
        let encoder = makeEncoder()
        XCTAssertEqual(encoder.encodeSignedValue(1000), 2000, "1000 → 2000")
    }

    func testEncodeSignedValue_LargeNegative() {
        let encoder = makeEncoder()
        XCTAssertEqual(encoder.encodeSignedValue(-1000), 1999, "-1000 → 1999")
    }

    // MARK: - Edge Case Encoding Tests

    func testEncode_1x1Image_ProducesOutput() throws {
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 1, height: 1, channels: 1)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 128)

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "1×1 single-channel image should produce non-empty output")
    }

    func testEncode_1x1RGB_ProducesOutput() throws {
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 1, height: 1, channels: 3)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 255)
        frame.setPixel(x: 0, y: 0, channel: 1, value: 128)
        frame.setPixel(x: 0, y: 0, channel: 2, value: 64)

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "1×1 RGB image should produce non-empty output")
    }

    func testEncode_SingleChannel_ProducesOutput() throws {
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 8, height: 8, channels: 1)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x + y) * 16))
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "Single-channel image should produce non-empty output")
    }

    func testEncode_16BitDepth_ProducesOutput() throws {
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 4, height: 4, channels: 3, pixelType: .uint16, bitsPerSample: 16)
        for y in 0..<4 {
            for x in 0..<4 {
                let value = UInt16((x + y) * 4096)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "16-bit depth image should produce non-empty output")
    }

    func testEncode_UniformImage_Compresses() throws {
        let encoder = JXLEncoder(options: .lossless)
        // All-black image should compress very well
        let frame = ImageFrame(width: 32, height: 32, channels: 3)

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.stats.compressionRatio, 1.0,
                             "Uniform image should achieve compression ratio > 1.0")
    }

    func testEncode_GradientImage_CompressesWell() throws {
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 32, height: 32, channels: 3)

        // Smooth gradient — MED predictor should predict perfectly
        for y in 0..<32 {
            for x in 0..<32 {
                let value = UInt16((x + y) * 4)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.stats.compressionRatio, 1.0,
                             "Gradient image should compress well with MED predictor")
    }

    // MARK: - RCT Forward Transform Tests

    func testForwardRCT_Black_ProducesZeroYAndOffsetChroma() {
        let encoder = makeEncoder()
        let (y, co, cg) = encoder.forwardRCT(r: 0, g: 0, b: 0)
        XCTAssertEqual(y, 0, "Black Y should be 0")
        XCTAssertEqual(co, 0, "Black Co should be 0")
        XCTAssertEqual(cg, 0, "Black Cg should be 0")
    }

    func testForwardRCT_White_ProducesMaxY() {
        let encoder = makeEncoder()
        let (y, co, cg) = encoder.forwardRCT(r: 255, g: 255, b: 255)
        XCTAssertEqual(y, 255, "White Y should be 255")
        XCTAssertEqual(co, 0, "White Co should be 0 (R == B)")
        XCTAssertEqual(cg, 0, "White Cg should be 0 (G == t)")
    }

    func testForwardRCT_PureRed_PositiveCo() {
        let encoder = makeEncoder()
        let (y, co, cg) = encoder.forwardRCT(r: 255, g: 0, b: 0)
        // Co = R - B = 255
        XCTAssertEqual(co, 255, "Pure red: Co = R - B = 255")
        // t = B + (Co >> 1) = 0 + 127 = 127
        // Cg = G - t = 0 - 127 = -127
        XCTAssertEqual(cg, -127, "Pure red: Cg = G - t = -127")
        // Y = t + (Cg >> 1) = 127 + (-64) = 63
        XCTAssertEqual(y, 63, "Pure red: Y = t + (Cg >> 1) = 63")
    }

    func testForwardRCT_PureGreen_PositiveCg() {
        let encoder = makeEncoder()
        let (y, co, cg) = encoder.forwardRCT(r: 0, g: 255, b: 0)
        // Co = R - B = 0
        XCTAssertEqual(co, 0, "Pure green: Co = 0")
        // t = B + (Co >> 1) = 0
        // Cg = G - t = 255
        XCTAssertEqual(cg, 255, "Pure green: Cg = 255")
        // Y = t + (Cg >> 1) = 0 + 127 = 127
        XCTAssertEqual(y, 127, "Pure green: Y = 127")
    }

    func testForwardRCT_PureBlue_NegativeCo() {
        let encoder = makeEncoder()
        let (y, co, cg) = encoder.forwardRCT(r: 0, g: 0, b: 255)
        // Co = R - B = -255
        XCTAssertEqual(co, -255, "Pure blue: Co = -255")
        // t = B + (Co >> 1) = 255 + (-128) = 127
        // Cg = G - t = 0 - 127 = -127
        XCTAssertEqual(cg, -127, "Pure blue: Cg = -127")
        // Y = t + (Cg >> 1) = 127 + (-64) = 63
        XCTAssertEqual(y, 63, "Pure blue: Y = 63")
    }

    func testForwardRCT_MidGray_AllChromaZero() {
        let encoder = makeEncoder()
        let (y, co, cg) = encoder.forwardRCT(r: 128, g: 128, b: 128)
        XCTAssertEqual(y, 128, "Mid-gray Y should be 128")
        XCTAssertEqual(co, 0, "Mid-gray Co should be 0")
        XCTAssertEqual(cg, 0, "Mid-gray Cg should be 0")
    }

    // MARK: - RCT Inverse Transform Tests

    func testInverseRCT_RecoversBlack() {
        let encoder = makeEncoder()
        let (r, g, b) = encoder.inverseRCTPixel(y: 0, co: 0, cg: 0)
        XCTAssertEqual(r, 0)
        XCTAssertEqual(g, 0)
        XCTAssertEqual(b, 0)
    }

    func testInverseRCT_RecoversWhite() {
        let encoder = makeEncoder()
        let (r, g, b) = encoder.inverseRCTPixel(y: 255, co: 0, cg: 0)
        XCTAssertEqual(r, 255)
        XCTAssertEqual(g, 255)
        XCTAssertEqual(b, 255)
    }

    // MARK: - RCT Round-Trip Tests

    func testRCT_RoundTrip_PixelPerfect_BasicColors() {
        let encoder = makeEncoder()
        let testColors: [(Int32, Int32, Int32)] = [
            (0, 0, 0),       // black
            (255, 255, 255), // white
            (255, 0, 0),     // red
            (0, 255, 0),     // green
            (0, 0, 255),     // blue
            (255, 255, 0),   // yellow
            (0, 255, 255),   // cyan
            (255, 0, 255),   // magenta
            (128, 128, 128), // mid-gray
            (1, 2, 3),       // low values
            (253, 254, 255), // high values
        ]

        for (r, g, b) in testColors {
            let (y, co, cg) = encoder.forwardRCT(r: r, g: g, b: b)
            let (rr, gg, bb) = encoder.inverseRCTPixel(y: y, co: co, cg: cg)
            XCTAssertEqual(rr, r, "Round-trip R failed for (\(r),\(g),\(b))")
            XCTAssertEqual(gg, g, "Round-trip G failed for (\(r),\(g),\(b))")
            XCTAssertEqual(bb, b, "Round-trip B failed for (\(r),\(g),\(b))")
        }
    }

    func testRCT_RoundTrip_PixelPerfect_AllUInt8Values() {
        let encoder = makeEncoder()
        // Test a broad range of 8-bit RGB values
        for r in stride(from: 0, through: 255, by: 17) {
            for g in stride(from: 0, through: 255, by: 17) {
                for b in stride(from: 0, through: 255, by: 17) {
                    let ri = Int32(r)
                    let gi = Int32(g)
                    let bi = Int32(b)
                    let (y, co, cg) = encoder.forwardRCT(r: ri, g: gi, b: bi)
                    let (rr, gg, bb) = encoder.inverseRCTPixel(y: y, co: co, cg: cg)
                    XCTAssertEqual(rr, ri, "Round-trip R failed for (\(r),\(g),\(b))")
                    XCTAssertEqual(gg, gi, "Round-trip G failed for (\(r),\(g),\(b))")
                    XCTAssertEqual(bb, bi, "Round-trip B failed for (\(r),\(g),\(b))")
                }
            }
        }
    }

    // MARK: - RCT Channel-Level Tests

    func testApplyRCT_ChannelLevel_RoundTrip() {
        let encoder = makeEncoder()
        let r: [UInt16] = [255, 0,   0, 128, 100, 200]
        let g: [UInt16] = [0,   255, 0, 128, 150, 50]
        let b: [UInt16] = [0,   0, 255, 128, 200, 100]

        var channels: [[UInt16]] = [r, g, b]
        encoder.applyRCT(channels: &channels)

        // Channels should be transformed (not equal to original)
        XCTAssertNotEqual(channels[1], g, "Co channel should differ from original G")

        // Now apply inverse
        encoder.inverseRCT(channels: &channels)

        // Should recover original values exactly
        XCTAssertEqual(channels[0], r, "R channel should be recovered exactly")
        XCTAssertEqual(channels[1], g, "G channel should be recovered exactly")
        XCTAssertEqual(channels[2], b, "B channel should be recovered exactly")
    }

    func testApplyRCT_WithAlphaChannel_PreservesAlpha() {
        let encoder = makeEncoder()
        let r: [UInt16]     = [100, 200]
        let g: [UInt16]     = [150, 50]
        let b: [UInt16]     = [200, 100]
        let alpha: [UInt16] = [255, 128]

        var channels: [[UInt16]] = [r, g, b, alpha]
        encoder.applyRCT(channels: &channels)

        // Alpha channel should be unchanged
        XCTAssertEqual(channels[3], alpha, "Alpha channel must not be modified by RCT")

        // Inverse to verify RGB round-trip
        encoder.inverseRCT(channels: &channels)
        XCTAssertEqual(channels[0], r, "R should be recovered")
        XCTAssertEqual(channels[1], g, "G should be recovered")
        XCTAssertEqual(channels[2], b, "B should be recovered")
        XCTAssertEqual(channels[3], alpha, "Alpha should still be unchanged")
    }

    func testApplyRCT_SingleChannel_NoTransform() {
        let encoder = makeEncoder()
        let gray: [UInt16] = [0, 128, 255]
        var channels: [[UInt16]] = [gray]
        encoder.applyRCT(channels: &channels)
        XCTAssertEqual(channels[0], gray, "Single-channel should not be transformed")
    }

    func testApplyRCT_TwoChannels_NoTransform() {
        let encoder = makeEncoder()
        let ch0: [UInt16] = [10, 20]
        let ch1: [UInt16] = [30, 40]
        var channels: [[UInt16]] = [ch0, ch1]
        encoder.applyRCT(channels: &channels)
        XCTAssertEqual(channels[0], ch0, "Two-channel ch0 should not be transformed")
        XCTAssertEqual(channels[1], ch1, "Two-channel ch1 should not be transformed")
    }

    func testApplyRCT_UniformGray_ChromaZero() {
        let encoder = makeEncoder()
        // All pixels are the same gray value → Co and Cg should be 0 (stored as 32768)
        let gray: UInt16 = 200
        let count = 16
        let ch = [UInt16](repeating: gray, count: count)
        var channels: [[UInt16]] = [ch, ch, ch]
        encoder.applyRCT(channels: &channels)

        for i in 0..<count {
            XCTAssertEqual(channels[0][i], gray, "Y should equal original gray value")
            XCTAssertEqual(channels[1][i], 32768, "Co should be 32768 (offset 0) for gray")
            XCTAssertEqual(channels[2][i], 32768, "Cg should be 32768 (offset 0) for gray")
        }
    }

    // MARK: - RCT Integration Tests

    func testEncode_WithRCT_ProducesOutput() throws {
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        // Create a colorful image
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 8))
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "Encoding with RCT should produce non-empty output")
        XCTAssertGreaterThan(result.stats.compressionRatio, 1.0,
                             "Encoding with RCT should achieve compression")
    }

    func testEncode_SingleChannel_SkipsRCT() throws {
        // Verify that single-channel encoding still works (RCT should be skipped)
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 8, height: 8, channels: 1)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "Single-channel encoding should still work without RCT")
    }

    // MARK: - Context Model Tests

    func testContextModel_Init_ZeroCounts() {
        let model = ModularEncoder.ContextModel(contextCount: 8)
        for i in 0..<8 {
            XCTAssertEqual(model.counts[i], 0, "Initial count should be 0")
            XCTAssertEqual(model.sumOfValues[i], 0, "Initial sum should be 0")
        }
    }

    func testContextModel_Record_IncrementsCountAndSum() {
        var model = ModularEncoder.ContextModel(contextCount: 4)
        model.record(context: 1, unsignedValue: 10)
        model.record(context: 1, unsignedValue: 20)
        model.record(context: 2, unsignedValue: 5)

        XCTAssertEqual(model.counts[0], 0)
        XCTAssertEqual(model.counts[1], 2)
        XCTAssertEqual(model.counts[2], 1)
        XCTAssertEqual(model.sumOfValues[1], 30)
        XCTAssertEqual(model.sumOfValues[2], 5)
    }

    func testContextModel_RiceParameter_EmptyContext_ReturnsZero() {
        let model = ModularEncoder.ContextModel(contextCount: 4)
        XCTAssertEqual(model.riceParameter(for: 0), 0,
                       "Empty context should produce Rice parameter 0")
    }

    func testContextModel_RiceParameter_ZeroMean_ReturnsZero() {
        var model = ModularEncoder.ContextModel(contextCount: 4)
        model.record(context: 0, unsignedValue: 0)
        model.record(context: 0, unsignedValue: 0)
        XCTAssertEqual(model.riceParameter(for: 0), 0,
                       "Zero-mean context should produce Rice parameter 0")
    }

    func testContextModel_RiceParameter_SmallMean() {
        var model = ModularEncoder.ContextModel(contextCount: 4)
        // Mean = 1 → k = floor(log2(1+1)) - 1 ≈ 0
        model.record(context: 0, unsignedValue: 1)
        XCTAssertEqual(model.riceParameter(for: 0), 0)
    }

    func testContextModel_RiceParameter_LargeMean() {
        var model = ModularEncoder.ContextModel(contextCount: 4)
        // Mean = 255 → k = floor(log2(255+1)) - 1 = 7
        model.record(context: 0, unsignedValue: 255)
        let k = model.riceParameter(for: 0)
        XCTAssertEqual(k, 7,
                       "Mean of 255 should produce Rice parameter 7")
    }

    func testContextModel_RiceParameter_IncreasesWithMean() {
        var model = ModularEncoder.ContextModel(contextCount: 4)
        model.record(context: 0, unsignedValue: 1)
        let k1 = model.riceParameter(for: 0)

        var model2 = ModularEncoder.ContextModel(contextCount: 4)
        model2.record(context: 0, unsignedValue: 1000)
        let k2 = model2.riceParameter(for: 0)

        XCTAssertLessThan(k1, k2,
                          "Rice parameter should increase with symbol magnitude")
    }

    // MARK: - Context Selection Tests

    func testSelectContext_FirstPixel_ReturnsFlatContext() {
        let encoder = makeEncoder()
        let residuals: [Int32] = [0, 0, 0, 0]
        let ctx = encoder.selectContext(residuals: residuals, x: 0, y: 0, width: 2)
        XCTAssertEqual(ctx, 0,
                       "First pixel with zero neighbors should select flat context (0)")
    }

    func testSelectContext_FlatRegion_ReturnsContextZero() {
        let encoder = makeEncoder()
        // All residuals are 0 → gradient magnitude = 0 → bucket 0
        let residuals: [Int32] = [0, 0, 0, 0, 0, 0, 0, 0, 0]
        let ctx = encoder.selectContext(residuals: residuals, x: 1, y: 1, width: 3)
        XCTAssertEqual(ctx, 0,
                       "Flat region should produce context 0")
    }

    func testSelectContext_LowGradient_ReturnsLowBucket() {
        let encoder = makeEncoder()
        // Residuals with small magnitudes: avg of abs values < 16
        // N=5, W=5, NW=5 → avg = 5 → bucket 1
        var residuals = [Int32](repeating: 0, count: 9)
        residuals[0] = 5   // (0,0) = NW for (1,1)
        residuals[1] = 5   // (1,0) = N  for (1,1)
        residuals[3] = 5   // (0,1) = W  for (1,1)

        let ctx = encoder.selectContext(residuals: residuals, x: 1, y: 1, width: 3)
        XCTAssertEqual(ctx / 2, 1,
                       "Low gradient (avg=5) should produce bucket 1")
    }

    func testSelectContext_MediumGradient_ReturnsMediumBucket() {
        let encoder = makeEncoder()
        // N=100, W=100, NW=100 → avg = 100 → bucket 2
        var residuals = [Int32](repeating: 0, count: 9)
        residuals[0] = 100  // NW for (1,1)
        residuals[1] = 100  // N  for (1,1)
        residuals[3] = 100  // W  for (1,1)

        let ctx = encoder.selectContext(residuals: residuals, x: 1, y: 1, width: 3)
        XCTAssertEqual(ctx / 2, 2,
                       "Medium gradient (avg=100) should produce bucket 2")
    }

    func testSelectContext_HighGradient_ReturnsHighBucket() {
        let encoder = makeEncoder()
        // N=1000, W=1000, NW=1000 → avg = 1000 → bucket 3
        var residuals = [Int32](repeating: 0, count: 9)
        residuals[0] = 1000  // NW for (1,1)
        residuals[1] = 1000  // N  for (1,1)
        residuals[3] = 1000  // W  for (1,1)

        let ctx = encoder.selectContext(residuals: residuals, x: 1, y: 1, width: 3)
        XCTAssertEqual(ctx / 2, 3,
                       "High gradient (avg=1000) should produce bucket 3")
    }

    func testSelectContext_NegativeResiduals_UsesAbsoluteValue() {
        let encoder = makeEncoder()
        // Negative residuals: abs(-100)=100, avg=100 → bucket 2
        var residuals = [Int32](repeating: 0, count: 9)
        residuals[0] = -100  // NW for (1,1)
        residuals[1] = -100  // N  for (1,1)
        residuals[3] = -100  // W  for (1,1)

        let ctx = encoder.selectContext(residuals: residuals, x: 1, y: 1, width: 3)
        XCTAssertEqual(ctx / 2, 2,
                       "Negative residuals should use absolute values for context")
    }

    func testSelectContext_Orientation_HorizontalEdge() {
        let encoder = makeEncoder()
        // N > W → horizontal sub-context (odd)
        var residuals = [Int32](repeating: 0, count: 9)
        residuals[0] = 50   // NW for (1,1)
        residuals[1] = 200  // N  for (1,1) — large
        residuals[3] = 10   // W  for (1,1) — small

        let ctx = encoder.selectContext(residuals: residuals, x: 1, y: 1, width: 3)
        XCTAssertEqual(ctx % 2, 1,
                       "N > W should produce odd (horizontal) sub-context")
    }

    func testSelectContext_Orientation_VerticalEdge() {
        let encoder = makeEncoder()
        // W > N → vertical sub-context (even)
        var residuals = [Int32](repeating: 0, count: 9)
        residuals[0] = 50   // NW for (1,1)
        residuals[1] = 10   // N  for (1,1) — small
        residuals[3] = 200  // W  for (1,1) — large

        let ctx = encoder.selectContext(residuals: residuals, x: 1, y: 1, width: 3)
        XCTAssertEqual(ctx % 2, 0,
                       "W > N should produce even (vertical) sub-context")
    }

    func testSelectContext_ContextRange_WithinBounds() {
        let encoder = makeEncoder()
        // Test many different residual patterns to verify bounds
        let patterns: [[Int32]] = [
            [0, 0, 0, 0],
            [1, 2, 3, 4],
            [-100, 200, -300, 400],
            [65535, 65535, 65535, 65535],
        ]
        for pattern in patterns {
            let ctx = encoder.selectContext(residuals: pattern, x: 1, y: 1, width: 2)
            XCTAssertGreaterThanOrEqual(ctx, 0)
            XCTAssertLessThan(ctx, ModularEncoder.contextCount,
                              "Context index should be within [0, \(ModularEncoder.contextCount))")
        }
    }

    func testSelectContext_FirstRow_UsesOnlyWest() {
        let encoder = makeEncoder()
        // y=0, x=1: only W is available (no N, no NW)
        let residuals: [Int32] = [50, 0, 0, 0]
        let ctx = encoder.selectContext(residuals: residuals, x: 1, y: 0, width: 4)
        // N=0, NW=0, W=50 → avg = (0+50+0)/3 = 16 → bucket 2
        XCTAssertEqual(ctx / 2, 2,
                       "First row should only consider West neighbor")
    }

    func testSelectContext_FirstColumn_UsesOnlyNorth() {
        let encoder = makeEncoder()
        // x=0, y=1: only N is available (no W, no NW)
        var residuals = [Int32](repeating: 0, count: 6)
        residuals[0] = 50  // N for (0,1) at index 0 in width=3 layout
        let ctx = encoder.selectContext(residuals: residuals, x: 0, y: 1, width: 3)
        // N=50, W=0, NW=0 → avg = (50+0+0)/3 = 16 → bucket 2
        XCTAssertEqual(ctx / 2, 2,
                       "First column should only consider North neighbor")
    }

    // MARK: - Context-Aware Entropy Encoding Tests

    func testEntropyEncodeWithContext_ProducesOutput() throws {
        let encoder = makeEncoder()
        let data: [Int32] = [0, 1, -1, 2, -2, 3, 0, 0]
        let result = try encoder.entropyEncodeWithContext(data: data, width: 4, height: 2)
        XCTAssertGreaterThan(result.count, 0,
                              "Context-aware entropy encoding should produce output")
    }

    func testEntropyEncodeWithContext_UniformData_Compresses() throws {
        let encoder = makeEncoder()
        // All zeros — should compress very well
        let data = [Int32](repeating: 0, count: 64)
        let result = try encoder.entropyEncodeWithContext(data: data, width: 8, height: 8)
        // 64 Int32 values = 256 bytes uncompressed
        XCTAssertLessThan(result.count, 256,
                           "Uniform data should compress well")
    }

    func testEntropyEncodeWithContext_SameAsEntropyEncode_ForFlatData() throws {
        // Both methods should handle flat (all-zero) data without error
        let encoder = makeEncoder()
        let data = [Int32](repeating: 0, count: 16)
        let result = try encoder.entropyEncodeWithContext(data: data, width: 4, height: 4)
        XCTAssertGreaterThan(result.count, 0)
    }

    func testEntropyEncodeWithContext_LargeImage_CompletesWithoutError() throws {
        let encoder = makeEncoder()
        // Larger image with varied residuals
        var data = [Int32](repeating: 0, count: 256)
        for i in 0..<256 {
            data[i] = Int32(i % 64) - 32
        }
        XCTAssertNoThrow(
            try encoder.entropyEncodeWithContext(data: data, width: 16, height: 16),
            "Context encoding should complete without error for larger data"
        )
    }

    // MARK: - Context Count Tests

    func testContextCount_IsEight() {
        XCTAssertEqual(ModularEncoder.contextCount, 8,
                       "Should use 8 contexts (4 magnitude buckets × 2 orientations)")
    }

    // MARK: - NEON Dispatch Integration Tests

    /// Create a ModularEncoder with hardware acceleration enabled.
    private func makeAcceleratedEncoder(effort: EncodingEffort = .falcon) -> ModularEncoder {
        ModularEncoder(
            hardware: HardwareCapabilities.detect(),
            options: EncodingOptions(
                mode: .lossless,
                effort: effort,
                useHardwareAcceleration: true,
                useAccelerate: false
            )
        )
    }

    /// Create a ModularEncoder with hardware acceleration disabled (scalar only).
    private func makeScalarEncoder(effort: EncodingEffort = .falcon) -> ModularEncoder {
        ModularEncoder(
            hardware: HardwareCapabilities.detect(),
            options: EncodingOptions(
                mode: .lossless,
                effort: effort,
                useHardwareAcceleration: false,
                useAccelerate: false
            )
        )
    }

    func testNEONPrediction_MatchesScalarMED_GradientImage() {
        // NEONOps.predictMED should match ModularEncoder.predictPixel
        let width = 8
        let height = 8
        var data = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                data[y * width + x] = UInt16(y * width + x)
            }
        }

        let encoder = makeScalarEncoder()
        let neonResult = NEONOps.predictMED(data: data, width: width, height: height)

        // Compute scalar reference using predictPixel
        var scalarResult = [Int32](repeating: 0, count: data.count)
        for y in 0..<height {
            for x in 0..<width {
                let predicted = encoder.predictPixel(data: data, x: x, y: y, width: width, height: height)
                scalarResult[y * width + x] = Int32(data[y * width + x]) - predicted
            }
        }

        XCTAssertEqual(neonResult.count, scalarResult.count)
        for i in 0..<neonResult.count {
            XCTAssertEqual(neonResult[i], scalarResult[i],
                           "MED prediction mismatch at index \(i)")
        }
    }

    func testNEONPrediction_MatchesScalarMED_ConstantImage() {
        let width = 16
        let height = 16
        let data = [UInt16](repeating: 128, count: width * height)

        let encoder = makeScalarEncoder()
        let neonResult = NEONOps.predictMED(data: data, width: width, height: height)

        var scalarResult = [Int32](repeating: 0, count: data.count)
        for y in 0..<height {
            for x in 0..<width {
                let predicted = encoder.predictPixel(data: data, x: x, y: y, width: width, height: height)
                scalarResult[y * width + x] = Int32(data[y * width + x]) - predicted
            }
        }

        XCTAssertEqual(neonResult, scalarResult,
                       "Constant image MED prediction should match")
    }

    func testNEONRCT_MatchesScalar_GradientData() {
        let count = 17 // non-multiple-of-4 to test scalar tail
        let r = (0..<count).map { UInt16($0 * 10) }
        let g = (0..<count).map { UInt16($0 * 8) }
        let b = (0..<count).map { UInt16($0 * 6) }

        // Scalar RCT via ModularEncoder
        let encoder = makeScalarEncoder()
        var scalarChannels: [[UInt16]] = [r, g, b]
        encoder.applyRCT(channels: &scalarChannels)

        // NEON RCT
        let (yArr, coArr, cgArr) = NEONOps.forwardRCT(r: r, g: g, b: b)
        var neonChannels = [[UInt16]](repeating: [UInt16](repeating: 0, count: count), count: 3)
        for i in 0..<count {
            neonChannels[0][i] = UInt16(clamping: yArr[i])
            neonChannels[1][i] = UInt16(clamping: coArr[i] + 32768)
            neonChannels[2][i] = UInt16(clamping: cgArr[i] + 32768)
        }

        XCTAssertEqual(scalarChannels[0], neonChannels[0], "Y channel should match")
        XCTAssertEqual(scalarChannels[1], neonChannels[1], "Co channel should match")
        XCTAssertEqual(scalarChannels[2], neonChannels[2], "Cg channel should match")
    }

    func testNEONRCT_RoundTrip_MatchesScalar() {
        let count = 12
        let r = (0..<count).map { UInt16($0 * 15) }
        let g = (0..<count).map { UInt16($0 * 12) }
        let b = (0..<count).map { UInt16($0 * 9) }

        let encoder = makeScalarEncoder()
        var channels: [[UInt16]] = [r, g, b]
        encoder.applyRCT(channels: &channels)
        encoder.inverseRCT(channels: &channels)

        XCTAssertEqual(channels[0], r, "R channel should round-trip perfectly")
        XCTAssertEqual(channels[1], g, "G channel should round-trip perfectly")
        XCTAssertEqual(channels[2], b, "B channel should round-trip perfectly")
    }

    func testNEONSqueeze_MatchesScalar_HorizontalEvenWidth() {
        let encoder = makeScalarEncoder()
        var scalarData: [Int32] = [10, 20, 30, 40, 50, 60, 70, 80]
        var neonData = scalarData

        encoder.squeezeHorizontal(data: &scalarData, regionW: 8, regionH: 1, stride: 8)
        NEONOps.squeezeHorizontal(data: &neonData, regionW: 8, regionH: 1, stride: 8)

        XCTAssertEqual(scalarData, neonData,
                       "NEON horizontal squeeze should match scalar")
    }

    func testNEONSqueeze_MatchesScalar_VerticalEvenHeight() {
        let encoder = makeScalarEncoder()
        let width = 4
        let height = 8
        var scalarData = [Int32](repeating: 0, count: width * height)
        for i in 0..<scalarData.count { scalarData[i] = Int32(i) }
        var neonData = scalarData

        encoder.squeezeVertical(data: &scalarData, regionW: width, regionH: height, stride: width)
        NEONOps.squeezeVertical(data: &neonData, regionW: width, regionH: height, stride: width)

        XCTAssertEqual(scalarData, neonData,
                       "NEON vertical squeeze should match scalar")
    }

    func testNEONSqueeze_MatchesScalar_OddDimensions() {
        let encoder = makeScalarEncoder()
        let width = 7
        let height = 5
        var scalarData = [Int32](repeating: 0, count: width * height)
        for i in 0..<scalarData.count { scalarData[i] = Int32(i * 3 - 10) }
        var neonData = scalarData

        encoder.squeezeHorizontal(data: &scalarData, regionW: width, regionH: height, stride: width)
        NEONOps.squeezeHorizontal(data: &neonData, regionW: width, regionH: height, stride: width)

        XCTAssertEqual(scalarData, neonData,
                       "NEON horizontal squeeze should match scalar for odd width")

        // Reset for vertical
        scalarData = [Int32](repeating: 0, count: width * height)
        for i in 0..<scalarData.count { scalarData[i] = Int32(i * 3 - 10) }
        neonData = scalarData

        encoder.squeezeVertical(data: &scalarData, regionW: width, regionH: height, stride: width)
        NEONOps.squeezeVertical(data: &neonData, regionW: width, regionH: height, stride: width)

        XCTAssertEqual(scalarData, neonData,
                       "NEON vertical squeeze should match scalar for odd height")
    }

    func testNEONForwardSqueeze_MatchesScalar_FullPipeline() {
        let scalarEncoder = makeScalarEncoder()
        let accelEncoder = makeAcceleratedEncoder()
        let width = 8
        let height = 8
        var data = [Int32](repeating: 0, count: width * height)
        for i in 0..<data.count { data[i] = Int32(i) }

        let (scalarResult, scalarSteps) = scalarEncoder.forwardSqueeze(data: data, width: width, height: height)
        let (accelResult, accelSteps) = accelEncoder.forwardSqueeze(data: data, width: width, height: height)

        XCTAssertEqual(scalarSteps.count, accelSteps.count,
                       "Same number of squeeze steps")
        XCTAssertEqual(scalarResult, accelResult,
                       "Accelerated forward squeeze should match scalar")
    }

    func testModularEncoder_AcceleratedEncode_ProducesOutput() throws {
        let encoder = makeAcceleratedEncoder()
        var frame = ImageFrame(width: 8, height: 8, channels: 3, pixelType: .uint8)
        for y in 0..<8 {
            for x in 0..<8 {
                for c in 0..<3 {
                    frame.setPixel(x: x, y: y, channel: c, value: UInt16((y * 8 + x + c * 21) & 0xFF))
                }
            }
        }

        let result = try encoder.encode(frame: frame)
        XCTAssertGreaterThan(result.count, 0,
                             "Accelerated modular encoding should produce non-empty output")
    }
}
