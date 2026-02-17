/// Benchmark report generation for validation results
///
/// Generates JSON and HTML reports from validation runs, enabling CI integration,
/// performance tracking, and regression detection over time.

import Foundation

// MARK: - Benchmark Report

/// A complete benchmark report that can be serialized to JSON or rendered as HTML.
public struct BenchmarkReport: Sendable {
    /// Report metadata
    public let metadata: ReportMetadata

    /// Individual benchmark entries
    public let entries: [BenchmarkEntry]

    /// Performance baselines for regression detection
    public let baselines: [PerformanceBaseline]

    /// Initialize a benchmark report.
    public init(metadata: ReportMetadata, entries: [BenchmarkEntry], baselines: [PerformanceBaseline]) {
        self.metadata = metadata
        self.entries = entries
        self.baselines = baselines
    }

    /// Regression alerts (entries that regressed beyond threshold)
    public var regressions: [RegressionAlert] {
        var alerts: [RegressionAlert] = []
        for entry in entries {
            for baseline in baselines where baseline.name == entry.name {
                // Check encoding time regression
                if baseline.encodingTimeSeconds > 0 {
                    let ratio = entry.encodingTimeSeconds / baseline.encodingTimeSeconds
                    if ratio > 1.0 + baseline.regressionThreshold {
                        alerts.append(RegressionAlert(
                            name: entry.name,
                            metric: "encodingTime",
                            baselineValue: baseline.encodingTimeSeconds,
                            currentValue: entry.encodingTimeSeconds,
                            regressionPercent: (ratio - 1.0) * 100.0,
                            threshold: baseline.regressionThreshold * 100.0
                        ))
                    }
                }

                // Check compression ratio regression
                if baseline.compressionRatio > 0 {
                    let ratio = baseline.compressionRatio / max(entry.compressionRatio, 0.001)
                    if ratio > 1.0 + baseline.regressionThreshold {
                        alerts.append(RegressionAlert(
                            name: entry.name,
                            metric: "compressionRatio",
                            baselineValue: baseline.compressionRatio,
                            currentValue: entry.compressionRatio,
                            regressionPercent: (ratio - 1.0) * 100.0,
                            threshold: baseline.regressionThreshold * 100.0
                        ))
                    }
                }
            }
        }
        return alerts
    }
}

/// Report metadata.
public struct ReportMetadata: Sendable {
    /// Report title
    public let title: String

    /// Timestamp of the report
    public let timestamp: Date

    /// JXLSwift version
    public let jxlSwiftVersion: String

    /// Platform description
    public let platform: String

    /// CPU architecture
    public let architecture: String

    /// Number of CPU cores
    public let cpuCores: Int

    /// Initialize report metadata.
    public init(
        title: String = "JXLSwift Benchmark Report",
        timestamp: Date = Date(),
        jxlSwiftVersion: String = JXLSwift.version,
        platform: String = platformDescription(),
        architecture: String = architectureDescription(),
        cpuCores: Int = ProcessInfo.processInfo.processorCount
    ) {
        self.title = title
        self.timestamp = timestamp
        self.jxlSwiftVersion = jxlSwiftVersion
        self.platform = platform
        self.architecture = architecture
        self.cpuCores = cpuCores
    }
}

/// A single benchmark entry.
public struct BenchmarkEntry: Sendable {
    /// Benchmark name
    public let name: String

    /// Image width
    public let width: Int

    /// Image height
    public let height: Int

    /// Compression mode description
    public let mode: String

    /// Effort level
    public let effort: Int

    /// Encoding time in seconds (average over iterations)
    public let encodingTimeSeconds: Double

    /// Megapixels per second throughput
    public let megapixelsPerSecond: Double

    /// Original size in bytes
    public let originalSize: Int

    /// Compressed size in bytes
    public let compressedSize: Int

    /// Compression ratio
    public let compressionRatio: Double

    /// Peak memory usage in bytes
    public let peakMemoryBytes: Int

    /// PSNR in dB (if available)
    public let psnr: Double?

    /// SSIM (if available)
    public let ssim: Double?

    /// Butteraugli distance (if available)
    public let butteraugli: Double?

    /// Initialize a benchmark entry.
    public init(
        name: String, width: Int, height: Int, mode: String, effort: Int,
        encodingTimeSeconds: Double, megapixelsPerSecond: Double,
        originalSize: Int, compressedSize: Int, compressionRatio: Double,
        peakMemoryBytes: Int, psnr: Double?, ssim: Double?, butteraugli: Double?
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.mode = mode
        self.effort = effort
        self.encodingTimeSeconds = encodingTimeSeconds
        self.megapixelsPerSecond = megapixelsPerSecond
        self.originalSize = originalSize
        self.compressedSize = compressedSize
        self.compressionRatio = compressionRatio
        self.peakMemoryBytes = peakMemoryBytes
        self.psnr = psnr
        self.ssim = ssim
        self.butteraugli = butteraugli
    }
}

/// A performance baseline for regression detection.
public struct PerformanceBaseline: Sendable {
    /// Baseline name (matches BenchmarkEntry name)
    public let name: String

    /// Baseline encoding time in seconds
    public let encodingTimeSeconds: Double

    /// Baseline compression ratio
    public let compressionRatio: Double

    /// Regression threshold (fraction, e.g. 0.10 = 10%)
    public let regressionThreshold: Double

    /// Timestamp when this baseline was established
    public let timestamp: Date

    /// Initialize a performance baseline.
    /// - Parameters:
    ///   - name: Baseline name
    ///   - encodingTimeSeconds: Baseline encoding time
    ///   - compressionRatio: Baseline compression ratio
    ///   - regressionThreshold: Fraction threshold for regression alerts (default: 0.10)
    ///   - timestamp: When the baseline was established
    public init(
        name: String,
        encodingTimeSeconds: Double,
        compressionRatio: Double,
        regressionThreshold: Double = 0.10,
        timestamp: Date = Date()
    ) {
        self.name = name
        self.encodingTimeSeconds = encodingTimeSeconds
        self.compressionRatio = compressionRatio
        self.regressionThreshold = regressionThreshold
        self.timestamp = timestamp
    }
}

/// A regression alert when performance degrades beyond threshold.
public struct RegressionAlert: Sendable {
    /// Benchmark name
    public let name: String

    /// Which metric regressed
    public let metric: String

    /// Baseline value
    public let baselineValue: Double

    /// Current value
    public let currentValue: Double

    /// Regression percentage
    public let regressionPercent: Double

    /// Threshold percentage
    public let threshold: Double

    /// Initialize a regression alert.
    public init(name: String, metric: String, baselineValue: Double, currentValue: Double, regressionPercent: Double, threshold: Double) {
        self.name = name
        self.metric = metric
        self.baselineValue = baselineValue
        self.currentValue = currentValue
        self.regressionPercent = regressionPercent
        self.threshold = threshold
    }
}

// MARK: - Report Generator

/// Generates benchmark reports in JSON and HTML formats.
public enum BenchmarkReportGenerator {

    // MARK: - JSON Output

    /// Generate a JSON representation of the benchmark report.
    /// - Parameter report: The benchmark report
    /// - Returns: JSON string
    public static func generateJSON(from report: BenchmarkReport) -> String {
        var json = "{\n"
        json += "  \"metadata\": \(metadataJSON(report.metadata)),\n"
        json += "  \"entries\": [\n"

        for (i, entry) in report.entries.enumerated() {
            json += "    \(entryJSON(entry))"
            if i < report.entries.count - 1 { json += "," }
            json += "\n"
        }

        json += "  ],\n"
        json += "  \"baselines\": [\n"

        for (i, baseline) in report.baselines.enumerated() {
            json += "    \(baselineJSON(baseline))"
            if i < report.baselines.count - 1 { json += "," }
            json += "\n"
        }

        json += "  ],\n"
        json += "  \"regressions\": [\n"

        let regressions = report.regressions
        for (i, alert) in regressions.enumerated() {
            json += "    \(regressionJSON(alert))"
            if i < regressions.count - 1 { json += "," }
            json += "\n"
        }

        json += "  ],\n"
        json += "  \"summary\": \(summaryJSON(from: report))\n"
        json += "}\n"
        return json
    }

    // MARK: - HTML Output

    /// Generate an HTML report from benchmark results.
    /// - Parameter report: The benchmark report
    /// - Returns: HTML string
    public static func generateHTML(from report: BenchmarkReport) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        let dateStr = dateFormatter.string(from: report.metadata.timestamp)

        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(escapeHTML(report.metadata.title))</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 2rem; background: #f5f5f5; }
                h1 { color: #333; }
                .metadata { background: #fff; padding: 1rem; border-radius: 8px; margin-bottom: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
                .metadata dt { font-weight: bold; display: inline; }
                .metadata dd { display: inline; margin-left: 0.5rem; margin-right: 2rem; }
                table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 1rem; }
                th { background: #2c3e50; color: #fff; padding: 0.75rem; text-align: left; font-size: 0.85rem; }
                td { padding: 0.75rem; border-bottom: 1px solid #eee; font-size: 0.85rem; }
                tr:hover { background: #f0f8ff; }
                .pass { color: #27ae60; font-weight: bold; }
                .fail { color: #e74c3c; font-weight: bold; }
                .alert { background: #fff3cd; border: 1px solid #ffc107; padding: 1rem; border-radius: 8px; margin-bottom: 1rem; }
                .alert-title { font-weight: bold; color: #856404; }
                .summary { background: #d4edda; border: 1px solid #c3e6cb; padding: 1rem; border-radius: 8px; margin-bottom: 1rem; }
            </style>
        </head>
        <body>
            <h1>\(escapeHTML(report.metadata.title))</h1>
            <div class="metadata">
                <dl>
                    <dt>Date:</dt><dd>\(escapeHTML(dateStr))</dd>
                    <dt>Version:</dt><dd>\(escapeHTML(report.metadata.jxlSwiftVersion))</dd>
                    <dt>Platform:</dt><dd>\(escapeHTML(report.metadata.platform))</dd>
                    <dt>Architecture:</dt><dd>\(escapeHTML(report.metadata.architecture))</dd>
                    <dt>CPU Cores:</dt><dd>\(report.metadata.cpuCores)</dd>
                </dl>
            </div>
        """

        // Regressions
        let regressions = report.regressions
        if !regressions.isEmpty {
            html += "<div class=\"alert\"><span class=\"alert-title\">⚠️ Regressions Detected</span><ul>\n"
            for alert in regressions {
                html += "<li><strong>\(escapeHTML(alert.name))</strong>: \(escapeHTML(alert.metric)) regressed by "
                html += String(format: "%.1f%%", alert.regressionPercent)
                html += " (threshold: \(String(format: "%.0f%%", alert.threshold)))</li>\n"
            }
            html += "</ul></div>\n"
        }

        // Results table
        html += """
            <h2>Benchmark Results</h2>
            <table>
                <thead>
                    <tr>
                        <th>Name</th>
                        <th>Size</th>
                        <th>Mode</th>
                        <th>Effort</th>
                        <th>Time (ms)</th>
                        <th>MP/s</th>
                        <th>Ratio</th>
                        <th>PSNR (dB)</th>
                        <th>SSIM</th>
                    </tr>
                </thead>
                <tbody>
        """

        for entry in report.entries {
            let psnrStr = entry.psnr.map { String(format: "%.2f", $0) } ?? "—"
            let ssimStr = entry.ssim.map { String(format: "%.4f", $0) } ?? "—"

            html += "        <tr>"
            html += "<td>\(escapeHTML(entry.name))</td>"
            html += "<td>\(entry.width)×\(entry.height)</td>"
            html += "<td>\(escapeHTML(entry.mode))</td>"
            html += "<td>\(entry.effort)</td>"
            html += "<td>\(String(format: "%.1f", entry.encodingTimeSeconds * 1000))</td>"
            html += "<td>\(String(format: "%.2f", entry.megapixelsPerSecond))</td>"
            html += "<td>\(String(format: "%.2f×", entry.compressionRatio))</td>"
            html += "<td>\(psnrStr)</td>"
            html += "<td>\(ssimStr)</td>"
            html += "</tr>\n"
        }

        html += """
                </tbody>
            </table>
        """

        // Summary
        let totalEntries = report.entries.count
        let avgTime = report.entries.isEmpty ? 0.0 :
            report.entries.map(\.encodingTimeSeconds).reduce(0, +) / Double(totalEntries)
        let avgRatio = report.entries.isEmpty ? 0.0 :
            report.entries.map(\.compressionRatio).reduce(0, +) / Double(totalEntries)

        html += """
            <div class="summary">
                <h3>Summary</h3>
                <p>Total benchmarks: \(totalEntries)</p>
                <p>Average encoding time: \(String(format: "%.1f", avgTime * 1000)) ms</p>
                <p>Average compression ratio: \(String(format: "%.2f", avgRatio))×</p>
                <p>Regressions: \(regressions.count)</p>
            </div>
        </body>
        </html>
        """

        return html
    }

    // MARK: - JSON Helpers

    private static func metadataJSON(_ m: ReportMetadata) -> String {
        let ts = ISO8601DateFormatter().string(from: m.timestamp)
        return """
        {"title": "\(escapeJSON(m.title))", "timestamp": "\(ts)", "version": "\(escapeJSON(m.jxlSwiftVersion))", "platform": "\(escapeJSON(m.platform))", "architecture": "\(escapeJSON(m.architecture))", "cpuCores": \(m.cpuCores)}
        """
    }

    private static func entryJSON(_ e: BenchmarkEntry) -> String {
        var fields = """
        {"name": "\(escapeJSON(e.name))", "width": \(e.width), "height": \(e.height), "mode": "\(escapeJSON(e.mode))", "effort": \(e.effort), "encodingTimeSeconds": \(String(format: "%.6f", e.encodingTimeSeconds)), "megapixelsPerSecond": \(String(format: "%.2f", e.megapixelsPerSecond)), "originalSize": \(e.originalSize), "compressedSize": \(e.compressedSize), "compressionRatio": \(String(format: "%.4f", e.compressionRatio)), "peakMemoryBytes": \(e.peakMemoryBytes)
        """

        if let psnr = e.psnr {
            fields += ", \"psnr\": \(String(format: "%.4f", psnr))"
        }
        if let ssim = e.ssim {
            fields += ", \"ssim\": \(String(format: "%.6f", ssim))"
        }
        if let b = e.butteraugli {
            fields += ", \"butteraugli\": \(String(format: "%.6f", b))"
        }

        fields += "}"
        return fields
    }

    private static func baselineJSON(_ b: PerformanceBaseline) -> String {
        let ts = ISO8601DateFormatter().string(from: b.timestamp)
        return """
        {"name": "\(escapeJSON(b.name))", "encodingTimeSeconds": \(String(format: "%.6f", b.encodingTimeSeconds)), "compressionRatio": \(String(format: "%.4f", b.compressionRatio)), "regressionThreshold": \(String(format: "%.4f", b.regressionThreshold)), "timestamp": "\(ts)"}
        """
    }

    private static func regressionJSON(_ r: RegressionAlert) -> String {
        return """
        {"name": "\(escapeJSON(r.name))", "metric": "\(escapeJSON(r.metric))", "baselineValue": \(String(format: "%.6f", r.baselineValue)), "currentValue": \(String(format: "%.6f", r.currentValue)), "regressionPercent": \(String(format: "%.2f", r.regressionPercent)), "threshold": \(String(format: "%.2f", r.threshold))}
        """
    }

    private static func summaryJSON(from report: BenchmarkReport) -> String {
        let entries = report.entries
        let count = entries.count
        let avgTime = count == 0 ? 0.0 : entries.map(\.encodingTimeSeconds).reduce(0, +) / Double(count)
        let avgRatio = count == 0 ? 0.0 : entries.map(\.compressionRatio).reduce(0, +) / Double(count)
        let regressionCount = report.regressions.count

        return """
        {"totalBenchmarks": \(count), "averageEncodingTimeSeconds": \(String(format: "%.6f", avgTime)), "averageCompressionRatio": \(String(format: "%.4f", avgRatio)), "regressionCount": \(regressionCount)}
        """
    }

    // MARK: - String Helpers

    private static func escapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Platform Helpers

/// Get a human-readable platform description.
public func platformDescription() -> String {
    #if os(macOS)
    return "macOS"
    #elseif os(iOS)
    return "iOS"
    #elseif os(tvOS)
    return "tvOS"
    #elseif os(watchOS)
    return "watchOS"
    #elseif os(visionOS)
    return "visionOS"
    #elseif os(Linux)
    return "Linux"
    #else
    return "Unknown"
    #endif
}

/// Get a human-readable architecture description.
public func architectureDescription() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}
