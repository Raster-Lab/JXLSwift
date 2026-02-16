import XCTest
@testable import JXLSwift

final class SqueezeTransformTests: XCTestCase {

    // MARK: - Setup

    private func makeEncoder() -> ModularEncoder {
        ModularEncoder(
            hardware: HardwareCapabilities.detect(),
            options: .lossless
        )
    }

    // MARK: - Horizontal Squeeze Round-Trip Tests

    func testSqueezeHorizontal_RoundTrip_EvenWidth() {
        let encoder = makeEncoder()
        let original: [Int32] = [1, 2, 3, 4,
                                 5, 6, 7, 8]
        let width = 4
        let height = 2

        var data = original
        encoder.squeezeHorizontal(data: &data, regionW: width, regionH: height, stride: width)
        encoder.inverseSqueezeHorizontal(data: &data, regionW: width, regionH: height, stride: width)

        XCTAssertEqual(data, original,
                       "Horizontal squeeze round-trip must be pixel-perfect for even width")
    }

    func testSqueezeHorizontal_RoundTrip_OddWidth() {
        let encoder = makeEncoder()
        let original: [Int32] = [10, 20, 30, 40, 50,
                                 60, 70, 80, 90, 100]
        let width = 5
        let height = 2

        var data = original
        encoder.squeezeHorizontal(data: &data, regionW: width, regionH: height, stride: width)
        encoder.inverseSqueezeHorizontal(data: &data, regionW: width, regionH: height, stride: width)

        XCTAssertEqual(data, original,
                       "Horizontal squeeze round-trip must be pixel-perfect for odd width")
    }

    func testSqueezeHorizontal_RoundTrip_Width1() {
        let encoder = makeEncoder()
        let original: [Int32] = [42, 99]
        let width = 1
        let height = 2

        var data = original
        encoder.squeezeHorizontal(data: &data, regionW: width, regionH: height, stride: width)
        encoder.inverseSqueezeHorizontal(data: &data, regionW: width, regionH: height, stride: width)

        XCTAssertEqual(data, original,
                       "Width=1 should pass through unchanged")
    }

    func testSqueezeHorizontal_RoundTrip_NegativeValues() {
        let encoder = makeEncoder()
        let original: [Int32] = [-100, 50, -30, 70]
        let width = 4
        let height = 1

        var data = original
        encoder.squeezeHorizontal(data: &data, regionW: width, regionH: height, stride: width)
        encoder.inverseSqueezeHorizontal(data: &data, regionW: width, regionH: height, stride: width)

        XCTAssertEqual(data, original,
                       "Horizontal squeeze must handle negative values correctly")
    }

    // MARK: - Vertical Squeeze Round-Trip Tests

    func testSqueezeVertical_RoundTrip_EvenHeight() {
        let encoder = makeEncoder()
        let original: [Int32] = [1, 2,
                                 3, 4,
                                 5, 6,
                                 7, 8]
        let width = 2
        let height = 4

        var data = original
        encoder.squeezeVertical(data: &data, regionW: width, regionH: height, stride: width)
        encoder.inverseSqueezeVertical(data: &data, regionW: width, regionH: height, stride: width)

        XCTAssertEqual(data, original,
                       "Vertical squeeze round-trip must be pixel-perfect for even height")
    }

    func testSqueezeVertical_RoundTrip_OddHeight() {
        let encoder = makeEncoder()
        let original: [Int32] = [10, 20,
                                 30, 40,
                                 50, 60,
                                 70, 80,
                                 90, 100]
        let width = 2
        let height = 5

        var data = original
        encoder.squeezeVertical(data: &data, regionW: width, regionH: height, stride: width)
        encoder.inverseSqueezeVertical(data: &data, regionW: width, regionH: height, stride: width)

        XCTAssertEqual(data, original,
                       "Vertical squeeze round-trip must be pixel-perfect for odd height")
    }

    func testSqueezeVertical_RoundTrip_Height1() {
        let encoder = makeEncoder()
        let original: [Int32] = [42, 99, 7]
        let width = 3
        let height = 1

        var data = original
        encoder.squeezeVertical(data: &data, regionW: width, regionH: height, stride: width)
        encoder.inverseSqueezeVertical(data: &data, regionW: width, regionH: height, stride: width)

        XCTAssertEqual(data, original,
                       "Height=1 should pass through unchanged")
    }

    func testSqueezeVertical_RoundTrip_NegativeValues() {
        let encoder = makeEncoder()
        let original: [Int32] = [-50,
                                  100,
                                 -200,
                                  300]
        let width = 1
        let height = 4

        var data = original
        encoder.squeezeVertical(data: &data, regionW: width, regionH: height, stride: width)
        encoder.inverseSqueezeVertical(data: &data, regionW: width, regionH: height, stride: width)

        XCTAssertEqual(data, original,
                       "Vertical squeeze must handle negative values correctly")
    }

    // MARK: - Full Squeeze (forwardSqueeze / inverseSqueeze) Round-Trip Tests

    func testForwardInverseSqueeze_RoundTrip_8x8() {
        let encoder = makeEncoder()
        var data = [Int32](repeating: 0, count: 64)
        for y in 0..<8 {
            for x in 0..<8 {
                data[y * 8 + x] = Int32(y * 8 + x)
            }
        }

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 8, height: 8)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "Full squeeze round-trip must be pixel-perfect for 8×8")
    }

    func testForwardInverseSqueeze_RoundTrip_16x16() {
        let encoder = makeEncoder()
        var data = [Int32](repeating: 0, count: 256)
        for i in 0..<256 {
            data[i] = Int32((i * 7 + 13) % 256)
        }

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 16, height: 16)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "Full squeeze round-trip must be pixel-perfect for 16×16")
    }

    func testForwardInverseSqueeze_RoundTrip_OddDimensions() {
        let encoder = makeEncoder()
        let width = 7
        let height = 5
        var data = [Int32](repeating: 0, count: width * height)
        for i in 0..<data.count {
            data[i] = Int32(i * 3 - 20)
        }

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: width, height: height)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "Full squeeze round-trip must be pixel-perfect for 7×5 (odd dimensions)")
    }

    func testForwardInverseSqueeze_RoundTrip_1x1() {
        let encoder = makeEncoder()
        let data: [Int32] = [42]

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 1, height: 1)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(steps.count, 0,
                       "1×1 image should produce no squeeze steps")
        XCTAssertEqual(recovered, data,
                       "1×1 image should pass through unchanged")
    }

    func testForwardInverseSqueeze_RoundTrip_1xN() {
        let encoder = makeEncoder()
        let data: [Int32] = [10, 20, 30, 40, 50, 60, 70, 80]

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 1, height: 8)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "1×8 column should squeeze/unsqueeze perfectly")
    }

    func testForwardInverseSqueeze_RoundTrip_Nx1() {
        let encoder = makeEncoder()
        let data: [Int32] = [10, 20, 30, 40, 50, 60, 70, 80]

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 8, height: 1)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "8×1 row should squeeze/unsqueeze perfectly")
    }

    func testForwardInverseSqueeze_RoundTrip_2x2() {
        let encoder = makeEncoder()
        let data: [Int32] = [100, 200, 300, 400]

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 2, height: 2)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "2×2 image should squeeze/unsqueeze perfectly")
    }

    func testForwardInverseSqueeze_RoundTrip_NegativeValues() {
        let encoder = makeEncoder()
        let data: [Int32] = [-1000, 500, -32768, 32767,
                              0, -1, 1, 65535,
                             -65535, 100, -100, 0,
                              12345, -12345, 0, 0]

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 4, height: 4)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "Squeeze must handle mixed positive/negative values perfectly")
    }

    func testForwardInverseSqueeze_RoundTrip_AllZeros() {
        let encoder = makeEncoder()
        let data = [Int32](repeating: 0, count: 64)

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 8, height: 8)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "All-zero data should round-trip perfectly")
        XCTAssertTrue(squeezed.allSatisfy { $0 == 0 },
                      "All-zero input should produce all-zero squeezed output")
    }

    func testForwardInverseSqueeze_RoundTrip_Constant() {
        let encoder = makeEncoder()
        let data = [Int32](repeating: 42, count: 64)

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 8, height: 8)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "Constant data should round-trip perfectly")
    }

    func testForwardInverseSqueeze_RoundTrip_LargeImage() {
        let encoder = makeEncoder()
        let width = 64
        let height = 64
        var data = [Int32](repeating: 0, count: width * height)
        for i in 0..<data.count {
            data[i] = Int32((i * 17 + 5) % 65536)
        }

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: width, height: height)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "64×64 image should squeeze/unsqueeze perfectly")
    }

    // MARK: - Squeeze Step Count and Structure Tests

    func testForwardSqueeze_Steps_8x8_Default3Levels() {
        let encoder = makeEncoder()
        let data = [Int32](repeating: 0, count: 64)

        let (_, steps) = encoder.forwardSqueeze(data: data, width: 8, height: 8)

        XCTAssertGreaterThan(steps.count, 0,
                             "8×8 should produce at least one squeeze step")
        XCTAssertLessThanOrEqual(steps.count, 6,
                                  "8×8 with 3 levels should produce at most 6 steps")

        // First step should be horizontal
        XCTAssertTrue(steps[0].horizontal,
                      "First squeeze step should be horizontal")
        XCTAssertEqual(steps[0].width, 8)
        XCTAssertEqual(steps[0].height, 8)
    }

    func testForwardSqueeze_Steps_1Level() {
        let encoder = makeEncoder()
        let data = [Int32](repeating: 0, count: 16)

        let (_, steps) = encoder.forwardSqueeze(data: data, width: 4, height: 4, levels: 1)

        XCTAssertEqual(steps.count, 2,
                       "4×4 with 1 level should produce exactly 2 steps (H + V)")
        XCTAssertTrue(steps[0].horizontal)
        XCTAssertFalse(steps[1].horizontal)
    }

    func testForwardSqueeze_Steps_0Levels() {
        let encoder = makeEncoder()
        let data: [Int32] = [1, 2, 3, 4]

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 2, height: 2, levels: 0)

        XCTAssertEqual(steps.count, 0,
                       "0 levels should produce no steps")
        XCTAssertEqual(squeezed, data,
                       "0 levels should leave data unchanged")
    }

    // MARK: - Squeeze Energy Concentration Tests

    func testSqueezeHorizontal_ConstantRow_AllEnergyInLowRes() {
        let encoder = makeEncoder()
        let width = 8
        let height = 1
        var data: [Int32] = [100, 100, 100, 100, 100, 100, 100, 100]
        let lowW = (width + 1) / 2

        encoder.squeezeHorizontal(data: &data, regionW: width, regionH: height, stride: width)

        for i in 0..<lowW {
            XCTAssertEqual(data[i], 100,
                           "Low-res values should be 100 for constant input")
        }
        for i in lowW..<width {
            XCTAssertEqual(data[i], 0,
                           "Detail values should be 0 for constant input")
        }
    }

    func testSqueezeVertical_ConstantColumn_AllEnergyInLowRes() {
        let encoder = makeEncoder()
        let width = 1
        let height = 4
        var data: [Int32] = [50, 50, 50, 50]
        let lowH = (height + 1) / 2

        encoder.squeezeVertical(data: &data, regionW: width, regionH: height, stride: width)

        for i in 0..<lowH {
            XCTAssertEqual(data[i], 50,
                           "Low-res values should be 50 for constant input")
        }
        for i in lowH..<height {
            XCTAssertEqual(data[i], 0,
                           "Detail values should be 0 for constant input")
        }
    }

    // MARK: - Integration with Encoding Pipeline

    func testEncode_WithSqueeze_ProducesOutput() throws {
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 8))
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "Encoding with squeeze should produce non-empty output")
    }

    func testEncode_WithSqueeze_SingleChannel_ProducesOutput() throws {
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 32, height: 32, channels: 1)
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x * y) % 256))
            }
        }

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "Single-channel encoding with squeeze should produce output")
    }

    func testEncode_WithSqueeze_1x1_ProducesOutput() throws {
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 1, height: 1, channels: 1)
        frame.setPixel(x: 0, y: 0, channel: 0, value: 128)

        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                             "1×1 image with squeeze should produce output")
    }

    // MARK: - Specific Value Tests

    func testSqueezeHorizontal_KnownValues() {
        let encoder = makeEncoder()
        var data: [Int32] = [10, 20]
        encoder.squeezeHorizontal(data: &data, regionW: 2, regionH: 1, stride: 2)

        XCTAssertEqual(data[0], 15, "avg of (10,20) should be 15")
        XCTAssertEqual(data[1], -10, "diff of (10,20) should be -10")
    }

    func testSqueezeVertical_KnownValues() {
        let encoder = makeEncoder()
        var data: [Int32] = [10, 20]
        encoder.squeezeVertical(data: &data, regionW: 1, regionH: 2, stride: 1)

        XCTAssertEqual(data[0], 15, "avg of (10,20) should be 15")
        XCTAssertEqual(data[1], -10, "diff of (10,20) should be -10")
    }

    func testSqueezeHorizontal_OddPair() {
        let encoder = makeEncoder()
        let original: [Int32] = [3, 4]
        var data = original
        encoder.squeezeHorizontal(data: &data, regionW: 2, regionH: 1, stride: 2)

        XCTAssertEqual(data[0], 3, "avg of (3,4) should be 3 (floor)")
        XCTAssertEqual(data[1], -1, "diff of (3,4) should be -1")

        encoder.inverseSqueezeHorizontal(data: &data, regionW: 2, regionH: 1, stride: 2)
        XCTAssertEqual(data, original)
    }

    // MARK: - Multi-Level Round-Trip with Various Levels

    func testForwardInverseSqueeze_RoundTrip_1Level() {
        let encoder = makeEncoder()
        var data = [Int32](repeating: 0, count: 64)
        for i in 0..<64 { data[i] = Int32(i) }

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 8, height: 8, levels: 1)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "1-level squeeze round-trip must be pixel-perfect")
    }

    func testForwardInverseSqueeze_RoundTrip_5Levels() {
        let encoder = makeEncoder()
        var data = [Int32](repeating: 0, count: 256)
        for i in 0..<256 { data[i] = Int32(i * 3 - 128) }

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 16, height: 16, levels: 5)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "5-level squeeze round-trip must be pixel-perfect for 16×16")
    }

    // MARK: - Squeeze with Asymmetric Dimensions

    func testForwardInverseSqueeze_RoundTrip_WideImage() {
        let encoder = makeEncoder()
        let width = 16
        let height = 2
        var data = [Int32](repeating: 0, count: width * height)
        for i in 0..<data.count { data[i] = Int32(i * 5) }

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: width, height: height)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "Wide 16×2 image should round-trip perfectly")
    }

    func testForwardInverseSqueeze_RoundTrip_TallImage() {
        let encoder = makeEncoder()
        let width = 2
        let height = 16
        var data = [Int32](repeating: 0, count: width * height)
        for i in 0..<data.count { data[i] = Int32(i * 7 - 50) }

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: width, height: height)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "Tall 2×16 image should round-trip perfectly")
    }

    // MARK: - Squeeze 3x3 (odd × odd, smallest non-trivial)

    func testForwardInverseSqueeze_RoundTrip_3x3() {
        let encoder = makeEncoder()
        let data: [Int32] = [1, 2, 3,
                             4, 5, 6,
                             7, 8, 9]

        let (squeezed, steps) = encoder.forwardSqueeze(data: data, width: 3, height: 3)
        let recovered = encoder.inverseSqueeze(data: squeezed, steps: steps)

        XCTAssertEqual(recovered, data,
                       "3×3 image should round-trip perfectly")
    }
}
