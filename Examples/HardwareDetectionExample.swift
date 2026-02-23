// Example: Hardware Detection
//
// Demonstrates detecting hardware capabilities at runtime so that you can
// choose the optimal encoding path for the current machine.

import Foundation
import JXLSwift

func hardwareDetectionExample() {
    print("=== Hardware Detection Example ===\n")

    // 1. Detect the current CPU architecture
    let arch = CPUArchitecture.current
    print("CPU architecture : \(arch.rawValue)")
    print("Apple Silicon    : \(arch.isAppleSilicon)")

    // 2. Detect all hardware capabilities
    let caps = HardwareCapabilities.detect()

    print("\nHardware capabilities:")
    print("  NEON (ARM SIMD) : \(caps.hasNEON)")
    print("  AVX2 (x86 SIMD) : \(caps.hasAVX2)")
    print("  Accelerate      : \(caps.hasAccelerate)")
    print("  Metal (GPU)     : \(caps.hasMetal)")
    if let gpu = caps.metalDeviceName {
        print("  Metal device    : \(gpu)")
    }
    print("  Vulkan (GPU)    : \(caps.hasVulkan)")
    if let vk = caps.vulkanDeviceName {
        print("  Vulkan device   : \(vk)")
    }
    print("  CPU cores       : \(caps.coreCount)")

    // 3. Use the shared singleton (detected once at startup)
    let shared = HardwareCapabilities.shared
    print("\nShared instance core count: \(shared.coreCount)")

    // 4. Build encoding options optimised for this machine
    let options = EncodingOptions(
        mode: .lossy(quality: 90),
        effort: .squirrel,
        useHardwareAcceleration: caps.hasNEON || caps.hasAVX2,
        useAccelerate: caps.hasAccelerate,
        useMetal: caps.hasMetal,
        numThreads: caps.coreCount   // Use all available cores
    )

    print("\nRecommended encoding options:")
    print("  Hardware acceleration : \(options.useHardwareAcceleration)")
    print("  Accelerate framework  : \(options.useAccelerate)")
    print("  Metal GPU             : \(options.useMetal)")
    print("  Thread count          : \(options.numThreads)")
}

// Run the example
hardwareDetectionExample()
