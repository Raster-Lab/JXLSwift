/// Vulkan Compute Operations Interface
///
/// High-level Swift interface for Vulkan GPU compute operations on Linux and
/// Windows. Provides wrapper functions for DCT, colour conversion, and
/// quantisation that mirror the `MetalCompute` API so that the
/// `GPUCompute` abstraction can select at compile time.
///
/// All code in this file is guarded by `#if canImport(Vulkan)`.

#if canImport(Vulkan)
import Vulkan
import Foundation

/// Vulkan compute operations — mirrors the `MetalCompute` API shape.
public enum VulkanCompute {

    // MARK: - Colour Conversion

    /// Convert RGB to YCbCr colour space using the Vulkan GPU.
    ///
    /// - Parameters:
    ///   - rgbData: Input RGB data (3 floats per pixel, interleaved R G B …).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    /// - Returns: YCbCr planar data (Y plane then Cb plane then Cr plane),
    ///   or `nil` if Vulkan is unavailable or an error occurred.
    public static func rgbToYCbCr(
        rgbData: [Float],
        width: Int,
        height: Int
    ) -> [Float]? {
        guard VulkanOps.isAvailable else { return nil }
        let pixelCount = width * height
        guard rgbData.count == pixelCount * 3 else { return nil }

        // Allocate GPU buffers
        let inputByteLen = rgbData.count * MemoryLayout<Float>.stride
        let outputByteLen = pixelCount * 3 * MemoryLayout<Float>.stride
        guard let inputBuf = VulkanOps.makeBuffer(length: inputByteLen),
              let outputBuf = VulkanOps.makeBuffer(length: outputByteLen) else { return nil }
        defer {
            inputBuf.destroy()
            outputBuf.destroy()
        }

        VulkanOps.uploadData(rgbData, to: inputBuf)

        // SPIR-V for the rgb_to_ycbcr shader
        guard let pipeline = VulkanOps.computePipeline(
            named: "rgb_to_ycbcr",
            spirv: VulkanShaders.rgbToYCbCrSPIRV
        ) else { return nil }

        let groupsX = (pixelCount + 63) / 64
        guard VulkanOps.dispatch(
            pipeline: pipeline,
            descriptors: [0: inputBuf, 1: outputBuf],
            groupCountX: UInt32(groupsX),
            groupCountY: 1
        ) else { return nil }

        return VulkanOps.downloadData(outputBuf, count: pixelCount * 3)
    }

    // MARK: - 2D DCT Transform

    /// Perform a 2D DCT on 8×8 blocks using the Vulkan GPU.
    ///
    /// - Parameters:
    ///   - inputData: Spatial-domain data (width × height floats).
    ///   - width: Image width — must be a multiple of 8.
    ///   - height: Image height — must be a multiple of 8.
    /// - Returns: Frequency-domain DCT coefficients, or `nil` on error.
    public static func dct8x8(
        inputData: [Float],
        width: Int,
        height: Int
    ) -> [Float]? {
        guard VulkanOps.isAvailable else { return nil }
        guard width % 8 == 0 && height % 8 == 0 else { return nil }
        guard inputData.count == width * height else { return nil }

        let byteLen = inputData.count * MemoryLayout<Float>.stride
        guard let inputBuf = VulkanOps.makeBuffer(length: byteLen),
              let outputBuf = VulkanOps.makeBuffer(length: byteLen) else { return nil }
        defer {
            inputBuf.destroy()
            outputBuf.destroy()
        }

        VulkanOps.uploadData(inputData, to: inputBuf)

        guard let pipeline = VulkanOps.computePipeline(
            named: "dct_8x8",
            spirv: VulkanShaders.dct8x8SPIRV
        ) else { return nil }

        // One workgroup per 8×8 block
        let groupsX = width / 8
        let groupsY = height / 8
        guard VulkanOps.dispatch(
            pipeline: pipeline,
            descriptors: [0: inputBuf, 1: outputBuf],
            groupCountX: UInt32(groupsX),
            groupCountY: UInt32(groupsY)
        ) else { return nil }

        return VulkanOps.downloadData(outputBuf, count: width * height)
    }

    /// Perform an inverse 2D DCT on 8×8 blocks using the Vulkan GPU.
    ///
    /// - Parameters:
    ///   - inputData: Frequency-domain DCT coefficients.
    ///   - width: Image width — must be a multiple of 8.
    ///   - height: Image height — must be a multiple of 8.
    /// - Returns: Reconstructed spatial-domain data, or `nil` on error.
    public static func idct8x8(
        inputData: [Float],
        width: Int,
        height: Int
    ) -> [Float]? {
        guard VulkanOps.isAvailable else { return nil }
        guard width % 8 == 0 && height % 8 == 0 else { return nil }
        guard inputData.count == width * height else { return nil }

        let byteLen = inputData.count * MemoryLayout<Float>.stride
        guard let inputBuf = VulkanOps.makeBuffer(length: byteLen),
              let outputBuf = VulkanOps.makeBuffer(length: byteLen) else { return nil }
        defer {
            inputBuf.destroy()
            outputBuf.destroy()
        }

        VulkanOps.uploadData(inputData, to: inputBuf)

        guard let pipeline = VulkanOps.computePipeline(
            named: "idct_8x8",
            spirv: VulkanShaders.idct8x8SPIRV
        ) else { return nil }

        let groupsX = width / 8
        let groupsY = height / 8
        guard VulkanOps.dispatch(
            pipeline: pipeline,
            descriptors: [0: inputBuf, 1: outputBuf],
            groupCountX: UInt32(groupsX),
            groupCountY: UInt32(groupsY)
        ) else { return nil }

        return VulkanOps.downloadData(outputBuf, count: width * height)
    }

    // MARK: - Quantisation

    /// Quantise DCT coefficients using the Vulkan GPU.
    ///
    /// - Parameters:
    ///   - coefficients: Floating-point DCT coefficients.
    ///   - quantTable: 64-element quantisation table.
    /// - Returns: Quantised coefficients as `Int16`, or `nil` on error.
    public static func quantize(
        coefficients: [Float],
        quantTable: [Float]
    ) -> [Int16]? {
        guard VulkanOps.isAvailable else { return nil }
        guard quantTable.count == 64 else { return nil }

        let inputByteLen = coefficients.count * MemoryLayout<Float>.stride
        let outputByteLen = coefficients.count * MemoryLayout<Int16>.stride
        let quantByteLen = quantTable.count * MemoryLayout<Float>.stride

        guard let inputBuf  = VulkanOps.makeBuffer(length: inputByteLen),
              let outputBuf = VulkanOps.makeBuffer(length: outputByteLen),
              let quantBuf  = VulkanOps.makeBuffer(length: quantByteLen) else { return nil }
        defer {
            inputBuf.destroy()
            outputBuf.destroy()
            quantBuf.destroy()
        }

        VulkanOps.uploadData(coefficients, to: inputBuf)
        VulkanOps.uploadData(quantTable, to: quantBuf)

        guard let pipeline = VulkanOps.computePipeline(
            named: "quantize",
            spirv: VulkanShaders.quantizeSPIRV
        ) else { return nil }

        let groups = (coefficients.count + 63) / 64
        guard VulkanOps.dispatch(
            pipeline: pipeline,
            descriptors: [0: inputBuf, 1: outputBuf, 2: quantBuf],
            groupCountX: UInt32(groups),
            groupCountY: 1
        ) else { return nil }

        return VulkanOps.downloadData(outputBuf, count: coefficients.count)
    }

    /// Dequantise DCT coefficients using the Vulkan GPU.
    ///
    /// - Parameters:
    ///   - quantized: Quantised coefficients (`Int16`).
    ///   - quantTable: 64-element quantisation table.
    /// - Returns: Dequantised coefficients as `Float`, or `nil` on error.
    public static func dequantize(
        quantized: [Int16],
        quantTable: [Float]
    ) -> [Float]? {
        guard VulkanOps.isAvailable else { return nil }
        guard quantTable.count == 64 else { return nil }

        let inputByteLen = quantized.count * MemoryLayout<Int16>.stride
        let outputByteLen = quantized.count * MemoryLayout<Float>.stride
        let quantByteLen = quantTable.count * MemoryLayout<Float>.stride

        guard let inputBuf  = VulkanOps.makeBuffer(length: inputByteLen),
              let outputBuf = VulkanOps.makeBuffer(length: outputByteLen),
              let quantBuf  = VulkanOps.makeBuffer(length: quantByteLen) else { return nil }
        defer {
            inputBuf.destroy()
            outputBuf.destroy()
            quantBuf.destroy()
        }

        VulkanOps.uploadData(quantized, to: inputBuf)
        VulkanOps.uploadData(quantTable, to: quantBuf)

        guard let pipeline = VulkanOps.computePipeline(
            named: "dequantize",
            spirv: VulkanShaders.dequantizeSPIRV
        ) else { return nil }

        let groups = (quantized.count + 63) / 64
        guard VulkanOps.dispatch(
            pipeline: pipeline,
            descriptors: [0: inputBuf, 1: outputBuf, 2: quantBuf],
            groupCountX: UInt32(groups),
            groupCountY: 1
        ) else { return nil }

        return VulkanOps.downloadData(outputBuf, count: quantized.count)
    }

    // MARK: - Async Operations

    /// Asynchronously perform a 2D DCT on 8×8 blocks using the Vulkan GPU.
    ///
    /// The completion handler is called from an unspecified background thread.
    ///
    /// - Parameters:
    ///   - inputData: Spatial-domain data (width × height floats).
    ///   - width: Image width — must be a multiple of 8.
    ///   - height: Image height — must be a multiple of 8.
    ///   - completion: Called with the result or `nil` on error.
    public static func dct8x8Async(
        inputData: [Float],
        width: Int,
        height: Int,
        completion: @escaping @Sendable ([Float]?) -> Void
    ) {
        guard VulkanOps.isAvailable else { completion(nil); return }
        guard width % 8 == 0 && height % 8 == 0 else { completion(nil); return }
        guard inputData.count == width * height else { completion(nil); return }

        DispatchQueue.global(qos: .userInitiated).async {
            completion(dct8x8(inputData: inputData, width: width, height: height))
        }
    }
}

// MARK: - SPIR-V Shader Data

/// Pre-compiled SPIR-V bytecode for each Vulkan compute shader.
///
/// In a production build these arrays are generated by compiling the GLSL
/// shaders in `Shaders.comp` with `glslc` (part of the Vulkan SDK):
/// ```
/// glslc --target-env=vulkan1.2 -fshader-stage=comp \
///       -DKERNEL=rgb_to_ycbcr  Shaders.comp -o rgb_to_ycbcr.spv
/// ```
/// and then embedding the resulting `.spv` bytes here.
///
/// The placeholder arrays below allow the Swift package to compile and link
/// without the Vulkan SDK present.
///
/// > Important: These are **stub placeholders**. `vkCreateShaderModule` will
/// > reject them at runtime and every `VulkanCompute` operation will return
/// > `nil`. To activate Vulkan acceleration, compile each GLSL shader in
/// > `Shaders.comp` to SPIR-V with `glslc` and replace the placeholder arrays
/// > with the real bytecode before linking.
internal enum VulkanShaders {
    // MARK: SPIR-V magic header
    // SPIR-V magic: 0x07230203, version 1.0, generator 0, bound 1, schema 0
    private static let spirvHeader: [UInt32] = [0x07230203, 0x00010000, 0, 1, 0]

    /// SPIR-V bytecode for the `rgb_to_ycbcr` compute shader.
    static let rgbToYCbCrSPIRV: [UInt32] = spirvHeader

    /// SPIR-V bytecode for the `dct_8x8` compute shader.
    static let dct8x8SPIRV: [UInt32] = spirvHeader

    /// SPIR-V bytecode for the `idct_8x8` compute shader.
    static let idct8x8SPIRV: [UInt32] = spirvHeader

    /// SPIR-V bytecode for the `quantize` compute shader.
    static let quantizeSPIRV: [UInt32] = spirvHeader

    /// SPIR-V bytecode for the `dequantize` compute shader.
    static let dequantizeSPIRV: [UInt32] = spirvHeader
}

// MARK: - Vulkan Buffer Pool

/// Thread-safe buffer pool for Vulkan buffer reuse in double-buffering scenarios.
///
/// Thread Safety: Uses `@unchecked Sendable` with `NSLock` protection for all
/// mutable state. All mutations go through the lock.
public final class VulkanBufferPool: @unchecked Sendable {
    private var availableBuffers: [Int: [VulkanBuffer]] = [:]
    private let lock = NSLock()
    private let maxBuffersPerSize = 4

    /// Initialise an empty buffer pool.
    public init() {}

    /// Acquire a buffer from the pool or allocate a new one.
    ///
    /// - Parameter length: Minimum required buffer length in bytes.
    /// - Returns: A `VulkanBuffer` of at least `length` bytes, or `nil` on failure.
    public func acquireBuffer(length: Int) -> VulkanBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if let buffer = availableBuffers[length]?.popLast() {
            return buffer
        }
        return VulkanOps.makeBuffer(length: length)
    }

    /// Return a buffer to the pool for reuse.
    ///
    /// - Parameter buffer: The buffer to cache.
    public func releaseBuffer(_ buffer: VulkanBuffer) {
        lock.lock()
        defer { lock.unlock() }

        let length = buffer.length
        if availableBuffers[length] == nil {
            availableBuffers[length] = []
        }
        if availableBuffers[length]!.count < maxBuffersPerSize {
            availableBuffers[length]!.append(buffer)
        } else {
            buffer.destroy()
        }
    }

    /// Release all cached buffers.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        for buffers in availableBuffers.values {
            for buf in buffers { buf.destroy() }
        }
        availableBuffers.removeAll()
    }

    /// Total number of cached buffers across all size classes.
    public var totalBuffers: Int {
        lock.lock()
        defer { lock.unlock() }
        return availableBuffers.values.reduce(0) { $0 + $1.count }
    }
}

// MARK: - Async Pipeline Manager

/// Manager for async Vulkan compute operations with simple double-buffering.
///
/// Thread Safety: Uses `@unchecked Sendable` with `NSLock` for the
/// `isProcessing` flag.
public final class VulkanAsyncPipeline: @unchecked Sendable {
    private let bufferPool = VulkanBufferPool()
    private var isProcessing = false
    private let lock = NSLock()

    /// Initialise a Vulkan async pipeline.
    ///
    /// Returns `nil` when Vulkan is unavailable on this platform.
    public init?() {
        guard VulkanOps.isAvailable else { return nil }
    }

    /// Process DCT on multiple batches using async dispatch.
    ///
    /// - Parameters:
    ///   - batches: Array of `(data, width, height)` tuples.
    ///   - completion: Called when all batches complete.
    public func processDCTBatches(
        batches: [(data: [Float], width: Int, height: Int)],
        completion: @escaping @Sendable ([[Float]?]) -> Void
    ) {
        lock.lock()
        guard !isProcessing else {
            lock.unlock()
            completion(Array(repeating: nil, count: batches.count))
            return
        }
        isProcessing = true
        lock.unlock()

        guard !batches.isEmpty else {
            lock.lock()
            isProcessing = false
            lock.unlock()
            completion([])
            return
        }

        let state = VulkanBatchState(count: batches.count)
        let group = DispatchGroup()

        for (index, batch) in batches.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = VulkanCompute.dct8x8(
                    inputData: batch.data,
                    width: batch.width,
                    height: batch.height
                )
                state.setResult(result, at: index)
                group.leave()
            }
        }

        group.notify(queue: .global()) {
            self.lock.lock()
            self.isProcessing = false
            self.lock.unlock()
            completion(state.getResults())
        }
    }

    /// Release cached buffers.
    public func cleanup() {
        bufferPool.clear()
    }
}

/// Thread-safe batch result collector for `VulkanAsyncPipeline`.
///
/// Stores `[[Float]?]` results from concurrent DCT dispatch operations.
/// All mutable state is protected by `NSLock`; mark `@unchecked Sendable`
/// because the lock guarantee cannot be expressed in the Swift type system.
private final class VulkanBatchState: @unchecked Sendable {
    private var results: [[Float]?]
    private let lock = NSLock()

    init(count: Int) {
        results = Array(repeating: nil, count: count)
    }

    func setResult(_ result: [Float]?, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        results[index] = result
    }

    func getResults() -> [[Float]?] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}

#endif // canImport(Vulkan)
