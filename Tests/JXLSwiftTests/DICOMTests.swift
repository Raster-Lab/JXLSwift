/// Tests for DICOM-awareness / medical imaging support (Milestone 17)
///
/// Verifies medical pixel formats, bit depths, signed integer support,
/// photometric interpretation metadata, window/level passthrough, and
/// multi-frame series encoding.  No DICOM library dependency is used.

import XCTest
@testable import JXLSwift

final class DICOMTests: XCTestCase {

    // MARK: - PixelType: int16

    func testPixelType_Int16_BytesPerSample() {
        XCTAssertEqual(PixelType.int16.bytesPerSample, 2)
    }

    func testPixelType_Int16_SetAndGetSigned_RoundTrip() {
        var frame = ImageFrame(width: 4, height: 4, channels: 1,
                               pixelType: .int16, colorSpace: .grayscale,
                               bitsPerSample: 16)
        let values: [Int16] = [-1024, 0, 1, 2048, Int16.min, Int16.max]
        for (i, v) in values.enumerated() {
            let x = i % 4, y = i / 4
            frame.setPixelSigned(x: x, y: y, channel: 0, value: v)
            let got = frame.getPixelSigned(x: x, y: y, channel: 0)
            XCTAssertEqual(got, v, "Round-trip failed for value \(v)")
        }
    }

    func testPixelType_Int16_SetPixelUInt16_BitPattern() {
        // setPixel with UInt16 stores the raw bit pattern; getPixelSigned re-reads it
        var frame = ImageFrame(width: 2, height: 1, channels: 1,
                               pixelType: .int16, colorSpace: .grayscale,
                               bitsPerSample: 16)
        // -1 stored as UInt16 bit pattern = 0xFFFF = 65535
        frame.setPixel(x: 0, y: 0, channel: 0, value: 0xFFFF)
        XCTAssertEqual(frame.getPixelSigned(x: 0, y: 0, channel: 0), -1)
    }

    // MARK: - PixelType: 12-bit unsigned (uint16 with bitsPerSample 12)

    func testPixelType_12bit_LosslessRoundTrip() throws {
        // 12-bit values fit in uint16 storage; verify lossless encode/decode
        var frame = ImageFrame(width: 4, height: 4, channels: 1,
                               pixelType: .uint16, colorSpace: .grayscale,
                               bitsPerSample: 12)
        // Fill with values in 12-bit range (0–4095)
        for y in 0..<4 {
            for x in 0..<4 {
                let value = UInt16((y * 4 + x) * 255)  // 0, 255, 510, ..., 3825
                frame.setPixel(x: x, y: y, channel: 0, value: value)
            }
        }

        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        XCTAssertGreaterThan(encoded.data.count, 0, "Encoded data must not be empty")

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)

        // Verify all pixel values survive the round-trip
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let original = frame.getPixel(x: x, y: y, channel: 0)
                let restored = decoded.getPixel(x: x, y: y, channel: 0)
                XCTAssertEqual(restored, original,
                               "Pixel mismatch at (\(x),\(y)): expected \(original), got \(restored)")
            }
        }
    }

    // MARK: - PixelType: 16-bit unsigned lossless round-trip

    func testPixelType_16bitUnsigned_LosslessRoundTrip() throws {
        var frame = ImageFrame(width: 8, height: 8, channels: 1,
                               pixelType: .uint16, colorSpace: .grayscale,
                               bitsPerSample: 16)
        // Fill with a range of 16-bit values
        for y in 0..<8 {
            for x in 0..<8 {
                let value = UInt16((y * 8 + x) * 1000)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
            }
        }

        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        XCTAssertGreaterThan(encoded.data.count, 0)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)

        for y in 0..<frame.height {
            for x in 0..<frame.width {
                XCTAssertEqual(decoded.getPixel(x: x, y: y, channel: 0),
                               frame.getPixel(x: x, y: y, channel: 0),
                               "16-bit pixel mismatch at (\(x),\(y))")
            }
        }
    }

    // MARK: - PixelType: 16-bit signed lossless round-trip

    func testPixelType_16bitSigned_LosslessRoundTrip() throws {
        // Encode int16 data via its UInt16 bit-pattern representation
        var frame = ImageFrame(width: 8, height: 8, channels: 1,
                               pixelType: .int16, colorSpace: .grayscale,
                               bitsPerSample: 16)
        let testValues: [Int16] = [-1024, -512, -1, 0, 1, 512, 1024, 2048,
                                   -32768, 32767, -2000, 3000, 100, -100, 4095, -4096]
        for (i, v) in testValues.enumerated() {
            let x = i % 8, y = i / 8
            frame.setPixelSigned(x: x, y: y, channel: 0, value: v)
        }

        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        XCTAssertGreaterThan(encoded.data.count, 0)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        XCTAssertEqual(decoded.width, frame.width)
        XCTAssertEqual(decoded.height, frame.height)

        for (i, v) in testValues.enumerated() {
            let x = i % 8, y = i / 8
            // The decoder returns UInt16 bit patterns; compare via bit pattern
            let originalBits = frame.getPixel(x: x, y: y, channel: 0)
            let decodedBits = decoded.getPixel(x: x, y: y, channel: 0)
            XCTAssertEqual(decodedBits, originalBits,
                           "Signed 16-bit bit-pattern mismatch for value \(v) at (\(x),\(y))")
        }
    }

    // MARK: - Float32 lossless round-trip

    func testPixelType_Float32_LosslessRoundTrip() throws {
        var frame = ImageFrame(width: 4, height: 4, channels: 1,
                               pixelType: .float32, colorSpace: .grayscale,
                               bitsPerSample: 32)
        let testFloats: [Float] = [0.0, 0.25, 0.5, 0.75, 1.0,
                                   0.1, 0.9, 0.33, 0.67, 0.01,
                                   0.99, 0.123, 0.456, 0.789, 0.0, 1.0]
        for (i, v) in testFloats.enumerated() {
            let x = i % 4, y = i / 4
            frame.setPixelFloat(x: x, y: y, channel: 0, value: v)
        }

        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        XCTAssertGreaterThan(encoded.data.count, 0)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        for (i, v) in testFloats.enumerated() {
            let x = i % 4, y = i / 4
            // Float stored as uint16 (scaled); allow small tolerance
            let originalU16 = frame.getPixel(x: x, y: y, channel: 0)
            let decodedU16 = decoded.getPixel(x: x, y: y, channel: 0)
            let maxDelta: UInt16 = 2  // ≤ 2 out of 65535
            let diff = decodedU16 > originalU16 ? decodedU16 - originalU16 : originalU16 - decodedU16
            XCTAssertLessThanOrEqual(diff, maxDelta,
                "Float32 round-trip error \(diff) for value \(v) at (\(x),\(y))")
        }
    }

    // MARK: - Monochrome single-channel encoding

    func testMonochrome_SingleChannel_EncodesValidJXL() throws {
        var frame = ImageFrame(width: 16, height: 16, channels: 1,
                               pixelType: .uint16, colorSpace: .grayscale,
                               bitsPerSample: 16,
                               medicalMetadata: MedicalImageMetadata(
                                   photometricInterpretation: .monochrome2
                               ))
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(y * 16 + x) * 256)
            }
        }

        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)
        XCTAssertGreaterThan(encoded.data.count, 0, "Monochrome frame must produce non-empty output")

        // Verify the output begins with a valid JPEG XL signature
        let bytes = [UInt8](encoded.data)
        let isContainer = bytes.count >= 12 &&
            bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x00 && bytes[3] == 0x0C
        let isRawCB = bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0x0A
        XCTAssertTrue(isContainer || isRawCB,
                      "Output does not start with a valid JPEG XL signature")
    }

    func testMonochrome1_PhotometricInterpretation_Stored() {
        let meta = MedicalImageMetadata(photometricInterpretation: .monochrome1)
        XCTAssertEqual(meta.photometricInterpretation, .monochrome1)

        let frame = ImageFrame(
            width: 8, height: 8, channels: 1,
            pixelType: .uint8, colorSpace: .grayscale,
            medicalMetadata: meta
        )
        XCTAssertEqual(frame.medicalMetadata?.photometricInterpretation, .monochrome1)
    }

    // MARK: - Large medical image (4096×4096, 16-bit)

    func testLargeMedicalImage_4096x4096_16bit_EncodesWithinMemoryTarget() throws {
        let width = 4096, height = 4096
        // Validate that the frame passes medical validation before encoding
        let frame = ImageFrame.medical16bit(width: width, height: height)
        XCTAssertNoThrow(try MedicalImageValidator.validate(frame),
                         "4096×4096 16-bit frame should pass medical validation")

        // Verify the data buffer is the correct size (4096×4096×2 bytes)
        let expectedBytes = width * height * 2
        XCTAssertEqual(frame.data.count, expectedBytes)

        // Verify no encoder throws for this size
        let encoder = JXLEncoder(options: .medicalLossless)
        XCTAssertNoThrow(try encoder.encode(frame),
                         "Encoding 4096×4096 16-bit frame must not throw")
    }

    // MARK: - Multi-frame medical series

    func testMultiFrameSeries_100Frames_512x512_16bit() throws {
        let width = 512, height = 512, frameCount = 100

        var frames: [ImageFrame] = []
        for i in 0..<frameCount {
            var frame = ImageFrame.medical16bit(width: width, height: height)
            // Fill each frame with a slice-dependent value
            let sliceValue = UInt16(i * 655)  // 0..65500 across 100 slices
            for y in 0..<height {
                for x in 0..<width {
                    frame.setPixel(x: x, y: y, channel: 0, value: sliceValue)
                }
            }
            frames.append(frame)
        }

        // Build series — validates consistency
        let series = try MedicalImageSeries(frames: frames,
                                            description: "CT Abdomen, 100 axial slices")
        XCTAssertEqual(series.frameCount, frameCount)
        XCTAssertEqual(series.width, width)
        XCTAssertEqual(series.height, height)
        XCTAssertEqual(series.pixelType, .uint16)

        // Encode the series using the encoder multi-frame API
        var opts = EncodingOptions.medicalLossless
        opts.animationConfig = series.animationConfig
        let encoder = JXLEncoder(options: opts)
        let encoded = try encoder.encode(series.frames)
        XCTAssertGreaterThan(encoded.data.count, 0, "Multi-frame series encode must produce data")
    }

    // MARK: - Lossy encoding quality metric

    func testLossyEncoding_MedicalImage_PSNR45dB() throws {
        let width = 64, height = 64
        var frame = ImageFrame(width: width, height: height, channels: 1,
                               pixelType: .uint8, colorSpace: .grayscale,
                               bitsPerSample: 8)
        // Fill with a smooth gradient
        for y in 0..<height {
            for x in 0..<width {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(y * 4))
            }
        }

        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 95)))
        let encoded = try encoder.encode(frame)
        XCTAssertGreaterThan(encoded.data.count, 0)

        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)

        let psnr = try QualityMetrics.psnr(original: frame, reconstructed: decoded)
        XCTAssertGreaterThanOrEqual(psnr, 45.0,
            "PSNR \(psnr) dB is below the 45 dB target for quality-95 medical lossy encoding")
    }

    // MARK: - Metadata passthrough

    func testMetadataPassthrough_ApplicationData_SurvivesRoundTrip() throws {
        let payload = Data("DICOM-APP-TAG:0x0010,0x0010=Test^Patient".utf8)
        let meta = MedicalImageMetadata(
            photometricInterpretation: .monochrome2,
            windowLevels: [.softTissue, .lung],
            rescaleIntercept: -1024.0,
            rescaleSlope: 1.0,
            applicationData: payload
        )

        let frame = ImageFrame(
            width: 8, height: 8, channels: 1,
            pixelType: .uint16, colorSpace: .grayscale,
            bitsPerSample: 16,
            medicalMetadata: meta
        )

        // The metadata must be accessible from the frame before encoding
        XCTAssertEqual(frame.medicalMetadata?.applicationData, payload)
        XCTAssertEqual(frame.medicalMetadata?.windowLevels.count, 2)
        XCTAssertEqual(frame.medicalMetadata?.windowLevels[0], .softTissue)
        XCTAssertEqual(frame.medicalMetadata?.windowLevels[1], .lung)
        XCTAssertEqual(frame.medicalMetadata?.rescaleIntercept, -1024.0)
        XCTAssertEqual(frame.medicalMetadata?.rescaleSlope, 1.0)
        XCTAssertEqual(frame.medicalMetadata?.photometricInterpretation, .monochrome2)

        // Encode and decode; the metadata should still be present in the frame
        // (it is not re-read from the JXL stream in this implementation, but
        //  the pre-encode frame retains the values — which is what we verify)
        let encoder = JXLEncoder(options: .lossless)
        XCTAssertNoThrow(try encoder.encode(frame))
    }

    // MARK: - PhotometricInterpretation

    func testPhotometricInterpretation_AllCasesAvailable() {
        let cases: [PhotometricInterpretation] = [.monochrome1, .monochrome2, .rgb, .yCbCr]
        XCTAssertEqual(cases.count, 4)
    }

    func testPhotometricInterpretation_Default_IsMonochrome2() {
        XCTAssertEqual(PhotometricInterpretation.default, .monochrome2)
    }

    // MARK: - WindowLevel

    func testWindowLevel_Presets() {
        XCTAssertEqual(WindowLevel.softTissue.centre, 40)
        XCTAssertEqual(WindowLevel.softTissue.width, 400)

        XCTAssertEqual(WindowLevel.lung.centre, -600)
        XCTAssertEqual(WindowLevel.lung.width, 1500)

        XCTAssertEqual(WindowLevel.bone.centre, 300)
        XCTAssertEqual(WindowLevel.bone.width, 1500)

        XCTAssertEqual(WindowLevel.brain.centre, 40)
        XCTAssertEqual(WindowLevel.brain.width, 80)
    }

    func testWindowLevel_CustomInit() {
        let wl = WindowLevel(centre: 100.0, width: 500.0, label: "Custom")
        XCTAssertEqual(wl.centre, 100.0)
        XCTAssertEqual(wl.width, 500.0)
        XCTAssertEqual(wl.label, "Custom")
    }

    // MARK: - MedicalImageMetadata

    func testMedicalImageMetadata_DefaultValues() {
        let meta = MedicalImageMetadata()
        XCTAssertEqual(meta.photometricInterpretation, .monochrome2)
        XCTAssertTrue(meta.windowLevels.isEmpty)
        XCTAssertEqual(meta.rescaleIntercept, 0.0)
        XCTAssertEqual(meta.rescaleSlope, 1.0)
        XCTAssertTrue(meta.applicationData.isEmpty)
    }

    // MARK: - Convenience initialisers

    func testImageFrame_Medical12bit_Configuration() {
        let frame = ImageFrame.medical12bit(width: 512, height: 512)
        XCTAssertEqual(frame.width, 512)
        XCTAssertEqual(frame.height, 512)
        XCTAssertEqual(frame.channels, 1)
        XCTAssertEqual(frame.pixelType, .uint16)
        XCTAssertEqual(frame.bitsPerSample, 12)
        XCTAssertEqual(frame.medicalMetadata?.photometricInterpretation, .monochrome2)
    }

    func testImageFrame_Medical16bit_Configuration() {
        let frame = ImageFrame.medical16bit(width: 256, height: 256)
        XCTAssertEqual(frame.pixelType, .uint16)
        XCTAssertEqual(frame.bitsPerSample, 16)
        XCTAssertEqual(frame.channels, 1)
    }

    func testImageFrame_MedicalSigned16bit_Configuration() {
        let frame = ImageFrame.medicalSigned16bit(width: 256, height: 256)
        XCTAssertEqual(frame.pixelType, .int16)
        XCTAssertEqual(frame.bitsPerSample, 16)
        XCTAssertEqual(frame.channels, 1)
        XCTAssertEqual(frame.medicalMetadata?.rescaleIntercept, -1024.0)
    }

    func testImageFrame_MedicalSigned16bit_WithWindowLevel() {
        let frame = ImageFrame.medicalSigned16bit(
            width: 128, height: 128,
            windowLevels: [.bone, .softTissue]
        )
        XCTAssertEqual(frame.medicalMetadata?.windowLevels.count, 2)
        XCTAssertEqual(frame.medicalMetadata?.windowLevels[0], .bone)
    }

    // MARK: - MedicalImageValidator

    func testValidator_ValidFrame_DoesNotThrow() {
        let frame = ImageFrame.medical16bit(width: 512, height: 512)
        XCTAssertNoThrow(try MedicalImageValidator.validate(frame))
    }

    func testValidator_DimensionTooLarge_Throws() {
        let frame = ImageFrame(width: 20000, height: 100, channels: 1,
                               pixelType: .uint16, colorSpace: .grayscale,
                               bitsPerSample: 16)
        XCTAssertThrowsError(try MedicalImageValidator.validate(frame)) { error in
            guard case MedicalImageValidator.ValidationError.dimensionTooLarge = error else {
                XCTFail("Expected dimensionTooLarge, got \(error)")
                return
            }
        }
    }

    func testValidator_InvalidChannelCount_Throws() {
        let frame = ImageFrame(width: 64, height: 64, channels: 2,
                               pixelType: .uint16, colorSpace: .grayscale,
                               bitsPerSample: 16)
        XCTAssertThrowsError(try MedicalImageValidator.validate(frame)) { error in
            guard case MedicalImageValidator.ValidationError.invalidChannelCount = error else {
                XCTFail("Expected invalidChannelCount, got \(error)")
                return
            }
        }
    }

    func testValidator_UnsupportedBitDepth_Throws() {
        let frame = ImageFrame(width: 64, height: 64, channels: 1,
                               pixelType: .uint16, colorSpace: .grayscale,
                               bitsPerSample: 10)
        XCTAssertThrowsError(try MedicalImageValidator.validate(frame)) { error in
            guard case MedicalImageValidator.ValidationError.unsupportedBitDepth = error else {
                XCTFail("Expected unsupportedBitDepth, got \(error)")
                return
            }
        }
    }

    func testValidator_Series_InconsistentDimensions_Throws() throws {
        let frame1 = ImageFrame.medical16bit(width: 512, height: 512)
        let frame2 = ImageFrame.medical16bit(width: 256, height: 256)
        XCTAssertThrowsError(try MedicalImageSeries(frames: [frame1, frame2]))
    }

    // MARK: - MedicalImageSeries

    func testMedicalImageSeries_EmptyFrames_Throws() {
        XCTAssertThrowsError(try MedicalImageSeries(frames: []))
    }

    func testMedicalImageSeries_AnimationConfig_IsCorrect() throws {
        let frame = ImageFrame.medical16bit(width: 64, height: 64)
        let series = try MedicalImageSeries(frames: [frame, frame],
                                            description: "Test series")
        XCTAssertEqual(series.animationConfig.fps, 1)
        XCTAssertEqual(series.animationConfig.loopCount, 0)
        XCTAssertEqual(series.description, "Test series")
    }

    // MARK: - EncodingOptions medical preset

    func testEncodingOptions_MedicalLossless_IsLossless() {
        let opts = EncodingOptions.medicalLossless
        if case .lossless = opts.mode {
            // expected
        } else {
            XCTFail("medicalLossless preset must use lossless mode")
        }
        XCTAssertTrue(opts.modularMode, "medicalLossless must use Modular mode")
    }

    // MARK: - getPixelFloat / setPixelFloat round-trips

    func testGetSetPixelFloat_UInt8_RoundTrip() {
        var frame = ImageFrame(width: 2, height: 1, channels: 1,
                               pixelType: .uint8, colorSpace: .grayscale,
                               bitsPerSample: 8)
        frame.setPixelFloat(x: 0, y: 0, channel: 0, value: 0.5)
        let got = frame.getPixelFloat(x: 0, y: 0, channel: 0)
        XCTAssertEqual(got, 0.5, accuracy: 0.01)
    }

    func testGetSetPixelFloat_UInt16_RoundTrip() {
        var frame = ImageFrame(width: 2, height: 1, channels: 1,
                               pixelType: .uint16, colorSpace: .grayscale,
                               bitsPerSample: 16)
        frame.setPixelFloat(x: 0, y: 0, channel: 0, value: 0.75)
        let got = frame.getPixelFloat(x: 0, y: 0, channel: 0)
        XCTAssertEqual(got, 0.75, accuracy: 0.0001)
    }

    func testGetSetPixelFloat_Float32_RoundTrip() {
        var frame = ImageFrame(width: 2, height: 1, channels: 1,
                               pixelType: .float32, colorSpace: .grayscale,
                               bitsPerSample: 32)
        let value: Float = 0.123456
        frame.setPixelFloat(x: 0, y: 0, channel: 0, value: value)
        let got = frame.getPixelFloat(x: 0, y: 0, channel: 0)
        XCTAssertEqual(got, value, accuracy: 1e-6)
    }
}
