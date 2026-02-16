/// Hardware subcommand — display detected hardware capabilities
///
/// Shows CPU architecture, SIMD support, and framework availability.

import ArgumentParser
import Foundation
import JXLSwift

struct Hardware: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Display detected hardware capabilities"
    )

    func run() throws {
        let arch = CPUArchitecture.current
        let caps = HardwareCapabilities.shared

        print("=== Hardware Capabilities ===")
        print()
        print("CPU Architecture: \(arch.rawValue)")
        print("Apple Silicon:    \(arch.isAppleSilicon ? "Yes" : "No")")
        print()
        print("SIMD Support:")
        print("  ARM NEON:       \(caps.hasNEON ? "✅ Available" : "❌ Not available")")
        print("  AVX2:           \(caps.hasAVX2 ? "✅ Available" : "❌ Not available")")
        print()
        print("Frameworks:")
        print("  Accelerate:     \(caps.hasAccelerate ? "✅ Available" : "❌ Not available")")
        print("  Metal GPU:      \(caps.hasMetal ? "✅ Available" : "❌ Not available")")
        if let metalName = caps.metalDeviceName {
            print("  Metal Device:   \(metalName)")
        }
        print()
        print("System:")
        print("  CPU Cores:      \(caps.coreCount)")
        print()
        print("Recommended Settings:")
        if caps.hasNEON {
            print("  • Use ARM NEON SIMD for vectorised operations")
        }
        if caps.hasAccelerate {
            print("  • Use Apple Accelerate for DCT and matrix operations")
        }
        if caps.hasMetal {
            print("  • Use Metal GPU for parallel block processing")
        }
        if !caps.hasNEON && !caps.hasAccelerate {
            print("  • Using scalar fallback implementations")
        }
    }
}
