// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import XCTest
@testable import JXLSwift

final class ComparisonBenchmarkTests: XCTestCase {

    // MARK: - SpeedComparisonResult Tests

    func testSpeedComparison_SingleEffort() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let runner = ComparisonBenchmark(iterations: 1)
        let result = try runner.compareSpeed(
            frame: frame,
            quality: 90,
            efforts: [.lightning]
        )
        XCTAssertEqual(result.measurements.count, 1)
        XCTAssertEqual(result.measurements[0].effort, .lightning)
        XCTAssertGreaterThan(result.measurements[0].averageTimeSeconds, 0)
        XCTAssertGreaterThan(result.measurements[0].megapixelsPerSecond, 0)
        XCTAssertGreaterThan(result.measurements[0].compressedSize, 0)
        XCTAssertGreaterThan(result.measurements[0].compressionRatio, 0)
    }

    func testSpeedComparison_MultipleEfforts() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let runner = ComparisonBenchmark(iterations: 1)
        let efforts: [EncodingEffort] = [.lightning, .falcon, .squirrel]
        let result = try runner.compareSpeed(
            frame: frame,
            quality: 90,
            efforts: efforts
        )
        XCTAssertEqual(result.measurements.count, 3)
        XCTAssertEqual(result.measurements[0].effort, .lightning)
        XCTAssertEqual(result.measurements[1].effort, .falcon)
        XCTAssertEqual(result.measurements[2].effort, .squirrel)
    }

    func testSpeedComparison_IterationTimes() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let runner = ComparisonBenchmark(iterations: 2)
        let result = try runner.compareSpeed(
            frame: frame,
            quality: 90,
            efforts: [.lightning]
        )
        XCTAssertEqual(result.measurements[0].iterationTimes.count, 2)
        for time in result.measurements[0].iterationTimes {
            XCTAssertGreaterThan(time, 0)
        }
    }

    func testSpeedComparison_SummaryFastestSlowest() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let runner = ComparisonBenchmark(iterations: 1)
        let result = try runner.compareSpeed(
            frame: frame,
            quality: 90,
            efforts: [.lightning, .tortoise]
        )
        let summary = result.summary
        XCTAssertGreaterThan(summary.fastestTimeSeconds, 0)
        XCTAssertGreaterThan(summary.slowestTimeSeconds, 0)
        XCTAssertGreaterThanOrEqual(summary.speedRange, 1.0)
    }

    func testSpeedSummary_EmptyMeasurements() {
        let result = SpeedComparisonResult(measurements: [])
        let summary = result.summary
        XCTAssertEqual(summary.fastestTimeSeconds, 0)
        XCTAssertEqual(summary.slowestTimeSeconds, 0)
        XCTAssertEqual(summary.speedRange, 0)
    }

    // MARK: - CompressionComparisonResult Tests

    func testCompressionComparison_SingleQuality() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let runner = ComparisonBenchmark(iterations: 1)
        let result = try runner.compareCompression(
            frame: frame,
            qualities: [90],
            effort: .lightning
        )
        XCTAssertEqual(result.measurements.count, 1)
        XCTAssertEqual(result.measurements[0].quality, 90)
        XCTAssertGreaterThan(result.measurements[0].originalSize, 0)
        XCTAssertGreaterThan(result.measurements[0].compressedSize, 0)
        XCTAssertGreaterThan(result.measurements[0].compressionRatio, 0)
        XCTAssertGreaterThan(result.measurements[0].encodingTimeSeconds, 0)
    }

    func testCompressionComparison_MultipleQualities() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let runner = ComparisonBenchmark(iterations: 1)
        let result = try runner.compareCompression(
            frame: frame,
            qualities: [25, 50, 75, 90],
            effort: .lightning
        )
        XCTAssertEqual(result.measurements.count, 4)
        XCTAssertEqual(result.measurements[0].quality, 25)
        XCTAssertEqual(result.measurements[1].quality, 50)
        XCTAssertEqual(result.measurements[2].quality, 75)
        XCTAssertEqual(result.measurements[3].quality, 90)
    }

    func testCompressionComparison_BitsPerPixel() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let runner = ComparisonBenchmark(iterations: 1)
        let result = try runner.compareCompression(
            frame: frame,
            qualities: [90],
            effort: .lightning
        )
        let bpp = result.measurements[0].bitsPerPixel
        XCTAssertGreaterThan(bpp, 0)
    }

    func testCompressionComparison_SummaryBestWorst() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let runner = ComparisonBenchmark(iterations: 1)
        let result = try runner.compareCompression(
            frame: frame,
            qualities: [25, 90],
            effort: .lightning
        )
        let summary = result.summary
        XCTAssertGreaterThan(summary.bestCompressionRatio, 0)
        XCTAssertGreaterThan(summary.worstCompressionRatio, 0)
        XCTAssertGreaterThanOrEqual(summary.bestCompressionRatio, summary.worstCompressionRatio)
        XCTAssertGreaterThan(summary.averageCompressionRatio, 0)
    }

    func testCompressionSummary_EmptyMeasurements() {
        let result = CompressionComparisonResult(measurements: [])
        let summary = result.summary
        XCTAssertEqual(summary.bestCompressionRatio, 0)
        XCTAssertEqual(summary.worstCompressionRatio, 0)
        XCTAssertEqual(summary.averageCompressionRatio, 0)
    }

    func testQualityMeasurement_BitsPerPixel_ZeroOriginalSize() {
        let m = QualityMeasurement(
            quality: 90,
            originalSize: 0,
            compressedSize: 100,
            compressionRatio: 0,
            encodingTimeSeconds: 0.1
        )
        XCTAssertEqual(m.bitsPerPixel, 0)
    }

    // MARK: - MemoryComparisonResult Tests

    func testMemoryComparison_SingleConfig() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        let runner = ComparisonBenchmark(iterations: 1)
        let result = try runner.compareMemory(
            configurations: [("test_gradient", frame, options)]
        )
        XCTAssertEqual(result.measurements.count, 1)
        XCTAssertEqual(result.measurements[0].name, "test_gradient")
        XCTAssertEqual(result.measurements[0].width, 16)
        XCTAssertEqual(result.measurements[0].height, 16)
        XCTAssertEqual(result.measurements[0].mode, "lossy(q=90.0)")
        XCTAssertGreaterThan(result.measurements[0].encodingTimeSeconds, 0)
    }

    func testMemoryComparison_MultipleConfigs() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let lossy = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        let lossless = EncodingOptions.lossless
        let runner = ComparisonBenchmark(iterations: 1)
        let result = try runner.compareMemory(
            configurations: [
                ("lossy_test", frame, lossy),
                ("lossless_test", frame, lossless),
            ]
        )
        XCTAssertEqual(result.measurements.count, 2)
        XCTAssertEqual(result.measurements[0].name, "lossy_test")
        XCTAssertEqual(result.measurements[1].name, "lossless_test")
    }

    func testMemoryComparison_Megapixels() {
        let m = MemoryMeasurement(
            name: "test", width: 1000, height: 1000,
            mode: "lossy(q=90.0)",
            memoryBeforeBytes: 1000, memoryAfterBytes: 2000,
            peakMemoryBytes: 2000, encodingTimeSeconds: 0.1
        )
        XCTAssertEqual(m.megapixels, 1.0, accuracy: 0.001)
        XCTAssertEqual(m.encodingMemoryBytes, 1000)
    }

    func testMemoryComparison_EncodingMemory_NoNegative() {
        let m = MemoryMeasurement(
            name: "test", width: 100, height: 100,
            mode: "lossy(q=90.0)",
            memoryBeforeBytes: 5000, memoryAfterBytes: 3000,
            peakMemoryBytes: 5000, encodingTimeSeconds: 0.1
        )
        XCTAssertEqual(m.encodingMemoryBytes, 0, "Should not be negative")
    }

    func testMemorySummary_EmptyMeasurements() {
        let result = MemoryComparisonResult(measurements: [])
        let summary = result.summary
        XCTAssertEqual(summary.peakMemoryBytes, 0)
        XCTAssertEqual(summary.averageMemoryBytes, 0)
        XCTAssertEqual(summary.minMemoryBytes, 0)
        XCTAssertEqual(summary.memoryPerMegapixel, 0)
    }

    func testMemorySummary_SingleMeasurement() {
        let m = MemoryMeasurement(
            name: "test", width: 1000, height: 1000,
            mode: "lossy(q=90.0)",
            memoryBeforeBytes: 1000, memoryAfterBytes: 5000,
            peakMemoryBytes: 5000, encodingTimeSeconds: 0.1
        )
        let result = MemoryComparisonResult(measurements: [m])
        let summary = result.summary
        XCTAssertEqual(summary.peakMemoryBytes, 5000)
        XCTAssertEqual(summary.averageMemoryBytes, 5000)
        XCTAssertEqual(summary.minMemoryBytes, 5000)
        XCTAssertEqual(summary.memoryPerMegapixel, 5000, accuracy: 1.0)
    }

    func testMemoryComparison_ModeDescriptions() throws {
        let frame = TestImageGenerator.gradient(width: 8, height: 8)
        let runner = ComparisonBenchmark(iterations: 1)

        let losslessOpts = EncodingOptions(mode: .lossless)
        let distOpts = EncodingOptions(mode: .distance(1.0))
        let result = try runner.compareMemory(
            configurations: [
                ("lossless", frame, losslessOpts),
                ("distance", frame, distOpts),
            ]
        )
        XCTAssertEqual(result.measurements[0].mode, "lossless")
        XCTAssertEqual(result.measurements[1].mode, "distance(1.0)")
    }

    // MARK: - ComparisonBenchmark Initialization Tests

    func testComparisonBenchmark_MinIterations() {
        let runner = ComparisonBenchmark(iterations: 0)
        XCTAssertEqual(runner.iterations, 1, "Minimum iterations should be 1")
    }

    func testComparisonBenchmark_DefaultIterations() {
        let runner = ComparisonBenchmark()
        XCTAssertEqual(runner.iterations, 3)
    }

    func testComparisonBenchmark_CustomIterations() {
        let runner = ComparisonBenchmark(iterations: 5)
        XCTAssertEqual(runner.iterations, 5)
    }

    // MARK: - Static Memory Helper Tests

    func testCurrentProcessMemory_ReturnsNonNegative() {
        let mem = ComparisonBenchmark.currentProcessMemory()
        XCTAssertGreaterThanOrEqual(mem, 0)
    }

    // MARK: - TestImageCorpus Tests

    func testTestImageCorpus_KodakLike_Count() {
        let corpus = TestImageCorpus.kodakLike()
        XCTAssertEqual(corpus.count, 8)
    }

    func testTestImageCorpus_KodakLike_UniqueIDs() {
        let corpus = TestImageCorpus.kodakLike()
        let ids = Set(corpus.map(\.id))
        XCTAssertEqual(ids.count, corpus.count, "All IDs should be unique")
    }

    func testTestImageCorpus_KodakLike_CorrectDimensions() {
        let corpus = TestImageCorpus.kodakLike(width: 64, height: 32)
        for image in corpus {
            XCTAssertEqual(image.frame.width, 64, "Image \(image.id) width mismatch")
            XCTAssertEqual(image.frame.height, 32, "Image \(image.id) height mismatch")
        }
    }

    func testTestImageCorpus_KodakLike_Categories() {
        let corpus = TestImageCorpus.kodakLike()
        let categories = Set(corpus.map(\.category))
        XCTAssertTrue(categories.contains(.gradient))
        XCTAssertTrue(categories.contains(.edges))
        XCTAssertTrue(categories.contains(.texture))
        XCTAssertTrue(categories.contains(.flat))
        XCTAssertTrue(categories.contains(.mixed))
    }

    func testTestImageCorpus_TecnickLike_Count() {
        let corpus = TestImageCorpus.tecnickLike()
        XCTAssertEqual(corpus.count, 4)
    }

    func testTestImageCorpus_TecnickLike_UniqueIDs() {
        let corpus = TestImageCorpus.tecnickLike()
        let ids = Set(corpus.map(\.id))
        XCTAssertEqual(ids.count, corpus.count)
    }

    func testTestImageCorpus_TecnickLike_CorrectDimensions() {
        let corpus = TestImageCorpus.tecnickLike(width: 48, height: 48)
        for image in corpus {
            XCTAssertEqual(image.frame.width, 48, "Image \(image.id) width mismatch")
            XCTAssertEqual(image.frame.height, 48, "Image \(image.id) height mismatch")
        }
    }

    func testTestImageCorpus_WikipediaLike_Count() {
        let corpus = TestImageCorpus.wikipediaLike()
        XCTAssertEqual(corpus.count, 4)
    }

    func testTestImageCorpus_WikipediaLike_UniqueIDs() {
        let corpus = TestImageCorpus.wikipediaLike()
        let ids = Set(corpus.map(\.id))
        XCTAssertEqual(ids.count, corpus.count)
    }

    func testTestImageCorpus_WikipediaLike_CorrectDimensions() {
        let corpus = TestImageCorpus.wikipediaLike(width: 32, height: 64)
        for image in corpus {
            XCTAssertEqual(image.frame.width, 32, "Image \(image.id) width mismatch")
            XCTAssertEqual(image.frame.height, 64, "Image \(image.id) height mismatch")
        }
    }

    func testTestImageCorpus_FullCorpus_Count() {
        let corpus = TestImageCorpus.fullCorpus()
        XCTAssertEqual(corpus.count, 16, "8 Kodak + 4 Tecnick + 4 Wikipedia")
    }

    func testTestImageCorpus_FullCorpus_UniqueIDs() {
        let corpus = TestImageCorpus.fullCorpus()
        let ids = Set(corpus.map(\.id))
        XCTAssertEqual(ids.count, corpus.count, "All IDs should be unique across all sub-corpora")
    }

    func testTestImageCorpus_FullCorpus_AllCategories() {
        let corpus = TestImageCorpus.fullCorpus()
        let categories = Set(corpus.map(\.category))
        XCTAssertGreaterThanOrEqual(categories.count, 5, "Should cover at least 5 categories")
    }

    func testTestImageCorpus_ImageCharacteristics_ValidRanges() {
        let corpus = TestImageCorpus.fullCorpus()
        for image in corpus {
            XCTAssertLessThanOrEqual(image.characteristics.spatialComplexity, 1.0,
                "Image \(image.id) spatial complexity should be <= 1.0")
            XCTAssertGreaterThanOrEqual(image.characteristics.spatialComplexity, 0.0,
                "Image \(image.id) spatial complexity should be >= 0.0")
            XCTAssertLessThanOrEqual(image.characteristics.frequencyComplexity, 1.0,
                "Image \(image.id) frequency complexity should be <= 1.0")
            XCTAssertGreaterThanOrEqual(image.characteristics.frequencyComplexity, 0.0,
                "Image \(image.id) frequency complexity should be >= 0.0")
            XCTAssertGreaterThan(image.characteristics.expectedCompressionRange.upperBound, 0)
        }
    }

    func testTestImageCorpus_ImageCategory_AllCases() {
        let allCases = TestImageCorpus.ImageCategory.allCases
        XCTAssertEqual(allCases.count, 6)
        XCTAssertTrue(allCases.contains(.gradient))
        XCTAssertTrue(allCases.contains(.edges))
        XCTAssertTrue(allCases.contains(.texture))
        XCTAssertTrue(allCases.contains(.flat))
        XCTAssertTrue(allCases.contains(.mixed))
        XCTAssertTrue(allCases.contains(.screen))
    }

    func testTestImageCorpus_ImageCategory_RawValues() {
        XCTAssertEqual(TestImageCorpus.ImageCategory.gradient.rawValue, "gradient")
        XCTAssertEqual(TestImageCorpus.ImageCategory.edges.rawValue, "edges")
        XCTAssertEqual(TestImageCorpus.ImageCategory.texture.rawValue, "texture")
        XCTAssertEqual(TestImageCorpus.ImageCategory.flat.rawValue, "flat")
        XCTAssertEqual(TestImageCorpus.ImageCategory.mixed.rawValue, "mixed")
        XCTAssertEqual(TestImageCorpus.ImageCategory.screen.rawValue, "screen")
    }

    // MARK: - Corpus Image Encoding Tests

    func testTestImageCorpus_AllImagesEncode() throws {
        let corpus = TestImageCorpus.fullCorpus(width: 16, height: 16)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90), effort: .lightning))
        for image in corpus {
            let result = try encoder.encode(image.frame)
            XCTAssertGreaterThan(result.data.count, 0, "Image \(image.id) should produce non-empty output")
            XCTAssertGreaterThan(result.stats.compressionRatio, 0, "Image \(image.id) should have positive compression ratio")
        }
    }

    func testTestImageCorpus_KodakLike_EncodesLossless() throws {
        let corpus = TestImageCorpus.kodakLike(width: 16, height: 16)
        let encoder = JXLEncoder(options: .lossless)
        for image in corpus {
            let result = try encoder.encode(image.frame)
            XCTAssertGreaterThan(result.data.count, 0, "Image \(image.id) lossless should produce output")
        }
    }

    // MARK: - Corpus Descriptions

    func testTestImageCorpus_Descriptions_NotEmpty() {
        let corpus = TestImageCorpus.fullCorpus()
        for image in corpus {
            XCTAssertFalse(image.description.isEmpty, "Image \(image.id) should have a description")
            XCTAssertFalse(image.id.isEmpty, "Image should have an ID")
        }
    }

    // MARK: - Integration Test: Speed + Compression + Memory

    func testIntegration_FullComparison() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let runner = ComparisonBenchmark(iterations: 1)

        // Speed comparison
        let speedResult = try runner.compareSpeed(
            frame: frame,
            quality: 90,
            efforts: [.lightning, .falcon]
        )
        XCTAssertEqual(speedResult.measurements.count, 2)

        // Compression comparison
        let compResult = try runner.compareCompression(
            frame: frame,
            qualities: [50, 90],
            effort: .lightning
        )
        XCTAssertEqual(compResult.measurements.count, 2)

        // Memory comparison
        let memResult = try runner.compareMemory(
            configurations: [
                ("lossy", frame, EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)),
            ]
        )
        XCTAssertEqual(memResult.measurements.count, 1)
    }

    // MARK: - EffortMeasurement Properties Tests

    func testEffortMeasurement_AllProperties() {
        let m = EffortMeasurement(
            effort: .squirrel,
            averageTimeSeconds: 0.5,
            megapixelsPerSecond: 2.0,
            compressedSize: 1000,
            compressionRatio: 3.0,
            iterationTimes: [0.4, 0.5, 0.6]
        )
        XCTAssertEqual(m.effort, .squirrel)
        XCTAssertEqual(m.averageTimeSeconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(m.megapixelsPerSecond, 2.0, accuracy: 0.001)
        XCTAssertEqual(m.compressedSize, 1000)
        XCTAssertEqual(m.compressionRatio, 3.0, accuracy: 0.001)
        XCTAssertEqual(m.iterationTimes.count, 3)
    }

    func testQualityMeasurement_AllProperties() {
        let m = QualityMeasurement(
            quality: 85,
            originalSize: 10000,
            compressedSize: 2000,
            compressionRatio: 5.0,
            encodingTimeSeconds: 0.2
        )
        XCTAssertEqual(m.quality, 85)
        XCTAssertEqual(m.originalSize, 10000)
        XCTAssertEqual(m.compressedSize, 2000)
        XCTAssertEqual(m.compressionRatio, 5.0, accuracy: 0.001)
        XCTAssertEqual(m.encodingTimeSeconds, 0.2, accuracy: 0.001)
        XCTAssertEqual(m.bitsPerPixel, 1.6, accuracy: 0.001)
    }

    // MARK: - Performance Tests

    func testPerformance_SpeedComparison() throws {
        let frame = TestImageGenerator.gradient(width: 16, height: 16)
        let runner = ComparisonBenchmark(iterations: 1)
        measure {
            _ = try? runner.compareSpeed(
                frame: frame,
                quality: 90,
                efforts: [.lightning]
            )
        }
    }

    func testPerformance_CorpusGeneration() {
        measure {
            _ = TestImageCorpus.fullCorpus(width: 64, height: 64)
        }
    }
}
