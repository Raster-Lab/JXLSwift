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

        print()
        print("Done.")
    }
}
