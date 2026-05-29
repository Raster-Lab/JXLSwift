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

enum BenchmarkMode: String, ExpressibleByArgument, CaseIterable {
    case m0
    case lossy
    case lossless
}

struct Benchmark: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "benchmark",
        abstract: "Time encode + decode round-trips on a PNM input. Default mode is `lossy` (VarDCT); use `--mode lossless` for the spec-compliant Modular path, or `--mode m0` for the project-internal M0 placeholder codec."
    )

    @Option(name: .shortAndLong, help: "Input image path (PGM, PPM, or PAM)")
    var input: String

    @Option(name: .shortAndLong, help: "Number of encode/decode iterations (each direction)")
    var iterations: Int = 10

    @Flag(name: .long, help: "Use M0 fast-encode mode (skip predictor + RCT search). Only honoured for `--mode m0`.")
    var fast: Bool = false

    @Option(name: .long, help: "Benchmark mode: m0 / lossy / lossless. Default: lossy.")
    var mode: BenchmarkMode = .lossy

    @Option(name: .customLong("effort"), help: "Encoder effort 1–9 (lossless mode; 1=fastest, 9=best ratio). Default: 7.")
    var encodeEffort: Int = 7

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

        let effort: M0Effort = fast ? .fast : .balanced

        // First pass: encode once to populate `encoded` for the
        // decode benchmark + capture the encoded byte count.
        let encoded: Data
        do { encoded = try benchmarkEncode(frame: frame, effort: effort) }
        catch { print("\(mode.rawValue) encode error: \(error)",
                      to: &standardError)
                throw JXLExitCode.generalError }
        // Lossless modes must round-trip exactly; lossy modes
        // skip the exactness check (mean-error checks belong in
        // the unit tests, not here).
        if mode != .lossy {
            do {
                let decoded = try benchmarkDecode(encoded: encoded)
                guard decoded.data == frame.data else {
                    print("\(mode.rawValue) round-trip mismatch — "
                        + "encoder/decoder disagree",
                          to: &standardError)
                    throw JXLExitCode.generalError
                }
            } catch {
                print("\(mode.rawValue) decode error: \(error)",
                      to: &standardError)
                throw JXLExitCode.generalError
            }
        }

        let n = max(1, iterations)

        // Encode benchmark.
        let encStart = clock_gettime_ns()
        for _ in 0..<n {
            _ = try benchmarkEncode(frame: frame, effort: effort)
        }
        let encNs = clock_gettime_ns() - encStart

        // Decode benchmark.
        let decStart = clock_gettime_ns()
        for _ in 0..<n {
            _ = try benchmarkDecode(encoded: encoded)
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
        let modeLabel: String
        switch mode {
        case .m0: modeLabel = "M0 placeholder (effort: " +
                              (fast ? "fast" : "balanced") + ")"
        case .lossy: modeLabel = "VarDCT lossy"
        case .lossless: modeLabel = "Modular lossless (effort \(max(1, min(encodeEffort, 9))))"
        }
        print("""

            Image:        \(widthLabel) \(kindLabel)
            Source size:  \(formatBytes(rawByteCount)) (\(totalPixels) pixels)
            Encoded size: \(formatBytes(encoded.count)) (\(String(format: "%.1f", ratio))% of source)
            Mode:         \(modeLabel)

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

    private func benchmarkEncode(
        frame: ImageFrame, effort: M0Effort
    ) throws -> Data {
        switch mode {
        case .m0:
            return try MinimalLosslessCodec.encode(
                frame, effort: effort)
        case .lossy:
            return try JXLEncoder(options: EncodingOptions(
                mode: .lossy(quality: 90))).encode(frame).data
        case .lossless:
            let level = EncodingEffort(rawValue: max(1, min(self.encodeEffort, 9))) ?? .squirrel
            return try JXLEncoder(options: EncodingOptions(
                mode: .lossless, effort: level)).encode(frame).data
        }
    }

    private func benchmarkDecode(
        encoded: Data
    ) throws -> ImageFrame {
        switch mode {
        case .m0:
            return try MinimalLosslessCodec.decode(encoded)
        case .lossy, .lossless:
            return try JXLDecoder().decode(encoded)
        }
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
