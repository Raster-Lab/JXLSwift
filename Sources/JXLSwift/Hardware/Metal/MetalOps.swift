/// Metal GPU Operations
///
/// Provides Metal compute shader operations for hardware-accelerated encoding.
/// This module handles Metal device management, buffer allocation, and GPU dispatch.

#if canImport(Metal)
import Metal
import Foundation

#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
import UIKit
#endif

/// Metal GPU operations for hardware-accelerated image encoding
@available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
public enum MetalOps {
    
    // MARK: - Device Management
    
    /// Shared Metal device instance (lazy-initialized)
    private nonisolated(unsafe) static var _device: MTLDevice?
    private static let deviceLock = NSLock()
    
    /// Get the default Metal device
    ///
    /// - Returns: The default Metal device, or `nil` if Metal is unavailable
    public static func device() -> MTLDevice? {
        deviceLock.lock()
        defer { deviceLock.unlock() }
        
        if _device == nil {
            _device = MTLCreateSystemDefaultDevice()
        }
        return _device
    }
    
    /// Check if Metal is available on this device
    public static var isAvailable: Bool {
        return device() != nil
    }
    
    /// Get Metal device name for display
    public static var deviceName: String {
        return device()?.name ?? "Not Available"
    }
    
    // MARK: - Command Queue Management
    
    /// Shared command queue (lazy-initialized)
    private nonisolated(unsafe) static var _commandQueue: MTLCommandQueue?
    private static let queueLock = NSLock()
    
    /// Get the shared command queue
    ///
    /// - Returns: A command queue, or `nil` if Metal is unavailable
    public static func commandQueue() -> MTLCommandQueue? {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        if _commandQueue == nil {
            _commandQueue = device()?.makeCommandQueue()
        }
        return _commandQueue
    }
    
    // MARK: - Shader Library Management
    
    /// Shared compute pipeline library (lazy-initialized)
    private nonisolated(unsafe) static var _library: MTLLibrary?
    private static let libraryLock = NSLock()
    
    /// Load the Metal shader library
    ///
    /// - Returns: The shader library, or `nil` if unavailable
    public static func library() -> MTLLibrary? {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        
        if _library == nil {
            guard let device = device() else { return nil }
            _library = try? device.makeDefaultLibrary()
        }
        return _library
    }
    
    // MARK: - Pipeline State Cache
    
    /// Cache for compute pipeline states
    private nonisolated(unsafe) static var pipelineCache: [String: MTLComputePipelineState] = [:]
    private static let pipelineLock = NSLock()
    
    /// Get or create a compute pipeline state for the given function name
    ///
    /// - Parameter functionName: Name of the Metal shader function
    /// - Returns: Compute pipeline state, or `nil` if creation failed
    public static func computePipelineState(for functionName: String) -> MTLComputePipelineState? {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        
        // Return cached pipeline if available
        if let cached = pipelineCache[functionName] {
            return cached
        }
        
        // Create new pipeline
        guard let device = device(),
              let library = library(),
              let function = library.makeFunction(name: functionName) else {
            return nil
        }
        
        guard let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }
        
        pipelineCache[functionName] = pipeline
        return pipeline
    }
    
    // MARK: - Buffer Management
    
    /// Create a Metal buffer from data
    ///
    /// - Parameters:
    ///   - data: Source data
    ///   - options: Resource options (defaults to `.storageModeShared`)
    /// - Returns: Metal buffer, or `nil` if creation failed
    public static func makeBuffer(
        from data: UnsafeRawPointer,
        length: Int,
        options: MTLResourceOptions = .storageModeShared
    ) -> MTLBuffer? {
        guard let device = device() else { return nil }
        return device.makeBuffer(bytes: data, length: length, options: options)
    }
    
    /// Create an empty Metal buffer
    ///
    /// - Parameters:
    ///   - length: Buffer size in bytes
    ///   - options: Resource options (defaults to `.storageModeShared`)
    /// - Returns: Metal buffer, or `nil` if creation failed
    public static func makeBuffer(
        length: Int,
        options: MTLResourceOptions = .storageModeShared
    ) -> MTLBuffer? {
        guard let device = device() else { return nil }
        return device.makeBuffer(length: length, options: options)
    }
    
    // MARK: - Dispatch Utilities
    
    /// Calculate optimal threadgroup size for a given total count
    ///
    /// - Parameters:
    ///   - pipeline: The compute pipeline state
    ///   - totalCount: Total number of elements to process
    /// - Returns: Threadgroup size and grid size
    public static func calculateThreadgroups(
        pipeline: MTLComputePipelineState,
        totalCount: Int
    ) -> (threadsPerThreadgroup: MTLSize, threadgroupsPerGrid: MTLSize) {
        let maxThreadsPerThreadgroup = pipeline.maxTotalThreadsPerThreadgroup
        let threadsPerThreadgroup = min(maxThreadsPerThreadgroup, totalCount)
        let threadgroupsPerGrid = (totalCount + threadsPerThreadgroup - 1) / threadsPerThreadgroup
        
        return (
            threadsPerThreadgroup: MTLSize(width: threadsPerThreadgroup, height: 1, depth: 1),
            threadgroupsPerGrid: MTLSize(width: threadgroupsPerGrid, height: 1, depth: 1)
        )
    }
    
    /// Calculate threadgroup configuration for 2D image processing
    ///
    /// - Parameters:
    ///   - pipeline: The compute pipeline state
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: Threadgroup size and grid size
    public static func calculateThreadgroups2D(
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) -> (threadsPerThreadgroup: MTLSize, threadgroupsPerGrid: MTLSize) {
        let maxThreads = pipeline.maxTotalThreadsPerThreadgroup
        let threadWidth = min(16, width)  // 16x16 is common for 2D processing
        let threadHeight = min(maxThreads / threadWidth, 16, height)
        
        let gridWidth = (width + threadWidth - 1) / threadWidth
        let gridHeight = (height + threadHeight - 1) / threadHeight
        
        return (
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1),
            threadgroupsPerGrid: MTLSize(width: gridWidth, height: gridHeight, depth: 1)
        )
    }
    
    // MARK: - Power Management
    
    /// Check if device is on AC power (plugged in)
    ///
    /// Used for power-aware scheduling: prefer GPU on AC power, CPU on battery
    ///
    /// - Returns: `true` if on AC power, `false` if on battery or unknown
    public static var isOnACPower: Bool {
        #if os(macOS)
        // On macOS, check power source via IOKit
        // For now, assume AC power (conservative default for GPU usage)
        return true
        #elseif os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // On iOS/tvOS, check battery state
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let state = device.batteryState
        return state == .charging || state == .full
        #else
        return true
        #endif
    }

    // MARK: - Batch Size Tuning

    /// Compute the optimal dispatch batch size for a 1-D compute kernel.
    ///
    /// The batch size is chosen so that each Metal threadgroup is fully occupied:
    /// - Start with `pipeline.maxTotalThreadsPerThreadgroup`.
    /// - Clamp to a power-of-two in [32, 1024] for memory-alignment efficiency.
    /// - Further clamp to `totalCount` so the last threadgroup is not oversized.
    ///
    /// - Parameters:
    ///   - pipeline: The compiled compute pipeline.
    ///   - totalCount: Total number of work items to dispatch.
    /// - Returns: Recommended threadgroup width.
    public static func optimalBatchSize(
        pipeline: MTLComputePipelineState,
        totalCount: Int
    ) -> Int {
        let maxThreads = pipeline.maxTotalThreadsPerThreadgroup
        // Round down to nearest power-of-two in [32, 1024]
        var size = maxThreads
        // Align to power-of-two
        var pot = 32
        while pot * 2 <= size && pot < 1024 { pot <<= 1 }
        size = pot
        return min(size, max(1, totalCount))
    }

    /// Compute the optimal 2-D threadgroup tile dimensions for image-processing kernels.
    ///
    /// Aims for a 16×16 tile on large images (GPU-cache-line friendly) and
    /// shrinks to fit smaller images.  The product `tileW × tileH` never
    /// exceeds `pipeline.maxTotalThreadsPerThreadgroup`.
    ///
    /// - Parameters:
    ///   - pipeline: The compiled compute pipeline.
    ///   - imageWidth:  Width of the image being processed.
    ///   - imageHeight: Height of the image being processed.
    /// - Returns: `(tileWidth, tileHeight)` for the Metal dispatch call.
    public static func optimalTileSize(
        pipeline: MTLComputePipelineState,
        imageWidth: Int,
        imageHeight: Int
    ) -> (width: Int, height: Int) {
        let maxThreads = pipeline.maxTotalThreadsPerThreadgroup
        // Prefer 16×16; fall back to 8×8 or smaller on constrained pipelines.
        var tileW = 16
        var tileH = 16
        while tileW * tileH > maxThreads {
            if tileW > tileH { tileW >>= 1 } else { tileH >>= 1 }
        }
        tileW = min(tileW, imageWidth)
        tileH = min(tileH, imageHeight)
        return (width: max(1, tileW), height: max(1, tileH))
    }

    // MARK: - Occupancy Analysis

    /// Estimate the achieved GPU occupancy for the current pipeline and threadgroup size.
    ///
    /// Occupancy is defined as `executionWidth / maxTotalThreadsPerThreadgroup`,
    /// where `executionWidth` is the SIMD group size of the pipeline.
    /// A value of 1.0 indicates full occupancy.
    ///
    /// - Parameters:
    ///   - pipeline:          The compiled compute pipeline.
    ///   - threadgroupWidth:  The threadgroup width that will be dispatched.
    /// - Returns: Estimated occupancy in [0, 1].
    public static func estimatedOccupancy(
        pipeline: MTLComputePipelineState,
        threadgroupWidth: Int
    ) -> Double {
        let simdWidth = pipeline.threadExecutionWidth
        guard simdWidth > 0 else { return 0 }
        let used = min(threadgroupWidth, pipeline.maxTotalThreadsPerThreadgroup)
        // Occupancy = (threads used rounded up to SIMD width) / maxThreads
        let roundedUp = ((used + simdWidth - 1) / simdWidth) * simdWidth
        return min(1.0, Double(roundedUp) / Double(pipeline.maxTotalThreadsPerThreadgroup))
    }

    // MARK: - Memory-Coalescing Buffer Helpers

    /// Minimum buffer size (in bytes) for which page-alignment is applied.
    ///
    /// Buffers smaller than this threshold use 64-byte (cache-line) alignment
    /// to avoid wasting full pages on small allocations.
    private static let coalescingThreshold = 16 * 1024  // 16 KB

    /// Create a Metal buffer with optimised storage alignment for memory coalescing.
    ///
    /// - For buffers ≥ 16 KB: uses VM-page alignment so the Metal driver can map
    ///   the buffer without a copy on unified-memory devices (Apple Silicon).
    /// - For buffers < 16 KB: uses 64-byte cache-line alignment to avoid wasting
    ///   a full page on small allocations.
    ///
    /// - Parameters:
    ///   - data:    Source bytes (copied into the buffer).
    ///   - length:  Byte length of the buffer.
    /// - Returns: An aligned `MTLBuffer`, or `nil` on failure.
    public static func makeCoalescedBuffer(
        from data: UnsafeRawPointer,
        length: Int
    ) -> MTLBuffer? {
        guard let device = device() else { return nil }
        let alignedLength = alignedBufferLength(length)
        return device.makeBuffer(bytes: data, length: alignedLength,
                                 options: .storageModeShared)
    }

    /// Create an empty Metal buffer with optimised storage alignment.
    ///
    /// - Parameter length: Requested byte length.
    /// - Returns: An aligned `MTLBuffer`, or `nil` on failure.
    public static func makeCoalescedBuffer(length: Int) -> MTLBuffer? {
        guard let device = device() else { return nil }
        let alignedLength = alignedBufferLength(length)
        return device.makeBuffer(length: alignedLength,
                                 options: .storageModeShared)
    }

    /// Compute the aligned byte length for a buffer.
    private static func alignedBufferLength(_ length: Int) -> Int {
        let safeLength = max(length, 1)
        if safeLength >= coalescingThreshold {
            let pageSize = Int(vm_page_size)
            return (safeLength + pageSize - 1) & ~(pageSize - 1)
        } else {
            // 64-byte cache-line alignment for small buffers.
            let cacheLineSize = 64
            return max((safeLength + cacheLineSize - 1) & ~(cacheLineSize - 1), cacheLineSize)
        }
    }
    
    // MARK: - Cleanup
    
    /// Clear cached pipeline states and release resources
    ///
    /// Call this when shutting down or when needing to free GPU memory
    public static func cleanup() {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        pipelineCache.removeAll()
        
        libraryLock.lock()
        defer { libraryLock.unlock() }
        _library = nil
        
        queueLock.lock()
        defer { queueLock.unlock() }
        _commandQueue = nil
        
        deviceLock.lock()
        defer { deviceLock.unlock() }
        _device = nil
    }
}

#endif // canImport(Metal)
