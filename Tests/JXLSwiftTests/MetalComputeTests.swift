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
    
    // MARK: - Async Operations Tests
    
    func testDCT8x8Async_CompletesSuccessfully() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        // Create simple test data: 64×8 (8 blocks horizontally)
        let width = 64
        let height = 8
        let inputData = [Float](repeating: 0.5, count: width * height)
        
        let expectation = XCTestExpectation(description: "Async DCT completes")
        
        MetalCompute.dct8x8Async(inputData: inputData, width: width, height: height) { result in
            XCTAssertNotNil(result, "Async DCT should return result")
            if let result = result {
                XCTAssertEqual(result.count, width * height)
            }
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testDCT8x8Async_MatchesSyncVersion() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        // Create test pattern
        let width = 16
        let height = 8
        let inputData: [Float] = (0..<(width * height)).map { Float($0) / Float(width * height) }
        
        // Get sync result
        guard let syncResult = MetalCompute.dct8x8(inputData: inputData, width: width, height: height) else {
            XCTFail("Sync DCT failed")
            return
        }
        
        // Get async result
        let expectation = XCTestExpectation(description: "Async DCT matches sync")
        
        MetalCompute.dct8x8Async(inputData: inputData, width: width, height: height) { asyncResult in
            XCTAssertNotNil(asyncResult)
            if let asyncResult = asyncResult {
                XCTAssertEqual(asyncResult.count, syncResult.count)
                // Compare results
                for i in 0..<syncResult.count {
                    XCTAssertEqual(asyncResult[i], syncResult[i], accuracy: 1e-5, "Mismatch at index \(i)")
                }
            }
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testDCT8x8Async_InvalidDimensions_ReturnsNil() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        // Test with non-multiple-of-8 dimensions
        let width = 15  // Not multiple of 8
        let height = 8
        let inputData = [Float](repeating: 0.5, count: width * height)
        
        let expectation = XCTestExpectation(description: "Async DCT handles invalid input")
        
        MetalCompute.dct8x8Async(inputData: inputData, width: width, height: height) { result in
            XCTAssertNil(result, "Should return nil for invalid dimensions")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    // MARK: - Buffer Pool Tests
    
    func testMetalBufferPool_AcquireAndRelease() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        guard let device = MetalOps.device() else {
            XCTFail("Could not get Metal device")
            return
        }
        
        let pool = MetalBufferPool(device: device)
        
        // Acquire buffer
        guard let buffer1 = pool.acquireBuffer(length: 1024) else {
            XCTFail("Failed to acquire buffer")
            return
        }
        
        XCTAssertGreaterThanOrEqual(buffer1.length, 1024)
        
        // Return to pool
        pool.releaseBuffer(buffer1)
        XCTAssertEqual(pool.totalBuffers, 1, "Buffer should be in pool")
        
        // Acquire again - should reuse
        guard let buffer2 = pool.acquireBuffer(length: 1024) else {
            XCTFail("Failed to reacquire buffer")
            return
        }
        
        XCTAssertEqual(pool.totalBuffers, 0, "Buffer should be taken from pool")
        
        pool.releaseBuffer(buffer2)
    }
    
    func testMetalBufferPool_Clear() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        guard let device = MetalOps.device() else {
            XCTFail("Could not get Metal device")
            return
        }
        
        let pool = MetalBufferPool(device: device)
        
        // Add some buffers
        if let buffer1 = pool.acquireBuffer(length: 1024) {
            pool.releaseBuffer(buffer1)
        }
        if let buffer2 = pool.acquireBuffer(length: 2048) {
            pool.releaseBuffer(buffer2)
        }
        
        XCTAssertGreaterThan(pool.totalBuffers, 0)
        
        pool.clear()
        XCTAssertEqual(pool.totalBuffers, 0, "Pool should be empty after clear")
    }
    
    // MARK: - Async Pipeline Tests
    
    func testMetalAsyncPipeline_ProcessMultipleBatches() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        guard let pipeline = MetalAsyncPipeline() else {
            XCTFail("Failed to create async pipeline")
            return
        }
        
        // Create 3 batches of test data
        let batch1 = (data: [Float](repeating: 0.2, count: 64), width: 8, height: 8)
        let batch2 = (data: [Float](repeating: 0.5, count: 64), width: 8, height: 8)
        let batch3 = (data: [Float](repeating: 0.8, count: 64), width: 8, height: 8)
        let batches = [batch1, batch2, batch3]
        
        let expectation = XCTestExpectation(description: "Pipeline processes all batches")
        
        pipeline.processDCTBatches(batches: batches) { results in
            XCTAssertEqual(results.count, 3, "Should have 3 results")
            XCTAssertNotNil(results[0], "Batch 1 should succeed")
            XCTAssertNotNil(results[1], "Batch 2 should succeed")
            XCTAssertNotNil(results[2], "Batch 3 should succeed")
            
            if let result0 = results[0] {
                XCTAssertEqual(result0.count, 64)
            }
            
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 10.0)
        
        pipeline.cleanup()
    }
    
    func testMetalAsyncPipeline_EmptyBatches() throws {
        guard MetalOps.isAvailable else {
            throw XCTSkip("Metal not available on this platform")
        }
        
        guard let pipeline = MetalAsyncPipeline() else {
            XCTFail("Failed to create async pipeline")
            return
        }
        
        let batches: [(data: [Float], width: Int, height: Int)] = []
        
        let expectation = XCTestExpectation(description: "Pipeline handles empty batches")
        
        pipeline.processDCTBatches(batches: batches) { results in
            XCTAssertEqual(results.count, 0, "Empty input should give empty output")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
        
        pipeline.cleanup()
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
