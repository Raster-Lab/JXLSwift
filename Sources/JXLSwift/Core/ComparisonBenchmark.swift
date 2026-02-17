/// Comparison benchmarking for speed, compression ratio, and memory usage
///
/// Provides structured comparison infrastructure for evaluating JXLSwift encoding
/// performance across effort levels, quality settings, and memory consumption.
/// Used for Milestone 11 validation against reference baselines.

import Foundation

// MARK: - Speed Comparison

/// Result of comparing encoding speed across effort levels.
public struct SpeedComparisonResult: Sendable {
    /// Individual effort level measurements
    public let measurements: [EffortMeasurement]

    /// Overall statistics
    public var summary: SpeedSummary {
        guard !measurements.isEmpty else {
            return SpeedSummary(
                fastestEffort: .lightning,
                slowestEffort: .tortoise,
                fastestTimeSeconds: 0,
                slowestTimeSeconds: 0,
                speedRange: 0
            )
        }
        let sorted = measurements.sorted { $0.averageTimeSeconds < $1.averageTimeSeconds }
        let fastest = sorted.first!
        let slowest = sorted.last!
        return SpeedSummary(
            fastestEffort: fastest.effort,
            slowestEffort: slowest.effort,
            fastestTimeSeconds: fastest.averageTimeSeconds,
            slowestTimeSeconds: slowest.averageTimeSeconds,
            speedRange: slowest.averageTimeSeconds / max(fastest.averageTimeSeconds, 1e-9)
        )
    }
}

/// Measurement for a single effort level.
public struct EffortMeasurement: Sendable {
    /// Effort level used
    public let effort: EncodingEffort

    /// Average encoding time in seconds
    public let averageTimeSeconds: Double

    /// Megapixels per second throughput
    public let megapixelsPerSecond: Double

    /// Compressed size in bytes
    public let compressedSize: Int

    /// Compression ratio achieved
    public let compressionRatio: Double

    /// Individual iteration times
    public let iterationTimes: [Double]
}

/// Summary of speed comparison across effort levels.
public struct SpeedSummary: Sendable {
    /// Fastest effort level
    public let fastestEffort: EncodingEffort

    /// Slowest effort level
    public let slowestEffort: EncodingEffort

    /// Fastest encoding time in seconds
    public let fastestTimeSeconds: Double

    /// Slowest encoding time in seconds
    public let slowestTimeSeconds: Double

    /// Speed range (slowest / fastest ratio)
    public let speedRange: Double
}

// MARK: - Compression Ratio Comparison

/// Result of comparing compression ratios across quality levels.
public struct CompressionComparisonResult: Sendable {
    /// Individual quality level measurements
    public let measurements: [QualityMeasurement]

    /// Overall statistics
    public var summary: CompressionSummary {
        guard !measurements.isEmpty else {
            return CompressionSummary(
                bestRatioQuality: 0,
                worstRatioQuality: 0,
                bestCompressionRatio: 0,
                worstCompressionRatio: 0,
                averageCompressionRatio: 0
            )
        }
        let sorted = measurements.sorted { $0.compressionRatio > $1.compressionRatio }
        let best = sorted.first!
        let worst = sorted.last!
        let avgRatio = measurements.map(\.compressionRatio).reduce(0, +) / Double(measurements.count)
        return CompressionSummary(
            bestRatioQuality: best.quality,
            worstRatioQuality: worst.quality,
            bestCompressionRatio: best.compressionRatio,
            worstCompressionRatio: worst.compressionRatio,
            averageCompressionRatio: avgRatio
        )
    }
}

/// Measurement for a single quality level.
public struct QualityMeasurement: Sendable {
    /// Quality level (0-100)
    public let quality: Float

    /// Original size in bytes
    public let originalSize: Int

    /// Compressed size in bytes
    public let compressedSize: Int

    /// Compression ratio (original / compressed)
    public let compressionRatio: Double

    /// Encoding time in seconds
    public let encodingTimeSeconds: Double

    /// Bits per pixel
    public var bitsPerPixel: Double {
        guard originalSize > 0 else { return 0 }
        return Double(compressedSize * 8) / Double(originalSize)
    }
}

/// Summary of compression ratio comparison.
public struct CompressionSummary: Sendable {
    /// Quality level with best compression ratio
    public let bestRatioQuality: Float

    /// Quality level with worst compression ratio
    public let worstRatioQuality: Float

    /// Best (highest) compression ratio
    public let bestCompressionRatio: Double

    /// Worst (lowest) compression ratio
    public let worstCompressionRatio: Double

    /// Average compression ratio across all quality levels
    public let averageCompressionRatio: Double
}

// MARK: - Memory Usage Comparison

/// Result of measuring memory usage during encoding.
public struct MemoryComparisonResult: Sendable {
    /// Individual memory measurements
    public let measurements: [MemoryMeasurement]

    /// Overall statistics
    public var summary: MemorySummary {
        guard !measurements.isEmpty else {
            return MemorySummary(
                peakMemoryBytes: 0,
                averageMemoryBytes: 0,
                minMemoryBytes: 0,
                memoryPerMegapixel: 0
            )
        }
        let peak = measurements.map(\.peakMemoryBytes).max() ?? 0
        let avg = measurements.map(\.peakMemoryBytes).reduce(0, +) / measurements.count
        let min = measurements.map(\.peakMemoryBytes).min() ?? 0
        let totalMegapixels = measurements.map(\.megapixels).reduce(0.0, +)
        let memPerMP = totalMegapixels > 0 ? Double(peak) / totalMegapixels : 0
        return MemorySummary(
            peakMemoryBytes: peak,
            averageMemoryBytes: avg,
            minMemoryBytes: min,
            memoryPerMegapixel: memPerMP
        )
    }
}

/// Memory measurement for a single encoding run.
public struct MemoryMeasurement: Sendable {
    /// Description of the test configuration
    public let name: String

    /// Image width
    public let width: Int

    /// Image height
    public let height: Int

    /// Compression mode description
    public let mode: String

    /// Memory usage before encoding (bytes)
    public let memoryBeforeBytes: Int

    /// Memory usage after encoding (bytes)
    public let memoryAfterBytes: Int

    /// Peak memory usage during encoding (bytes)
    public let peakMemoryBytes: Int

    /// Encoding time in seconds
    public let encodingTimeSeconds: Double

    /// Megapixels in the image
    public var megapixels: Double {
        Double(width * height) / 1_000_000.0
    }

    /// Memory used specifically for encoding (after - before), in bytes
    public var encodingMemoryBytes: Int {
        max(0, memoryAfterBytes - memoryBeforeBytes)
    }
}

/// Summary of memory usage comparison.
public struct MemorySummary: Sendable {
    /// Peak memory usage across all measurements (bytes)
    public let peakMemoryBytes: Int

    /// Average memory usage across all measurements (bytes)
    public let averageMemoryBytes: Int

    /// Minimum memory usage across all measurements (bytes)
    public let minMemoryBytes: Int

    /// Approximate bytes per megapixel at peak
    public let memoryPerMegapixel: Double
}

// MARK: - Comparison Benchmark Runner

/// Runs systematic comparison benchmarks for speed, compression, and memory.
///
/// Provides methods to measure encoding performance across different effort levels,
/// quality settings, and image sizes, producing structured results suitable for
/// CI regression tracking and report generation.
///
/// # Usage
/// ```swift
/// let runner = ComparisonBenchmark(iterations: 3)
/// let frame = TestImageGenerator.gradient(width: 256, height: 256)
///
/// let speedResult = try runner.compareSpeed(frame: frame)
/// let compressionResult = try runner.compareCompression(frame: frame)
/// let memoryResult = try runner.compareMemory(frames: [frame])
/// ```
public class ComparisonBenchmark {
    /// Number of iterations for timing measurements
    public let iterations: Int

    /// Initialize a comparison benchmark runner.
    /// - Parameter iterations: Number of encoding iterations for each measurement (default: 3)
    public init(iterations: Int = 3) {
        self.iterations = max(1, iterations)
    }

    // MARK: - Speed Comparison

    /// Compare encoding speed across all effort levels.
    /// - Parameters:
    ///   - frame: Image frame to encode
    ///   - quality: Quality level for lossy encoding (default: 90)
    ///   - efforts: Effort levels to compare (default: all 9 levels)
    /// - Returns: Speed comparison result with measurements for each effort level
    /// - Throws: If encoding fails
    public func compareSpeed(
        frame: ImageFrame,
        quality: Float = 90,
        efforts: [EncodingEffort] = [
            .lightning, .thunder, .falcon, .cheetah, .hare,
            .wombat, .squirrel, .kitten, .tortoise
        ]
    ) throws -> SpeedComparisonResult {
        let megapixels = Double(frame.width * frame.height) / 1_000_000.0
        var measurements: [EffortMeasurement] = []

        for effort in efforts {
            let options = EncodingOptions(
                mode: .lossy(quality: quality),
                effort: effort
            )
            let encoder = JXLEncoder(options: options)

            var iterationTimes: [Double] = []
            var lastResult: EncodedImage?

            for _ in 0..<iterations {
                let start = ProcessInfo.processInfo.systemUptime
                let result = try encoder.encode(frame)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                iterationTimes.append(elapsed)
                lastResult = result
            }

            let avgTime = iterationTimes.reduce(0, +) / Double(iterations)
            let mpps = megapixels / max(avgTime, 1e-9)

            if let result = lastResult {
                measurements.append(EffortMeasurement(
                    effort: effort,
                    averageTimeSeconds: avgTime,
                    megapixelsPerSecond: mpps,
                    compressedSize: result.stats.compressedSize,
                    compressionRatio: result.stats.compressionRatio,
                    iterationTimes: iterationTimes
                ))
            }
        }

        return SpeedComparisonResult(measurements: measurements)
    }

    // MARK: - Compression Ratio Comparison

    /// Compare compression ratios across quality levels.
    /// - Parameters:
    ///   - frame: Image frame to encode
    ///   - qualities: Quality levels to compare (default: standard range)
    ///   - effort: Effort level to use (default: squirrel)
    /// - Returns: Compression comparison result with measurements for each quality level
    /// - Throws: If encoding fails
    public func compareCompression(
        frame: ImageFrame,
        qualities: [Float] = [10, 25, 50, 75, 85, 90, 95, 100],
        effort: EncodingEffort = .squirrel
    ) throws -> CompressionComparisonResult {
        var measurements: [QualityMeasurement] = []

        for quality in qualities {
            let options = EncodingOptions(
                mode: .lossy(quality: quality),
                effort: effort
            )
            let encoder = JXLEncoder(options: options)

            let start = ProcessInfo.processInfo.systemUptime
            let result = try encoder.encode(frame)
            let elapsed = ProcessInfo.processInfo.systemUptime - start

            measurements.append(QualityMeasurement(
                quality: quality,
                originalSize: result.stats.originalSize,
                compressedSize: result.stats.compressedSize,
                compressionRatio: result.stats.compressionRatio,
                encodingTimeSeconds: elapsed
            ))
        }

        return CompressionComparisonResult(measurements: measurements)
    }

    // MARK: - Memory Usage Comparison

    /// Measure memory usage during encoding for various configurations.
    /// - Parameter frames: Array of (name, frame, options) tuples to measure
    /// - Returns: Memory comparison result with measurements for each configuration
    /// - Throws: If encoding fails
    public func compareMemory(
        configurations: [(name: String, frame: ImageFrame, options: EncodingOptions)]
    ) throws -> MemoryComparisonResult {
        var measurements: [MemoryMeasurement] = []

        for config in configurations {
            let encoder = JXLEncoder(options: config.options)

            let memBefore = currentMemoryUsage()
            let start = ProcessInfo.processInfo.systemUptime
            _ = try encoder.encode(config.frame)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let memAfter = currentMemoryUsage()

            let modeStr: String
            switch config.options.mode {
            case .lossless: modeStr = "lossless"
            case .lossy(let q): modeStr = "lossy(q=\(q))"
            case .distance(let d): modeStr = "distance(\(d))"
            }

            measurements.append(MemoryMeasurement(
                name: config.name,
                width: config.frame.width,
                height: config.frame.height,
                mode: modeStr,
                memoryBeforeBytes: memBefore,
                memoryAfterBytes: memAfter,
                peakMemoryBytes: max(memBefore, memAfter),
                encodingTimeSeconds: elapsed
            ))
        }

        return MemoryComparisonResult(measurements: measurements)
    }

    // MARK: - Memory Tracking

    /// Get current process memory usage in bytes.
    /// - Returns: Resident memory size in bytes
    public static func currentProcessMemory() -> Int {
        currentMemoryUsageStatic()
    }
}

// MARK: - Memory Usage Helpers

/// Get current process memory usage in bytes using Darwin task_info.
private func currentMemoryUsage() -> Int {
    currentMemoryUsageStatic()
}

/// Static version of memory usage query.
private func currentMemoryUsageStatic() -> Int {
    #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rawPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rawPtr, &count)
        }
    }
    if result == KERN_SUCCESS {
        return Int(info.resident_size)
    }
    return 0
    #else
    // Linux fallback: read from /proc/self/status
    if let contents = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) {
        for line in contents.split(separator: "\n") {
            if line.hasPrefix("VmRSS:") {
                let parts = line.split(separator: " ")
                if parts.count >= 2, let kb = Int(parts[1]) {
                    return kb * 1024
                }
            }
        }
    }
    return 0
    #endif
}

// MARK: - Test Image Corpus

/// Standard test image corpus for systematic validation.
///
/// Provides a collection of synthetic test images that mimic the characteristics
/// of standard test image corpora (Kodak, Tecnick, Wikipedia) for reproducible
/// benchmarking without requiring external image files.
///
/// The corpus includes images with varying characteristics:
/// - Smooth gradients (tests predictor efficiency)
/// - Sharp edges (tests DCT ringing)
/// - Natural-like textures (tests entropy coding)
/// - Flat regions (tests run-length encoding)
/// - Mixed content (tests adaptive quantization)
public enum TestImageCorpus {

    /// A single corpus image with metadata.
    public struct CorpusImage {
        /// Image identifier
        public let id: String

        /// Human-readable description
        public let description: String

        /// Image category
        public let category: ImageCategory

        /// The image frame
        public let frame: ImageFrame

        /// Expected compression characteristics
        public let characteristics: ImageCharacteristics
    }

    /// Category of a corpus image.
    public enum ImageCategory: String, Sendable, CaseIterable {
        /// Smooth color gradients
        case gradient = "gradient"
        /// Sharp edges and high contrast
        case edges = "edges"
        /// Natural-looking texture patterns
        case texture = "texture"
        /// Flat or near-uniform regions
        case flat = "flat"
        /// Mixed content types
        case mixed = "mixed"
        /// Screen content (text, UI elements)
        case screen = "screen"
    }

    /// Expected characteristics for a corpus image.
    public struct ImageCharacteristics: Sendable {
        /// Expected approximate compression ratio range (lossy, q=90)
        public let expectedCompressionRange: ClosedRange<Double>
        /// Spatial complexity (0.0 = flat, 1.0 = highly complex)
        public let spatialComplexity: Double
        /// Frequency complexity (0.0 = smooth, 1.0 = high frequency)
        public let frequencyComplexity: Double
    }

    // MARK: - Corpus Generation

    /// Generate the standard Kodak-like test corpus.
    ///
    /// Produces 8 synthetic images mimicking characteristics of the Kodak
    /// PhotoCD test set: varied natural images at 768×512 resolution.
    /// - Parameters:
    ///   - width: Image width (default: 128 for fast testing)
    ///   - height: Image height (default: 128 for fast testing)
    /// - Returns: Array of corpus images
    public static func kodakLike(width: Int = 128, height: Int = 128) -> [CorpusImage] {
        [
            CorpusImage(
                id: "kodak_gradient_smooth",
                description: "Smooth diagonal gradient (sky-like)",
                category: .gradient,
                frame: generateSmoothGradient(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 5.0...30.0,
                    spatialComplexity: 0.1,
                    frequencyComplexity: 0.05
                )
            ),
            CorpusImage(
                id: "kodak_gradient_radial",
                description: "Radial gradient (vignette-like)",
                category: .gradient,
                frame: generateRadialGradient(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 4.0...25.0,
                    spatialComplexity: 0.15,
                    frequencyComplexity: 0.1
                )
            ),
            CorpusImage(
                id: "kodak_edges_checker",
                description: "High-contrast checkerboard pattern",
                category: .edges,
                frame: TestImageGenerator.checkerboard(width: width, height: height, blockSize: 8),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 2.0...15.0,
                    spatialComplexity: 0.8,
                    frequencyComplexity: 0.9
                )
            ),
            CorpusImage(
                id: "kodak_edges_stripes",
                description: "Alternating color stripes",
                category: .edges,
                frame: generateStripes(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 3.0...20.0,
                    spatialComplexity: 0.7,
                    frequencyComplexity: 0.8
                )
            ),
            CorpusImage(
                id: "kodak_texture_noise",
                description: "Pseudo-random noise (natural texture)",
                category: .texture,
                frame: TestImageGenerator.noise(width: width, height: height, seed: 12345),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 1.0...5.0,
                    spatialComplexity: 0.95,
                    frequencyComplexity: 0.95
                )
            ),
            CorpusImage(
                id: "kodak_texture_perlin",
                description: "Smooth noise (cloud-like texture)",
                category: .texture,
                frame: generatePerlinLike(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 2.0...15.0,
                    spatialComplexity: 0.5,
                    frequencyComplexity: 0.4
                )
            ),
            CorpusImage(
                id: "kodak_flat_solid",
                description: "Solid color region",
                category: .flat,
                frame: TestImageGenerator.solid(width: width, height: height, color: [128, 96, 64]),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 10.0...100.0,
                    spatialComplexity: 0.0,
                    frequencyComplexity: 0.0
                )
            ),
            CorpusImage(
                id: "kodak_mixed_blocks",
                description: "Mixed content blocks (flat + edges + gradient)",
                category: .mixed,
                frame: generateMixedContent(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 2.0...20.0,
                    spatialComplexity: 0.6,
                    frequencyComplexity: 0.5
                )
            ),
        ]
    }

    /// Generate the standard Tecnick-like test corpus.
    ///
    /// Produces 4 synthetic images mimicking characteristics of the Tecnick
    /// test set: high-resolution images with challenging content.
    /// - Parameters:
    ///   - width: Image width (default: 128 for fast testing)
    ///   - height: Image height (default: 128 for fast testing)
    /// - Returns: Array of corpus images
    public static func tecnickLike(width: Int = 128, height: Int = 128) -> [CorpusImage] {
        [
            CorpusImage(
                id: "tecnick_color_bars",
                description: "Color bar test pattern",
                category: .edges,
                frame: generateColorBars(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 3.0...20.0,
                    spatialComplexity: 0.6,
                    frequencyComplexity: 0.7
                )
            ),
            CorpusImage(
                id: "tecnick_zone_plate",
                description: "Zone plate (frequency sweep)",
                category: .texture,
                frame: generateZonePlate(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 1.5...10.0,
                    spatialComplexity: 0.7,
                    frequencyComplexity: 0.85
                )
            ),
            CorpusImage(
                id: "tecnick_gradient_fine",
                description: "Fine gradient with subtle color transitions",
                category: .gradient,
                frame: generateFineGradient(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 3.0...25.0,
                    spatialComplexity: 0.2,
                    frequencyComplexity: 0.15
                )
            ),
            CorpusImage(
                id: "tecnick_screen_ui",
                description: "Simulated screen/UI content",
                category: .screen,
                frame: generateScreenContent(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 3.0...30.0,
                    spatialComplexity: 0.5,
                    frequencyComplexity: 0.6
                )
            ),
        ]
    }

    /// Generate the standard Wikipedia-like test corpus.
    ///
    /// Produces 4 synthetic images mimicking characteristics of images
    /// commonly found on Wikipedia: diagrams, photographs, illustrations.
    /// - Parameters:
    ///   - width: Image width (default: 128 for fast testing)
    ///   - height: Image height (default: 128 for fast testing)
    /// - Returns: Array of corpus images
    public static func wikipediaLike(width: Int = 128, height: Int = 128) -> [CorpusImage] {
        [
            CorpusImage(
                id: "wiki_diagram",
                description: "Diagram-like content (lines on white)",
                category: .screen,
                frame: generateDiagram(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 5.0...40.0,
                    spatialComplexity: 0.3,
                    frequencyComplexity: 0.4
                )
            ),
            CorpusImage(
                id: "wiki_photo_nature",
                description: "Nature photograph simulation (gradients + noise)",
                category: .mixed,
                frame: generateNaturePhoto(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 2.0...15.0,
                    spatialComplexity: 0.5,
                    frequencyComplexity: 0.45
                )
            ),
            CorpusImage(
                id: "wiki_illustration",
                description: "Illustration (flat areas with sharp edges)",
                category: .mixed,
                frame: generateIllustration(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 4.0...30.0,
                    spatialComplexity: 0.4,
                    frequencyComplexity: 0.5
                )
            ),
            CorpusImage(
                id: "wiki_text_heavy",
                description: "Text-heavy content simulation",
                category: .screen,
                frame: generateTextHeavy(width: width, height: height),
                characteristics: ImageCharacteristics(
                    expectedCompressionRange: 5.0...35.0,
                    spatialComplexity: 0.35,
                    frequencyComplexity: 0.45
                )
            ),
        ]
    }

    /// Generate the complete test corpus including all categories.
    /// - Parameters:
    ///   - width: Image width (default: 128 for fast testing)
    ///   - height: Image height (default: 128 for fast testing)
    /// - Returns: Combined array of all corpus images
    public static func fullCorpus(width: Int = 128, height: Int = 128) -> [CorpusImage] {
        kodakLike(width: width, height: height) +
        tecnickLike(width: width, height: height) +
        wikipediaLike(width: width, height: height)
    }

    // MARK: - Image Generation Helpers

    /// Generate a smooth diagonal gradient.
    private static func generateSmoothGradient(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        for y in 0..<height {
            for x in 0..<width {
                let t = Double(x + y) / Double(max(width + height - 2, 1))
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(t * 200 + 30))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(t * 150 + 50))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((1.0 - t) * 180 + 40))
            }
        }
        return frame
    }

    /// Generate a radial gradient from center.
    private static func generateRadialGradient(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        let cx = Double(width) / 2.0
        let cy = Double(height) / 2.0
        let maxDist = sqrt(cx * cx + cy * cy)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                let dist = sqrt(dx * dx + dy * dy)
                let t = min(1.0, dist / maxDist)
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((1.0 - t) * 255))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16((1.0 - t) * 220))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((1.0 - t) * 200))
            }
        }
        return frame
    }

    /// Generate alternating color stripes.
    private static func generateStripes(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        let stripeWidth = max(1, width / 16)
        for y in 0..<height {
            for x in 0..<width {
                let stripe = (x / stripeWidth) % 4
                let colors: [(UInt16, UInt16, UInt16)] = [
                    (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)
                ]
                let c = colors[stripe]
                frame.setPixel(x: x, y: y, channel: 0, value: c.0)
                frame.setPixel(x: x, y: y, channel: 1, value: c.1)
                frame.setPixel(x: x, y: y, channel: 2, value: c.2)
            }
        }
        return frame
    }

    /// Generate Perlin-like smooth noise.
    private static func generatePerlinLike(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        let scale = 8.0
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x) / Double(max(width - 1, 1)) * scale
                let fy = Double(y) / Double(max(height - 1, 1)) * scale
                // Simple smooth noise approximation using sine waves
                let v1 = sin(fx * 1.7 + fy * 0.9) * 0.5 + 0.5
                let v2 = sin(fx * 0.8 + fy * 2.1 + 1.5) * 0.5 + 0.5
                let v3 = sin(fx * 1.3 + fy * 1.5 + 3.0) * 0.5 + 0.5
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(v1 * 255))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(v2 * 255))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(v3 * 255))
            }
        }
        return frame
    }

    /// Generate mixed content blocks.
    private static func generateMixedContent(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        let halfW = width / 2
        let halfH = height / 2
        var rng: UInt64 = 42
        for y in 0..<height {
            for x in 0..<width {
                let r: UInt16
                let g: UInt16
                let b: UInt16
                if x < halfW && y < halfH {
                    // Top-left: gradient
                    let t = Double(x + y) / Double(max(halfW + halfH - 2, 1))
                    r = UInt16(t * 255)
                    g = UInt16(t * 200)
                    b = UInt16(t * 150)
                } else if x >= halfW && y < halfH {
                    // Top-right: checkerboard
                    let isWhite = ((x / 4) + (y / 4)) % 2 == 0
                    let val: UInt16 = isWhite ? 255 : 0
                    r = val; g = val; b = val
                } else if x < halfW && y >= halfH {
                    // Bottom-left: solid
                    r = 100; g = 150; b = 200
                } else {
                    // Bottom-right: noise
                    rng ^= rng >> 12
                    rng ^= rng << 25
                    rng ^= rng >> 27
                    r = UInt16((rng &* 0x2545F4914F6CDD1D) >> 56)
                    rng ^= rng >> 12
                    rng ^= rng << 25
                    rng ^= rng >> 27
                    g = UInt16((rng &* 0x2545F4914F6CDD1D) >> 56)
                    rng ^= rng >> 12
                    rng ^= rng << 25
                    rng ^= rng >> 27
                    b = UInt16((rng &* 0x2545F4914F6CDD1D) >> 56)
                }
                frame.setPixel(x: x, y: y, channel: 0, value: r)
                frame.setPixel(x: x, y: y, channel: 1, value: g)
                frame.setPixel(x: x, y: y, channel: 2, value: b)
            }
        }
        return frame
    }

    /// Generate color bar test pattern.
    private static func generateColorBars(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        let barColors: [(UInt16, UInt16, UInt16)] = [
            (255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
            (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)
        ]
        let barWidth = max(1, width / barColors.count)
        for y in 0..<height {
            for x in 0..<width {
                let barIdx = min(x / barWidth, barColors.count - 1)
                let c = barColors[barIdx]
                frame.setPixel(x: x, y: y, channel: 0, value: c.0)
                frame.setPixel(x: x, y: y, channel: 1, value: c.1)
                frame.setPixel(x: x, y: y, channel: 2, value: c.2)
            }
        }
        return frame
    }

    /// Generate zone plate (frequency sweep pattern).
    private static func generateZonePlate(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        let cx = Double(width) / 2.0
        let cy = Double(height) / 2.0
        let maxR = sqrt(cx * cx + cy * cy)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                let r = sqrt(dx * dx + dy * dy)
                let freq = r / maxR * 20.0
                let val = UInt16((sin(freq * r * 0.1) * 0.5 + 0.5) * 255)
                frame.setPixel(x: x, y: y, channel: 0, value: val)
                frame.setPixel(x: x, y: y, channel: 1, value: val)
                frame.setPixel(x: x, y: y, channel: 2, value: val)
            }
        }
        return frame
    }

    /// Generate fine gradient with subtle transitions.
    private static func generateFineGradient(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        for y in 0..<height {
            for x in 0..<width {
                let tx = Double(x) / Double(max(width - 1, 1))
                let ty = Double(y) / Double(max(height - 1, 1))
                let r = UInt16(tx * 10 + 120)
                let g = UInt16(ty * 10 + 125)
                let b = UInt16((tx + ty) * 5 + 130)
                frame.setPixel(x: x, y: y, channel: 0, value: r)
                frame.setPixel(x: x, y: y, channel: 1, value: g)
                frame.setPixel(x: x, y: y, channel: 2, value: b)
            }
        }
        return frame
    }

    /// Generate simulated screen/UI content.
    private static func generateScreenContent(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        // White background
        for y in 0..<height {
            for x in 0..<width {
                frame.setPixel(x: x, y: y, channel: 0, value: 245)
                frame.setPixel(x: x, y: y, channel: 1, value: 245)
                frame.setPixel(x: x, y: y, channel: 2, value: 245)
            }
        }
        // Dark header bar
        let headerH = max(1, height / 8)
        for y in 0..<headerH {
            for x in 0..<width {
                frame.setPixel(x: x, y: y, channel: 0, value: 50)
                frame.setPixel(x: x, y: y, channel: 1, value: 50)
                frame.setPixel(x: x, y: y, channel: 2, value: 60)
            }
        }
        // Colored button-like rectangle
        let btnX = width / 4
        let btnY = height / 2
        let btnW = width / 2
        let btnH = max(1, height / 10)
        for y in btnY..<min(btnY + btnH, height) {
            for x in btnX..<min(btnX + btnW, width) {
                frame.setPixel(x: x, y: y, channel: 0, value: 30)
                frame.setPixel(x: x, y: y, channel: 1, value: 120)
                frame.setPixel(x: x, y: y, channel: 2, value: 230)
            }
        }
        return frame
    }

    /// Generate diagram-like content.
    private static func generateDiagram(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        // White background
        for y in 0..<height {
            for x in 0..<width {
                frame.setPixel(x: x, y: y, channel: 0, value: 255)
                frame.setPixel(x: x, y: y, channel: 1, value: 255)
                frame.setPixel(x: x, y: y, channel: 2, value: 255)
            }
        }
        // Horizontal lines
        let lineSpacing = max(1, height / 8)
        for lineY in stride(from: lineSpacing, to: height, by: lineSpacing) {
            for x in 0..<width {
                let y = min(lineY, height - 1)
                frame.setPixel(x: x, y: y, channel: 0, value: 0)
                frame.setPixel(x: x, y: y, channel: 1, value: 0)
                frame.setPixel(x: x, y: y, channel: 2, value: 0)
            }
        }
        // Vertical lines
        let vLineSpacing = max(1, width / 8)
        for lineX in stride(from: vLineSpacing, to: width, by: vLineSpacing) {
            for y in 0..<height {
                let x = min(lineX, width - 1)
                frame.setPixel(x: x, y: y, channel: 0, value: 0)
                frame.setPixel(x: x, y: y, channel: 1, value: 0)
                frame.setPixel(x: x, y: y, channel: 2, value: 0)
            }
        }
        // Colored rectangles
        let rectW = max(1, width / 4)
        let rectH = max(1, height / 4)
        for y in (height / 4)..<min(height / 4 + rectH, height) {
            for x in (width / 4)..<min(width / 4 + rectW, width) {
                frame.setPixel(x: x, y: y, channel: 0, value: 200)
                frame.setPixel(x: x, y: y, channel: 1, value: 220)
                frame.setPixel(x: x, y: y, channel: 2, value: 240)
            }
        }
        return frame
    }

    /// Generate nature photograph simulation.
    private static func generateNaturePhoto(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        var rng: UInt64 = 7654321
        for y in 0..<height {
            for x in 0..<width {
                let ty = Double(y) / Double(max(height - 1, 1))
                // Sky (top) to ground (bottom) gradient
                let baseR = (1.0 - ty) * 135 + ty * 34
                let baseG = (1.0 - ty) * 206 + ty * 139
                let baseB = (1.0 - ty) * 235 + ty * 34
                // Add slight texture noise
                rng ^= rng >> 12
                rng ^= rng << 25
                rng ^= rng >> 27
                let noise = Double(Int((rng &* 0x2545F4914F6CDD1D) >> 56) - 128) * 0.1
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(max(0, min(255, baseR + noise))))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(max(0, min(255, baseG + noise))))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16(max(0, min(255, baseB + noise))))
            }
        }
        return frame
    }

    /// Generate illustration-like content (flat areas with sharp edges).
    private static func generateIllustration(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        let cx = Double(width) / 2.0
        let cy = Double(height) / 2.0
        let radius = Double(min(width, height)) / 3.0
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                let dist = sqrt(dx * dx + dy * dy)
                if dist < radius {
                    // Inside circle: flat blue
                    frame.setPixel(x: x, y: y, channel: 0, value: 65)
                    frame.setPixel(x: x, y: y, channel: 1, value: 105)
                    frame.setPixel(x: x, y: y, channel: 2, value: 225)
                } else {
                    // Outside: pale yellow background
                    frame.setPixel(x: x, y: y, channel: 0, value: 255)
                    frame.setPixel(x: x, y: y, channel: 1, value: 248)
                    frame.setPixel(x: x, y: y, channel: 2, value: 220)
                }
            }
        }
        return frame
    }

    /// Generate text-heavy content simulation.
    private static func generateTextHeavy(width: Int, height: Int) -> ImageFrame {
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint8, colorSpace: .sRGB
        )
        // White background
        for y in 0..<height {
            for x in 0..<width {
                frame.setPixel(x: x, y: y, channel: 0, value: 255)
                frame.setPixel(x: x, y: y, channel: 1, value: 255)
                frame.setPixel(x: x, y: y, channel: 2, value: 255)
            }
        }
        // Simulate text lines as thin horizontal dark stripes
        let lineH = max(1, height / 20)
        let lineSpacing = max(1, height / 10)
        let marginX = max(1, width / 8)
        var rng: UInt64 = 99999
        for lineStart in stride(from: lineSpacing, to: height - lineH, by: lineSpacing) {
            // Vary line length
            rng ^= rng >> 12
            rng ^= rng << 25
            rng ^= rng >> 27
            let lineLen = width - marginX * 2 - Int((rng &* 0x2545F4914F6CDD1D) >> 58)
            for y in lineStart..<min(lineStart + lineH, height) {
                for x in marginX..<min(marginX + max(0, lineLen), width) {
                    frame.setPixel(x: x, y: y, channel: 0, value: 30)
                    frame.setPixel(x: x, y: y, channel: 1, value: 30)
                    frame.setPixel(x: x, y: y, channel: 2, value: 30)
                }
            }
        }
        return frame
    }
}
