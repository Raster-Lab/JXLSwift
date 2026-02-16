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
}

#endif // canImport(Metal)
