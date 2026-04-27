// `jxl-tool benchmark` — time the M0 encode/decode pipeline on a
// PNM input and report throughput.
//
// The benchmark reads the PNM once (input I/O time isn't included),
// then runs `MinimalLosslessCodec.encode(_:)` and
// `MinimalLosslessCodec.decode(_:)` `iterations` times each in
// release configuration, recording the total wall-clock time. It
// reports per-iteration milliseconds and source-pixels-per-second
// throughput so you can compare across image sizes.
//
// Throughput numbers measured on Apple Silicon (arm64) in release
// mode tell us roughly where the codec sits today and surface the
// next optimisation target — whether the bottleneck is in
// prediction, the entropy coder, or the bit-level I/O.
//
// Round-trip correctness is verified once (the first decode is
// compared against the original frame); subsequent iterations skip
// the comparison so the measurement isn't dominated by it.

import ArgumentParser
import Foundation
import JXLSwift

struct Benchmark: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "benchmark",
        abstract: "Time M0 encode + decode on a PNM input."
    )

    @Option(name: .shortAndLong, help: "Input image path (PGM, PPM, or PAM)")
    var input: String

    @Option(name: .shortAndLong, help: "Number of encode/decode iterations (each direction)")
    var iterations: Int = 10

    func run() throws {
        let url = URL(fileURLWithPath: input)
        let pnmData: Data
        do { pnmData = try Data(contentsOf: url) }
        catch { print("error reading \(input): \(error)", to: &standardError)
                throw JXLExitCode.generalError }

        let frame: ImageFrame
        do { frame = try PNM.read(pnmData) }
        catch let e as PNMError {
            print("PNM parse error: \(e)", to: &standardError)
            throw JXLExitCode.invalidArguments
        }

        let totalPixels = frame.width * frame.height
        let totalSamples = totalPixels * frame.channels
        let rawByteCount = totalSamples * frame.pixelType.bytesPerSample

        // First pass: round-trip correctness check + populate
        // `encoded` for the decode benchmark.
        let encoded: Data
        do { encoded = try MinimalLosslessCodec.encode(frame) }
        catch { print("M0 encode error: \(error)", to: &standardError)
                throw JXLExitCode.generalError }
        do {
            let decoded = try MinimalLosslessCodec.decode(encoded)
            guard decoded.data == frame.data else {
                print("M0 round-trip mismatch — encoder/decoder disagree",
                      to: &standardError)
                throw JXLExitCode.generalError
            }
        } catch {
            print("M0 decode error: \(error)", to: &standardError)
            throw JXLExitCode.generalError
        }

        let n = max(1, iterations)

        // Encode benchmark.
        let encStart = clock_gettime_ns()
        for _ in 0..<n {
            _ = try MinimalLosslessCodec.encode(frame)
        }
        let encNs = clock_gettime_ns() - encStart

        // Decode benchmark.
        let decStart = clock_gettime_ns()
        for _ in 0..<n {
            _ = try MinimalLosslessCodec.decode(encoded)
        }
        let decNs = clock_gettime_ns() - decStart

        let encMsPer = Double(encNs) / Double(n) / 1_000_000.0
        let decMsPer = Double(decNs) / Double(n) / 1_000_000.0
        let encMpps = Double(totalPixels) * Double(n) / (Double(encNs) / 1e9) / 1e6
        let decMpps = Double(totalPixels) * Double(n) / (Double(decNs) / 1e9) / 1e6
        let encMBs = Double(rawByteCount) * Double(n) / (Double(encNs) / 1e9) / (1024 * 1024)
        let decMBs = Double(rawByteCount) * Double(n) / (Double(decNs) / 1e9) / (1024 * 1024)
        let ratio = Double(encoded.count) * 100 / Double(rawByteCount)

        let widthLabel = "\(frame.width)×\(frame.height)"
        let kindLabel  = channelDescription(frame.channels) +
                        " " + "\(frame.pixelType.bitsPerSample)-bit"
        print("""

            Image:        \(widthLabel) \(kindLabel)
            Source size:  \(formatBytes(rawByteCount)) (\(totalPixels) pixels)
            Encoded size: \(formatBytes(encoded.count)) (\(String(format: "%.1f", ratio))% of source)

            Encode (\(n)× iterations):
              total       \(String(format: "%.1f", Double(encNs) / 1_000_000)) ms
              per pass    \(String(format: "%.2f", encMsPer)) ms
              throughput  \(String(format: "%.1f", encMpps)) Mpx/s  /  \(String(format: "%.1f", encMBs)) MB/s

            Decode (\(n)× iterations):
              total       \(String(format: "%.1f", Double(decNs) / 1_000_000)) ms
              per pass    \(String(format: "%.2f", decMsPer)) ms
              throughput  \(String(format: "%.1f", decMpps)) Mpx/s  /  \(String(format: "%.1f", decMBs)) MB/s
            """)
    }
}

/// Monotonic nanosecond clock (`CLOCK_UPTIME_RAW` on Darwin /
/// `CLOCK_MONOTONIC` on Linux). `Date()` deltas drift across system
/// time changes; this avoids that.
private func clock_gettime_ns() -> UInt64 {
    var ts = timespec()
    #if os(Darwin)
    clock_gettime(CLOCK_UPTIME_RAW, &ts)
    #else
    clock_gettime(CLOCK_MONOTONIC, &ts)
    #endif
    return UInt64(ts.tv_sec) * 1_000_000_000 &+ UInt64(ts.tv_nsec)
}
