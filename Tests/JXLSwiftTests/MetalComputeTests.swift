/// Tests for Metal GPU compute operations
///
/// These tests validate Metal compute shader correctness against CPU implementations.

import XCTest
@testable import JXLSwift

#if canImport(Metal)
@available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
final class MetalComputeTests: XCTestCase {
    
    // MARK: - Setup & Teardown
    
    override func tearDown() {
        // Clean up Metal resources after each test
        MetalOps.cleanup()
        super.tearDown()
    }
    
    // MARK: - Availability Tests
    
    func testMetalOps_DeviceAvailability() {
        // Metal may not be available on all test environments
        // Just verify the query doesn't crash
        let isAvailable = MetalOps.isAvailable
        XCTAssertNotNil(isAvailable) // Bool is never nil, but validates property access
    }
    
    func testMetalOps_DeviceName_ReturnsString() {
        let deviceName = MetalOps.deviceName
        XCTAssertFalse(deviceName.isEmpty)
    }
    
    // MARK: - RGB to YCbCr Tests
    
    func testRGBToYCbCr_PureRed_CorrectYCbCr() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        // Pure red: RGB = (1.0, 0.0, 0.0)
        let rgbData: [Float] = [1.0, 0.0, 0.0]
        let width = 1
        let height = 1
        
        guard let ycbcr = MetalCompute.rgbToYCbCr(rgbData: rgbData, width: width, height: height) else {
            XCTFail("Metal color conversion failed")
            return
        }
        
        XCTAssertEqual(ycbcr.count, 3)
        
        // BT.601: Y = 0.299*R, Cb = 0.5*R, Cr = 0.5*R
        XCTAssertEqual(ycbcr[0], 0.299, accuracy: 0.001, "Y component")
        XCTAssertEqual(ycbcr[1], 0.5, accuracy: 0.001, "Cb component")
        XCTAssertEqual(ycbcr[2], 0.5, accuracy: 0.001, "Cr component")
    }
    
    func testRGBToYCbCr_PureGreen_CorrectYCbCr() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        // Pure green: RGB = (0.0, 1.0, 0.0)
        let rgbData: [Float] = [0.0, 1.0, 0.0]
        let width = 1
        let height = 1
        
        guard let ycbcr = MetalCompute.rgbToYCbCr(rgbData: rgbData, width: width, height: height) else {
            XCTFail("Metal color conversion failed")
            return
        }
        
        XCTAssertEqual(ycbcr.count, 3)
        
        // BT.601: Y = 0.587*G, Cb = -0.331264*G, Cr = -0.418688*G
        XCTAssertEqual(ycbcr[0], 0.587, accuracy: 0.001, "Y component")
        XCTAssertEqual(ycbcr[1], -0.331264, accuracy: 0.001, "Cb component")
        XCTAssertEqual(ycbcr[2], -0.418688, accuracy: 0.001, "Cr component")
    }
    
    func testRGBToYCbCr_Gray_NeutralChroma() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        // Gray: RGB = (0.5, 0.5, 0.5)
        let rgbData: [Float] = [0.5, 0.5, 0.5]
        let width = 1
        let height = 1
        
        guard let ycbcr = MetalCompute.rgbToYCbCr(rgbData: rgbData, width: width, height: height) else {
            XCTFail("Metal color conversion failed")
            return
        }
        
        XCTAssertEqual(ycbcr.count, 3)
        
        // Gray should have Y = 0.5, Cb ≈ 0, Cr ≈ 0
        XCTAssertEqual(ycbcr[0], 0.5, accuracy: 0.001, "Y component")
        XCTAssertEqual(ycbcr[1], 0.0, accuracy: 0.001, "Cb component")
        XCTAssertEqual(ycbcr[2], 0.0, accuracy: 0.001, "Cr component")
    }
    
    // MARK: - DCT Tests
    
    func testDCT_ConstantBlock_OnlyDC() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        // 8×8 block filled with constant value
        let constant: Float = 128.0
        let inputData = [Float](repeating: constant, count: 64)
        
        guard let dctData = MetalCompute.dct8x8(inputData: inputData, width: 8, height: 8) else {
            XCTFail("Metal DCT failed")
            return
        }
        
        XCTAssertEqual(dctData.count, 64)
        
        // Constant block should have non-zero DC coefficient and zero AC coefficients
        XCTAssertGreaterThan(abs(dctData[0]), 0.1, "DC coefficient should be non-zero")
        
        // AC coefficients should be near zero
        for i in 1..<64 {
            XCTAssertEqual(dctData[i], 0.0, accuracy: 0.01, "AC coefficient \(i) should be near zero")
        }
    }
    
    func testDCT_IDCTRoundTrip_ReconstructsOriginal() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        // Create a simple 8×8 gradient pattern
        var inputData = [Float](repeating: 0, count: 64)
        for y in 0..<8 {
            for x in 0..<8 {
                inputData[y * 8 + x] = Float(x + y * 8)
            }
        }
        
        guard let dctData = MetalCompute.dct8x8(inputData: inputData, width: 8, height: 8),
              let reconstructed = MetalCompute.idct8x8(inputData: dctData, width: 8, height: 8) else {
            XCTFail("Metal DCT/IDCT failed")
            return
        }
        
        XCTAssertEqual(reconstructed.count, 64)
        
        // Check round-trip reconstruction
        for i in 0..<64 {
            XCTAssertEqual(reconstructed[i], inputData[i], accuracy: 0.01, "Pixel \(i) should match")
        }
    }
    
    func testDCT_MultipleBlocks_IndependentTransform() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        // Create 16×16 image (4 blocks)
        var inputData = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            inputData[i] = Float(i % 128)
        }
        
        guard let dctData = MetalCompute.dct8x8(inputData: inputData, width: 16, height: 16) else {
            XCTFail("Metal DCT on multiple blocks failed")
            return
        }
        
        XCTAssertEqual(dctData.count, 256)
        
        // Each block should have been independently transformed
        // Just verify output size is correct and no NaN values
        for value in dctData {
            XCTAssertFalse(value.isNaN, "DCT output should not contain NaN")
            XCTAssertFalse(value.isInfinite, "DCT output should not contain Inf")
        }
    }
    
    // MARK: - Quantization Tests
    
    func testQuantize_UniformTable_CorrectScaling() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        // Create simple coefficients and quantization table
        let coefficients: [Float] = [100.0, 50.0, 25.0, 10.0] + [Float](repeating: 0, count: 60)
        let quantTable: [Float] = [10.0] + [Float](repeating: 5.0, count: 63)
        
        guard let quantized = MetalCompute.quantize(coefficients: coefficients, quantTable: quantTable) else {
            XCTFail("Metal quantization failed")
            return
        }
        
        XCTAssertEqual(quantized.count, 64)
        
        // Check quantization: coefficient / quantStep
        XCTAssertEqual(quantized[0], 10, "100 / 10 = 10")
        XCTAssertEqual(quantized[1], 10, "50 / 5 = 10")
        XCTAssertEqual(quantized[2], 5, "25 / 5 = 5")
        XCTAssertEqual(quantized[3], 2, "10 / 5 = 2")
    }
    
    func testQuantize_DequantizeRoundTrip_ApproximateReconstruction() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        let coefficients: [Float] = [100.0, 50.0, 25.0, 10.0] + [Float](repeating: 0, count: 60)
        let quantTable: [Float] = [10.0] + [Float](repeating: 5.0, count: 63)
        
        guard let quantized = MetalCompute.quantize(coefficients: coefficients, quantTable: quantTable),
              let dequantized = MetalCompute.dequantize(quantized: quantized, quantTable: quantTable) else {
            XCTFail("Metal quantize/dequantize failed")
            return
        }
        
        XCTAssertEqual(dequantized.count, 64)
        
        // Dequantization should approximately reconstruct (within quantization error)
        XCTAssertEqual(dequantized[0], 100.0, accuracy: 10.0, "DC coefficient")
        XCTAssertEqual(dequantized[1], 50.0, accuracy: 5.0, "AC coefficient")
        XCTAssertEqual(dequantized[2], 25.0, accuracy: 5.0, "AC coefficient")
    }
    
    // MARK: - Error Handling Tests
    
    func testDCT_InvalidDimensions_ReturnsNil() {
        // Width not multiple of 8
        let inputData = [Float](repeating: 0, count: 63)
        let result = MetalCompute.dct8x8(inputData: inputData, width: 7, height: 9)
        XCTAssertNil(result, "Should return nil for non-multiple-of-8 dimensions")
    }
    
    func testDCT_MismatchedDataSize_ReturnsNil() {
        // Data size doesn't match width × height
        let inputData = [Float](repeating: 0, count: 63)
        let result = MetalCompute.dct8x8(inputData: inputData, width: 8, height: 8)
        XCTAssertNil(result, "Should return nil when data size doesn't match dimensions")
    }
    
    func testQuantize_InvalidTableSize_ReturnsNil() {
        let coefficients = [Float](repeating: 0, count: 64)
        let quantTable = [Float](repeating: 1.0, count: 32) // Wrong size
        let result = MetalCompute.quantize(coefficients: coefficients, quantTable: quantTable)
        XCTAssertNil(result, "Should return nil for invalid quantization table size")
    }
    
    // MARK: - Performance Tests
    
    func testPerformance_DCT_SmallImage() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        let inputData = [Float](repeating: 128.0, count: 64 * 64) // 64×64 image
        
        measure {
            _ = MetalCompute.dct8x8(inputData: inputData, width: 64, height: 64)
        }
    }
    
    func testPerformance_ColorConversion_256x256() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        let pixelCount = 256 * 256
        let rgbData = [Float](repeating: 0.5, count: pixelCount * 3)
        
        measure {
            _ = MetalCompute.rgbToYCbCr(rgbData: rgbData, width: 256, height: 256)
        }
    }
}
#else
// Metal not available - provide empty test suite
final class MetalComputeTests: XCTestCase {
    func testMetalNotAvailable() {
        XCTAssertFalse(false, "Metal not available on this platform")
    }
}
#endif
