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
