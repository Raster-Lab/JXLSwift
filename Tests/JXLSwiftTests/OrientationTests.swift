/// Tests for EXIF orientation support
///
/// Validates orientation handling in ImageFrame, EXIF parsing, and encoding pipeline.

import XCTest
@testable import JXLSwift

final class OrientationTests: XCTestCase {
    
    // MARK: - ImageFrame Orientation Tests
    
    func testImageFrame_DefaultOrientation_IsOne() {
        let frame = ImageFrame(width: 64, height: 64, channels: 3)
        XCTAssertEqual(frame.orientation, 1, "Default orientation should be 1 (normal)")
    }
    
    func testImageFrame_CustomOrientation_IsPreserved() {
        for orientation in 1...8 {
            let frame = ImageFrame(
                width: 64,
                height: 64,
                channels: 3,
                orientation: UInt32(orientation)
            )
            XCTAssertEqual(
                frame.orientation,
                UInt32(orientation),
                "Orientation \(orientation) should be preserved"
            )
        }
    }
    
    func testImageFrame_InvalidOrientation_IsClamped() {
        // Test values outside valid range
        let testCases: [(input: UInt32, expected: UInt32)] = [
            (0, 1),     // Below minimum → clamped to 1
            (1, 1),     // Minimum valid
            (8, 8),     // Maximum valid
            (9, 8),     // Above maximum → clamped to 8
            (100, 8),   // Way above → clamped to 8
        ]
        
        for testCase in testCases {
            let frame = ImageFrame(
                width: 64,
                height: 64,
                channels: 3,
                orientation: testCase.input
            )
            XCTAssertEqual(
                frame.orientation,
                testCase.expected,
                "Orientation \(testCase.input) should be clamped to \(testCase.expected)"
            )
        }
    }
    
    // MARK: - EXIF Orientation Extraction Tests
    
    func testEXIFOrientation_AllValidValues_AreExtracted() {
        for orientation in 1...8 {
            let exifData = EXIFBuilder.createWithOrientation(UInt32(orientation))
            let extracted = EXIFOrientation.extractOrientation(from: exifData)
            
            XCTAssertEqual(
                extracted,
                UInt32(orientation),
                "EXIF orientation \(orientation) should be extracted correctly"
            )
        }
    }
    
    func testEXIFOrientation_EmptyData_ReturnsDefault() {
        let emptyData = Data()
        let orientation = EXIFOrientation.extractOrientation(from: emptyData)
        XCTAssertEqual(orientation, 1, "Empty EXIF data should return default orientation 1")
    }
    
    func testEXIFOrientation_InvalidHeader_ReturnsDefault() {
        // Create invalid TIFF header
        let invalidData = Data([0x00, 0x00, 0x00, 0x00])
        let orientation = EXIFOrientation.extractOrientation(from: invalidData)
        XCTAssertEqual(orientation, 1, "Invalid EXIF header should return default orientation 1")
    }
    
    func testEXIFOrientation_BigEndian_IsSupported() {
        // Create big-endian EXIF with orientation 6
        var exif = Data()
        exif.append(contentsOf: [0x4D, 0x4D]) // "MM" - big-endian
        exif.append(contentsOf: [0x00, 0x2A]) // Magic number 42
        exif.append(contentsOf: [0x00, 0x00, 0x00, 0x08]) // IFD offset
        
        // IFD0
        exif.append(contentsOf: [0x00, 0x01]) // 1 entry
        
        // Orientation tag entry
        exif.append(contentsOf: [0x01, 0x12]) // Tag ID: 0x0112 (big-endian)
        exif.append(contentsOf: [0x00, 0x03]) // Type: SHORT
        exif.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
        exif.append(contentsOf: [0x00, 0x06, 0x00, 0x00]) // Value: 6 (big-endian)
        
        // Next IFD offset
        exif.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        
        let orientation = EXIFOrientation.extractOrientation(from: exif)
        XCTAssertEqual(orientation, 6, "Big-endian EXIF should be parsed correctly")
    }
    
    func testEXIFOrientation_MissingOrientationTag_ReturnsDefault() {
        // Create valid EXIF without orientation tag
        var exif = Data()
        exif.append(contentsOf: [0x49, 0x49]) // "II" - little-endian
        exif.append(contentsOf: [0x2A, 0x00]) // Magic number 42
        exif.append(contentsOf: [0x08, 0x00, 0x00, 0x00]) // IFD offset
        
        // IFD0 with different tag (not orientation)
        exif.append(contentsOf: [0x01, 0x00]) // 1 entry
        exif.append(contentsOf: [0x0F, 0x01]) // Tag ID: 0x010F (Manufacturer) - not orientation
        exif.append(contentsOf: [0x02, 0x00]) // Type: ASCII
        exif.append(contentsOf: [0x05, 0x00, 0x00, 0x00]) // Count: 5
        exif.append(contentsOf: [0x1A, 0x00, 0x00, 0x00]) // Value offset
        
        // Next IFD offset
        exif.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        
        let orientation = EXIFOrientation.extractOrientation(from: exif)
        XCTAssertEqual(orientation, 1, "Missing orientation tag should return default 1")
    }
    
    // MARK: - Encoding Integration Tests
    
    func testEncoder_SingleFrame_PreservesOrientation() throws {
        for orientation in 1...8 {
            var frame = ImageFrame(
                width: 8,
                height: 8,
                channels: 3,
                orientation: UInt32(orientation)
            )
            
            // Fill with gradient data
            for y in 0..<8 {
                for x in 0..<8 {
                    let value = UInt16((x + y) * 32)
                    frame.setPixel(x: x, y: y, channel: 0, value: value)
                    frame.setPixel(x: x, y: y, channel: 1, value: value)
                    frame.setPixel(x: x, y: y, channel: 2, value: value)
                }
            }
            
            let encoder = JXLEncoder(options: EncodingOptions(mode: .lossless))
            let encoded = try encoder.encode(frame)
            
            XCTAssertGreaterThan(
                encoded.data.count,
                0,
                "Encoding with orientation \(orientation) should produce data"
            )
        }
    }
    
    func testEncoder_MultiFrame_PreservesOrientation() throws {
        let orientations: [UInt32] = [1, 3, 6, 8]
        
        for orientation in orientations {
            var frame1 = ImageFrame(
                width: 8,
                height: 8,
                channels: 3,
                orientation: orientation
            )
            var frame2 = ImageFrame(
                width: 8,
                height: 8,
                channels: 3,
                orientation: orientation
            )
            
            // Fill with different patterns
            for y in 0..<8 {
                for x in 0..<8 {
                    frame1.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
                    frame1.setPixel(x: x, y: y, channel: 1, value: 128)
                    frame1.setPixel(x: x, y: y, channel: 2, value: UInt16(y * 32))
                    
                    frame2.setPixel(x: x, y: y, channel: 0, value: UInt16(y * 32))
                    frame2.setPixel(x: x, y: y, channel: 1, value: 128)
                    frame2.setPixel(x: x, y: y, channel: 2, value: UInt16(x * 32))
                }
            }
            
            let animConfig = AnimationConfig(fps: 10)
            let options = EncodingOptions(
                mode: .lossless,
                animationConfig: animConfig
            )
            let encoder = JXLEncoder(options: options)
            let encoded = try encoder.encode([frame1, frame2])
            
            XCTAssertGreaterThan(
                encoded.data.count,
                0,
                "Animation encoding with orientation \(orientation) should produce data"
            )
        }
    }
    
    func testCodestreamHeader_WithOrientation_Serializes() throws {
        for orientation in 1...8 {
            let frame = ImageFrame(
                width: 64,
                height: 64,
                channels: 3,
                orientation: UInt32(orientation)
            )
            
            let header = try CodestreamHeader(frame: frame)
            XCTAssertEqual(
                header.metadata.orientation,
                UInt32(orientation),
                "CodestreamHeader should preserve orientation \(orientation)"
            )
            
            // Verify serialization doesn't fail
            let serialized = header.serialise()
            XCTAssertGreaterThan(
                serialized.count,
                0,
                "Serialized header with orientation \(orientation) should have data"
            )
        }
    }
    
    // MARK: - Integration with Alpha and HDR
    
    func testOrientation_WithAlphaChannel_Works() throws {
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 4,
            hasAlpha: true,
            alphaMode: .straight,
            orientation: 6 // 90° CW rotation
        )
        
        // Fill with checkerboard pattern
        for y in 0..<16 {
            for x in 0..<16 {
                let isWhite = (x + y) % 2 == 0
                let value: UInt16 = isWhite ? 65535 : 0
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
                frame.setPixel(x: x, y: y, channel: 3, value: 65535) // Full alpha
            }
        }
        
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossless))
        let encoded = try encoder.encode(frame)
        
        XCTAssertGreaterThan(encoded.data.count, 0)
    }
    
    func testOrientation_WithHDR_Works() throws {
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 3,
            colorSpace: .rec2020PQ,
            orientation: 3 // 180° rotation
        )
        
        // Fill with HDR gradient
        for y in 0..<16 {
            for x in 0..<16 {
                let value = UInt16((x * 4096) + (y * 256))
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90)))
        let encoded = try encoder.encode(frame)
        
        XCTAssertGreaterThan(encoded.data.count, 0)
    }
    
    // MARK: - Performance Tests
    
    func testEXIFParsing_Performance() {
        let exifData = EXIFBuilder.createWithOrientation(6)
        
        measure {
            for _ in 0..<1000 {
                _ = EXIFOrientation.extractOrientation(from: exifData)
            }
        }
    }
    
    func testOrientation_Encoding_Performance() throws {
        var frame = ImageFrame(
            width: 256,
            height: 256,
            channels: 3,
            orientation: 6
        )
        
        // Fill with test pattern
        for y in 0..<256 {
            for x in 0..<256 {
                let value = UInt16((x ^ y) * 256)
                frame.setPixel(x: x, y: y, channel: 0, value: value)
                frame.setPixel(x: x, y: y, channel: 1, value: value)
                frame.setPixel(x: x, y: y, channel: 2, value: value)
            }
        }
        
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossless))
        
        measure {
            _ = try? encoder.encode(frame)
        }
    }
}
