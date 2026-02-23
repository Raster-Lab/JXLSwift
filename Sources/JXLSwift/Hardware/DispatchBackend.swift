/// Backend Dispatch Layer
///
/// Provides runtime selection of the optimal implementation backend
/// without scattering `#if arch()` guards throughout the codebase.
///
/// All architecture-specific code is routed through this dispatcher.
/// The `#if arch()` guards live only here, keeping the rest of the
/// codebase clean.

import Foundation

/// Available computation backends for encoding/decoding operations.
///
/// Use `DispatchBackend.current` to auto-detect the best available backend
/// for the current platform. Individual backends can also be selected
/// explicitly for testing or benchmarking.
///
/// # Example
/// ```swift
/// let backend = DispatchBackend.current
/// switch backend {
/// case .neon:
///     // ARM64 NEON SIMD path
/// case .accelerate:
///     // Apple Accelerate framework path
/// case .scalar:
///     // Universal fallback
/// default:
///     break
/// }
/// ```
public enum DispatchBackend: String, Sendable, CaseIterable {
    /// Scalar reference implementation — always available on all platforms.
    case scalar

    /// ARM64 NEON SIMD — available on Apple Silicon and other ARM64 chips.
    case neon

    /// x86_64 SSE2 — available on Intel/AMD processors.
    case sse2

    /// x86_64 AVX2 — available on modern Intel/AMD processors.
    case avx2

    /// Apple Accelerate framework (vDSP, vImage).
    case accelerate

    /// Metal GPU compute shaders.
    case metal

    /// Vulkan GPU compute shaders (Linux/Windows).
    case vulkan

    // MARK: - Auto-Detection

    /// Auto-detect the best available backend for the current platform.
    ///
    /// Priority order:
    /// 1. Accelerate (if available — fastest for most operations on Apple platforms)
    /// 2. NEON (ARM64)
    /// 3. AVX2 (x86_64)
    /// 4. SSE2 (x86_64)
    /// 5. Scalar (always available)
    ///
    /// Metal is not returned by auto-detection because GPU dispatch requires
    /// explicit opt-in due to CPU↔GPU transfer overhead.
    ///
    /// - Returns: The best available `DispatchBackend` for CPU operations.
    public static var current: DispatchBackend {
        #if canImport(Accelerate)
        return .accelerate
        #elseif arch(arm64)
        return .neon
        #elseif arch(x86_64)
        return .avx2
        #else
        return .scalar
        #endif
    }

    // MARK: - Capability Queries

    /// Returns all backends available on the current platform.
    ///
    /// - Returns: An array of available backends, always including `.scalar`.
    public static var available: [DispatchBackend] {
        var backends: [DispatchBackend] = [.scalar]

        #if arch(arm64)
        backends.append(.neon)
        #endif

        #if arch(x86_64)
        backends.append(.sse2)
        backends.append(.avx2)
        #endif

        #if canImport(Accelerate)
        backends.append(.accelerate)
        #endif

        #if canImport(Metal)
        backends.append(.metal)
        #endif

        #if canImport(Vulkan)
        backends.append(.vulkan)
        #endif

        return backends
    }

    /// Whether this backend is available on the current platform.
    public var isAvailable: Bool {
        return DispatchBackend.available.contains(self)
    }

    /// Whether this backend requires a GPU.
    public var requiresGPU: Bool {
        return self == .metal || self == .vulkan
    }

    /// Human-readable description of the backend.
    public var displayName: String {
        switch self {
        case .scalar:     return "Scalar (reference)"
        case .neon:       return "ARM NEON SIMD"
        case .sse2:       return "x86_64 SSE2"
        case .avx2:       return "x86_64 AVX2"
        case .accelerate: return "Apple Accelerate"
        case .metal:      return "Metal GPU"
        case .vulkan:     return "Vulkan GPU"
        }
    }
}
