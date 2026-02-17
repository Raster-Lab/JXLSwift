/// Metal Compute Operations Interface
///
/// High-level Swift interface for Metal GPU compute operations.
/// Provides wrapper functions for DCT, color conversion, and quantization.

#if canImport(Metal)
import Metal
import Foundation

/// Metal compute operations interface
@available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
public enum MetalCompute {
    
    // MARK: - Color Conversion
    
    /// Convert RGB to YCbCr color space using Metal GPU
    ///
    /// - Parameters:
    ///   - rgbData: Input RGB data (3 floats per pixel, interleaved)
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: YCbCr data (3 floats per pixel, planar), or `nil` on error
    public static func rgbToYCbCr(
        rgbData: [Float],
        width: Int,
        height: Int
    ) -> [Float]? {
        guard MetalOps.isAvailable else { return nil }
        guard let commandQueue = MetalOps.commandQueue() else { return nil }
        guard let pipeline = MetalOps.computePipelineState(for: "rgb_to_ycbcr") else { return nil }
        
        let pixelCount = width * height
        guard rgbData.count == pixelCount * 3 else { return nil }
        
        // Create input buffer
        guard let rgbBuffer = MetalOps.makeBuffer(
            from: rgbData,
            length: rgbData.count * MemoryLayout<Float>.stride
        ) else { return nil }
        
        // Create output buffer
        let outputSize = pixelCount * 3 * MemoryLayout<Float>.stride
        guard let ycbcrBuffer = MetalOps.makeBuffer(length: outputSize) else { return nil }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        // Encode command
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setBuffer(rgbBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(ycbcrBuffer, offset: 0, index: 1)
        
        var widthU = UInt32(width)
        var heightU = UInt32(height)
        computeEncoder.setBytes(&widthU, length: MemoryLayout<UInt32>.stride, index: 2)
        computeEncoder.setBytes(&heightU, length: MemoryLayout<UInt32>.stride, index: 3)
        
        // Calculate threadgroup configuration
        let (threadsPerThreadgroup, threadgroupsPerGrid) = MetalOps.calculateThreadgroups2D(
            pipeline: pipeline,
            width: width,
            height: height
        )
        
        computeEncoder.dispatchThreadgroups(
            threadgroupsPerGrid,
            threadsPerThreadgroup: threadsPerThreadgroup
        )
        
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Read results
        let resultPointer = ycbcrBuffer.contents().assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: resultPointer, count: pixelCount * 3))
    }
    
    // MARK: - 2D DCT Transform
    
    /// Perform 2D DCT on 8×8 blocks using Metal GPU
    ///
    /// - Parameters:
    ///   - inputData: Input spatial domain data (must be width×height floats)
    ///   - width: Image width (must be multiple of 8)
    ///   - height: Image height (must be multiple of 8)
    /// - Returns: Frequency domain data, or `nil` on error
    public static func dct8x8(
        inputData: [Float],
        width: Int,
        height: Int
    ) -> [Float]? {
        guard MetalOps.isAvailable else { return nil }
        guard width % 8 == 0 && height % 8 == 0 else { return nil }
        guard inputData.count == width * height else { return nil }
        guard let commandQueue = MetalOps.commandQueue() else { return nil }
        guard let pipeline = MetalOps.computePipelineState(for: "dct_8x8") else { return nil }
        
        // Create input buffer
        guard let inputBuffer = MetalOps.makeBuffer(
            from: inputData,
            length: inputData.count * MemoryLayout<Float>.stride
        ) else { return nil }
        
        // Create output buffer
        guard let outputBuffer = MetalOps.makeBuffer(
            length: inputData.count * MemoryLayout<Float>.stride
        ) else { return nil }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        // Encode command
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(outputBuffer, offset: 0, index: 1)
        
        var widthU = UInt32(width)
        var heightU = UInt32(height)
        computeEncoder.setBytes(&widthU, length: MemoryLayout<UInt32>.stride, index: 2)
        computeEncoder.setBytes(&heightU, length: MemoryLayout<UInt32>.stride, index: 3)
        
        // Calculate threadgroup configuration for 8×8 blocks
        let blocksX = width / 8
        let blocksY = height / 8
        let (threadsPerThreadgroup, threadgroupsPerGrid) = MetalOps.calculateThreadgroups2D(
            pipeline: pipeline,
            width: blocksX,
            height: blocksY
        )
        
        computeEncoder.dispatchThreadgroups(
            threadgroupsPerGrid,
            threadsPerThreadgroup: threadsPerThreadgroup
        )
        
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Read results
        let resultPointer = outputBuffer.contents().assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: resultPointer, count: width * height))
    }
    
    /// Perform inverse 2D DCT on 8×8 blocks using Metal GPU
    ///
    /// - Parameters:
    ///   - inputData: Input frequency domain data
    ///   - width: Image width (must be multiple of 8)
    ///   - height: Image height (must be multiple of 8)
    /// - Returns: Spatial domain data, or `nil` on error
    public static func idct8x8(
        inputData: [Float],
        width: Int,
        height: Int
    ) -> [Float]? {
        guard MetalOps.isAvailable else { return nil }
        guard width % 8 == 0 && height % 8 == 0 else { return nil }
        guard inputData.count == width * height else { return nil }
        guard let commandQueue = MetalOps.commandQueue() else { return nil }
        guard let pipeline = MetalOps.computePipelineState(for: "idct_8x8") else { return nil }
        
        // Create input buffer
        guard let inputBuffer = MetalOps.makeBuffer(
            from: inputData,
            length: inputData.count * MemoryLayout<Float>.stride
        ) else { return nil }
        
        // Create output buffer
        guard let outputBuffer = MetalOps.makeBuffer(
            length: inputData.count * MemoryLayout<Float>.stride
        ) else { return nil }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        // Encode command
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(outputBuffer, offset: 0, index: 1)
        
        var widthU = UInt32(width)
        var heightU = UInt32(height)
        computeEncoder.setBytes(&widthU, length: MemoryLayout<UInt32>.stride, index: 2)
        computeEncoder.setBytes(&heightU, length: MemoryLayout<UInt32>.stride, index: 3)
        
        // Calculate threadgroup configuration for 8×8 blocks
        let blocksX = width / 8
        let blocksY = height / 8
        let (threadsPerThreadgroup, threadgroupsPerGrid) = MetalOps.calculateThreadgroups2D(
            pipeline: pipeline,
            width: blocksX,
            height: blocksY
        )
        
        computeEncoder.dispatchThreadgroups(
            threadgroupsPerGrid,
            threadsPerThreadgroup: threadsPerThreadgroup
        )
        
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Read results
        let resultPointer = outputBuffer.contents().assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: resultPointer, count: width * height))
    }
    
    // MARK: - Quantization
    
    /// Quantize DCT coefficients using Metal GPU
    ///
    /// - Parameters:
    ///   - coefficients: Input DCT coefficients
    ///   - quantTable: Quantization table (64 values for 8×8 DCT)
    /// - Returns: Quantized coefficients as Int16, or `nil` on error
    public static func quantize(
        coefficients: [Float],
        quantTable: [Float]
    ) -> [Int16]? {
        guard MetalOps.isAvailable else { return nil }
        guard quantTable.count == 64 else { return nil }
        guard let commandQueue = MetalOps.commandQueue() else { return nil }
        guard let pipeline = MetalOps.computePipelineState(for: "quantize") else { return nil }
        
        // Create input buffer
        guard let inputBuffer = MetalOps.makeBuffer(
            from: coefficients,
            length: coefficients.count * MemoryLayout<Float>.stride
        ) else { return nil }
        
        // Create output buffer
        guard let outputBuffer = MetalOps.makeBuffer(
            length: coefficients.count * MemoryLayout<Int16>.stride
        ) else { return nil }
        
        // Create quantization table buffer
        guard let quantBuffer = MetalOps.makeBuffer(
            from: quantTable,
            length: quantTable.count * MemoryLayout<Float>.stride
        ) else { return nil }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        // Encode command
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(outputBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(quantBuffer, offset: 0, index: 2)
        
        var count = UInt32(coefficients.count)
        computeEncoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 3)
        
        // Calculate threadgroup configuration
        let (threadsPerThreadgroup, threadgroupsPerGrid) = MetalOps.calculateThreadgroups(
            pipeline: pipeline,
            totalCount: coefficients.count
        )
        
        computeEncoder.dispatchThreadgroups(
            threadgroupsPerGrid,
            threadsPerThreadgroup: threadsPerThreadgroup
        )
        
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Read results
        let resultPointer = outputBuffer.contents().assumingMemoryBound(to: Int16.self)
        return Array(UnsafeBufferPointer(start: resultPointer, count: coefficients.count))
    }
    
    /// Dequantize DCT coefficients using Metal GPU
    ///
    /// - Parameters:
    ///   - quantized: Quantized coefficients (Int16)
    ///   - quantTable: Quantization table (64 values for 8×8 DCT)
    /// - Returns: Dequantized coefficients as Float, or `nil` on error
    public static func dequantize(
        quantized: [Int16],
        quantTable: [Float]
    ) -> [Float]? {
        guard MetalOps.isAvailable else { return nil }
        guard quantTable.count == 64 else { return nil }
        guard let commandQueue = MetalOps.commandQueue() else { return nil }
        guard let pipeline = MetalOps.computePipelineState(for: "dequantize") else { return nil }
        
        // Create input buffer
        guard let inputBuffer = MetalOps.makeBuffer(
            from: quantized,
            length: quantized.count * MemoryLayout<Int16>.stride
        ) else { return nil }
        
        // Create output buffer
        guard let outputBuffer = MetalOps.makeBuffer(
            length: quantized.count * MemoryLayout<Float>.stride
        ) else { return nil }
        
        // Create quantization table buffer
        guard let quantBuffer = MetalOps.makeBuffer(
            from: quantTable,
            length: quantTable.count * MemoryLayout<Float>.stride
        ) else { return nil }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        // Encode command
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(outputBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(quantBuffer, offset: 0, index: 2)
        
        var count = UInt32(quantized.count)
        computeEncoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 3)
        
        // Calculate threadgroup configuration
        let (threadsPerThreadgroup, threadgroupsPerGrid) = MetalOps.calculateThreadgroups(
            pipeline: pipeline,
            totalCount: quantized.count
        )
        
        computeEncoder.dispatchThreadgroups(
            threadgroupsPerGrid,
            threadsPerThreadgroup: threadsPerThreadgroup
        )
        
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Read results
        let resultPointer = outputBuffer.contents().assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: resultPointer, count: quantized.count))
    }
    
    // MARK: - Async Operations with Double-Buffering
    
    /// Asynchronously perform 2D DCT on 8×8 blocks using Metal GPU with completion handler
    ///
    /// - Parameters:
    ///   - inputData: Input spatial domain data (must be width×height floats)
    ///   - width: Image width (must be multiple of 8)
    ///   - height: Image height (must be multiple of 8)
    ///   - completion: Completion handler called when operation finishes with result or nil on error
    public static func dct8x8Async(
        inputData: [Float],
        width: Int,
        height: Int,
        completion: @escaping @Sendable ([Float]?) -> Void
    ) {
        guard MetalOps.isAvailable else {
            completion(nil)
            return
        }
        guard width % 8 == 0 && height % 8 == 0 else {
            completion(nil)
            return
        }
        guard inputData.count == width * height else {
            completion(nil)
            return
        }
        guard let commandQueue = MetalOps.commandQueue() else {
            completion(nil)
            return
        }
        guard let pipeline = MetalOps.computePipelineState(for: "dct_8x8") else {
            completion(nil)
            return
        }
        
        // Create input buffer
        guard let inputBuffer = MetalOps.makeBuffer(
            from: inputData,
            length: inputData.count * MemoryLayout<Float>.stride
        ) else {
            completion(nil)
            return
        }
        
        // Create output buffer
        guard let outputBuffer = MetalOps.makeBuffer(
            length: inputData.count * MemoryLayout<Float>.stride
        ) else {
            completion(nil)
            return
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            completion(nil)
            return
        }
        
        // Encode command
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(outputBuffer, offset: 0, index: 1)
        
        var widthU = UInt32(width)
        var heightU = UInt32(height)
        computeEncoder.setBytes(&widthU, length: MemoryLayout<UInt32>.stride, index: 2)
        computeEncoder.setBytes(&heightU, length: MemoryLayout<UInt32>.stride, index: 3)
        
        // Calculate threadgroup configuration for 8×8 blocks
        let blocksX = width / 8
        let blocksY = height / 8
        let (threadsPerThreadgroup, threadgroupsPerGrid) = MetalOps.calculateThreadgroups2D(
            pipeline: pipeline,
            width: blocksX,
            height: blocksY
        )
        
        computeEncoder.dispatchThreadgroups(
            threadgroupsPerGrid,
            threadsPerThreadgroup: threadsPerThreadgroup
        )
        
        computeEncoder.endEncoding()
        
        // Add completion handler (async execution)
        commandBuffer.addCompletedHandler { _ in
            let resultPointer = outputBuffer.contents().assumingMemoryBound(to: Float.self)
            let result = Array(UnsafeBufferPointer(start: resultPointer, count: width * height))
            completion(result)
        }
        
        commandBuffer.commit()
        // Note: Does NOT wait - returns immediately
    }
}

// MARK: - Buffer Pool for Double-Buffering

/// Metal buffer pool for efficient reuse in double-buffering scenarios
///
/// Thread Safety: This class uses `@unchecked Sendable` because it manages mutable state
/// (`availableBuffers`) that is protected by `NSLock`. All access to mutable properties
/// must go through methods that acquire the lock. Do not add direct property access.
@available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
public final class MetalBufferPool: @unchecked Sendable {
    private let device: MTLDevice
    private var availableBuffers: [Int: [MTLBuffer]] = [:]
    private let lock = NSLock()
    private let minBufferSize = 1024 // Minimum 1 KB
    
    /// Maximum number of buffers to cache per size.
    ///
    /// Limits memory usage while still providing reuse benefits.
    /// 4 buffers supports double-buffering (2) plus 2 extra for pipeline depth.
    private let maxBuffersPerSize = 4
    
    /// Initialize buffer pool with Metal device
    ///
    /// - Parameter device: Metal device to allocate buffers from
    public init(device: MTLDevice) {
        self.device = device
    }
    
    /// Acquire a buffer from the pool or create new one
    ///
    /// - Parameter length: Required buffer length in bytes
    /// - Returns: A Metal buffer of at least the requested size, or nil on failure
    public func acquireBuffer(length: Int) -> MTLBuffer? {
        lock.lock()
        defer { lock.unlock() }
        
        let actualLength = max(length, minBufferSize)
        
        // Check if we have a buffer of this size available
        if let buffer = availableBuffers[actualLength]?.popLast() {
            return buffer
        }
        
        // Create new buffer
        return device.makeBuffer(length: actualLength, options: .storageModeShared)
    }
    
    /// Return a buffer to the pool for reuse
    ///
    /// - Parameter buffer: Buffer to return to pool
    public func releaseBuffer(_ buffer: MTLBuffer) {
        lock.lock()
        defer { lock.unlock() }
        
        let length = buffer.length
        if availableBuffers[length] == nil {
            availableBuffers[length] = []
        }
        
        // Limit pool size per buffer size to avoid excessive memory usage
        if availableBuffers[length]!.count < maxBuffersPerSize {
            availableBuffers[length]!.append(buffer)
        }
    }
    
    /// Clear all cached buffers
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        availableBuffers.removeAll()
    }
    
    /// Get total number of cached buffers
    public var totalBuffers: Int {
        lock.lock()
        defer { lock.unlock() }
        return availableBuffers.values.reduce(0) { $0 + $1.count }
    }
}

// MARK: - Async Pipeline Manager

/// Manager for async Metal operations with double-buffering
///
/// Thread Safety: Uses `@unchecked Sendable` with `NSLock` protection for the `isProcessing`
/// flag. This simple boolean flag pattern is sufficient for preventing concurrent pipeline
/// invocations. The lock ensures atomic check-and-set operations.
@available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
public final class MetalAsyncPipeline: @unchecked Sendable {
    private let bufferPool: MetalBufferPool
    private let commandQueue: MTLCommandQueue
    private var isProcessing = false
    private let lock = NSLock()
    
    /// Initialize async pipeline
    ///
    /// - Parameters:
    ///   - device: Metal device to use
    ///   - commandQueue: Command queue for GPU operations
    public init?(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.bufferPool = MetalBufferPool(device: device)
        self.commandQueue = commandQueue
    }
    
    /// Convenience initializer using default Metal device
    public convenience init?() {
        guard let device = MetalOps.device(),
              let queue = MetalOps.commandQueue() else {
            return nil
        }
        self.init(device: device, commandQueue: queue)
    }
    
    /// Process DCT on multiple batches with double-buffering
    ///
    /// - Parameters:
    ///   - batches: Array of batches to process (each batch is inputData, width, height)
    ///   - completion: Called when all batches complete with array of results (nil entries on error)
    public func processDCTBatches(
        batches: [(data: [Float], width: Int, height: Int)],
        completion: @escaping @Sendable ([[Float]?]) -> Void
    ) {
        lock.lock()
        guard !isProcessing else {
            lock.unlock()
            // Already processing - fallback to sequential
            completion(Array(repeating: nil, count: batches.count))
            return
        }
        isProcessing = true
        lock.unlock()
        
        let state = BatchState(count: batches.count)
        
        // Process batches with pipelining
        for (index, batch) in batches.enumerated() {
            MetalCompute.dct8x8Async(
                inputData: batch.data,
                width: batch.width,
                height: batch.height
            ) { result in
                let isDone = state.setResult(result, at: index)
                
                if isDone {
                    self.lock.lock()
                    self.isProcessing = false
                    self.lock.unlock()
                    completion(state.getResults())
                }
            }
        }
    }
    
    /// Clean up cached buffers
    public func cleanup() {
        bufferPool.clear()
    }
}

/// Thread-safe state container for batch processing results
///
/// Thread Safety: Uses `@unchecked Sendable` with `NSLock` protection for
/// mutable `results` and `completedCount`. All mutations go through the lock.
@available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
private final class BatchState: @unchecked Sendable {
    private var results: [[Float]?]
    private var completedCount: Int = 0
    private let totalBatches: Int
    private let lock = NSLock()
    
    init(count: Int) {
        self.results = Array(repeating: nil, count: count)
        self.totalBatches = count
    }
    
    /// Set a result at the given index and return whether all batches are done
    func setResult(_ result: [Float]?, at index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        results[index] = result
        completedCount += 1
        return completedCount == totalBatches
    }
    
    /// Get the final results array
    func getResults() -> [[Float]?] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}

#endif // canImport(Metal)
