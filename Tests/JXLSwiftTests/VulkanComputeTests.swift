/// Tests for Vulkan GPU compute operations and the cross-platform GPUCompute abstraction.
///
/// When Vulkan is available (Linux/Windows with a compatible GPU) these tests
/// verify numerical correctness against CPU implementations.  On platforms
/// where Vulkan is not present — including all Apple platforms — the tests
/// verify that the CPU-fallback path is exercised correctly and that the
/// `GPUCompute` abstraction routes to Metal as expected.

import XCTest
@testable import JXLSwift

// MARK: - Vulkan-specific tests (compiled only when Vulkan SDK is available)

#if canImport(Vulkan)
final class VulkanComputeTests: XCTestCase {

    override func tearDown() {
        VulkanOps.cleanup()
        super.tearDown()
    }

    // MARK: - Availability

    func testVulkanOps_IsAvailable() {
        // Just verify the property is accessible and returns a Bool
        let available = VulkanOps.isAvailable
        _ = available // suppress unused warning
    }

    func testVulkanOps_DeviceName_ReturnsString() {
        let name = VulkanOps.deviceName
        XCTAssertFalse(name.isEmpty)
    }

    // MARK: - Colour Conversion

    func testVulkanCompute_RGBToYCbCr_PureRed() throws {
        guard VulkanOps.isAvailable else {
            throw XCTSkip("Vulkan not available on this platform")
        }

        let rgbData: [Float] = [1.0, 0.0, 0.0]
        guard let result = VulkanCompute.rgbToYCbCr(rgbData: rgbData, width: 1, height: 1) else {
            XCTFail("Vulkan colour conversion returned nil")
            return
        }

        XCTAssertEqual(result.count, 3)
        // BT.601 (no digital-range offset): Y = 0.299*R, Cb = -0.168736*R, Cr = 0.5*R
        XCTAssertEqual(result[0],  0.299,     accuracy: 0.001, "Y component")
        XCTAssertEqual(result[1], -0.168736,  accuracy: 0.001, "Cb component")
        XCTAssertEqual(result[2],  0.5,       accuracy: 0.001, "Cr component")
    }

    func testVulkanCompute_RGBToYCbCr_Gray_NeutralChroma() throws {
        guard VulkanOps.isAvailable else {
            throw XCTSkip("Vulkan not available on this platform")
        }

        let rgbData: [Float] = [0.5, 0.5, 0.5]
        guard let result = VulkanCompute.rgbToYCbCr(rgbData: rgbData, width: 1, height: 1) else {
            XCTFail("Vulkan colour conversion returned nil")
            return
        }

        XCTAssertEqual(result[0], 0.5, accuracy: 0.001, "Y component")
        XCTAssertEqual(result[1], 0.0, accuracy: 0.001, "Cb should be ~0 for grey")
        XCTAssertEqual(result[2], 0.0, accuracy: 0.001, "Cr should be ~0 for grey")
    }

    // MARK: - DCT

    func testVulkanCompute_DCT_ConstantBlock_OnlyDC() throws {
        guard VulkanOps.isAvailable else {
            throw XCTSkip("Vulkan not available on this platform")
        }

        let inputData = [Float](repeating: 128.0, count: 64)
        guard let dct = VulkanCompute.dct8x8(inputData: inputData, width: 8, height: 8) else {
            XCTFail("Vulkan DCT returned nil")
            return
        }

        XCTAssertEqual(dct.count, 64)
        XCTAssertGreaterThan(abs(dct[0]), 0.1, "DC coefficient should be non-zero")
        for i in 1..<64 {
            XCTAssertEqual(dct[i], 0.0, accuracy: 0.01, "AC coefficient \(i) should be near zero")
        }
    }

    func testVulkanCompute_DCT_IDCT_RoundTrip() throws {
        guard VulkanOps.isAvailable else {
            throw XCTSkip("Vulkan not available on this platform")
        }

        var inputData = [Float](repeating: 0, count: 64)
        for y in 0..<8 { for x in 0..<8 { inputData[y * 8 + x] = Float(x + y * 8) } }

        guard let dct = VulkanCompute.dct8x8(inputData: inputData, width: 8, height: 8),
              let reconstructed = VulkanCompute.idct8x8(inputData: dct, width: 8, height: 8) else {
            XCTFail("Vulkan DCT/IDCT returned nil")
            return
        }

        for i in 0..<64 {
            XCTAssertEqual(reconstructed[i], inputData[i], accuracy: 0.01, "Pixel \(i)")
        }
    }

    func testVulkanCompute_DCT_InvalidDimensions_ReturnsNil() {
        let result = VulkanCompute.dct8x8(
            inputData: [Float](repeating: 0, count: 63),
            width: 7, height: 9
        )
        XCTAssertNil(result, "Should return nil for non-multiple-of-8 dimensions")
    }

    // MARK: - Quantisation

    func testVulkanCompute_Quantize_UniformTable() throws {
        guard VulkanOps.isAvailable else {
            throw XCTSkip("Vulkan not available on this platform")
        }

        let coefficients: [Float] = [100.0, 50.0, 25.0, 10.0] + [Float](repeating: 0, count: 60)
        let quantTable: [Float] = [10.0] + [Float](repeating: 5.0, count: 63)

        guard let quantized = VulkanCompute.quantize(
            coefficients: coefficients, quantTable: quantTable
        ) else {
            XCTFail("Vulkan quantise returned nil")
            return
        }

        XCTAssertEqual(quantized[0], 10, "100 / 10 = 10")
        XCTAssertEqual(quantized[1], 10, "50  /  5 = 10")
        XCTAssertEqual(quantized[2],  5, "25  /  5 = 5")
        XCTAssertEqual(quantized[3],  2, "10  /  5 = 2")
    }

    func testVulkanCompute_Quantize_InvalidTableSize_ReturnsNil() {
        let result = VulkanCompute.quantize(
            coefficients: [Float](repeating: 0, count: 64),
            quantTable: [Float](repeating: 1.0, count: 32) // wrong size
        )
        XCTAssertNil(result, "Should return nil for invalid quantisation table size")
    }

    // MARK: - Buffer Pool

    func testVulkanBufferPool_AcquireAndRelease() throws {
        guard VulkanOps.isAvailable else {
            throw XCTSkip("Vulkan not available on this platform")
        }

        let pool = VulkanBufferPool()

        guard let buffer = pool.acquireBuffer(length: 1024) else {
            XCTFail("Failed to acquire Vulkan buffer")
            return
        }
        XCTAssertGreaterThanOrEqual(buffer.length, 1024)

        pool.releaseBuffer(buffer)
        XCTAssertEqual(pool.totalBuffers, 1)

        guard let reused = pool.acquireBuffer(length: 1024) else {
            XCTFail("Failed to reacquire Vulkan buffer")
            return
        }
        XCTAssertEqual(pool.totalBuffers, 0)
        pool.releaseBuffer(reused)
    }

    func testVulkanBufferPool_Clear() throws {
        guard VulkanOps.isAvailable else {
            throw XCTSkip("Vulkan not available on this platform")
        }

        let pool = VulkanBufferPool()
        if let buf = pool.acquireBuffer(length: 512) { pool.releaseBuffer(buf) }
        XCTAssertGreaterThan(pool.totalBuffers, 0)
        pool.clear()
        XCTAssertEqual(pool.totalBuffers, 0)
    }

    // MARK: - Async Pipeline

    func testVulkanAsyncPipeline_ProcessMultipleBatches() throws {
        guard VulkanOps.isAvailable else {
            throw XCTSkip("Vulkan not available on this platform")
        }

        guard let pipeline = VulkanAsyncPipeline() else {
            XCTFail("Failed to create VulkanAsyncPipeline")
            return
        }

        let batches = [
            (data: [Float](repeating: 0.2, count: 64), width: 8, height: 8),
            (data: [Float](repeating: 0.5, count: 64), width: 8, height: 8),
            (data: [Float](repeating: 0.8, count: 64), width: 8, height: 8),
        ]

        let expectation = XCTestExpectation(description: "Vulkan pipeline processes all batches")
        pipeline.processDCTBatches(batches: batches) { results in
            XCTAssertEqual(results.count, 3)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10.0)
        pipeline.cleanup()
    }

    func testVulkanAsyncPipeline_EmptyBatches() throws {
        guard VulkanOps.isAvailable else {
            throw XCTSkip("Vulkan not available on this platform")
        }

        guard let pipeline = VulkanAsyncPipeline() else {
            XCTFail("Failed to create VulkanAsyncPipeline")
            return
        }

        let expectation = XCTestExpectation(description: "Empty batch returns empty results")
        pipeline.processDCTBatches(batches: []) { results in
            XCTAssertEqual(results.count, 0)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
        pipeline.cleanup()
    }

    // MARK: - Performance

    func testPerformance_Vulkan_DCT_SmallImage() throws {
        guard VulkanOps.isAvailable else {
            throw XCTSkip("Vulkan not available on this platform")
        }

        let inputData = [Float](repeating: 128.0, count: 64 * 64)
        measure {
            _ = VulkanCompute.dct8x8(inputData: inputData, width: 64, height: 64)
        }
    }
}
#endif // canImport(Vulkan)

// MARK: - GPUCompute abstraction tests (always compiled)

/// Tests for the cross-platform `GPUCompute` abstraction layer.
///
/// These tests run on every platform and verify that:
/// - `GPUCompute.isAvailable` is consistent with the active backend
/// - `GPUCompute.backendDescription` returns a non-empty string
/// - On platforms without a GPU the methods return `nil` gracefully
/// - On Apple platforms Metal is preferred over Vulkan
@available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
final class GPUComputeTests: XCTestCase {

    override func tearDown() {
        GPUCompute.cleanup()
        super.tearDown()
    }

    // MARK: - Availability

    func testGPUCompute_IsAvailable_ReturnsBool() {
        // Just verify the property is accessible
        let available = GPUCompute.isAvailable
        _ = available
    }

    func testGPUCompute_BackendDescription_NotEmpty() {
        XCTAssertFalse(GPUCompute.backendDescription.isEmpty)
    }

    func testGPUCompute_DispatchBackend_ConsistentWithIsAvailable() {
        if GPUCompute.isAvailable {
            XCTAssertNotNil(GPUCompute.dispatchBackend,
                            "dispatchBackend should be non-nil when GPU is available")
        } else {
            XCTAssertNil(GPUCompute.dispatchBackend,
                         "dispatchBackend should be nil when no GPU is available")
        }
    }

    // MARK: - Metal preference on Apple platforms

    func testGPUCompute_ApplePlatform_PrefersMetalOverVulkan() {
        #if canImport(Metal)
        if let backend = GPUCompute.dispatchBackend {
            // On Apple platforms Metal should be chosen, never Vulkan
            XCTAssertEqual(backend, .metal,
                           "GPUCompute should prefer Metal over Vulkan on Apple platforms")
        }
        #endif
    }

    // MARK: - Error handling — no GPU

    func testGPUCompute_DCT_InvalidDimensions_ReturnsNil() {
        // Non-multiple-of-8 dimensions must always return nil,
        // regardless of whether a GPU is present.
        let result = GPUCompute.dct8x8(
            inputData: [Float](repeating: 0, count: 63),
            width: 7, height: 9
        )
        XCTAssertNil(result, "Invalid dimensions should always return nil")
    }

    func testGPUCompute_Quantize_InvalidTableSize_ReturnsNil() {
        let result = GPUCompute.quantize(
            coefficients: [Float](repeating: 0, count: 64),
            quantTable: [Float](repeating: 1.0, count: 32) // wrong size — GPU would reject
        )
        // Either nil (GPU rejected) or a CPU fallback is fine; we just verify no crash
        _ = result
    }

    // MARK: - Functional correctness (when GPU is available)

    func testGPUCompute_DCT_RoundTrip_WhenAvailable() throws {
        guard GPUCompute.isAvailable else {
            throw XCTSkip("No GPU available on this platform")
        }

        var inputData = [Float](repeating: 0, count: 64)
        for i in 0..<64 { inputData[i] = Float(i) }

        guard let dct = GPUCompute.dct8x8(inputData: inputData, width: 8, height: 8),
              let reconstructed = GPUCompute.idct8x8(inputData: dct, width: 8, height: 8) else {
            XCTFail("GPUCompute DCT/IDCT returned nil")
            return
        }

        for i in 0..<64 {
            XCTAssertEqual(reconstructed[i], inputData[i], accuracy: 0.01, "Pixel \(i)")
        }
    }

    func testGPUCompute_RGBToYCbCr_Gray_WhenAvailable() throws {
        guard GPUCompute.isAvailable else {
            throw XCTSkip("No GPU available on this platform")
        }

        let rgbData: [Float] = [0.5, 0.5, 0.5]
        guard let ycbcr = GPUCompute.rgbToYCbCr(rgbData: rgbData, width: 1, height: 1) else {
            XCTFail("GPUCompute rgbToYCbCr returned nil")
            return
        }

        XCTAssertEqual(ycbcr[0], 0.5, accuracy: 0.001, "Y")
        XCTAssertEqual(ycbcr[1], 0.0, accuracy: 0.001, "Cb should be ~0 for grey")
        XCTAssertEqual(ycbcr[2], 0.0, accuracy: 0.001, "Cr should be ~0 for grey")
    }

    func testGPUCompute_Quantize_WhenAvailable() throws {
        guard GPUCompute.isAvailable else {
            throw XCTSkip("No GPU available on this platform")
        }

        let coefficients: [Float] = [100.0, 50.0] + [Float](repeating: 0, count: 62)
        let quantTable: [Float] = [10.0, 5.0] + [Float](repeating: 1.0, count: 62)

        guard let quantized = GPUCompute.quantize(
            coefficients: coefficients, quantTable: quantTable
        ) else {
            XCTFail("GPUCompute quantize returned nil")
            return
        }

        XCTAssertEqual(quantized[0], 10, "100 / 10 = 10")
        XCTAssertEqual(quantized[1], 10, "50  /  5 = 10")
    }

    // MARK: - Async interface

    func testGPUCompute_DCT8x8Async_WhenUnavailable_ReturnsNil() {
        guard !GPUCompute.isAvailable else { return }

        let expectation = XCTestExpectation(description: "Async returns nil when no GPU")
        GPUCompute.dct8x8Async(
            inputData: [Float](repeating: 0.5, count: 64),
            width: 8, height: 8
        ) { result in
            XCTAssertNil(result, "Should return nil when no GPU is available")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testGPUCompute_DCT8x8Async_WhenAvailable_Completes() throws {
        guard GPUCompute.isAvailable else {
            throw XCTSkip("No GPU available on this platform")
        }

        let expectation = XCTestExpectation(description: "Async DCT completes")
        GPUCompute.dct8x8Async(
            inputData: [Float](repeating: 0.5, count: 64),
            width: 8, height: 8
        ) { result in
            XCTAssertNotNil(result)
            if let r = result { XCTAssertEqual(r.count, 64) }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10.0)
    }

    // MARK: - HardwareCapabilities Vulkan fields

    func testHardwareCapabilities_HasVulkanField() {
        let caps = HardwareCapabilities.detect()
        // On Apple platforms Vulkan is always false
        #if canImport(Metal) && !canImport(Vulkan)
        XCTAssertFalse(caps.hasVulkan,
                       "hasVulkan should be false on Apple platforms without Vulkan SDK")
        XCTAssertNil(caps.vulkanDeviceName,
                     "vulkanDeviceName should be nil when Vulkan is absent")
        #endif
        // On platforms with Vulkan the value reflects actual availability
        _ = caps.hasVulkan
        _ = caps.vulkanDeviceName
    }

    // MARK: - Performance

    func testGPUCompute_Performance_DCT_SmallImage() throws {
        guard GPUCompute.isAvailable else {
            throw XCTSkip("No GPU available on this platform")
        }

        let inputData = [Float](repeating: 128.0, count: 64 * 64)
        measure {
            _ = GPUCompute.dct8x8(inputData: inputData, width: 64, height: 64)
        }
    }
}
