/// Validate subcommand — validate JXLSwift encoding quality and performance
///
/// Runs a validation suite encoding test images at various settings and
/// reports quality metrics, compression ratios, and performance baselines.
/// Outputs results in human-readable, JSON, or HTML format.

import ArgumentParser
import Foundation
import JXLSwift

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Validate encoding quality, compression, and performance"
    )

    @Option(name: .shortAndLong, help: "Image width for test images")
    var width: Int = 64

    @Option(name: .long, help: "Image height for test images")
    var height: Int = 64

    @Option(name: .shortAndLong, help: "Number of encoding iterations for timing")
    var iterations: Int = 3

    @Option(name: .shortAndLong, help: "Output format: text, json, or html")
    var format: String = "text"

    @Option(name: .shortAndLong, help: "Output file path (stdout if not specified)")
    var output: String?

    @Option(name: .long, help: "Minimum acceptable PSNR in dB")
    var minPSNR: Double = 30.0

    @Option(name: .long, help: "Minimum acceptable SSIM")
    var minSSIM: Double = 0.9

    @Option(name: .long, help: "Maximum acceptable encoding time in seconds")
    var maxTime: Double = 30.0

    @Flag(name: .long, help: "Include lossless mode validation")
    var includeLossless: Bool = false

    @Flag(name: .long, help: "Include all effort levels")
    var allEfforts: Bool = false

    @Flag(name: .long, help: "Run quality metrics comparison between original and encoded")
    var qualityMetrics: Bool = false

    func run() throws {
        // Build test cases
        var testCases: [ValidationHarness.TestCase] = []

        // Generate test images
        let gradientFrame = TestImageGenerator.gradient(width: width, height: height)
        let checkerFrame = TestImageGenerator.checkerboard(width: width, height: height)
        let noiseFrame = TestImageGenerator.noise(width: width, height: height)

        // Lossy test cases at default effort
        let lossyQualities: [Float] = [75, 85, 90, 95]
        for quality in lossyQualities {
            let options = EncodingOptions(
                mode: .lossy(quality: quality),
                effort: .squirrel
            )
            testCases.append(ValidationHarness.TestCase(
                name: "lossy_q\(Int(quality))_gradient",
                frame: gradientFrame,
                options: options
            ))
            testCases.append(ValidationHarness.TestCase(
                name: "lossy_q\(Int(quality))_checker",
                frame: checkerFrame,
                options: options
            ))
            testCases.append(ValidationHarness.TestCase(
                name: "lossy_q\(Int(quality))_noise",
                frame: noiseFrame,
                options: options
            ))
        }

        // Lossless test cases
        if includeLossless {
            let losslessOptions = EncodingOptions.lossless
            testCases.append(ValidationHarness.TestCase(
                name: "lossless_gradient",
                frame: gradientFrame,
                options: losslessOptions,
                isLossless: true
            ))
            testCases.append(ValidationHarness.TestCase(
                name: "lossless_checker",
                frame: checkerFrame,
                options: losslessOptions,
                isLossless: true
            ))
            testCases.append(ValidationHarness.TestCase(
                name: "lossless_noise",
                frame: noiseFrame,
                options: losslessOptions,
                isLossless: true
            ))
        }

        // All effort levels
        if allEfforts {
            let efforts: [(String, EncodingEffort)] = [
                ("lightning", .lightning),
                ("thunder", .thunder),
                ("falcon", .falcon),
                ("cheetah", .cheetah),
                ("hare", .hare),
                ("wombat", .wombat),
                ("squirrel", .squirrel),
                ("kitten", .kitten),
                ("tortoise", .tortoise),
            ]
            for (name, effort) in efforts {
                let options = EncodingOptions(
                    mode: .lossy(quality: 90),
                    effort: effort
                )
                testCases.append(ValidationHarness.TestCase(
                    name: "effort_\(name)_gradient",
                    frame: gradientFrame,
                    options: options
                ))
            }
        }

        // Run validation
        let criteria = ValidationCriteria(
            minPSNR: minPSNR,
            minSSIM: minSSIM,
            maxEncodingTime: maxTime
        )
        let harness = ValidationHarness(criteria: criteria, iterations: iterations)
        let report = try harness.validate(corpus: "synthetic-\(width)x\(height)", testCases: testCases)

        // Run quality metrics if requested
        if qualityMetrics {
            printQualityMetrics(gradientFrame: gradientFrame)
        }

        // Generate output
        let outputStr: String
        switch format.lowercased() {
        case "json":
            let benchmarkReport = convertToBenchmarkReport(report)
            outputStr = BenchmarkReportGenerator.generateJSON(from: benchmarkReport)
        case "html":
            let benchmarkReport = convertToBenchmarkReport(report)
            outputStr = BenchmarkReportGenerator.generateHTML(from: benchmarkReport)
        default:
            outputStr = formatTextReport(report)
        }

        // Write output
        if let outputPath = output {
            try outputStr.write(toFile: outputPath, atomically: true, encoding: .utf8)
            print("Report written to: \(outputPath)")
        } else {
            print(outputStr)
        }

        // Exit with error if any tests failed
        if !report.summary.allPassed {
            throw ExitCode.failure
        }
    }

    // MARK: - Quality Metrics

    private func printQualityMetrics(gradientFrame: ImageFrame) {
        print()
        print("=== Quality Metrics (Self-Comparison) ===")
        print()

        // Compare frame with itself (should be perfect)
        do {
            let result = try QualityMetrics.compare(original: gradientFrame, reconstructed: gradientFrame)
            print("Identical frames:")
            print(String(format: "  PSNR:        %s dB", result.psnr.isInfinite ? "∞" : String(format: "%.2f", result.psnr)))
            print(String(format: "  SSIM:        %.6f", result.ssim))
            print(String(format: "  MS-SSIM:     %.6f", result.msSSIM))
            print(String(format: "  Butteraugli: %.6f", result.butteraugli))
        } catch {
            print("Error computing quality metrics: \(error)")
        }

        // Compare with a slightly modified version
        var modifiedFrame = ImageFrame(
            width: gradientFrame.width,
            height: gradientFrame.height,
            channels: gradientFrame.channels,
            pixelType: gradientFrame.pixelType,
            colorSpace: gradientFrame.colorSpace
        )

        for y in 0..<gradientFrame.height {
            for x in 0..<gradientFrame.width {
                for c in 0..<gradientFrame.channels {
                    var value = gradientFrame.getPixel(x: x, y: y, channel: c)
                    // Add small perturbation
                    if (x + y) % 4 == 0 {
                        value = UInt16(min(255, Int(value) + 5))
                    }
                    modifiedFrame.setPixel(x: x, y: y, channel: c, value: value)
                }
            }
        }

        do {
            let result = try QualityMetrics.compare(original: gradientFrame, reconstructed: modifiedFrame)
            print()
            print("Slightly modified frames:")
            print(String(format: "  PSNR:        %.2f dB", result.psnr))
            print(String(format: "  SSIM:        %.6f", result.ssim))
            print(String(format: "  MS-SSIM:     %.6f", result.msSSIM))
            print(String(format: "  Butteraugli: %.6f", result.butteraugli))
        } catch {
            print("Error computing quality metrics: \(error)")
        }
    }

    // MARK: - Report Formatting

    private func formatTextReport(_ report: ValidationReport) -> String {
        var lines: [String] = []
        let summary = report.summary

        lines.append("=== JXLSwift Validation Report ===")
        lines.append("")
        lines.append("Corpus: \(report.corpus)")
        lines.append("Tests: \(summary.totalTests) (✅ \(summary.passed) passed, ❌ \(summary.failed) failed)")
        lines.append("")

        lines.append(String(format: "%-35s %10s %10s %10s %8s",
            "Test", "Time(ms)", "Ratio", "Size(B)", "Status"))
        lines.append(String(repeating: "─", count: 78))

        for result in report.results {
            let status = result.passed ? "✅" : "❌"
            let timeStr = result.performanceResult.map { String(format: "%.1f", $0.encodingTimeSeconds * 1000) } ?? "—"
            let ratioStr = result.compressionResult.map { String(format: "%.2f×", $0.compressionRatio) } ?? "—"
            let sizeStr = result.compressionResult.map { "\($0.compressedSize)" } ?? "—"

            lines.append(String(format: "%-35s %10s %10s %10s %8s",
                String(result.name.prefix(35)),
                timeStr,
                ratioStr,
                sizeStr,
                status
            ))
        }

        // Failed tests details
        let failedResults = report.results.filter { !$0.passed }
        if !failedResults.isEmpty {
            lines.append("")
            lines.append("=== Failed Tests ===")
            for result in failedResults {
                lines.append("  \(result.name):")
                for reason in result.failureReasons {
                    lines.append("    - \(reason)")
                }
            }
        }

        lines.append("")
        lines.append("Summary:")
        lines.append(String(format: "  Average encoding time: %.1f ms", summary.averageEncodingTime * 1000))
        lines.append(String(format: "  Average compression ratio: %.2f×", summary.averageCompressionRatio))
        if summary.averagePSNR.isFinite {
            lines.append(String(format: "  Average PSNR: %.2f dB", summary.averagePSNR))
        }
        lines.append(String(format: "  Average SSIM: %.4f", summary.averageSSIM))

        return lines.joined(separator: "\n")
    }

    // MARK: - Report Conversion

    private func convertToBenchmarkReport(_ report: ValidationReport) -> BenchmarkReport {
        let entries = report.results.map { result -> BenchmarkEntry in
            BenchmarkEntry(
                name: result.name,
                width: result.width,
                height: result.height,
                mode: result.optionsDescription,
                effort: 7,
                encodingTimeSeconds: result.performanceResult?.encodingTimeSeconds ?? 0,
                megapixelsPerSecond: result.performanceResult?.megapixelsPerSecond ?? 0,
                originalSize: result.compressionResult?.originalSize ?? 0,
                compressedSize: result.compressionResult?.compressedSize ?? 0,
                compressionRatio: result.compressionResult?.compressionRatio ?? 0,
                peakMemoryBytes: result.performanceResult?.peakMemoryBytes ?? 0,
                psnr: result.qualityResult?.psnr,
                ssim: result.qualityResult?.ssim,
                butteraugli: result.qualityResult?.butteraugli
            )
        }

        return BenchmarkReport(
            metadata: ReportMetadata(),
            entries: entries,
            baselines: []
        )
    }
}
