// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import XCTest
@testable import JXLSwift

final class SplineEncodingTests: XCTestCase {
    
    // MARK: - Spline.Point Tests
    
    func testSplinePoint_Initialization() {
        let point = Spline.Point(x: 10.5, y: 20.3)
        XCTAssertEqual(point.x, 10.5, accuracy: 1e-6)
        XCTAssertEqual(point.y, 20.3, accuracy: 1e-6)
    }
    
    func testSplinePoint_Equality() {
        let point1 = Spline.Point(x: 10.0, y: 20.0)
        let point2 = Spline.Point(x: 10.0, y: 20.0)
        let point3 = Spline.Point(x: 10.0005, y: 20.0005) // Within tolerance (< 1e-3)
        let point4 = Spline.Point(x: 15.0, y: 25.0)
        
        XCTAssertEqual(point1, point2)
        XCTAssertEqual(point1, point3) // Should be equal within tolerance
        XCTAssertNotEqual(point1, point4)
    }
    
    func testSplinePoint_ZeroPoint() {
        let zero = Spline.Point(x: 0.0, y: 0.0)
        XCTAssertEqual(zero.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(zero.y, 0.0, accuracy: 1e-6)
    }
    
    func testSplinePoint_NegativeCoordinates() {
        let point = Spline.Point(x: -50.0, y: -100.0)
        XCTAssertEqual(point.x, -50.0, accuracy: 1e-6)
        XCTAssertEqual(point.y, -100.0, accuracy: 1e-6)
    }
    
    // MARK: - Spline Tests
    
    func testSpline_Initialization() {
        let points = [
            Spline.Point(x: 0.0, y: 0.0),
            Spline.Point(x: 100.0, y: 100.0)
        ]
        
        let colorDCT = [
            [Float](repeating: 1.0, count: 32),
            [Float](repeating: 0.5, count: 32),
            [Float](repeating: 0.0, count: 32)
        ]
        
        let sigmaDCT = [Float](repeating: 2.0, count: 32)
        
        let spline = Spline(
            controlPoints: points,
            colorDCT: colorDCT,
            sigmaDCT: sigmaDCT
        )
        
        XCTAssertEqual(spline.controlPoints.count, 2)
        XCTAssertEqual(spline.colorDCT.count, 3)
        XCTAssertEqual(spline.colorDCT[0].count, 32)
        XCTAssertEqual(spline.sigmaDCT.count, 32)
    }
    
    func testSpline_ValidateMinimumControlPoints() throws {
        // Valid: 2 control points
        let validPoints = [
            Spline.Point(x: 0.0, y: 0.0),
            Spline.Point(x: 10.0, y: 10.0)
        ]
        
        let colorDCT = [
            [Float](repeating: 0.0, count: 32),
            [Float](repeating: 0.0, count: 32),
            [Float](repeating: 0.0, count: 32)
        ]
        let sigmaDCT = [Float](repeating: 1.0, count: 32)
        
        let validSpline = Spline(
            controlPoints: validPoints,
            colorDCT: colorDCT,
            sigmaDCT: sigmaDCT
        )
        
        XCTAssertNoThrow(try validSpline.validate())
        
        // Invalid: 0 control points
        let emptySpline = Spline(
            controlPoints: [],
            colorDCT: colorDCT,
            sigmaDCT: sigmaDCT
        )
        
        XCTAssertThrowsError(try emptySpline.validate()) { error in
            guard case EncoderError.encodingFailed(let message) = error else {
                XCTFail("Expected EncoderError.encodingFailed")
                return
            }
            XCTAssertTrue(message.contains("at least 2 control points"))
        }
        
        // Invalid: 1 control point
        let singlePointSpline = Spline(
            controlPoints: [Spline.Point(x: 0.0, y: 0.0)],
            colorDCT: colorDCT,
            sigmaDCT: sigmaDCT
        )
        
        XCTAssertThrowsError(try singlePointSpline.validate()) { error in
            guard case EncoderError.encodingFailed(let message) = error else {
                XCTFail("Expected EncoderError.encodingFailed")
                return
            }
            XCTAssertTrue(message.contains("at least 2 control points"))
        }
    }
    
    func testSpline_ValidateControlPointBounds() throws {
        let colorDCT = [
            [Float](repeating: 0.0, count: 32),
            [Float](repeating: 0.0, count: 32),
            [Float](repeating: 0.0, count: 32)
        ]
        let sigmaDCT = [Float](repeating: 1.0, count: 32)
        
        // Valid: within bounds
        let validPoints = [
            Spline.Point(x: 0.0, y: 0.0),
            Spline.Point(x: 1000.0, y: 1000.0)
        ]
        let validSpline = Spline(
            controlPoints: validPoints,
            colorDCT: colorDCT,
            sigmaDCT: sigmaDCT
        )
        XCTAssertNoThrow(try validSpline.validate())
        
        // Invalid: X coordinate out of bounds
        let outOfBoundsX = [
            Spline.Point(x: 0.0, y: 0.0),
            Spline.Point(x: Float(1 << 23), y: 100.0) // At limit
        ]
        let invalidSplineX = Spline(
            controlPoints: outOfBoundsX,
            colorDCT: colorDCT,
            sigmaDCT: sigmaDCT
        )
        XCTAssertThrowsError(try invalidSplineX.validate()) { error in
            guard case EncoderError.encodingFailed(let message) = error else {
                XCTFail("Expected EncoderError.encodingFailed")
                return
            }
            XCTAssertTrue(message.contains("out of bounds"))
        }
        
        // Invalid: Y coordinate out of bounds
        let outOfBoundsY = [
            Spline.Point(x: 0.0, y: 0.0),
            Spline.Point(x: 100.0, y: -Float(1 << 23)) // At negative limit
        ]
        let invalidSplineY = Spline(
            controlPoints: outOfBoundsY,
            colorDCT: colorDCT,
            sigmaDCT: sigmaDCT
        )
        XCTAssertThrowsError(try invalidSplineY.validate()) { error in
            guard case EncoderError.encodingFailed(let message) = error else {
                XCTFail("Expected EncoderError.encodingFailed")
                return
            }
            XCTAssertTrue(message.contains("out of bounds"))
        }
    }
    
    func testSpline_ValidateColorDCTStructure() throws {
        let points = [
            Spline.Point(x: 0.0, y: 0.0),
            Spline.Point(x: 100.0, y: 100.0)
        ]
        let sigmaDCT = [Float](repeating: 1.0, count: 32)
        
        // Invalid: wrong number of channels
        let invalidChannels = [
            [Float](repeating: 0.0, count: 32),
            [Float](repeating: 0.0, count: 32)
        ]
        let invalidSpline1 = Spline(
            controlPoints: points,
            colorDCT: invalidChannels,
            sigmaDCT: sigmaDCT
        )
        XCTAssertThrowsError(try invalidSpline1.validate()) { error in
            guard case EncoderError.encodingFailed(let message) = error else {
                XCTFail("Expected EncoderError.encodingFailed")
                return
            }
            XCTAssertTrue(message.contains("3 channels"))
        }
        
        // Invalid: wrong number of coefficients
        let invalidCoefficients = [
            [Float](repeating: 0.0, count: 32),
            [Float](repeating: 0.0, count: 16), // Wrong count
            [Float](repeating: 0.0, count: 32)
        ]
        let invalidSpline2 = Spline(
            controlPoints: points,
            colorDCT: invalidCoefficients,
            sigmaDCT: sigmaDCT
        )
        XCTAssertThrowsError(try invalidSpline2.validate()) { error in
            guard case EncoderError.encodingFailed(let message) = error else {
                XCTFail("Expected EncoderError.encodingFailed")
                return
            }
            XCTAssertTrue(message.contains("32 coefficients"))
        }
    }
    
    func testSpline_ValidateSigmaDCTStructure() throws {
        let points = [
            Spline.Point(x: 0.0, y: 0.0),
            Spline.Point(x: 100.0, y: 100.0)
        ]
        let colorDCT = [
            [Float](repeating: 0.0, count: 32),
            [Float](repeating: 0.0, count: 32),
            [Float](repeating: 0.0, count: 32)
        ]
        
        // Invalid: wrong number of sigma coefficients
        let invalidSigma = [Float](repeating: 1.0, count: 16)
        let invalidSpline = Spline(
            controlPoints: points,
            colorDCT: colorDCT,
            sigmaDCT: invalidSigma
        )
        XCTAssertThrowsError(try invalidSpline.validate()) { error in
            guard case EncoderError.encodingFailed(let message) = error else {
                XCTFail("Expected EncoderError.encodingFailed")
                return
            }
            XCTAssertTrue(message.contains("32 coefficients"))
        }
    }
    
    // MARK: - SplineConfig Tests
    
    func testSplineConfig_Initialization() {
        let config = SplineConfig(
            enabled: true,
            quantizationAdjustment: 5,
            minControlPointDistance: 4.0,
            maxSplinesPerFrame: 64,
            edgeThreshold: 0.3,
            minEdgeLength: 10.0
        )
        
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.quantizationAdjustment, 5)
        XCTAssertEqual(config.minControlPointDistance, 4.0, accuracy: 1e-6)
        XCTAssertEqual(config.maxSplinesPerFrame, 64)
        XCTAssertEqual(config.edgeThreshold, 0.3, accuracy: 1e-6)
        XCTAssertEqual(config.minEdgeLength, 10.0, accuracy: 1e-6)
    }
    
    func testSplineConfig_DefaultValues() {
        let config = SplineConfig()
        
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.quantizationAdjustment, 0)
        XCTAssertEqual(config.minControlPointDistance, 4.0, accuracy: 1e-6)
        XCTAssertEqual(config.maxSplinesPerFrame, 64)
        XCTAssertEqual(config.edgeThreshold, 0.3, accuracy: 1e-6)
        XCTAssertEqual(config.minEdgeLength, 10.0, accuracy: 1e-6)
    }
    
    func testSplineConfig_QuantizationAdjustmentClamping() {
        // Test upper bound
        let configHigh = SplineConfig(quantizationAdjustment: 200)
        XCTAssertEqual(configHigh.quantizationAdjustment, 127)
        
        // Test lower bound
        let configLow = SplineConfig(quantizationAdjustment: -200)
        XCTAssertEqual(configLow.quantizationAdjustment, -128)
        
        // Test within range
        let configValid = SplineConfig(quantizationAdjustment: 50)
        XCTAssertEqual(configValid.quantizationAdjustment, 50)
    }
    
    func testSplineConfig_MinControlPointDistanceClamping() {
        // Test clamping to minimum
        let config = SplineConfig(minControlPointDistance: 0.5)
        XCTAssertEqual(config.minControlPointDistance, 1.0, accuracy: 1e-6)
        
        // Test valid value
        let configValid = SplineConfig(minControlPointDistance: 8.0)
        XCTAssertEqual(configValid.minControlPointDistance, 8.0, accuracy: 1e-6)
    }
    
    func testSplineConfig_MaxSplinesPerFrameClamping() {
        // Test clamping to minimum
        let config = SplineConfig(maxSplinesPerFrame: 0)
        XCTAssertEqual(config.maxSplinesPerFrame, 1)
        
        // Test valid value
        let configValid = SplineConfig(maxSplinesPerFrame: 128)
        XCTAssertEqual(configValid.maxSplinesPerFrame, 128)
    }
    
    func testSplineConfig_EdgeThresholdClamping() {
        // Test lower bound
        let configLow = SplineConfig(edgeThreshold: -0.5)
        XCTAssertEqual(configLow.edgeThreshold, 0.0, accuracy: 1e-6)
        
        // Test upper bound
        let configHigh = SplineConfig(edgeThreshold: 1.5)
        XCTAssertEqual(configHigh.edgeThreshold, 1.0, accuracy: 1e-6)
        
        // Test valid value
        let configValid = SplineConfig(edgeThreshold: 0.5)
        XCTAssertEqual(configValid.edgeThreshold, 0.5, accuracy: 1e-6)
    }
    
    func testSplineConfig_MinEdgeLengthClamping() {
        // Test clamping to minimum
        let config = SplineConfig(minEdgeLength: 0.5)
        XCTAssertEqual(config.minEdgeLength, 1.0, accuracy: 1e-6)
        
        // Test valid value
        let configValid = SplineConfig(minEdgeLength: 20.0)
        XCTAssertEqual(configValid.minEdgeLength, 20.0, accuracy: 1e-6)
    }
    
    func testSplineConfig_Validate() throws {
        // Valid configuration
        let validConfig = SplineConfig(
            enabled: true,
            quantizationAdjustment: 5,
            minControlPointDistance: 4.0,
            maxSplinesPerFrame: 64,
            edgeThreshold: 0.3,
            minEdgeLength: 10.0
        )
        XCTAssertNoThrow(try validConfig.validate())
    }
    
    // MARK: - SplineConfig Presets
    
    func testSplineConfig_DisabledPreset() {
        let config = SplineConfig.disabled
        
        XCTAssertFalse(config.enabled)
        XCTAssertNoThrow(try config.validate())
    }
    
    func testSplineConfig_SubtlePreset() {
        let config = SplineConfig.subtle
        
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.quantizationAdjustment, 0)
        XCTAssertEqual(config.minControlPointDistance, 8.0, accuracy: 1e-6)
        XCTAssertEqual(config.maxSplinesPerFrame, 32)
        XCTAssertEqual(config.edgeThreshold, 0.6, accuracy: 1e-6)
        XCTAssertEqual(config.minEdgeLength, 20.0, accuracy: 1e-6)
        XCTAssertNoThrow(try config.validate())
    }
    
    func testSplineConfig_ModeratePreset() {
        let config = SplineConfig.moderate
        
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.quantizationAdjustment, 2)
        XCTAssertEqual(config.minControlPointDistance, 4.0, accuracy: 1e-6)
        XCTAssertEqual(config.maxSplinesPerFrame, 64)
        XCTAssertEqual(config.edgeThreshold, 0.3, accuracy: 1e-6)
        XCTAssertEqual(config.minEdgeLength, 10.0, accuracy: 1e-6)
        XCTAssertNoThrow(try config.validate())
    }
    
    func testSplineConfig_ArtisticPreset() {
        let config = SplineConfig.artistic
        
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.quantizationAdjustment, 4)
        XCTAssertEqual(config.minControlPointDistance, 2.0, accuracy: 1e-6)
        XCTAssertEqual(config.maxSplinesPerFrame, 128)
        XCTAssertEqual(config.edgeThreshold, 0.15, accuracy: 1e-6)
        XCTAssertEqual(config.minEdgeLength, 5.0, accuracy: 1e-6)
        XCTAssertNoThrow(try config.validate())
    }
    
    // MARK: - SplineDetector Tests
    
    func testSplineDetector_Initialization() {
        let config = SplineConfig.moderate
        let detector = SplineDetector(config: config)
        
        // Just verify it initializes without crashing
        XCTAssertNotNil(detector)
    }
    
    func testSplineDetector_DetectSplinesDisabled() throws {
        let config = SplineConfig.disabled
        let detector = SplineDetector(config: config)
        
        var frame = ImageFrame(width: 64, height: 64, channels: 3)
        // Fill with test data
        for y in 0..<64 {
            for x in 0..<64 {
                try frame.setPixel(x: x, y: y, channel: 0, value: 128)
                try frame.setPixel(x: x, y: y, channel: 1, value: 128)
                try frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let splines = try detector.detectSplines(in: frame)
        XCTAssertTrue(splines.isEmpty, "Should return no splines when disabled")
    }
    
    func testSplineDetector_DetectSplinesEnabled() throws {
        let config = SplineConfig.moderate
        let detector = SplineDetector(config: config)
        
        var frame = ImageFrame(width: 64, height: 64, channels: 3)
        // Fill with test data
        for y in 0..<64 {
            for x in 0..<64 {
                try frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 4))
                try frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 4))
                try frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        let splines = try detector.detectSplines(in: frame)
        // For now, implementation returns empty array
        // A full implementation would detect edges and return splines
        XCTAssertTrue(splines.isEmpty)
    }
    
    func testSplineDetector_CreateLineSpline() throws {
        let start = Spline.Point(x: 0.0, y: 0.0)
        let end = Spline.Point(x: 100.0, y: 100.0)
        let color: [Float] = [1.0, 0.5, 0.0]
        let sigma: Float = 2.0
        
        let spline = SplineDetector.createLineSpline(
            from: start,
            to: end,
            color: color,
            sigma: sigma
        )
        
        XCTAssertEqual(spline.controlPoints.count, 2)
        XCTAssertEqual(spline.controlPoints[0], start)
        XCTAssertEqual(spline.controlPoints[1], end)
        
        // Verify color DCT (DC component should be color * sqrt(2))
        let sqrt2 = Float(sqrt(2.0))
        XCTAssertEqual(spline.colorDCT[0][0], color[0] * sqrt2, accuracy: 1e-5)
        XCTAssertEqual(spline.colorDCT[1][0], color[1] * sqrt2, accuracy: 1e-5)
        XCTAssertEqual(spline.colorDCT[2][0], color[2] * sqrt2, accuracy: 1e-5)
        
        // Verify sigma DCT
        XCTAssertEqual(spline.sigmaDCT[0], sigma * sqrt2, accuracy: 1e-5)
        
        // Verify AC components are zero
        for i in 1..<32 {
            XCTAssertEqual(spline.colorDCT[0][i], 0.0, accuracy: 1e-6)
            XCTAssertEqual(spline.colorDCT[1][i], 0.0, accuracy: 1e-6)
            XCTAssertEqual(spline.colorDCT[2][i], 0.0, accuracy: 1e-6)
            XCTAssertEqual(spline.sigmaDCT[i], 0.0, accuracy: 1e-6)
        }
        
        // Validate the spline
        XCTAssertNoThrow(try spline.validate())
    }
    
    func testSplineDetector_CreateLineSplineDefaultParameters() throws {
        let start = Spline.Point(x: 10.0, y: 20.0)
        let end = Spline.Point(x: 50.0, y: 80.0)
        
        let spline = SplineDetector.createLineSpline(from: start, to: end)
        
        XCTAssertEqual(spline.controlPoints.count, 2)
        XCTAssertNoThrow(try spline.validate())
        
        // Default color should be white (1.0, 1.0, 1.0)
        let sqrt2 = Float(sqrt(2.0))
        XCTAssertEqual(spline.colorDCT[0][0], Float(1.0 * sqrt2), accuracy: 1e-5)
        XCTAssertEqual(spline.colorDCT[1][0], Float(1.0 * sqrt2), accuracy: 1e-5)
        XCTAssertEqual(spline.colorDCT[2][0], Float(1.0 * sqrt2), accuracy: 1e-5)
        
        // Default sigma should be 1.0
        XCTAssertEqual(spline.sigmaDCT[0], Float(1.0 * sqrt2), accuracy: 1e-5)
    }
    
    // MARK: - EncodingOptions Integration Tests
    
    func testEncodingOptions_SplineConfigIntegration() {
        let splineConfig = SplineConfig.moderate
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            splineConfig: splineConfig
        )
        
        XCTAssertNotNil(options.splineConfig)
        XCTAssertTrue(options.splineConfig!.enabled)
        XCTAssertEqual(options.splineConfig!.maxSplinesPerFrame, 64)
    }
    
    func testEncodingOptions_NoSplineConfig() {
        let options = EncodingOptions(mode: .lossy(quality: 90))
        
        XCTAssertNil(options.splineConfig)
    }
    
    // MARK: - Edge Case Tests
    
    func testSpline_ManyControlPoints() throws {
        // Create a spline with many control points
        var points: [Spline.Point] = []
        for i in 0..<100 {
            points.append(Spline.Point(x: Float(i * 10), y: Float(i * 10)))
        }
        
        let colorDCT = [
            [Float](repeating: 0.5, count: 32),
            [Float](repeating: 0.5, count: 32),
            [Float](repeating: 0.5, count: 32)
        ]
        let sigmaDCT = [Float](repeating: 1.0, count: 32)
        
        let spline = Spline(
            controlPoints: points,
            colorDCT: colorDCT,
            sigmaDCT: sigmaDCT
        )
        
        XCTAssertNoThrow(try spline.validate())
        XCTAssertEqual(spline.controlPoints.count, 100)
    }
    
    func testSpline_ZeroColorValues() throws {
        let points = [
            Spline.Point(x: 0.0, y: 0.0),
            Spline.Point(x: 100.0, y: 100.0)
        ]
        
        let colorDCT = [
            [Float](repeating: 0.0, count: 32),
            [Float](repeating: 0.0, count: 32),
            [Float](repeating: 0.0, count: 32)
        ]
        let sigmaDCT = [Float](repeating: 1.0, count: 32)
        
        let spline = Spline(
            controlPoints: points,
            colorDCT: colorDCT,
            sigmaDCT: sigmaDCT
        )
        
        XCTAssertNoThrow(try spline.validate())
    }
    
    func testSpline_ZeroSigmaValues() throws {
        let points = [
            Spline.Point(x: 0.0, y: 0.0),
            Spline.Point(x: 100.0, y: 100.0)
        ]
        
        let colorDCT = [
            [Float](repeating: 1.0, count: 32),
            [Float](repeating: 1.0, count: 32),
            [Float](repeating: 1.0, count: 32)
        ]
        let sigmaDCT = [Float](repeating: 0.0, count: 32)
        
        let spline = Spline(
            controlPoints: points,
            colorDCT: colorDCT,
            sigmaDCT: sigmaDCT
        )
        
        XCTAssertNoThrow(try spline.validate())
    }
    
    // MARK: - Performance Tests
    
    func testSplineValidation_Performance() throws {
        let points = [
            Spline.Point(x: 0.0, y: 0.0),
            Spline.Point(x: 100.0, y: 100.0)
        ]
        
        let colorDCT = [
            [Float](repeating: 1.0, count: 32),
            [Float](repeating: 0.5, count: 32),
            [Float](repeating: 0.0, count: 32)
        ]
        let sigmaDCT = [Float](repeating: 2.0, count: 32)
        
        let spline = Spline(
            controlPoints: points,
            colorDCT: colorDCT,
            sigmaDCT: sigmaDCT
        )
        
        measure {
            for _ in 0..<1000 {
                _ = try? spline.validate()
            }
        }
    }
    
    func testSplineDetector_Performance() throws {
        let config = SplineConfig.moderate
        let detector = SplineDetector(config: config)
        
        var frame = ImageFrame(width: 256, height: 256, channels: 3)
        for y in 0..<256 {
            for x in 0..<256 {
                try frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x))
                try frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y))
                try frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        
        measure {
            _ = try? detector.detectSplines(in: frame)
        }
    }
}
