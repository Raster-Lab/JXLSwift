import XCTest
@testable import JXLSwift

/// Tests for responsive encoding (quality-layered progressive delivery)
final class ResponsiveEncodingTests: XCTestCase {
    
    // MARK: - ResponsiveConfig Tests
    
    func testResponsiveConfig_DefaultInitialization_ThreeLayers() {
        let config = ResponsiveConfig()
        
        XCTAssertEqual(config.layerCount, 3)
        XCTAssertTrue(config.layerDistances.isEmpty)
    }
    
    func testResponsiveConfig_CustomLayerCount_ClampsToValidRange() {
        let tooLow = ResponsiveConfig(layerCount: 1)
        let tooHigh = ResponsiveConfig(layerCount: 10)
        let valid = ResponsiveConfig(layerCount: 4)
        
        XCTAssertEqual(tooLow.layerCount, 2, "Layer count should be clamped to minimum 2")
        XCTAssertEqual(tooHigh.layerCount, 8, "Layer count should be clamped to maximum 8")
        XCTAssertEqual(valid.layerCount, 4)
    }
    
    func testResponsiveConfig_CustomDistances_Valid() throws {
        // Distances in descending order (highest distance/lowest quality first)
        let config = ResponsiveConfig(
            layerCount: 3,
            layerDistances: [6.0, 3.0, 1.0]
        )
        
        XCTAssertNoThrow(try config.validate())
    }
    
    func testResponsiveConfig_CustomDistances_CountMismatch_ThrowsError() {
        let config = ResponsiveConfig(
            layerCount: 3,
            layerDistances: [6.0, 3.0] // Only 2 distances for 3 layers
        )
        
        XCTAssertThrowsError(try config.validate()) { error in
            let nsError = error as NSError
            XCTAssertTrue(nsError.localizedDescription.contains("must match layerCount"))
        }
    }
    
    func testResponsiveConfig_CustomDistances_NotDescending_ThrowsError() {
        let config = ResponsiveConfig(
            layerCount: 3,
            layerDistances: [3.0, 6.0, 1.0] // Not in descending order
        )
        
        XCTAssertThrowsError(try config.validate()) { error in
            let nsError = error as NSError
            XCTAssertTrue(nsError.localizedDescription.contains("descending order"))
        }
    }
    
    func testResponsiveConfig_Presets_HaveCorrectLayerCounts() {
        XCTAssertEqual(ResponsiveConfig.twoLayers.layerCount, 2)
        XCTAssertEqual(ResponsiveConfig.threeLayers.layerCount, 3)
        XCTAssertEqual(ResponsiveConfig.fourLayers.layerCount, 4)
    }
    
    // MARK: - Basic Responsive Encoding Tests
    
    func testResponsiveEncoding_TwoLayers_EncodesSuccessfully() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: .twoLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 64, height: 64, channels: 3)
        // Fill with test pattern
        for y in 0..<64 {
            for x in 0..<64 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x + y) * 256))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(x * 512))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(y * 512))
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testResponsiveEncoding_ThreeLayers_EncodesSuccessfully() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            responsiveEncoding: true,
            responsiveConfig: .threeLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 128, height: 128, channels: 3)
        // Fill with gradient
        for y in 0..<128 {
            for x in 0..<128 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 512))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 512))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 256))
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testResponsiveEncoding_FourLayers_EncodesSuccessfully() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 95),
            responsiveEncoding: true,
            responsiveConfig: .fourLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 256, height: 256, channels: 3)
        // Fill with checkerboard pattern
        for y in 0..<256 {
            for x in 0..<256 {
                let value: UInt16 = ((x / 8) + (y / 8)) % 2 == 0 ? 65535 : 0
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testResponsiveEncoding_CustomDistances_EncodesSuccessfully() throws {
        let config = ResponsiveConfig(
            layerCount: 3,
            layerDistances: [8.0, 4.0, 1.5]
        )
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: config
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 128, height: 128, channels: 3)
        for y in 0..<128 {
            for x in 0..<128 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 512))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 512))
                frame.setPixel(x: x, y: y, channel: 2, value: 32768)
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Pixel Type Tests
    
    func testResponsiveEncoding_UInt8_EncodesSuccessfully() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: .threeLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 64, height: 64, channels: 3, pixelType: .uint8)
        for y in 0..<64 {
            for x in 0..<64 {
                // setPixel expects UInt16 internally - it will convert
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x + y) % 256))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(x % 256))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(y % 256))
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testResponsiveEncoding_UInt16_EncodesSuccessfully() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: .threeLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 64, height: 64, channels: 3, pixelType: .uint16)
        for y in 0..<64 {
            for x in 0..<64 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 1024))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 1024))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 512))
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testResponsiveEncoding_Float32_EncodesSuccessfully() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: .threeLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 64, height: 64, channels: 3, pixelType: .float32)
        for y in 0..<64 {
            for x in 0..<64 {
                // setPixel expects UInt16 internally - will be converted for float32
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 1024))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 1024))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(32768))
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Combination with Other Features
    
    func testResponsiveEncoding_WithAlphaChannel_EncodesSuccessfully() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: .threeLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 64, height: 64, channels: 4, hasAlpha: true)
        for y in 0..<64 {
            for x in 0..<64 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 1024))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 1024))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 512))
                frame.setPixel(x: x, y: y, channel: 3, value: UInt16(32768)) // Alpha
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testResponsiveEncoding_WithHDR_EncodesSuccessfully() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: .threeLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(
            width: 64,
            height: 64,
            channels: 3,
            pixelType: .float32,
            colorSpace: .rec2020PQ  // HDR PQ
        )
        for y in 0..<64 {
            for x in 0..<64 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 1024))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 1024))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(32768))
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testResponsiveEncoding_WithWideGamut_EncodesSuccessfully() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: .threeLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(
            width: 64,
            height: 64,
            channels: 3,
            colorSpace: .displayP3
        )
        for y in 0..<64 {
            for x in 0..<64 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 1024))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 1024))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(32768))
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testResponsiveEncoding_WithProgressiveEncoding_EncodesSuccessfully() throws {
        // Test combination of responsive (quality layers) and progressive (frequency layers)
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            progressive: true,
            responsiveEncoding: true,
            responsiveConfig: .threeLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 128, height: 128, channels: 3)
        for y in 0..<128 {
            for x in 0..<128 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 512))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 512))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 256))
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Error Cases
    
    func testResponsiveEncoding_InvalidLayerDistances_ThrowsError() {
        let config = ResponsiveConfig(
            layerCount: 3,
            layerDistances: [1.0, 2.0, 3.0] // Ascending instead of descending
        )
        
        XCTAssertThrowsError(try config.validate())
    }
    
    func testResponsiveEncoding_InvalidImageDimensions_ThrowsError() {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: .threeLayers
        )
        let encoder = JXLEncoder(options: options)
        
        let frame = ImageFrame(width: 0, height: 0, channels: 3)
        
        XCTAssertThrowsError(try encoder.encode(frame))
    }
    
    // MARK: - Grayscale Tests
    
    func testResponsiveEncoding_Grayscale_EncodesSuccessfully() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: .threeLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 64, height: 64, channels: 1)
        for y in 0..<64 {
            for x in 0..<64 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * y * 16))
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Size Tests
    
    func testResponsiveEncoding_SmallImage_EncodesSuccessfully() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: .twoLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 8192))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 8192))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(32768))
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testResponsiveEncoding_LargeImage_EncodesSuccessfully() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            responsiveEncoding: true,
            responsiveConfig: .threeLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 512, height: 512, channels: 3)
        // Fill with pattern (sparse to save test time)
        for y in stride(from: 0, to: 512, by: 8) {
            for x in stride(from: 0, to: 512, by: 8) {
                let value = UInt16((x + y) * 64)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(x * 128))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(y * 128))
            }
        }
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    // MARK: - Performance Tests
    
    func testResponsiveEncoding_Performance_TwoLayers() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: .twoLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 256, height: 256, channels: 3)
        for y in 0..<256 {
            for x in 0..<256 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 256))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 256))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 128))
            }
        }
        
        measure {
            _ = try? encoder.encode(frame)
        }
    }
    
    func testResponsiveEncoding_Performance_FourLayers() throws {
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            responsiveEncoding: true,
            responsiveConfig: .fourLayers
        )
        let encoder = JXLEncoder(options: options)
        
        var frame = ImageFrame(width: 256, height: 256, channels: 3)
        for y in 0..<256 {
            for x in 0..<256 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 256))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 256))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 128))
            }
        }
        
        measure {
            _ = try? encoder.encode(frame)
        }
    }
}
