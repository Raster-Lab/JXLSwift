/// Tests for Region of Interest (ROI) encoding
///
/// Validates ROI configuration, validation, distance multiplier calculations,
/// and integration with the encoding pipeline.

import XCTest
@testable import JXLSwift

final class ROIEncodingTests: XCTestCase {
    
    // MARK: - RegionOfInterest Initialization Tests
    
    func testROI_Initialization_DefaultValues() {
        let roi = RegionOfInterest(x: 10, y: 20, width: 100, height: 80)
        
        XCTAssertEqual(roi.x, 10)
        XCTAssertEqual(roi.y, 20)
        XCTAssertEqual(roi.width, 100)
        XCTAssertEqual(roi.height, 80)
        XCTAssertEqual(roi.qualityBoost, 10.0)
        XCTAssertEqual(roi.featherWidth, 16)
    }
    
    func testROI_Initialization_CustomValues() {
        let roi = RegionOfInterest(
            x: 50,
            y: 60,
            width: 200,
            height: 150,
            qualityBoost: 20.0,
            featherWidth: 32
        )
        
        XCTAssertEqual(roi.x, 50)
        XCTAssertEqual(roi.y, 60)
        XCTAssertEqual(roi.width, 200)
        XCTAssertEqual(roi.height, 150)
        XCTAssertEqual(roi.qualityBoost, 20.0)
        XCTAssertEqual(roi.featherWidth, 32)
    }
    
    func testROI_Initialization_ClampQualityBoost() {
        // Test clamping to maximum
        let roiMax = RegionOfInterest(x: 0, y: 0, width: 100, height: 100, qualityBoost: 100.0)
        XCTAssertEqual(roiMax.qualityBoost, 50.0, "Quality boost should be clamped to 50")
        
        // Test clamping to minimum
        let roiMin = RegionOfInterest(x: 0, y: 0, width: 100, height: 100, qualityBoost: -10.0)
        XCTAssertEqual(roiMin.qualityBoost, 0.0, "Quality boost should be clamped to 0")
    }
    
    func testROI_Initialization_ClampFeatherWidth() {
        let roi = RegionOfInterest(x: 0, y: 0, width: 100, height: 100, featherWidth: -5)
        XCTAssertEqual(roi.featherWidth, 0, "Feather width should be clamped to 0")
    }
    
    // MARK: - RegionOfInterest Validation Tests
    
    func testROI_Validation_ValidROI() throws {
        let roi = RegionOfInterest(x: 10, y: 10, width: 50, height: 50)
        XCTAssertNoThrow(try roi.validate(imageWidth: 100, imageHeight: 100))
    }
    
    func testROI_Validation_FullImageROI() throws {
        let roi = RegionOfInterest(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNoThrow(try roi.validate(imageWidth: 100, imageHeight: 100))
    }
    
    func testROI_Validation_ZeroWidth_ThrowsError() {
        let roi = RegionOfInterest(x: 10, y: 10, width: 0, height: 50)
        XCTAssertThrowsError(try roi.validate(imageWidth: 100, imageHeight: 100)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "RegionOfInterest")
            XCTAssertEqual(nsError.code, 1)
            XCTAssertTrue(nsError.localizedDescription.contains("width and height must be positive"))
        }
    }
    
    func testROI_Validation_ZeroHeight_ThrowsError() {
        let roi = RegionOfInterest(x: 10, y: 10, width: 50, height: 0)
        XCTAssertThrowsError(try roi.validate(imageWidth: 100, imageHeight: 100)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "RegionOfInterest")
            XCTAssertEqual(nsError.code, 1)
        }
    }
    
    func testROI_Validation_NegativeWidth_ThrowsError() {
        let roi = RegionOfInterest(x: 10, y: 10, width: -50, height: 50)
        XCTAssertThrowsError(try roi.validate(imageWidth: 100, imageHeight: 100)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "RegionOfInterest")
            XCTAssertEqual(nsError.code, 1)
        }
    }
    
    func testROI_Validation_NegativeX_ThrowsError() {
        let roi = RegionOfInterest(x: -10, y: 10, width: 50, height: 50)
        XCTAssertThrowsError(try roi.validate(imageWidth: 100, imageHeight: 100)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "RegionOfInterest")
            XCTAssertEqual(nsError.code, 4)
            XCTAssertTrue(nsError.localizedDescription.contains("coordinates must be non-negative"))
        }
    }
    
    func testROI_Validation_NegativeY_ThrowsError() {
        let roi = RegionOfInterest(x: 10, y: -10, width: 50, height: 50)
        XCTAssertThrowsError(try roi.validate(imageWidth: 100, imageHeight: 100)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "RegionOfInterest")
            XCTAssertEqual(nsError.code, 4)
        }
    }
    
    func testROI_Validation_OutOfBoundsX_ThrowsError() {
        let roi = RegionOfInterest(x: 100, y: 10, width: 50, height: 50)
        XCTAssertThrowsError(try roi.validate(imageWidth: 100, imageHeight: 100)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "RegionOfInterest")
            XCTAssertEqual(nsError.code, 2)
            XCTAssertTrue(nsError.localizedDescription.contains("outside image bounds"))
        }
    }
    
    func testROI_Validation_OutOfBoundsY_ThrowsError() {
        let roi = RegionOfInterest(x: 10, y: 100, width: 50, height: 50)
        XCTAssertThrowsError(try roi.validate(imageWidth: 100, imageHeight: 100)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "RegionOfInterest")
            XCTAssertEqual(nsError.code, 2)
        }
    }
    
    func testROI_Validation_ExtendsRight_ThrowsError() {
        let roi = RegionOfInterest(x: 60, y: 10, width: 50, height: 50)
        XCTAssertThrowsError(try roi.validate(imageWidth: 100, imageHeight: 100)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "RegionOfInterest")
            XCTAssertEqual(nsError.code, 3)
            XCTAssertTrue(nsError.localizedDescription.contains("extends beyond image bounds"))
        }
    }
    
    func testROI_Validation_ExtendsBottom_ThrowsError() {
        let roi = RegionOfInterest(x: 10, y: 60, width: 50, height: 50)
        XCTAssertThrowsError(try roi.validate(imageWidth: 100, imageHeight: 100)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "RegionOfInterest")
            XCTAssertEqual(nsError.code, 3)
        }
    }
    
    // MARK: - Distance Multiplier Tests
    
    func testROI_DistanceMultiplier_InsideROI_FullBoost() {
        let roi = RegionOfInterest(
            x: 20,
            y: 20,
            width: 40,
            height: 40,
            qualityBoost: 10.0,
            featherWidth: 16
        )
        
        // Test pixel at center of ROI
        let multiplier = roi.distanceMultiplier(px: 40, py: 40)
        
        // Quality boost of 10 should give multiplier ≈ 1.0 / 1.1 ≈ 0.909
        XCTAssertEqual(multiplier, 1.0 / 1.1, accuracy: 0.001)
    }
    
    func testROI_DistanceMultiplier_OutsideROI_NoChange() {
        let roi = RegionOfInterest(
            x: 20,
            y: 20,
            width: 40,
            height: 40,
            qualityBoost: 10.0,
            featherWidth: 16
        )
        
        // Test pixel far outside ROI
        let multiplier = roi.distanceMultiplier(px: 100, py: 100)
        
        XCTAssertEqual(multiplier, 1.0, "Distance multiplier should be 1.0 outside ROI")
    }
    
    func testROI_DistanceMultiplier_ZeroFeathering_HardEdge() {
        let roi = RegionOfInterest(
            x: 20,
            y: 20,
            width: 40,
            height: 40,
            qualityBoost: 10.0,
            featherWidth: 0
        )
        
        // Inside ROI
        let insideMultiplier = roi.distanceMultiplier(px: 30, py: 30)
        XCTAssertEqual(insideMultiplier, 1.0 / 1.1, accuracy: 0.001)
        
        // Just outside ROI (no feathering, should be 1.0)
        let outsideMultiplier = roi.distanceMultiplier(px: 60, py: 30)
        XCTAssertEqual(outsideMultiplier, 1.0)
    }
    
    func testROI_DistanceMultiplier_Feathering_SmoothTransition() {
        let roi = RegionOfInterest(
            x: 20,
            y: 20,
            width: 40,
            height: 40,
            qualityBoost: 20.0,
            featherWidth: 16
        )
        
        // Pixel at ROI edge should be in feather zone
        let edgeMultiplier = roi.distanceMultiplier(px: 60, py: 30)
        
        // Should be between full boost and no boost
        let fullBoost: Float = 1.0 / 1.2 // 0.833...
        XCTAssertGreaterThan(edgeMultiplier, fullBoost)
        XCTAssertLessThan(edgeMultiplier, 1.0 as Float)
    }
    
    func testROI_DistanceMultiplier_CornerFeathering() {
        let roi = RegionOfInterest(
            x: 20,
            y: 20,
            width: 40,
            height: 40,
            qualityBoost: 10.0,
            featherWidth: 16
        )
        
        // Pixel near corner of ROI (in feather zone diagonally)
        let cornerMultiplier = roi.distanceMultiplier(px: 61, py: 61)
        
        // Should be between full boost and no boost
        let fullBoost: Float = 1.0 / 1.1
        XCTAssertGreaterThan(cornerMultiplier, fullBoost)
        XCTAssertLessThan(cornerMultiplier, 1.0 as Float)
    }
    
    func testROI_DistanceMultiplier_ZeroQualityBoost_NoEffect() {
        let roi = RegionOfInterest(
            x: 20,
            y: 20,
            width: 40,
            height: 40,
            qualityBoost: 0.0,
            featherWidth: 16
        )
        
        // Inside ROI with zero boost should give multiplier = 1.0
        let multiplier = roi.distanceMultiplier(px: 30, py: 30)
        XCTAssertEqual(multiplier, 1.0, "Zero quality boost should result in no change")
    }
    
    func testROI_DistanceMultiplier_MaxQualityBoost() {
        let roi = RegionOfInterest(
            x: 20,
            y: 20,
            width: 40,
            height: 40,
            qualityBoost: 50.0,
            featherWidth: 0
        )
        
        // Max boost of 50 should give multiplier = 1.0 / 1.5 ≈ 0.667
        let multiplier = roi.distanceMultiplier(px: 30, py: 30)
        XCTAssertEqual(multiplier, 1.0 / 1.5, accuracy: 0.001)
    }
    
    // MARK: - EncodingOptions Integration Tests
    
    func testEncodingOptions_WithROI_Initialization() {
        let roi = RegionOfInterest(x: 10, y: 10, width: 100, height: 100)
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            regionOfInterest: roi
        )
        
        XCTAssertNotNil(options.regionOfInterest)
        XCTAssertEqual(options.regionOfInterest?.x, 10)
        XCTAssertEqual(options.regionOfInterest?.width, 100)
    }
    
    func testEncodingOptions_WithoutROI_DefaultsToNil() {
        let options = EncodingOptions(mode: .lossy(quality: 90))
        XCTAssertNil(options.regionOfInterest)
    }
    
    // MARK: - ROI Equatable Tests
    
    func testROI_Equatable_SameValues_AreEqual() {
        let roi1 = RegionOfInterest(x: 10, y: 20, width: 100, height: 80, qualityBoost: 15.0, featherWidth: 20)
        let roi2 = RegionOfInterest(x: 10, y: 20, width: 100, height: 80, qualityBoost: 15.0, featherWidth: 20)
        
        XCTAssertEqual(roi1, roi2)
    }
    
    func testROI_Equatable_DifferentValues_AreNotEqual() {
        let roi1 = RegionOfInterest(x: 10, y: 20, width: 100, height: 80)
        let roi2 = RegionOfInterest(x: 10, y: 20, width: 100, height: 90)
        
        XCTAssertNotEqual(roi1, roi2)
    }
    
    // MARK: - Edge Case Tests
    
    func testROI_SinglePixel_Valid() throws {
        let roi = RegionOfInterest(x: 50, y: 50, width: 1, height: 1)
        XCTAssertNoThrow(try roi.validate(imageWidth: 100, imageHeight: 100))
    }
    
    func testROI_EntireImage_Valid() throws {
        let roi = RegionOfInterest(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertNoThrow(try roi.validate(imageWidth: 1920, imageHeight: 1080))
        
        // All pixels should have the same boost
        let center = roi.distanceMultiplier(px: 960, py: 540)
        let corner = roi.distanceMultiplier(px: 1919, py: 1079)
        XCTAssertEqual(center, corner, accuracy: 0.001)
    }
    
    func testROI_SmallImage_8x8() throws {
        let roi = RegionOfInterest(x: 2, y: 2, width: 4, height: 4, featherWidth: 1)
        XCTAssertNoThrow(try roi.validate(imageWidth: 8, imageHeight: 8))
        
        // Test that distance multiplier works correctly for small ROI
        let insideMultiplier = roi.distanceMultiplier(px: 3, py: 3)
        XCTAssertLessThan(insideMultiplier, 1.0)
    }
    
    func testROI_LargeFeathering_ExceedsROISize() {
        let roi = RegionOfInterest(x: 20, y: 20, width: 10, height: 10, featherWidth: 20)
        
        // Feathering is larger than ROI itself - should still work
        let insideMultiplier = roi.distanceMultiplier(px: 25, py: 25)
        XCTAssertLessThan(insideMultiplier, 1.0, "Inside ROI should have boost even with large feathering")
        
        // Point within feather but outside ROI
        let featherMultiplier = roi.distanceMultiplier(px: 15, py: 25)
        XCTAssertGreaterThan(featherMultiplier, insideMultiplier)
        XCTAssertLessThan(featherMultiplier, 1.0)
    }
    
    func testROI_AtImageEdge_TopLeft() throws {
        let roi = RegionOfInterest(x: 0, y: 0, width: 50, height: 50)
        XCTAssertNoThrow(try roi.validate(imageWidth: 100, imageHeight: 100))
    }
    
    func testROI_AtImageEdge_BottomRight() throws {
        let roi = RegionOfInterest(x: 50, y: 50, width: 50, height: 50)
        XCTAssertNoThrow(try roi.validate(imageWidth: 100, imageHeight: 100))
    }
    
    func testROI_JustFitsImage_NoExtraPixel() throws {
        let roi = RegionOfInterest(x: 0, y: 0, width: 99, height: 99)
        XCTAssertNoThrow(try roi.validate(imageWidth: 100, imageHeight: 100))
    }
    
    // MARK: - End-to-End Encoding Tests
    
    func testROI_Encoding_BasicImage_CenterROI() throws {
        // Create a simple test image
        var frame = ImageFrame(width: 64, height: 64, channels: 3, pixelType: .uint8)
        
        // Fill with gradient pattern
        for y in 0..<64 {
            for x in 0..<64 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 4))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 4))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        // Define ROI in center
        let roi = RegionOfInterest(
            x: 16,
            y: 16,
            width: 32,
            height: 32,
            qualityBoost: 15.0,
            featherWidth: 8
        )
        
        // Encode with ROI
        let options = EncodingOptions(
            mode: .lossy(quality: 80),
            effort: .falcon,
            regionOfInterest: roi
        )
        let encoder = JXLEncoder(options: options)
        
        // Should encode without errors
        XCTAssertNoThrow(try encoder.encode(frame))
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.stats.compressedSize, 0)
    }
    
    func testROI_Encoding_InvalidROI_ThrowsError() throws {
        let frame = ImageFrame(width: 64, height: 64, channels: 3, pixelType: .uint8)
        
        // ROI extends beyond image bounds
        let roi = RegionOfInterest(x: 50, y: 50, width: 30, height: 30)
        
        let options = EncodingOptions(
            mode: .lossy(quality: 80),
            regionOfInterest: roi
        )
        let encoder = JXLEncoder(options: options)
        
        // Should throw error during encoding
        XCTAssertThrowsError(try encoder.encode(frame)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "RegionOfInterest")
        }
    }
    
    func testROI_Encoding_FullImageROI() throws {
        var frame = ImageFrame(width: 32, height: 32, channels: 3, pixelType: .uint8)
        
        // Fill with test pattern
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x + y) % 256))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16((x * 2) % 256))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((y * 2) % 256))
            }
        }
        
        // ROI covers entire image
        let roi = RegionOfInterest(x: 0, y: 0, width: 32, height: 32, qualityBoost: 10.0)
        
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            regionOfInterest: roi
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testROI_Encoding_CornerROI() throws {
        var frame = ImageFrame(width: 48, height: 48, channels: 3, pixelType: .uint8)
        
        // Fill with checkerboard
        for y in 0..<48 {
            for x in 0..<48 {
                let val: UInt16 = ((x / 8) + (y / 8)) % 2 == 0 ? 255 : 0
                frame.setPixel(x: x, y: y, channel: 0, value: val)
                frame.setPixel(x: x, y: y, channel: 1, value: val)
                frame.setPixel(x: x, y: y, channel: 2, value: val)
            }
        }
        
        // ROI in top-left corner
        let roi = RegionOfInterest(x: 0, y: 0, width: 16, height: 16, qualityBoost: 20.0)
        
        let options = EncodingOptions(
            mode: .lossy(quality: 75),
            regionOfInterest: roi
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testROI_Encoding_SmallROI_SingleBlock() throws {
        var frame = ImageFrame(width: 64, height: 64, channels: 3, pixelType: .uint8)
        
        // Fill with solid color
        for y in 0..<64 {
            for x in 0..<64 {
                frame.setPixel(x: x, y: y, channel: 0, value: 128)
                frame.setPixel(x: x, y: y, channel: 1, value: 128)
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        // Very small ROI (8x8, exactly one DCT block)
        let roi = RegionOfInterest(x: 24, y: 24, width: 8, height: 8, qualityBoost: 25.0, featherWidth: 0)
        
        let options = EncodingOptions(
            mode: .lossy(quality: 70),
            regionOfInterest: roi
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testROI_Encoding_WithFeathering() throws {
        var frame = ImageFrame(width: 80, height: 80, channels: 3, pixelType: .uint8)
        
        // Fill with gradient
        for y in 0..<80 {
            for x in 0..<80 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 3))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 3))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 2))
            }
        }
        
        // ROI with large feathering
        let roi = RegionOfInterest(
            x: 20,
            y: 20,
            width: 40,
            height: 40,
            qualityBoost: 12.0,
            featherWidth: 16
        )
        
        let options = EncodingOptions(
            mode: .lossy(quality: 82),
            regionOfInterest: roi
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testROI_Encoding_WithFloat32() throws {
        var frame = ImageFrame(width: 32, height: 32, channels: 3, pixelType: .float32)
        
        // Fill with normalized values
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(Float(x) / 32.0 * 65535.0))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(Float(y) / 32.0 * 65535.0))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(0.5 * 65535.0))
            }
        }
        
        let roi = RegionOfInterest(x: 8, y: 8, width: 16, height: 16, qualityBoost: 10.0)
        
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            regionOfInterest: roi
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testROI_Encoding_WithUInt16() throws {
        var frame = ImageFrame(width: 40, height: 40, channels: 3, pixelType: .uint16)
        
        // Fill with 16-bit values
        for y in 0..<40 {
            for x in 0..<40 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 1638))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 1638))
                frame.setPixel(x: x, y: y, channel: 2, value: 32768)
            }
        }
        
        let roi = RegionOfInterest(x: 10, y: 10, width: 20, height: 20, qualityBoost: 15.0)
        
        let options = EncodingOptions(
            mode: .lossy(quality: 88),
            regionOfInterest: roi
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
    
    func testROI_Encoding_Lossless_IgnoresROI() throws {
        // ROI should be ignored in lossless mode since quantization doesn't apply
        var frame = ImageFrame(width: 24, height: 24, channels: 3, pixelType: .uint8)
        
        for y in 0..<24 {
            for x in 0..<24 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 10))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 10))
                frame.setPixel(x: x, y: y, channel: 2, value: 100)
            }
        }
        
        let roi = RegionOfInterest(x: 4, y: 4, width: 16, height: 16, qualityBoost: 20.0)
        
        let options = EncodingOptions(
            mode: .lossless,
            modularMode: true,
            regionOfInterest: roi
        )
        let encoder = JXLEncoder(options: options)
        
        // Should encode successfully (ROI is silently ignored for lossless)
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }
}
