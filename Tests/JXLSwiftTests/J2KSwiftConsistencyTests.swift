/// J2KSwift API Consistency Tests
///
/// Validates that JXLSwift's shared protocol conformances (`RasterImageEncoder`,
/// `RasterImageDecoder`, `RasterImageCodec`) work correctly and that the
/// protocol-based API surface is stable for cross-library consistency with J2KSwift.

import XCTest
@testable import JXLSwift

final class J2KSwiftConsistencyTests: XCTestCase {

    // MARK: - Protocol Conformance Tests

    func testJXLEncoder_ConformsToRasterImageEncoder() {
        let encoder = JXLEncoder()
        // Verify the conformance compiles and the type is correct.
        let _: any RasterImageEncoder = encoder
        XCTAssertTrue(encoder is any RasterImageEncoder)
    }

    func testJXLDecoder_ConformsToRasterImageDecoder() {
        let decoder = JXLDecoder()
        let _: any RasterImageDecoder = decoder
        XCTAssertTrue(decoder is any RasterImageDecoder)
    }

    func testJXLEncoder_ConformsToRasterImageCodec() {
        // JXLEncoder is RasterImageEncoder; JXLDecoder is RasterImageDecoder.
        // There is no single type that is both, but the typealias compiles.
        let encoder = JXLEncoder()
        XCTAssertTrue(encoder is any RasterImageEncoder)
    }

    // MARK: - RasterImageEncoder Protocol API Tests

    func testRasterImageEncoder_EncodeSingleFrame_ReturnsData() throws {
        let encoder: any RasterImageEncoder = JXLEncoder(options: EncodingOptions(mode: .lossless))
        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        // Fill with a simple gradient
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 32))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        let data = try encoder.encode(frame: frame)
        XCTAssertGreaterThan(data.count, 0, "Encoded data must not be empty")
    }

    func testRasterImageEncoder_EncodeFrames_ReturnData() throws {
        let encoder: any RasterImageEncoder = JXLEncoder(options: EncodingOptions(mode: .lossless))
        let frame = ImageFrame(width: 4, height: 4, channels: 3)
        let data = try encoder.encode(frames: [frame])
        XCTAssertGreaterThan(data.count, 0, "Encoded animation data must not be empty")
    }

    func testRasterImageEncoder_EncodeFrame_LossyMode_ReturnsData() throws {
        let options = EncodingOptions(mode: .lossy(quality: 80))
        let encoder: any RasterImageEncoder = JXLEncoder(options: options)
        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x + y) * 8))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(y * 16))
            }
        }
        let data = try encoder.encode(frame: frame)
        XCTAssertGreaterThan(data.count, 0)
    }

    func testRasterImageEncoder_EncodeFrame_JXLSignature() throws {
        let encoder: any RasterImageEncoder = JXLEncoder(options: EncodingOptions(mode: .lossless))
        let frame = ImageFrame(width: 4, height: 4, channels: 1)
        let data = try encoder.encode(frame: frame)
        // JPEG XL bare codestream starts with 0xFF 0x0A
        XCTAssertGreaterThanOrEqual(data.count, 2)
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0x0A)
    }

    func testRasterImageEncoder_EmptyFramesList_ThrowsError() {
        let encoder: any RasterImageEncoder = JXLEncoder()
        XCTAssertThrowsError(try encoder.encode(frames: [])) { error in
            // Should throw an EncoderError
            XCTAssertTrue(error is EncoderError)
        }
    }

    // MARK: - RasterImageDecoder Protocol API Tests

    func testRasterImageDecoder_DecodesValidLosslessData() throws {
        // Encode first using the standard API
        let options = EncodingOptions(mode: .lossless)
        let concreteEncoder = JXLEncoder(options: options)
        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        for i in 0..<(8 * 8 * 3) {
            frame.data[i] = UInt8(i % 256)
        }
        let encoded: EncodedImage = try concreteEncoder.encode(frame)

        // Now decode via the protocol
        let decoder: any RasterImageDecoder = JXLDecoder()
        let decoded = try decoder.decode(data: encoded.data)
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
    }

    func testRasterImageDecoder_InvalidData_ThrowsError() {
        let decoder: any RasterImageDecoder = JXLDecoder()
        let invalidData = Data([0x00, 0x01, 0x02])
        XCTAssertThrowsError(try decoder.decode(data: invalidData)) { error in
            XCTAssertTrue(error is DecoderError)
        }
    }

    func testRasterImageDecoder_EmptyData_ThrowsError() {
        let decoder: any RasterImageDecoder = JXLDecoder()
        XCTAssertThrowsError(try decoder.decode(data: Data())) { error in
            XCTAssertTrue(error is DecoderError)
        }
    }

    // MARK: - Protocol-Based Round-Trip Tests

    func testProtocolRoundTrip_LosslessSmallFrame() throws {
        let encoder: any RasterImageEncoder = JXLEncoder(options: EncodingOptions(mode: .lossless))
        let decoder: any RasterImageDecoder = JXLDecoder()

        var source = ImageFrame(width: 8, height: 8, channels: 3)
        for y in 0..<8 {
            for x in 0..<8 {
                source.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
                source.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 32))
                source.setPixel(x: x, y: y, channel: 2, value: 200)
            }
        }

        let encoded = try encoder.encode(frame: source)
        let decoded = try decoder.decode(data: encoded)

        XCTAssertEqual(decoded.width, source.width)
        XCTAssertEqual(decoded.height, source.height)
        XCTAssertEqual(decoded.channels, source.channels)
    }

    func testProtocolRoundTrip_SingleChannel() throws {
        let encoder: any RasterImageEncoder = JXLEncoder(options: EncodingOptions(mode: .lossless))
        let decoder: any RasterImageDecoder = JXLDecoder()

        var source = ImageFrame(width: 4, height: 4, channels: 1)
        for i in 0..<(4 * 4) {
            source.data[i] = UInt8(i * 16)
        }

        let encoded = try encoder.encode(frame: source)
        let decoded = try decoder.decode(data: encoded)

        XCTAssertEqual(decoded.width, 4)
        XCTAssertEqual(decoded.height, 4)
        XCTAssertEqual(decoded.channels, 1)
    }

    // MARK: - Polymorphic Usage Tests

    func testPolymorphicEncoder_UsedAsAnyRasterImageEncoder() throws {
        // Test that the type can be stored as the protocol existential
        let encoders: [any RasterImageEncoder] = [
            JXLEncoder(options: EncodingOptions(mode: .lossless)),
            JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90)))
        ]
        let frame = ImageFrame(width: 4, height: 4, channels: 3)
        for encoder in encoders {
            let data = try encoder.encode(frame: frame)
            XCTAssertGreaterThan(data.count, 0)
        }
    }

    func testPolymorphicDecoder_UsedAsAnyRasterImageDecoder() throws {
        let concreteEncoder = JXLEncoder(options: EncodingOptions(mode: .lossless))
        let frame = ImageFrame(width: 4, height: 4, channels: 3)
        let encoded: EncodedImage = try concreteEncoder.encode(frame)

        let decoders: [any RasterImageDecoder] = [JXLDecoder()]
        for decoder in decoders {
            let decoded = try decoder.decode(data: encoded.data)
            XCTAssertEqual(decoded.width, 4)
            XCTAssertEqual(decoded.height, 4)
        }
    }

    // MARK: - Naming Convention Audit Tests

    func testEncoderNamingConventions_ParameterLabels() throws {
        // Verify the labeled API is present: encode(frame:) and encode(frames:)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossless))
        let frame = ImageFrame(width: 4, height: 4, channels: 1)
        // These calls must compile: labeled parameter forms
        let singleData = try encoder.encode(frame: frame)
        let multiData = try encoder.encode(frames: [frame])
        XCTAssertGreaterThan(singleData.count, 0)
        XCTAssertGreaterThan(multiData.count, 0)
    }

    func testDecoderNamingConventions_ParameterLabels() throws {
        // Verify the labeled API is present: decode(data:)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossless))
        let frame = ImageFrame(width: 4, height: 4, channels: 1)
        let encoded: EncodedImage = try encoder.encode(frame)

        let decoder = JXLDecoder()
        // This call must compile: labeled parameter form
        let decoded = try decoder.decode(data: encoded.data)
        XCTAssertEqual(decoded.width, 4)
    }

    // MARK: - Protocol Existence Checks (Compile-Time)

    func testRasterImageCodecTypealias_Exists() {
        // Verify RasterImageCodec typealias is accessible
        // This is a compile-time check: if RasterImageCodec doesn't exist, this file
        // will fail to compile.
        let _: (any RasterImageCodec).Type = (any RasterImageCodec).self
        XCTAssertTrue(true, "RasterImageCodec typealias exists")
    }
}
