/// Benchmark subcommand — performance benchmarking
///
/// Runs encoding benchmarks at various effort levels and reports results.

import ArgumentParser
import Foundation
import JXLSwift

struct Benchmark: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run encoding performance benchmarks"
    )

    @Option(name: .shortAndLong, help: "Image width for benchmarks")
    var width: Int = 256

    @Option(name: .long, help: "Image height for benchmarks")
    var height: Int = 256

    @Option(name: .shortAndLong, help: "Number of iterations per benchmark")
    var iterations: Int = 3

    @Flag(name: .long, help: "Include lossless mode in benchmarks")
    var includeLossless: Bool = false

    @Flag(name: .long, help: "Compare ANS vs simplified entropy encoding")
    var compareEntropy: Bool = false

    @Flag(name: .long, help: "Compare hardware acceleration (NEON vs scalar)")
    var compareHardware: Bool = false

    func run() throws {
        print("=== JXLSwift Benchmark ===")
        print("Image size: \(width)×\(height)")
        print("Iterations: \(iterations)")
        print()

        // Generate test image
        var frame = ImageFrame(
            width: width,
            height: height,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB
        )

        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x * y) % 256))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16((x + y) % 256))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x ^ y) % 256))
            }
        }

        // Benchmark lossy at different effort levels
        let efforts: [(String, EncodingEffort)] = [
            ("Lightning (1)", .lightning),
            ("Falcon (3)",    .falcon),
            ("Squirrel (7)",  .squirrel),
            ("Tortoise (9)",  .tortoise),
        ]

        print(String(format: "%-16s %10s %10s %10s", "Effort", "Time (ms)", "Size (B)", "Ratio"))
        print(String(repeating: "─", count: 50))

        for (name, effort) in efforts {
            let options = EncodingOptions(
                mode: .lossy(quality: 90),
                effort: effort
            )
            let encoder = JXLEncoder(options: options)

            var totalTime: TimeInterval = 0
            var lastResult: EncodedImage?

            for _ in 0..<iterations {
                let start = Date()
                let result = try encoder.encode(frame)
                totalTime += Date().timeIntervalSince(start)
                lastResult = result
            }

            let avgTime = totalTime / Double(iterations)
            if let result = lastResult {
                print(String(format: "%-16s %10.1f %10d %10.2f×",
                    name,
                    avgTime * 1000,
                    result.stats.compressedSize,
                    result.stats.compressionRatio
                ))
            }
        }

        // Benchmark lossless if requested
        if includeLossless {
            print()
            print("Lossless mode:")
            print(String(format: "%-16s %10s %10s %10s", "Mode", "Time (ms)", "Size (B)", "Ratio"))
            print(String(repeating: "─", count: 50))

            let options = EncodingOptions.lossless
            let encoder = JXLEncoder(options: options)

            var totalTime: TimeInterval = 0
            var lastResult: EncodedImage?

            for _ in 0..<iterations {
                let start = Date()
                let result = try encoder.encode(frame)
                totalTime += Date().timeIntervalSince(start)
                lastResult = result
            }

            let avgTime = totalTime / Double(iterations)
            if let result = lastResult {
                print(String(format: "%-16s %10.1f %10d %10.2f×",
                    "Lossless",
                    avgTime * 1000,
                    result.stats.compressedSize,
                    result.stats.compressionRatio
                ))
            }
        }

        // Compare ANS vs simplified entropy encoding if requested
        if compareEntropy {
            try runEntropyComparison()
        }

        // Compare hardware acceleration if requested
        if compareHardware {
            try runHardwareComparison()
        }

        print()
        print("Done.")
    }

    // MARK: - Entropy Encoding Comparison

    private func runEntropyComparison() throws {
        print()
        print("=== ANS vs Simplified Entropy Encoding ===")
        print()

        // Generate a natural-looking test image with gradients
        var frame = ImageFrame(
            width: width,
            height: height,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB
        )

        // Create smooth gradients (compresses well with predictive coding)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let r = UInt16((x * 255) / frame.width)
                let g = UInt16((y * 255) / frame.height)
                let b = UInt16(((x + y) * 255) / (frame.width + frame.height))
                frame.setPixel(x: x, y: y, channel: 0, value: r)
                frame.setPixel(x: x, y: y, channel: 1, value: g)
                frame.setPixel(x: x, y: y, channel: 2, value: b)
            }
        }

        print("Image: \(width)×\(height) gradient pattern")
        print("Iterations: \(iterations)")
        print()
        print(String(format: "%-20s %10s %10s %10s %10s", "Encoder", "Time (ms)", "Size (B)", "Ratio", "Throughput"))
        print(String(repeating: "─", count: 65))

        // Test with simplified entropy encoding (useANS: false)
        let simplifiedOptions = EncodingOptions(
            mode: .lossless,
            effort: .squirrel,
            modularMode: true,
            useANS: false
        )
        let simplifiedEncoder = JXLEncoder(options: simplifiedOptions)

        var simplifiedTime: TimeInterval = 0
        var simplifiedResult: EncodedImage?

        for _ in 0..<iterations {
            let start = Date()
            let result = try simplifiedEncoder.encode(frame)
            simplifiedTime += Date().timeIntervalSince(start)
            simplifiedResult = result
        }
        let simplifiedAvgTime = simplifiedTime / Double(iterations)

        if let result = simplifiedResult {
            let throughput = Double(result.stats.originalSize) / simplifiedAvgTime / 1_000_000.0
            print(String(format: "%-20s %10.1f %10d %10.2f× %10.2f MB/s",
                "Simplified (RLE)",
                simplifiedAvgTime * 1000,
                result.stats.compressedSize,
                result.stats.compressionRatio,
                throughput
            ))
        }

        // Test with ANS entropy encoding (useANS: true)
        let ansOptions = EncodingOptions(
            mode: .lossless,
            effort: .squirrel,
            modularMode: true,
            useANS: true
        )
        let ansEncoder = JXLEncoder(options: ansOptions)

        var ansTime: TimeInterval = 0
        var ansResult: EncodedImage?

        for _ in 0..<iterations {
            let start = Date()
            let result = try ansEncoder.encode(frame)
            ansTime += Date().timeIntervalSince(start)
            ansResult = result
        }
        let ansAvgTime = ansTime / Double(iterations)

        if let result = ansResult {
            let throughput = Double(result.stats.originalSize) / ansAvgTime / 1_000_000.0
            print(String(format: "%-20s %10.1f %10d %10.2f× %10.2f MB/s",
                "ANS (rANS)",
                ansAvgTime * 1000,
                result.stats.compressedSize,
                result.stats.compressionRatio,
                throughput
            ))
        }

        // Calculate improvements
        if let simplified = simplifiedResult, let ans = ansResult {
            print()
            let compressionImprovement = ((simplified.stats.compressionRatio - ans.stats.compressionRatio) / simplified.stats.compressionRatio) * 100.0
            let sizeReduction = Double(simplified.stats.compressedSize - ans.stats.compressedSize) / Double(simplified.stats.compressedSize) * 100.0
            let speedRatio = simplifiedAvgTime / ansAvgTime

            print("Results:")
            print(String(format: "  ANS size reduction: %.1f%%", sizeReduction))
            print(String(format: "  ANS compression improvement: %.1f%%", abs(compressionImprovement)))
            print(String(format: "  ANS throughput: %.0f%% of simplified encoder", speedRatio * 100.0))

            // Check milestone targets
            let throughputTarget = 80.0
            let compressionTarget = 10.0

            print()
            print("Milestone 8 Targets:")
            if speedRatio * 100.0 >= throughputTarget {
                print(String(format: "  ✅ Performance: %.0f%% ≥ %.0f%% (PASS)", speedRatio * 100.0, throughputTarget))
            } else {
                print(String(format: "  ⚠️  Performance: %.0f%% < %.0f%% (needs improvement)", speedRatio * 100.0, throughputTarget))
            }

            if abs(sizeReduction) >= compressionTarget {
                print(String(format: "  ✅ Compression: %.1f%% ≥ %.1f%% (PASS)", abs(sizeReduction), compressionTarget))
            } else {
                print(String(format: "  ⚠️  Compression: %.1f%% < %.1f%% (needs improvement)", abs(sizeReduction), compressionTarget))
            }
        }
    }

    // MARK: - Hardware Acceleration Comparison

    private func runHardwareComparison() throws {
        print()
        print("=== Hardware Acceleration Comparison ===")
        print()

        let caps = HardwareCapabilities.shared
        print("Architecture: \(CPUArchitecture.current)")
        print("NEON available: \(caps.hasNEON)")
        print("Accelerate available: \(caps.hasAccelerate)")
        print()

        // Generate test image
        var frame = ImageFrame(
            width: width,
            height: height,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB
        )

        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let r = UInt16((x * 255) / frame.width)
                let g = UInt16((y * 255) / frame.height)
                let b = UInt16(((x + y) * 255) / (frame.width + frame.height))
                frame.setPixel(x: x, y: y, channel: 0, value: r)
                frame.setPixel(x: x, y: y, channel: 1, value: g)
                frame.setPixel(x: x, y: y, channel: 2, value: b)
            }
        }

        print("Image: \(width)×\(height)")
        print("Mode: Lossless (Modular)")
        print("Iterations: \(iterations)")
        print()
        print(String(format: "%-25s %10s %10s", "Configuration", "Time (ms)", "Speedup"))
        print(String(repeating: "─", count: 50))

        // Test with all acceleration disabled (scalar only)
        let scalarOptions = EncodingOptions(
            mode: .lossless,
            effort: .squirrel,
            modularMode: true,
            useHardwareAcceleration: false,
            useAccelerate: false,
            useANS: false
        )
        let scalarEncoder = JXLEncoder(options: scalarOptions)

        var scalarTime: TimeInterval = 0
        for _ in 0..<iterations {
            let start = Date()
            _ = try scalarEncoder.encode(frame)
            scalarTime += Date().timeIntervalSince(start)
        }
        let scalarAvgTime = scalarTime / Double(iterations)
        print(String(format: "%-25s %10.1f %10s",
            "Scalar (baseline)",
            scalarAvgTime * 1000,
            "1.00×"
        ))

        // Test with hardware acceleration enabled
        let hardwareOptions = EncodingOptions(
            mode: .lossless,
            effort: .squirrel,
            modularMode: true,
            useHardwareAcceleration: true,
            useAccelerate: true,
            useANS: false
        )
        let hardwareEncoder = JXLEncoder(options: hardwareOptions)

        var hardwareTime: TimeInterval = 0
        for _ in 0..<iterations {
            let start = Date()
            _ = try hardwareEncoder.encode(frame)
            hardwareTime += Date().timeIntervalSince(start)
        }
        let hardwareAvgTime = hardwareTime / Double(iterations)
        let speedup = scalarAvgTime / hardwareAvgTime
        print(String(format: "%-25s %10.1f %10.2f×",
            "Hardware accelerated",
            hardwareAvgTime * 1000,
            speedup
        ))

        // Test lossy mode (VarDCT) which uses more acceleration
        print()
        print("Mode: Lossy (VarDCT, quality 90)")
        print(String(repeating: "─", count: 50))

        let scalarLossyOptions = EncodingOptions(
            mode: .lossy(quality: 90),
            effort: .squirrel,
            useHardwareAcceleration: false,
            useAccelerate: false,
            useANS: false
        )
        let scalarLossyEncoder = JXLEncoder(options: scalarLossyOptions)

        var scalarLossyTime: TimeInterval = 0
        for _ in 0..<iterations {
            let start = Date()
            _ = try scalarLossyEncoder.encode(frame)
            scalarLossyTime += Date().timeIntervalSince(start)
        }
        let scalarLossyAvgTime = scalarLossyTime / Double(iterations)
        print(String(format: "%-25s %10.1f %10s",
            "Scalar (baseline)",
            scalarLossyAvgTime * 1000,
            "1.00×"
        ))

        let hardwareLossyOptions = EncodingOptions(
            mode: .lossy(quality: 90),
            effort: .squirrel,
            useHardwareAcceleration: true,
            useAccelerate: true,
            useANS: false
        )
        let hardwareLossyEncoder = JXLEncoder(options: hardwareLossyOptions)

        var hardwareLossyTime: TimeInterval = 0
        for _ in 0..<iterations {
            let start = Date()
            _ = try hardwareLossyEncoder.encode(frame)
            hardwareLossyTime += Date().timeIntervalSince(start)
        }
        let hardwareLossyAvgTime = hardwareLossyTime / Double(iterations)
        let lossySpeedup = scalarLossyAvgTime / hardwareLossyAvgTime
        print(String(format: "%-25s %10.1f %10.2f×",
            "Hardware accelerated",
            hardwareLossyAvgTime * 1000,
            lossySpeedup
        ))

        // Check milestone targets
        print()
        print("Milestone 6 Target:")
        let neonTarget = 3.0
        #if arch(arm64)
        // On ARM64, check actual NEON speedup
        if caps.hasNEON && speedup >= neonTarget {
            print(String(format: "  ✅ NEON speedup: %.2f× ≥ %.1f× (PASS)", speedup, neonTarget))
        } else if caps.hasNEON {
            print(String(format: "  ⚠️  NEON speedup: %.2f× < %.1f× (needs improvement)", speedup, neonTarget))
        } else {
            print("  ℹ️  NEON not available on this system")
        }
        #else
        print("  ℹ️  NEON benchmarks require ARM64 architecture")
        print(String(format: "  Hardware speedup (non-NEON): %.2f×", speedup))
        #endif
    }
}
