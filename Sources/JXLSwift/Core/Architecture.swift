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

#if canImport(Metal)
import Metal
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
    
    /// Metal device name (if available)
    public let metalDeviceName: String?
    
    /// Vulkan GPU support (Linux/Windows)
    public let hasVulkan: Bool
    
    /// Vulkan device name (if available)
    public let vulkanDeviceName: String?
    
    /// Number of CPU cores
    public let coreCount: Int
    
    /// Designated initialiser.
    ///
    /// `hasVulkan` and `vulkanDeviceName` default to `false`/`nil` so that
    /// existing call sites that pre-date Milestone 16 continue to compile
    /// without modification.
    public init(
        hasNEON: Bool,
        hasAVX2: Bool,
        hasAccelerate: Bool,
        hasMetal: Bool,
        metalDeviceName: String?,
        hasVulkan: Bool = false,
        vulkanDeviceName: String? = nil,
        coreCount: Int
    ) {
        self.hasNEON = hasNEON
        self.hasAVX2 = hasAVX2
        self.hasAccelerate = hasAccelerate
        self.hasMetal = hasMetal
        self.metalDeviceName = metalDeviceName
        self.hasVulkan = hasVulkan
        self.vulkanDeviceName = vulkanDeviceName
        self.coreCount = coreCount
    }
    
    /// Detect hardware capabilities
    public static func detect() -> HardwareCapabilities {
        let arch = CPUArchitecture.current
        
        // ARM NEON is standard on all ARM64
        let hasNEON = arch == .arm64
        
        // AVX2 runtime detection for x86-64
        let hasAVX2: Bool = {
            #if arch(x86_64)
            #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            // Darwin: query sysctl for confirmed AVX2 support
            var avx2: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let ret = sysctlbyname("hw.optional.avx2_0", &avx2, &size, nil, 0)
            return ret == 0 && avx2 != 0
            #elseif os(Linux)
            // Linux: scan /proc/cpuinfo flags line for "avx2" as a complete token
            if let cpuInfo = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) {
                for line in cpuInfo.components(separatedBy: "\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("flags") {
                        // Split by whitespace so "avx2" matches only as a full token
                        let tokens = lower.components(separatedBy: .whitespaces)
                        return tokens.contains("avx2")
                    }
                }
            }
            return false
            #else
            return false
            #endif
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
        
        // Metal availability and device name
        let (hasMetal, metalDeviceName): (Bool, String?) = {
            #if canImport(Metal)
            if let device = MTLCreateSystemDefaultDevice() {
                return (true, device.name)
            } else {
                return (false, nil)
            }
            #else
            return (false, nil)
            #endif
        }()
        
        // Get CPU core count
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        
        // Vulkan availability (Linux/Windows only)
        let (hasVulkan, vulkanDeviceName): (Bool, String?) = {
            #if canImport(Vulkan)
            if VulkanOps.isAvailable {
                return (true, VulkanOps.deviceName)
            } else {
                return (false, nil)
            }
            #else
            return (false, nil)
            #endif
        }()
        
        return HardwareCapabilities(
            hasNEON: hasNEON,
            hasAVX2: hasAVX2,
            hasAccelerate: hasAccelerate,
            hasMetal: hasMetal,
            metalDeviceName: metalDeviceName,
            hasVulkan: hasVulkan,
            vulkanDeviceName: vulkanDeviceName,
            coreCount: coreCount
        )
    }
    
    /// Shared instance for global access
    public static let shared = detect()
}
