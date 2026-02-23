/// Cross-Platform GPU Compute Abstraction
///
/// `GPUCompute` provides a single API for GPU-accelerated encoding operations
/// that selects the best available GPU backend at compile time:
///
/// | Platform       | Backend  |
/// |----------------|----------|
/// | Apple (all)    | Metal    |
/// | Linux / Windows| Vulkan   |
/// | No GPU         | CPU fallback via caller |
///
/// Using `GPUCompute` instead of calling `MetalCompute` or `VulkanCompute`
/// directly means that callers do not need any `#if canImport(Metal)` or
/// `#if canImport(Vulkan)` guards — the abstraction handles that.

import Foundation

#if canImport(Metal)
import Metal
#endif

// MARK: - GPUCompute

/// Cross-platform GPU compute interface.
///
/// Methods return `nil` when no GPU backend is available, allowing callers to
/// fall back to their CPU implementation.
public enum GPUCompute {

    // MARK: - Availability

    /// Whether any GPU backend is available on the current platform.
    public static var isAvailable: Bool {
        #if canImport(Metal)
        return MetalOps.isAvailable
        #elseif canImport(Vulkan)
        return VulkanOps.isAvailable
        #else
        return false
        #endif
    }

    /// Human-readable name of the active GPU backend and device.
    public static var backendDescription: String {
        #if canImport(Metal)
        if MetalOps.isAvailable {
            return "Metal — \(MetalOps.deviceName)"
        }
        #endif
        #if canImport(Vulkan)
        if VulkanOps.isAvailable {
            return "Vulkan — \(VulkanOps.deviceName)"
        }
        #endif
        return "GPU not available"
    }

    /// The `DispatchBackend` case corresponding to the active GPU backend.
    ///
    /// Returns `nil` when no GPU is available.
    public static var dispatchBackend: DispatchBackend? {
        #if canImport(Metal)
        if MetalOps.isAvailable { return .metal }
        #endif
        #if canImport(Vulkan)
        if VulkanOps.isAvailable { return .vulkan }
        #endif
        return nil
    }

    // MARK: - Colour Conversion

    /// Convert RGB to YCbCr colour space using the available GPU backend.
    ///
    /// - Parameters:
    ///   - rgbData: Input RGB data (3 floats per pixel, interleaved R G B …).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    /// - Returns: YCbCr data, or `nil` if no GPU is available or an error occurred.
    @available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
    public static func rgbToYCbCr(
        rgbData: [Float],
        width: Int,
        height: Int
    ) -> [Float]? {
        #if canImport(Metal)
        if MetalOps.isAvailable {
            return MetalCompute.rgbToYCbCr(rgbData: rgbData, width: width, height: height)
        }
        #endif
        #if canImport(Vulkan)
        if VulkanOps.isAvailable {
            return VulkanCompute.rgbToYCbCr(rgbData: rgbData, width: width, height: height)
        }
        #endif
        return nil
    }

    // MARK: - 2D DCT Transform

    /// Perform a forward 2D DCT on 8×8 blocks using the available GPU backend.
    ///
    /// - Parameters:
    ///   - inputData: Spatial-domain data (width × height floats).
    ///   - width: Image width — must be a multiple of 8.
    ///   - height: Image height — must be a multiple of 8.
    /// - Returns: Frequency-domain DCT coefficients, or `nil` on error.
    @available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
    public static func dct8x8(
        inputData: [Float],
        width: Int,
        height: Int
    ) -> [Float]? {
        #if canImport(Metal)
        if MetalOps.isAvailable {
            return MetalCompute.dct8x8(inputData: inputData, width: width, height: height)
        }
        #endif
        #if canImport(Vulkan)
        if VulkanOps.isAvailable {
            return VulkanCompute.dct8x8(inputData: inputData, width: width, height: height)
        }
        #endif
        return nil
    }

    /// Perform an inverse 2D DCT on 8×8 blocks using the available GPU backend.
    ///
    /// - Parameters:
    ///   - inputData: Frequency-domain DCT coefficients.
    ///   - width: Image width — must be a multiple of 8.
    ///   - height: Image height — must be a multiple of 8.
    /// - Returns: Reconstructed spatial-domain data, or `nil` on error.
    @available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
    public static func idct8x8(
        inputData: [Float],
        width: Int,
        height: Int
    ) -> [Float]? {
        #if canImport(Metal)
        if MetalOps.isAvailable {
            return MetalCompute.idct8x8(inputData: inputData, width: width, height: height)
        }
        #endif
        #if canImport(Vulkan)
        if VulkanOps.isAvailable {
            return VulkanCompute.idct8x8(inputData: inputData, width: width, height: height)
        }
        #endif
        return nil
    }

    // MARK: - Quantisation

    /// Quantise DCT coefficients using the available GPU backend.
    ///
    /// - Parameters:
    ///   - coefficients: Floating-point DCT coefficients.
    ///   - quantTable: 64-element quantisation table.
    /// - Returns: Quantised `Int16` coefficients, or `nil` on error.
    @available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
    public static func quantize(
        coefficients: [Float],
        quantTable: [Float]
    ) -> [Int16]? {
        #if canImport(Metal)
        if MetalOps.isAvailable {
            return MetalCompute.quantize(coefficients: coefficients, quantTable: quantTable)
        }
        #endif
        #if canImport(Vulkan)
        if VulkanOps.isAvailable {
            return VulkanCompute.quantize(coefficients: coefficients, quantTable: quantTable)
        }
        #endif
        return nil
    }

    /// Dequantise DCT coefficients using the available GPU backend.
    ///
    /// - Parameters:
    ///   - quantized: Quantised `Int16` coefficients.
    ///   - quantTable: 64-element quantisation table.
    /// - Returns: Dequantised `Float` coefficients, or `nil` on error.
    @available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
    public static func dequantize(
        quantized: [Int16],
        quantTable: [Float]
    ) -> [Float]? {
        #if canImport(Metal)
        if MetalOps.isAvailable {
            return MetalCompute.dequantize(quantized: quantized, quantTable: quantTable)
        }
        #endif
        #if canImport(Vulkan)
        if VulkanOps.isAvailable {
            return VulkanCompute.dequantize(quantized: quantized, quantTable: quantTable)
        }
        #endif
        return nil
    }

    // MARK: - Async Operations

    /// Asynchronously perform a 2D DCT on 8×8 blocks using the available GPU backend.
    ///
    /// The completion handler is called on an unspecified background thread.
    ///
    /// - Parameters:
    ///   - inputData: Spatial-domain data (width × height floats).
    ///   - width: Image width — must be a multiple of 8.
    ///   - height: Image height — must be a multiple of 8.
    ///   - completion: Called with the result or `nil` on error.
    @available(macOS 13.0, iOS 16.0, tvOS 16.0, *)
    public static func dct8x8Async(
        inputData: [Float],
        width: Int,
        height: Int,
        completion: @escaping @Sendable ([Float]?) -> Void
    ) {
        #if canImport(Metal)
        if MetalOps.isAvailable {
            MetalCompute.dct8x8Async(
                inputData: inputData, width: width, height: height,
                completion: completion
            )
            return
        }
        #endif
        #if canImport(Vulkan)
        if VulkanOps.isAvailable {
            VulkanCompute.dct8x8Async(
                inputData: inputData, width: width, height: height,
                completion: completion
            )
            return
        }
        #endif
        // No GPU backend available
        completion(nil)
    }

    // MARK: - Resource Management

    /// Release all cached GPU resources for the active backend.
    ///
    /// Call during application shutdown or when freeing GPU memory.
    public static func cleanup() {
        #if canImport(Metal)
        MetalOps.cleanup()
        #endif
        #if canImport(Vulkan)
        VulkanOps.cleanup()
        #endif
    }
}
