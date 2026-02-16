/// Architecture detection and CPU capability detection
///
/// This module provides runtime detection of CPU architecture and available
/// hardware features to enable optimal code paths.

import Foundation

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// CPU Architecture type
public enum CPUArchitecture: String {
    case arm64
    case x86_64
    case unknown
    
    /// Detect current CPU architecture
    public static var current: CPUArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .unknown
        #endif
    }
    
    /// Check if running on Apple Silicon
    public var isAppleSilicon: Bool {
        #if arch(arm64) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        return true
        #else
        return false
        #endif
    }
}

/// Hardware capabilities for optimization
public struct HardwareCapabilities: Sendable {
    /// ARM NEON SIMD support
    public let hasNEON: Bool
    
    /// AVX2 support (x86-64)
    public let hasAVX2: Bool
    
    /// Apple Accelerate framework availability
    public let hasAccelerate: Bool
    
    /// Metal GPU support
    public let hasMetal: Bool
    
    /// Number of CPU cores
    public let coreCount: Int
    
    /// Detect hardware capabilities
    public static func detect() -> HardwareCapabilities {
        let arch = CPUArchitecture.current
        
        // ARM NEON is standard on all ARM64
        let hasNEON = arch == .arm64
        
        // AVX2 detection for x86-64
        let hasAVX2: Bool = {
            #if arch(x86_64)
            // On macOS, we can assume AVX2 support on modern chips
            // For Linux, would need CPU flags detection
            return true
            #else
            return false
            #endif
        }()
        
        // Accelerate framework availability
        let hasAccelerate: Bool = {
            #if canImport(Accelerate)
            return true
            #else
            return false
            #endif
        }()
        
        // Metal availability
        let hasMetal: Bool = {
            #if canImport(Metal)
            return true
            #else
            return false
            #endif
        }()
        
        // Get CPU core count
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        
        return HardwareCapabilities(
            hasNEON: hasNEON,
            hasAVX2: hasAVX2,
            hasAccelerate: hasAccelerate,
            hasMetal: hasMetal,
            coreCount: coreCount
        )
    }
    
    /// Shared instance for global access
    public static let shared = detect()
}
