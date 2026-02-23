/// Performance profiler for JXLSwift encoding and decoding pipelines.
///
/// Provides stage-level timing measurement, throughput calculation, and
/// regression detection for the encoding/decoding hot paths:
/// colour conversion, DCT, quantisation, and entropy coding.
///
/// # Usage
/// ```swift
/// var profiler = PerformanceProfiler()
/// profiler.beginStage(.colourConversion)
/// // ... perform colour conversion ...
/// profiler.endStage(.colourConversion)
/// let report = profiler.buildReport(width: 256, height: 256)
/// print(report.summary)
/// ```

import Foundation

// MARK: - Pipeline Stage

/// A named stage in the encoding or decoding pipeline.
public enum PipelineStage: String, Sendable, CaseIterable {
    /// Colour space conversion (RGB → YCbCr / XYB)
    case colourConversion = "colour_conversion"
    /// Forward DCT transform
    case dct = "dct"
    /// Inverse DCT transform
    case idct = "idct"
    /// Quantisation (encoder side)
    case quantisation = "quantisation"
    /// Dequantisation (decoder side)
    case dequantisation = "dequantisation"
    /// ANS/Huffman entropy encoding
    case entropyEncoding = "entropy_encoding"
    /// ANS/Huffman entropy decoding
    case entropyDecoding = "entropy_decoding"
    /// Chroma-from-luma (CfL) prediction
    case chromaFromLuma = "chroma_from_luma"
    /// Noise synthesis application
    case noiseSynthesis = "noise_synthesis"
    /// Spline rendering
    case splineRendering = "spline_rendering"
    /// Patch application
    case patchApplication = "patch_application"
    /// Frame header serialisation/deserialisation
    case frameHeader = "frame_header"
    /// Bitstream write / flush
    case bitstreamWrite = "bitstream_write"

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .colourConversion:   return "Colour Conversion"
        case .dct:                return "Forward DCT"
        case .idct:               return "Inverse DCT"
        case .quantisation:       return "Quantisation"
        case .dequantisation:     return "Dequantisation"
        case .entropyEncoding:    return "Entropy Encoding"
        case .entropyDecoding:    return "Entropy Decoding"
        case .chromaFromLuma:     return "Chroma-from-Luma"
        case .noiseSynthesis:     return "Noise Synthesis"
        case .splineRendering:    return "Spline Rendering"
        case .patchApplication:   return "Patch Application"
        case .frameHeader:        return "Frame Header"
        case .bitstreamWrite:     return "Bitstream Write"
        }
    }
}

// MARK: - Stage Timing

/// Timing record for a single pipeline stage invocation.
public struct StageTiming: Sendable {
    /// The stage that was measured.
    public let stage: PipelineStage
    /// Wall-clock elapsed time in seconds.
    public let elapsedSeconds: Double

    public init(stage: PipelineStage, elapsedSeconds: Double) {
        self.stage = stage
        self.elapsedSeconds = elapsedSeconds
    }
}

// MARK: - Profiling Report

/// Aggregated profiling report for one encode or decode invocation.
public struct ProfilingReport: Sendable {
    /// Total wall-clock time for the entire operation in seconds.
    public let totalSeconds: Double
    /// Per-stage aggregated statistics.
    public let stageStats: [PipelineStage: StageStats]
    /// Image dimensions that were processed.
    public let width: Int
    public let height: Int

    /// Throughput in megapixels per second.
    public var megapixelsPerSecond: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(width * height) / 1_000_000.0 / totalSeconds
    }

    /// One-line summary of the top hot path stages.
    public var summary: String {
        let sorted = stageStats.sorted { $0.value.totalSeconds > $1.value.totalSeconds }
        let top = sorted.prefix(3).map { "\($0.key.displayName): \(String(format: "%.1f", $0.value.totalSeconds * 1000)) ms" }
        return "Total: \(String(format: "%.1f", totalSeconds * 1000)) ms (\(String(format: "%.1f", megapixelsPerSecond)) MP/s) | \(top.joined(separator: ", "))"
    }

    /// Fraction of total time spent in each stage (0–1).
    public func timeShare(for stage: PipelineStage) -> Double {
        guard totalSeconds > 0, let stats = stageStats[stage] else { return 0 }
        return stats.totalSeconds / totalSeconds
    }
}

/// Aggregated statistics for one pipeline stage.
public struct StageStats: Sendable {
    /// Total accumulated time across all invocations.
    public let totalSeconds: Double
    /// Number of times this stage was entered.
    public let callCount: Int
    /// Average time per invocation.
    public var averageSeconds: Double {
        guard callCount > 0 else { return 0 }
        return totalSeconds / Double(callCount)
    }
}

// MARK: - Performance Profiler

/// Lightweight wall-clock profiler for the JXLSwift pipeline.
///
/// Thread-unsafe — create one profiler per encode/decode call and accumulate
/// results on a single thread. For multi-threaded profiling, use separate
/// instances and merge via `merge(_:)`.
public struct PerformanceProfiler: Sendable {

    // Storage: stage → (accumulated seconds, call count, optional start time)
    private var accumulated: [PipelineStage: (total: Double, count: Int)] = [:]
    private var starts: [PipelineStage: Double] = [:]
    private var totalStart: Double = ProcessInfo.processInfo.systemUptime

    // MARK: Lifecycle

    /// Create a new profiler with all counters reset.
    public init() {}

    // MARK: Stage Control

    /// Mark the beginning of a pipeline stage.
    ///
    /// Calling `beginStage` again for the same stage before calling `endStage`
    /// replaces the start time (the previous un-ended measurement is discarded).
    ///
    /// - Parameter stage: The pipeline stage to start timing.
    public mutating func beginStage(_ stage: PipelineStage) {
        starts[stage] = ProcessInfo.processInfo.systemUptime
    }

    /// Mark the end of a pipeline stage and accumulate the elapsed time.
    ///
    /// If `beginStage` was not called for this stage, the call is a no-op.
    ///
    /// - Parameter stage: The pipeline stage to stop timing.
    public mutating func endStage(_ stage: PipelineStage) {
        guard let start = starts[stage] else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        starts.removeValue(forKey: stage)
        let prev = accumulated[stage] ?? (total: 0, count: 0)
        accumulated[stage] = (total: prev.total + elapsed, count: prev.count + 1)
    }

    /// Record a pre-measured duration for a stage (useful when timing externally).
    ///
    /// - Parameters:
    ///   - stage: The pipeline stage.
    ///   - seconds: Elapsed time to record.
    public mutating func record(_ stage: PipelineStage, seconds: Double) {
        let prev = accumulated[stage] ?? (total: 0, count: 0)
        accumulated[stage] = (total: prev.total + seconds, count: prev.count + 1)
    }

    // MARK: Report

    /// Build a profiling report for an image of the given dimensions.
    ///
    /// - Parameters:
    ///   - width:  Image width in pixels.
    ///   - height: Image height in pixels.
    /// - Returns: A `ProfilingReport` summarising this profiler's timings.
    public func buildReport(width: Int, height: Int) -> ProfilingReport {
        let totalSeconds = ProcessInfo.processInfo.systemUptime - totalStart
        var stageStats: [PipelineStage: StageStats] = [:]
        for (stage, data) in accumulated {
            stageStats[stage] = StageStats(totalSeconds: data.total, callCount: data.count)
        }
        return ProfilingReport(
            totalSeconds: totalSeconds,
            stageStats: stageStats,
            width: width,
            height: height
        )
    }

    // MARK: Merge

    /// Merge another profiler's measurements into this one.
    ///
    /// Useful for aggregating results from multiple worker threads.
    ///
    /// - Parameter other: The profiler whose measurements to incorporate.
    public mutating func merge(_ other: PerformanceProfiler) {
        for (stage, data) in other.accumulated {
            let prev = accumulated[stage] ?? (total: 0, count: 0)
            accumulated[stage] = (total: prev.total + data.total, count: prev.count + data.count)
        }
    }

    /// Reset all timers and counters.
    public mutating func reset() {
        accumulated.removeAll()
        starts.removeAll()
        totalStart = ProcessInfo.processInfo.systemUptime
    }
}

// MARK: - Regression Gate

/// Compares a profiling report against a stored baseline and flags regressions.
public struct PerformanceRegressionGate: Sendable {

    /// Maximum allowed throughput slowdown (0.10 = 10%).
    public let regressionThreshold: Double

    /// Baseline megapixels-per-second from a reference run.
    public let baselineMegapixelsPerSecond: Double

    public init(baselineMegapixelsPerSecond: Double, regressionThreshold: Double = 0.10) {
        self.baselineMegapixelsPerSecond = baselineMegapixelsPerSecond
        self.regressionThreshold = regressionThreshold
    }

    /// Returns `true` if the report's throughput is within the allowed range.
    ///
    /// - Parameter report: The profiling report to evaluate.
    /// - Returns: `true` if no regression detected.
    public func passes(_ report: ProfilingReport) -> Bool {
        guard baselineMegapixelsPerSecond > 0 else { return true }
        let ratio = report.megapixelsPerSecond / baselineMegapixelsPerSecond
        return ratio >= (1.0 - regressionThreshold)
    }

    /// Returns the regression percentage (negative = slower, positive = faster).
    public func regressionPercent(_ report: ProfilingReport) -> Double {
        guard baselineMegapixelsPerSecond > 0 else { return 0 }
        return (report.megapixelsPerSecond / baselineMegapixelsPerSecond - 1.0) * 100.0
    }
}
