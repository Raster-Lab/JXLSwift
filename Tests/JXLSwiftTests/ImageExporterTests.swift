/// Tests for ImageExporter and PixelConversion
///
/// Tests cover:
/// - OutputFormat enum detection and all cases
/// - ExporterError error descriptions
/// - PixelConversion planar-to-interleaved for uint8, uint16, float32
/// - Grayscale, RGB, and RGBA frame conversion
/// - Edge cases (1×1 images, large images, zero dimensions)
/// - ImageExporter platform-specific behavior
/// - CLI decode format resolution

import XCTest
@testable import JXLSwift

final class ImageExporterTests: XCTestCase {

    // MARK: - OutputFormat Tests

    func testOutputFormat_AllCases() {
        XCTAssertEqual(OutputFormat.allCases.count, 3)
        XCTAssertTrue(OutputFormat.allCases.contains(.png))
        XCTAssertTrue(OutputFormat.allCases.contains(.tiff))
        XCTAssertTrue(OutputFormat.allCases.contains(.bmp))
    }

    func testOutputFormat_RawValues() {
        XCTAssertEqual(OutputFormat.png.rawValue, "png")
        XCTAssertEqual(OutputFormat.tiff.rawValue, "tiff")
        XCTAssertEqual(OutputFormat.bmp.rawValue, "bmp")
    }

    func testOutputFormat_FromFileExtension_PNG() {
        XCTAssertEqual(OutputFormat.from(fileExtension: "png"), .png)
        XCTAssertEqual(OutputFormat.from(fileExtension: "PNG"), .png)
        XCTAssertEqual(OutputFormat.from(fileExtension: "Png"), .png)
    }

    func testOutputFormat_FromFileExtension_TIFF() {
        XCTAssertEqual(OutputFormat.from(fileExtension: "tiff"), .tiff)
        XCTAssertEqual(OutputFormat.from(fileExtension: "tif"), .tiff)
        XCTAssertEqual(OutputFormat.from(fileExtension: "TIFF"), .tiff)
        XCTAssertEqual(OutputFormat.from(fileExtension: "TIF"), .tiff)
    }

    func testOutputFormat_FromFileExtension_BMP() {
        XCTAssertEqual(OutputFormat.from(fileExtension: "bmp"), .bmp)
        XCTAssertEqual(OutputFormat.from(fileExtension: "BMP"), .bmp)
    }

    func testOutputFormat_FromFileExtension_Unknown() {
        XCTAssertNil(OutputFormat.from(fileExtension: "jpg"))
        XCTAssertNil(OutputFormat.from(fileExtension: "jpeg"))
        XCTAssertNil(OutputFormat.from(fileExtension: "webp"))
        XCTAssertNil(OutputFormat.from(fileExtension: ""))
        XCTAssertNil(OutputFormat.from(fileExtension: "jxl"))
    }

    // MARK: - ExporterError Tests

    func testExporterError_InvalidDimensions_Description() {
        let error = ExporterError.invalidImageDimensions(width: 0, height: 0)
        XCTAssertEqual(error.errorDescription, "Invalid image dimensions: 0×0")
    }

    func testExporterError_CGImageCreationFailed_Description() {
        let error = ExporterError.cgImageCreationFailed
        XCTAssertEqual(error.errorDescription, "Failed to create CGImage from frame data")
    }

    func testExporterError_DestinationCreationFailed_Description() {
        let error = ExporterError.destinationCreationFailed
        XCTAssertEqual(error.errorDescription, "Failed to create image destination")
    }

    func testExporterError_WriteFailed_Description() {
        let error = ExporterError.writeFailed
        XCTAssertEqual(error.errorDescription, "Failed to write image data")
    }

    func testExporterError_UnsupportedChannelCount_Description() {
        let error = ExporterError.unsupportedChannelCount(5)
        XCTAssertEqual(error.errorDescription, "Unsupported channel count for export: 5")
    }

    func testExporterError_UnsupportedPlatform_Description() {
        let error = ExporterError.unsupportedPlatform
        XCTAssertEqual(error.errorDescription, "Image export requires Apple platforms (macOS, iOS, tvOS, watchOS, visionOS)")
    }

    func testExporterError_Equatable() {
        XCTAssertEqual(ExporterError.cgImageCreationFailed, ExporterError.cgImageCreationFailed)
        XCTAssertEqual(ExporterError.writeFailed, ExporterError.writeFailed)
        XCTAssertNotEqual(ExporterError.cgImageCreationFailed, ExporterError.writeFailed)
        XCTAssertEqual(
            ExporterError.invalidImageDimensions(width: 0, height: 0),
            ExporterError.invalidImageDimensions(width: 0, height: 0)
        )
        XCTAssertNotEqual(
            ExporterError.invalidImageDimensions(width: 0, height: 0),
            ExporterError.invalidImageDimensions(width: 1, height: 1)
        )
    }

    // MARK: - PixelConversion — uint8 RGB

    func testInterleave_RGB_UInt8_2x2() throws {
        // 2×2 RGB image, planar: [R0,R1,R2,R3, G0,G1,G2,G3, B0,B1,B2,B3]
        var frame = ImageFrame(width: 2, height: 2, channels: 3, pixelType: .uint8)
        // R channel
        frame.data[0] = 10; frame.data[1] = 20; frame.data[2] = 30; frame.data[3] = 40
        // G channel
        frame.data[4] = 50; frame.data[5] = 60; frame.data[6] = 70; frame.data[7] = 80
        // B channel
        frame.data[8] = 90; frame.data[9] = 100; frame.data[10] = 110; frame.data[11] = 120

        let (data, bytesPerComponent, componentCount) = try PixelConversion.interleave(frame)

        XCTAssertEqual(bytesPerComponent, 1)
        XCTAssertEqual(componentCount, 3)
        XCTAssertEqual(data.count, 12) // 4 pixels × 3 components

        // Pixel 0: R=10, G=50, B=90
        XCTAssertEqual(data[0], 10)
        XCTAssertEqual(data[1], 50)
        XCTAssertEqual(data[2], 90)

        // Pixel 1: R=20, G=60, B=100
        XCTAssertEqual(data[3], 20)
        XCTAssertEqual(data[4], 60)
        XCTAssertEqual(data[5], 100)

        // Pixel 2: R=30, G=70, B=110
        XCTAssertEqual(data[6], 30)
        XCTAssertEqual(data[7], 70)
        XCTAssertEqual(data[8], 110)

        // Pixel 3: R=40, G=80, B=120
        XCTAssertEqual(data[9], 40)
        XCTAssertEqual(data[10], 80)
        XCTAssertEqual(data[11], 120)
    }

    func testInterleave_RGB_UInt8_1x1() throws {
        var frame = ImageFrame(width: 1, height: 1, channels: 3, pixelType: .uint8)
        frame.data[0] = 255  // R
        frame.data[1] = 128  // G
        frame.data[2] = 0    // B

        let (data, bytesPerComponent, componentCount) = try PixelConversion.interleave(frame)

        XCTAssertEqual(bytesPerComponent, 1)
        XCTAssertEqual(componentCount, 3)
        XCTAssertEqual(data, [255, 128, 0])
    }

    // MARK: - PixelConversion — uint8 RGBA

    func testInterleave_RGBA_UInt8_2x1() throws {
        var frame = ImageFrame(width: 2, height: 1, channels: 4, pixelType: .uint8, hasAlpha: true)
        let pixelCount = 2
        // R channel
        frame.data[0] = 100; frame.data[1] = 200
        // G channel
        frame.data[pixelCount] = 110; frame.data[pixelCount + 1] = 210
        // B channel
        frame.data[pixelCount * 2] = 120; frame.data[pixelCount * 2 + 1] = 220
        // A channel
        frame.data[pixelCount * 3] = 255; frame.data[pixelCount * 3 + 1] = 128

        let (data, bytesPerComponent, componentCount) = try PixelConversion.interleave(frame)

        XCTAssertEqual(bytesPerComponent, 1)
        XCTAssertEqual(componentCount, 4)
        XCTAssertEqual(data.count, 8) // 2 pixels × 4 components

        // Pixel 0: R=100, G=110, B=120, A=255
        XCTAssertEqual(data[0], 100)
        XCTAssertEqual(data[1], 110)
        XCTAssertEqual(data[2], 120)
        XCTAssertEqual(data[3], 255)

        // Pixel 1: R=200, G=210, B=220, A=128
        XCTAssertEqual(data[4], 200)
        XCTAssertEqual(data[5], 210)
        XCTAssertEqual(data[6], 220)
        XCTAssertEqual(data[7], 128)
    }

    // MARK: - PixelConversion — uint8 Grayscale

    func testInterleave_Grayscale_UInt8() throws {
        var frame = ImageFrame(width: 3, height: 1, channels: 1, pixelType: .uint8)
        frame.data[0] = 0
        frame.data[1] = 128
        frame.data[2] = 255

        let (data, bytesPerComponent, componentCount) = try PixelConversion.interleave(frame)

        XCTAssertEqual(bytesPerComponent, 1)
        XCTAssertEqual(componentCount, 1)
        XCTAssertEqual(data, [0, 128, 255])
    }

    // MARK: - PixelConversion — uint16 RGB

    func testInterleave_RGB_UInt16_1x1() throws {
        var frame = ImageFrame(width: 1, height: 1, channels: 3, pixelType: .uint16, bitsPerSample: 16)
        // R = 1000 (0x03E8), G = 2000 (0x07D0), B = 3000 (0x0BB8) — little-endian
        frame.data[0] = 0xE8; frame.data[1] = 0x03  // R
        frame.data[2] = 0xD0; frame.data[3] = 0x07  // G
        frame.data[4] = 0xB8; frame.data[5] = 0x0B  // B

        let (data, bytesPerComponent, componentCount) = try PixelConversion.interleave(frame)

        XCTAssertEqual(bytesPerComponent, 2)
        XCTAssertEqual(componentCount, 3)
        XCTAssertEqual(data.count, 6) // 1 pixel × 3 components × 2 bytes

        // R low, R high, G low, G high, B low, B high
        XCTAssertEqual(data[0], 0xE8)
        XCTAssertEqual(data[1], 0x03)
        XCTAssertEqual(data[2], 0xD0)
        XCTAssertEqual(data[3], 0x07)
        XCTAssertEqual(data[4], 0xB8)
        XCTAssertEqual(data[5], 0x0B)
    }

    // MARK: - PixelConversion — uint16 Grayscale

    func testInterleave_Grayscale_UInt16() throws {
        var frame = ImageFrame(width: 2, height: 1, channels: 1, pixelType: .uint16, bitsPerSample: 16)
        // Pixel 0: value 500 (0x01F4), Pixel 1: value 60000 (0xEA60)
        frame.data[0] = 0xF4; frame.data[1] = 0x01
        frame.data[2] = 0x60; frame.data[3] = 0xEA

        let (data, bytesPerComponent, componentCount) = try PixelConversion.interleave(frame)

        XCTAssertEqual(bytesPerComponent, 2)
        XCTAssertEqual(componentCount, 1)
        XCTAssertEqual(data.count, 4) // 2 pixels × 1 component × 2 bytes

        XCTAssertEqual(data[0], 0xF4)
        XCTAssertEqual(data[1], 0x01)
        XCTAssertEqual(data[2], 0x60)
        XCTAssertEqual(data[3], 0xEA)
    }

    // MARK: - PixelConversion — float32 RGB

    func testInterleave_RGB_Float32_1x1() throws {
        var frame = ImageFrame(width: 1, height: 1, channels: 3, pixelType: .float32)
        // Write float values: R=1.0, G=0.5, B=0.0
        writeFloat(&frame.data, at: 0, value: 1.0)  // R
        writeFloat(&frame.data, at: 4, value: 0.5)  // G
        writeFloat(&frame.data, at: 8, value: 0.0)  // B

        let (data, bytesPerComponent, componentCount) = try PixelConversion.interleave(frame)

        XCTAssertEqual(bytesPerComponent, 1) // float32 converts to uint8
        XCTAssertEqual(componentCount, 3)
        XCTAssertEqual(data.count, 3)

        XCTAssertEqual(data[0], 255) // 1.0 → 255
        XCTAssertEqual(data[1], 128) // 0.5 → 128
        XCTAssertEqual(data[2], 0)   // 0.0 → 0
    }

    func testInterleave_RGB_Float32_Clamping() throws {
        var frame = ImageFrame(width: 1, height: 1, channels: 3, pixelType: .float32)
        // Out-of-range values
        writeFloat(&frame.data, at: 0, value: 2.0)   // R > 1.0
        writeFloat(&frame.data, at: 4, value: -0.5)   // G < 0.0
        writeFloat(&frame.data, at: 8, value: 0.75)   // B = normal

        let (data, _, _) = try PixelConversion.interleave(frame)

        XCTAssertEqual(data[0], 255) // clamped to 255
        XCTAssertEqual(data[1], 0)   // clamped to 0
        XCTAssertEqual(data[2], 191) // 0.75 * 255 ≈ 191
    }

    // MARK: - PixelConversion — float32 Grayscale

    func testInterleave_Grayscale_Float32() throws {
        var frame = ImageFrame(width: 2, height: 1, channels: 1, pixelType: .float32)
        writeFloat(&frame.data, at: 0, value: 0.0)
        writeFloat(&frame.data, at: 4, value: 1.0)

        let (data, bytesPerComponent, componentCount) = try PixelConversion.interleave(frame)

        XCTAssertEqual(bytesPerComponent, 1)
        XCTAssertEqual(componentCount, 1)
        XCTAssertEqual(data, [0, 255])
    }

    // MARK: - PixelConversion — Error Cases

    func testInterleave_ZeroDimensions_ThrowsError() {
        let frame = ImageFrame(width: 0, height: 10, channels: 3)
        XCTAssertThrowsError(try PixelConversion.interleave(frame)) { error in
            guard let exportError = error as? ExporterError else {
                XCTFail("Expected ExporterError"); return
            }
            XCTAssertEqual(exportError, ExporterError.invalidImageDimensions(width: 0, height: 10))
        }
    }

    func testInterleave_UnsupportedChannelCount_ThrowsError() {
        let frame = ImageFrame(width: 2, height: 2, channels: 2)
        XCTAssertThrowsError(try PixelConversion.interleave(frame)) { error in
            guard let exportError = error as? ExporterError else {
                XCTFail("Expected ExporterError"); return
            }
            XCTAssertEqual(exportError, ExporterError.unsupportedChannelCount(2))
        }
    }

    func testInterleave_FiveChannels_ThrowsError() {
        // 5 channels is not supported (only 1, 3, 4)
        // ImageFrame will allocate for 5 channels but interleave should reject
        let frame = ImageFrame(width: 2, height: 2, channels: 5)
        XCTAssertThrowsError(try PixelConversion.interleave(frame)) { error in
            guard let exportError = error as? ExporterError else {
                XCTFail("Expected ExporterError"); return
            }
            XCTAssertEqual(exportError, ExporterError.unsupportedChannelCount(5))
        }
    }

    // MARK: - PixelConversion — Larger Images

    func testInterleave_RGB_UInt8_8x8() throws {
        var frame = ImageFrame(width: 8, height: 8, channels: 3, pixelType: .uint8)
        let pixelCount = 64
        // Fill with gradient pattern
        for i in 0..<pixelCount {
            frame.data[i] = UInt8(i * 4 % 256)                       // R
            frame.data[pixelCount + i] = UInt8((i * 3 + 50) % 256)   // G
            frame.data[pixelCount * 2 + i] = UInt8((i * 2 + 100) % 256) // B
        }

        let (data, bytesPerComponent, componentCount) = try PixelConversion.interleave(frame)

        XCTAssertEqual(bytesPerComponent, 1)
        XCTAssertEqual(componentCount, 3)
        XCTAssertEqual(data.count, pixelCount * 3)

        // Verify first and last pixels
        XCTAssertEqual(data[0], 0)       // R[0]
        XCTAssertEqual(data[1], 50)      // G[0]
        XCTAssertEqual(data[2], 100)     // B[0]

        let lastIdx = (pixelCount - 1) * 3
        XCTAssertEqual(data[lastIdx], UInt8(63 * 4 % 256))
        XCTAssertEqual(data[lastIdx + 1], UInt8((63 * 3 + 50) % 256))
        XCTAssertEqual(data[lastIdx + 2], UInt8((63 * 2 + 100) % 256))
    }

    // MARK: - PixelConversion — RGB without alpha flag

    func testInterleave_RGB_NoAlpha_3Channels() throws {
        // 3-channel frame without alpha flag should produce RGB (3 components)
        var frame = ImageFrame(width: 1, height: 1, channels: 3, pixelType: .uint8, hasAlpha: false)
        frame.data[0] = 100  // R
        frame.data[1] = 150  // G
        frame.data[2] = 200  // B

        let (data, _, componentCount) = try PixelConversion.interleave(frame)

        XCTAssertEqual(componentCount, 3)
        XCTAssertEqual(data, [100, 150, 200])
    }

    // MARK: - PixelConversion — 4-channel frame with alpha

    func testInterleave_RGBA_UInt16_1x1() throws {
        var frame = ImageFrame(width: 1, height: 1, channels: 4, pixelType: .uint16, hasAlpha: true, bitsPerSample: 16)
        let pixelCount = 1
        // R = 0x1234, G = 0x5678, B = 0x9ABC, A = 0xDEF0
        frame.data[0] = 0x34; frame.data[1] = 0x12  // R
        frame.data[pixelCount * 2] = 0x78; frame.data[pixelCount * 2 + 1] = 0x56  // G
        frame.data[pixelCount * 4] = 0xBC; frame.data[pixelCount * 4 + 1] = 0x9A  // B
        frame.data[pixelCount * 6] = 0xF0; frame.data[pixelCount * 6 + 1] = 0xDE  // A

        let (data, bytesPerComponent, componentCount) = try PixelConversion.interleave(frame)

        XCTAssertEqual(bytesPerComponent, 2)
        XCTAssertEqual(componentCount, 4)
        XCTAssertEqual(data.count, 8) // 1 pixel × 4 components × 2 bytes

        // R
        XCTAssertEqual(data[0], 0x34)
        XCTAssertEqual(data[1], 0x12)
        // G
        XCTAssertEqual(data[2], 0x78)
        XCTAssertEqual(data[3], 0x56)
        // B
        XCTAssertEqual(data[4], 0xBC)
        XCTAssertEqual(data[5], 0x9A)
        // A
        XCTAssertEqual(data[6], 0xF0)
        XCTAssertEqual(data[7], 0xDE)
    }

    // MARK: - PixelConversion Helper — readFloat / clampToUInt8

    func testReadFloat_LittleEndian() {
        let value: Float = 0.5
        let bits = value.bitPattern
        let bytes: [UInt8] = [
            UInt8(bits & 0xFF),
            UInt8((bits >> 8) & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 24) & 0xFF)
        ]

        let result = PixelConversion.readFloat(from: bytes, at: 0)
        XCTAssertEqual(result, 0.5, accuracy: 0.0001)
    }

    func testClampToUInt8_NormalRange() {
        XCTAssertEqual(PixelConversion.clampToUInt8(0.0), 0)
        XCTAssertEqual(PixelConversion.clampToUInt8(1.0), 255)
        XCTAssertEqual(PixelConversion.clampToUInt8(0.5), 128)
    }

    func testClampToUInt8_OutOfRange() {
        XCTAssertEqual(PixelConversion.clampToUInt8(-1.0), 0)
        XCTAssertEqual(PixelConversion.clampToUInt8(2.0), 255)
        XCTAssertEqual(PixelConversion.clampToUInt8(100.0), 255)
    }

    // MARK: - ImageExporter — Platform-Specific Tests

    #if canImport(CoreGraphics) && canImport(ImageIO)

    func testExport_PNG_RGB_UInt8() throws {
        var frame = ImageFrame(width: 4, height: 4, channels: 3, pixelType: .uint8)
        for i in 0..<48 {
            frame.data[i] = UInt8(i * 5 % 256)
        }

        let data = try ImageExporter.export(frame, format: .png)
        XCTAssertGreaterThan(data.count, 0)
        // PNG signature: 0x89 0x50 0x4E 0x47
        XCTAssertEqual(data[0], 0x89)
        XCTAssertEqual(data[1], 0x50)
        XCTAssertEqual(data[2], 0x4E)
        XCTAssertEqual(data[3], 0x47)
    }

    func testExport_TIFF_RGB_UInt8() throws {
        var frame = ImageFrame(width: 4, height: 4, channels: 3, pixelType: .uint8)
        for i in 0..<48 {
            frame.data[i] = UInt8(i * 3 % 256)
        }

        let data = try ImageExporter.export(frame, format: .tiff)
        XCTAssertGreaterThan(data.count, 0)
        // TIFF starts with II (0x49 0x49) or MM (0x4D 0x4D)
        let isLittleEndian = data[0] == 0x49 && data[1] == 0x49
        let isBigEndian = data[0] == 0x4D && data[1] == 0x4D
        XCTAssertTrue(isLittleEndian || isBigEndian, "Expected TIFF signature")
    }

    func testExport_BMP_RGB_UInt8() throws {
        var frame = ImageFrame(width: 4, height: 4, channels: 3, pixelType: .uint8)
        for i in 0..<48 {
            frame.data[i] = UInt8(i * 7 % 256)
        }

        let data = try ImageExporter.export(frame, format: .bmp)
        XCTAssertGreaterThan(data.count, 0)
        // BMP signature: BM (0x42 0x4D)
        XCTAssertEqual(data[0], 0x42)
        XCTAssertEqual(data[1], 0x4D)
    }

    func testExport_PNG_Grayscale_UInt8() throws {
        var frame = ImageFrame(width: 8, height: 8, channels: 1, pixelType: .uint8)
        for i in 0..<64 {
            frame.data[i] = UInt8(i * 4 % 256)
        }

        let data = try ImageExporter.export(frame, format: .png)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(data[0], 0x89) // PNG signature
    }

    func testExport_PNG_RGBA_UInt8() throws {
        var frame = ImageFrame(width: 4, height: 4, channels: 4, pixelType: .uint8, hasAlpha: true)
        let pixelCount = 16
        for i in 0..<pixelCount {
            frame.data[i] = UInt8(i * 10 % 256)                    // R
            frame.data[pixelCount + i] = UInt8((i * 10 + 50) % 256)  // G
            frame.data[pixelCount * 2 + i] = UInt8((i * 10 + 100) % 256) // B
            frame.data[pixelCount * 3 + i] = 200                   // A
        }

        let data = try ImageExporter.export(frame, format: .png)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(data[0], 0x89) // PNG signature
    }

    func testExport_ToFile_AutoDetectFormat() throws {
        var frame = ImageFrame(width: 2, height: 2, channels: 3, pixelType: .uint8)
        for i in 0..<12 {
            frame.data[i] = UInt8(i * 20 % 256)
        }

        let tempDir = FileManager.default.temporaryDirectory
        let pngURL = tempDir.appendingPathComponent("test_export_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: pngURL) }

        try ImageExporter.export(frame, to: pngURL)

        let savedData = try Data(contentsOf: pngURL)
        XCTAssertGreaterThan(savedData.count, 0)
        XCTAssertEqual(savedData[0], 0x89) // PNG signature
    }

    func testExport_ToFile_ExplicitFormat() throws {
        var frame = ImageFrame(width: 2, height: 2, channels: 3, pixelType: .uint8)
        for i in 0..<12 {
            frame.data[i] = UInt8(i * 20 % 256)
        }

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("test_export_\(UUID().uuidString).dat")
        defer { try? FileManager.default.removeItem(at: url) }

        try ImageExporter.export(frame, to: url, format: .tiff)

        let savedData = try Data(contentsOf: url)
        XCTAssertGreaterThan(savedData.count, 0)
        // TIFF signature
        let isLittleEndian = savedData[0] == 0x49 && savedData[1] == 0x49
        let isBigEndian = savedData[0] == 0x4D && savedData[1] == 0x4D
        XCTAssertTrue(isLittleEndian || isBigEndian)
    }

    func testCreateCGImage_RGB_UInt8() throws {
        var frame = ImageFrame(width: 4, height: 4, channels: 3, pixelType: .uint8)
        for i in 0..<48 {
            frame.data[i] = UInt8(i * 5 % 256)
        }

        let cgImage = try ImageExporter.createCGImage(from: frame)
        XCTAssertEqual(cgImage.width, 4)
        XCTAssertEqual(cgImage.height, 4)
        XCTAssertEqual(cgImage.bitsPerComponent, 8)
        XCTAssertEqual(cgImage.bitsPerPixel, 24)
    }

    func testCreateCGImage_Grayscale_UInt8() throws {
        var frame = ImageFrame(width: 4, height: 4, channels: 1, pixelType: .uint8)
        for i in 0..<16 {
            frame.data[i] = UInt8(i * 16)
        }

        let cgImage = try ImageExporter.createCGImage(from: frame)
        XCTAssertEqual(cgImage.width, 4)
        XCTAssertEqual(cgImage.height, 4)
        XCTAssertEqual(cgImage.bitsPerComponent, 8)
        XCTAssertEqual(cgImage.bitsPerPixel, 8)
    }

    func testCreateCGImage_RGB_UInt16() throws {
        var frame = ImageFrame(width: 2, height: 2, channels: 3, pixelType: .uint16, bitsPerSample: 16)
        // Fill with some 16-bit values
        for i in 0..<12 {
            let offset = i * 2
            frame.data[offset] = UInt8(i * 10 % 256)
            frame.data[offset + 1] = UInt8(i % 256)
        }

        let cgImage = try ImageExporter.createCGImage(from: frame)
        XCTAssertEqual(cgImage.width, 2)
        XCTAssertEqual(cgImage.height, 2)
        XCTAssertEqual(cgImage.bitsPerComponent, 16)
        XCTAssertEqual(cgImage.bitsPerPixel, 48)
    }

    func testCreateCGImage_Float32_ConvertedToUInt8() throws {
        var frame = ImageFrame(width: 2, height: 2, channels: 3, pixelType: .float32)
        let pixelCount = 4
        for c in 0..<3 {
            for i in 0..<pixelCount {
                writeFloat(&frame.data, at: (c * pixelCount + i) * 4, value: Float(i) / Float(pixelCount - 1))
            }
        }

        let cgImage = try ImageExporter.createCGImage(from: frame)
        XCTAssertEqual(cgImage.width, 2)
        XCTAssertEqual(cgImage.height, 2)
        XCTAssertEqual(cgImage.bitsPerComponent, 8) // float32 → uint8
    }

    #else

    func testExport_UnsupportedPlatform_ThrowsError() {
        let frame = ImageFrame(width: 2, height: 2, channels: 3, pixelType: .uint8)
        XCTAssertThrowsError(try ImageExporter.export(frame, format: .png)) { error in
            guard let exportError = error as? ExporterError else {
                XCTFail("Expected ExporterError"); return
            }
            XCTAssertEqual(exportError, ExporterError.unsupportedPlatform)
        }
    }

    func testExportToFile_UnsupportedPlatform_ThrowsError() {
        let frame = ImageFrame(width: 2, height: 2, channels: 3, pixelType: .uint8)
        let url = URL(fileURLWithPath: "/tmp/test.png")
        XCTAssertThrowsError(try ImageExporter.export(frame, to: url)) { error in
            guard let exportError = error as? ExporterError else {
                XCTFail("Expected ExporterError"); return
            }
            XCTAssertEqual(exportError, ExporterError.unsupportedPlatform)
        }
    }

    #endif

    // MARK: - Round-trip: Encode → Decode → Export Interleave

    func testRoundTrip_Encode_Decode_Interleave() throws {
        // Create a small test image
        var frame = ImageFrame(width: 8, height: 8, channels: 3, pixelType: .uint8)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))   // R
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 32))   // G
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(128))       // B
            }
        }

        // Encode with lossless mode
        let encoder = JXLEncoder(options: .lossless)
        let encoded = try encoder.encode(frame)

        // Decode
        let decoder = JXLDecoder()
        let decoded = try decoder.decode(encoded.data)
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)

        // Convert to interleaved
        let (data, bytesPerComponent, componentCount) = try PixelConversion.interleave(decoded)
        XCTAssertEqual(bytesPerComponent, 1)
        XCTAssertEqual(componentCount, 3)
        XCTAssertEqual(data.count, 8 * 8 * 3)

        // Verify pixel values are preserved (lossless)
        for y in 0..<8 {
            for x in 0..<8 {
                let idx = (y * 8 + x) * 3
                XCTAssertEqual(data[idx], UInt8(x * 32), "R mismatch at (\(x), \(y))")
                XCTAssertEqual(data[idx + 1], UInt8(y * 32), "G mismatch at (\(x), \(y))")
                XCTAssertEqual(data[idx + 2], 128, "B mismatch at (\(x), \(y))")
            }
        }
    }

    // MARK: - Helpers

    /// Write a Float32 value to a byte array at the given offset (little-endian).
    private func writeFloat(_ data: inout [UInt8], at offset: Int, value: Float) {
        let bits = value.bitPattern
        data[offset] = UInt8(bits & 0xFF)
        data[offset + 1] = UInt8((bits >> 8) & 0xFF)
        data[offset + 2] = UInt8((bits >> 16) & 0xFF)
        data[offset + 3] = UInt8((bits >> 24) & 0xFF)
    }
}
