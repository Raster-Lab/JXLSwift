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
}
