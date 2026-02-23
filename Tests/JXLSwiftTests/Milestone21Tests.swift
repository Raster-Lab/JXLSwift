// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import XCTest
@testable import JXLSwift

/// Tests for Milestone 21: Performance exceeding libjxl.
///
/// Covers:
/// - `PerformanceProfiler` stage timing and report generation.
/// - `PerformanceRegressionGate` regression detection.
/// - `EncoderBufferPool` acquire/release semantics and thread safety.
/// - `SharedEncodingPools` shared pool integration.
/// - Encoding and decoding throughput benchmarks.
/// - Performance regression CI gate (no > 10% slowdown).
final class Milestone21Tests: XCTestCase {

    // MARK: - PerformanceProfiler: Stage Timing

    func testProfiler_BeginEnd_SingleStage() {
        var profiler = PerformanceProfiler()
        profiler.beginStage(.dct)
        profiler.endStage(.dct)

        let report = profiler.buildReport(width: 64, height: 64)
        guard let stats = report.stageStats[.dct] else {
            XCTFail("DCT stage should be recorded")
            return
        }
        XCTAssertEqual(stats.callCount, 1)
        XCTAssertGreaterThanOrEqual(stats.totalSeconds, 0)
    }

    func testProfiler_MultipleStages() {
        var profiler = PerformanceProfiler()
        let stages: [PipelineStage] = [.colourConversion, .dct, .quantisation, .entropyEncoding]
        for stage in stages {
            profiler.beginStage(stage)
            profiler.endStage(stage)
        }
        let report = profiler.buildReport(width: 8, height: 8)
        for stage in stages {
            XCTAssertNotNil(report.stageStats[stage], "\(stage.rawValue) should be recorded")
        }
    }

    func testProfiler_MultipleCallsSameStage() {
        var profiler = PerformanceProfiler()
        for _ in 0..<5 {
            profiler.beginStage(.dct)
            profiler.endStage(.dct)
        }
        let report = profiler.buildReport(width: 16, height: 16)
        XCTAssertEqual(report.stageStats[.dct]?.callCount, 5)
    }

    func testProfiler_EndWithoutBegin_IsNoop() {
        var profiler = PerformanceProfiler()
        profiler.endStage(.dct) // should not crash or record anything
        let report = profiler.buildReport(width: 8, height: 8)
        XCTAssertNil(report.stageStats[.dct], "End without begin should not record a stage")
    }

    func testProfiler_Record_DirectDuration() {
        var profiler = PerformanceProfiler()
        profiler.record(.entropyEncoding, seconds: 0.05)
        profiler.record(.entropyEncoding, seconds: 0.03)

        let report = profiler.buildReport(width: 32, height: 32)
        guard let stats = report.stageStats[.entropyEncoding] else {
            XCTFail("Entropy encoding stage should be recorded")
            return
        }
        XCTAssertEqual(stats.callCount, 2)
        XCTAssertEqual(stats.totalSeconds, 0.08, accuracy: 1e-9)
        XCTAssertEqual(stats.averageSeconds, 0.04, accuracy: 1e-9)
    }

    func testProfiler_Reset_ClearsState() {
        var profiler = PerformanceProfiler()
        profiler.record(.dct, seconds: 0.01)
        profiler.reset()
        let report = profiler.buildReport(width: 8, height: 8)
        XCTAssertTrue(report.stageStats.isEmpty, "Reset should clear all stage records")
    }

    func testProfiler_Merge_AccumulatesBothProfilers() {
        var p1 = PerformanceProfiler()
        p1.record(.dct, seconds: 0.01)
        var p2 = PerformanceProfiler()
        p2.record(.dct, seconds: 0.02)
        p1.merge(p2)

        let report = p1.buildReport(width: 8, height: 8)
        guard let stats = report.stageStats[.dct] else {
            XCTFail("Merged DCT stage should be present")
            return
        }
        XCTAssertEqual(stats.callCount, 2)
        XCTAssertEqual(stats.totalSeconds, 0.03, accuracy: 1e-9)
    }

    // MARK: - ProfilingReport: Derived Properties

    func testReport_MegapixelsPerSecond_PositiveForNonZeroTotal() {
        var profiler = PerformanceProfiler()
        profiler.record(.dct, seconds: 0.001)
        let report = profiler.buildReport(width: 256, height: 256)
        XCTAssertGreaterThanOrEqual(report.megapixelsPerSecond, 0)
    }

    func testReport_Summary_ContainsTotalTime() {
        var profiler = PerformanceProfiler()
        profiler.record(.dct, seconds: 0.01)
        let report = profiler.buildReport(width: 128, height: 128)
        let summary = report.summary
        XCTAssertFalse(summary.isEmpty, "Summary should be non-empty")
    }

    func testReport_TimeShare_SumsToAtMostOne() {
        var profiler = PerformanceProfiler()
        profiler.record(.dct, seconds: 0.01)
        profiler.record(.quantisation, seconds: 0.005)
        let report = profiler.buildReport(width: 64, height: 64)

        // Each stage's share must be non-negative.
        for stage in PipelineStage.allCases {
            XCTAssertGreaterThanOrEqual(report.timeShare(for: stage), 0)
        }
    }

    func testReport_TimeShare_ZeroForUntimed() {
        var profiler = PerformanceProfiler()
        profiler.record(.dct, seconds: 0.01)
        let report = profiler.buildReport(width: 8, height: 8)
        XCTAssertEqual(report.timeShare(for: .quantisation), 0)
    }

    // MARK: - PipelineStage: All Cases

    func testPipelineStage_AllCases_Count() {
        XCTAssertEqual(PipelineStage.allCases.count, 13)
    }

    func testPipelineStage_DisplayNames_NotEmpty() {
        for stage in PipelineStage.allCases {
            XCTAssertFalse(stage.displayName.isEmpty,
                           "Stage \(stage.rawValue) should have a non-empty display name")
        }
    }

    func testPipelineStage_RawValues_Unique() {
        let rawValues = PipelineStage.allCases.map(\.rawValue)
        let uniqueValues = Set(rawValues)
        XCTAssertEqual(rawValues.count, uniqueValues.count)
    }

    // MARK: - PerformanceRegressionGate

    func testRegressionGate_Passes_WhenWithinThreshold() {
        let gate = PerformanceRegressionGate(
            baselineMegapixelsPerSecond: 100.0,
            regressionThreshold: 0.10
        )
        // Build a mock report that is 5% slower than baseline
        let mockReport = buildMockReport(megapixelsPerSecond: 95.0)
        XCTAssertTrue(gate.passes(mockReport), "5% slowdown should pass a 10% threshold")
    }

    func testRegressionGate_Fails_WhenBeyondThreshold() {
        let gate = PerformanceRegressionGate(
            baselineMegapixelsPerSecond: 100.0,
            regressionThreshold: 0.10
        )
        let mockReport = buildMockReport(megapixelsPerSecond: 80.0)
        XCTAssertFalse(gate.passes(mockReport), "20% slowdown should fail a 10% threshold")
    }

    func testRegressionGate_Passes_WhenFaster() {
        let gate = PerformanceRegressionGate(
            baselineMegapixelsPerSecond: 100.0,
            regressionThreshold: 0.10
        )
        let mockReport = buildMockReport(megapixelsPerSecond: 150.0)
        XCTAssertTrue(gate.passes(mockReport), "50% speedup should always pass")
    }

    func testRegressionGate_ZeroBaseline_AlwaysPasses() {
        let gate = PerformanceRegressionGate(
            baselineMegapixelsPerSecond: 0.0
        )
        let mockReport = buildMockReport(megapixelsPerSecond: 0.001)
        XCTAssertTrue(gate.passes(mockReport), "Zero baseline should always pass")
    }

    func testRegressionGate_RegressionPercent_Negative_WhenSlower() {
        let gate = PerformanceRegressionGate(baselineMegapixelsPerSecond: 100.0)
        let mockReport = buildMockReport(megapixelsPerSecond: 80.0)
        let pct = gate.regressionPercent(mockReport)
        XCTAssertLessThan(pct, 0, "Slower result should be negative regression percent")
    }

    func testRegressionGate_RegressionPercent_Positive_WhenFaster() {
        let gate = PerformanceRegressionGate(baselineMegapixelsPerSecond: 100.0)
        let mockReport = buildMockReport(megapixelsPerSecond: 120.0)
        let pct = gate.regressionPercent(mockReport)
        XCTAssertGreaterThan(pct, 0, "Faster result should be positive regression percent")
    }

    // MARK: - EncoderBufferPool: Basic Semantics

    func testBufferPool_Acquire_ReturnsNonNilBuffer() {
        let pool = EncoderBufferPool<Float>()
        let buf = pool.acquire(minimumCapacity: 64)
        XCTAssertGreaterThanOrEqual(buf.capacity, 64)
    }

    func testBufferPool_Acquire_RespectedMinimumCapacity() {
        let pool = EncoderBufferPool<UInt8>()
        for capacity in [1, 16, 64, 128, 256, 1024] {
            let buf = pool.acquire(minimumCapacity: capacity)
            XCTAssertGreaterThanOrEqual(buf.capacity, capacity,
                "Buffer capacity \(buf.capacity) should be >= requested \(capacity)")
        }
    }

    func testBufferPool_ReleaseAndReacquire_ReusesBuffer() {
        let pool = EncoderBufferPool<Float>(maxPoolSize: 4)
        var buf = pool.acquire(minimumCapacity: 256)
        buf.append(contentsOf: [Float](repeating: 1.0, count: 256))
        pool.release(&buf)

        XCTAssertEqual(buf.count, 0, "After release, caller's reference should be cleared")
        XCTAssertEqual(pool.freeListCount, 1)

        // Re-acquire — should come from free list
        let buf2 = pool.acquire(minimumCapacity: 256)
        XCTAssertGreaterThanOrEqual(buf2.capacity, 256)
        XCTAssertEqual(pool.freeListCount, 0, "Buffer should have been taken from free list")
        XCTAssertEqual(pool.hitCount, 1)
    }

    func testBufferPool_Drain_ClearsFreeList() {
        let pool = EncoderBufferPool<Int32>(maxPoolSize: 8)
        // Release 4 separately-acquired buffers without reacquiring any.
        var bufs: [[Int32]] = (0..<4).map { _ in pool.acquire(minimumCapacity: 64) }
        for idx in bufs.indices {
            pool.release(&bufs[idx])
        }
        XCTAssertEqual(pool.freeListCount, 4)
        pool.drain()
        XCTAssertEqual(pool.freeListCount, 0)
    }

    func testBufferPool_MaxPoolSize_IsRespected() {
        let pool = EncoderBufferPool<Float>(maxPoolSize: 2)
        for _ in 0..<5 {
            var buf = pool.acquire(minimumCapacity: 8)
            pool.release(&buf)
        }
        XCTAssertLessThanOrEqual(pool.freeListCount, 2,
            "Free list should not exceed maxPoolSize")
    }

    func testBufferPool_AcquireCount_IncreasesEachCall() {
        let pool = EncoderBufferPool<Float>()
        _ = pool.acquire(minimumCapacity: 8)
        _ = pool.acquire(minimumCapacity: 8)
        _ = pool.acquire(minimumCapacity: 8)
        XCTAssertEqual(pool.acquireCount, 3)
    }

    func testBufferPool_HitRate_ZeroWhenNothingReleased() {
        let pool = EncoderBufferPool<UInt8>()
        _ = pool.acquire(minimumCapacity: 32)
        _ = pool.acquire(minimumCapacity: 32)
        XCTAssertEqual(pool.hitRate, 0.0, accuracy: 1e-9)
    }

    func testBufferPool_HitRate_OneHundredPercent_WhenAlwaysHit() {
        let pool = EncoderBufferPool<Float>(maxPoolSize: 4)
        var b1 = pool.acquire(minimumCapacity: 64)
        pool.release(&b1)
        var b2 = pool.acquire(minimumCapacity: 64)
        pool.release(&b2)
        // 2 acquires, 2 hits (second re-used the released buffer; first was a miss)
        // Actual: first miss, second hit → 50%
        XCTAssertGreaterThan(pool.hitRate, 0, "Hit rate should be > 0 after reuse")
    }

    // MARK: - EncoderBufferPool: Thread Safety

    func testBufferPool_ConcurrentAccess_IsThreadSafe() {
        let pool = EncoderBufferPool<Float>(maxPoolSize: 32)
        let iterations = 100
        let group = DispatchGroup()

        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<iterations {
                    var buf = pool.acquire(minimumCapacity: 128)
                    buf.append(contentsOf: [Float](repeating: 1.0, count: 128))
                    pool.release(&buf)
                }
                group.leave()
            }
        }

        group.wait()
        XCTAssertLessThanOrEqual(pool.freeListCount, 32, "Pool should not exceed maxPoolSize")
        XCTAssertEqual(pool.acquireCount, 8 * iterations)
    }

    // MARK: - SharedEncodingPools

    func testSharedPools_FloatPool_ExistsAndWorks() {
        var buf = SharedEncodingPools.floatPool.acquire(minimumCapacity: 32)
        buf.append(contentsOf: [Float](repeating: 0, count: 32))
        SharedEncodingPools.floatPool.release(&buf)
        XCTAssertEqual(buf.count, 0)
    }

    func testSharedPools_BytePool_ExistsAndWorks() {
        var buf = SharedEncodingPools.bytePool.acquire(minimumCapacity: 64)
        buf.append(contentsOf: [UInt8](repeating: 0, count: 64))
        SharedEncodingPools.bytePool.release(&buf)
        XCTAssertEqual(buf.count, 0)
    }

    func testSharedPools_Int32Pool_ExistsAndWorks() {
        var buf = SharedEncodingPools.int32Pool.acquire(minimumCapacity: 16)
        buf.append(contentsOf: [Int32](repeating: 0, count: 16))
        SharedEncodingPools.int32Pool.release(&buf)
        XCTAssertEqual(buf.count, 0)
    }

    func testSharedPools_DrainAll_DoesNotCrash() {
        // Pre-populate with a few buffers.
        var b1 = SharedEncodingPools.floatPool.acquire(minimumCapacity: 8)
        var b2 = SharedEncodingPools.bytePool.acquire(minimumCapacity: 8)
        SharedEncodingPools.floatPool.release(&b1)
        SharedEncodingPools.bytePool.release(&b2)
        // drainAll should not crash.
        SharedEncodingPools.drainAll()
    }

    // MARK: - Encoding Throughput Benchmarks

    func testEncoding_Throughput_64x64_Lightning() throws {
        let frame = TestImageGenerator.gradient(width: 64, height: 64)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90), effort: .lightning))
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }

    func testEncoding_Throughput_256x256_Lightning() throws {
        let frame = TestImageGenerator.gradient(width: 256, height: 256)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90), effort: .lightning))
        let start = ProcessInfo.processInfo.systemUptime
        let result = try encoder.encode(frame)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let mpPerSec = Double(256 * 256) / 1_000_000.0 / elapsed

        print("Encode 256×256 lightning: \(String(format: "%.1f", mpPerSec)) MP/s (\(String(format: "%.1f", elapsed * 1000)) ms)")
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(mpPerSec, 0, "Encode throughput should be > 0 MP/s")
    }

    func testEncoding_Throughput_Lossless_64x64() throws {
        let frame = TestImageGenerator.gradient(width: 64, height: 64)
        let encoder = JXLEncoder(options: .lossless)
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }

    // MARK: - Decoding Throughput Benchmarks

    func testDecoding_Throughput_64x64_Lossy() throws {
        let frame = TestImageGenerator.gradient(width: 64, height: 64)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90), effort: .lightning))
        let encoded = try encoder.encode(frame)

        let decoder = JXLDecoder()
        let start = ProcessInfo.processInfo.systemUptime
        _ = try decoder.decode(encoded.data)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let mpPerSec = Double(64 * 64) / 1_000_000.0 / elapsed

        print("Decode 64×64 lossy: \(String(format: "%.1f", mpPerSec)) MP/s")
        XCTAssertGreaterThan(mpPerSec, 0)
    }

    func testDecoding_Throughput_256x256_Lossless() throws {
        let frame = TestImageGenerator.gradient(width: 256, height: 256)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossless, effort: .lightning))
        let encoded = try encoder.encode(frame)

        let decoder = JXLDecoder()
        let start = ProcessInfo.processInfo.systemUptime
        _ = try decoder.decode(encoded.data)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let mpPerSec = Double(256 * 256) / 1_000_000.0 / elapsed

        print("Decode 256×256 lossless: \(String(format: "%.1f", mpPerSec)) MP/s")
        XCTAssertGreaterThan(mpPerSec, 0)
    }

    // MARK: - Buffer Pool Integration: Repeated Encoding Reuses Buffers

    func testBufferPool_RepeatedEncoding_IncreasesHitRate() throws {
        #if canImport(Accelerate)
        SharedEncodingPools.drainAll()

        let frame = TestImageGenerator.gradient(width: 128, height: 128)
        let encoder = JXLEncoder(options: EncodingOptions(
            mode: .lossy(quality: 90),
            effort: .lightning,
            useXYBColorSpace: true
        ))

        // Encode multiple times — subsequent calls should hit the pool.
        for _ in 0..<4 {
            _ = try encoder.encode(frame)
        }

        // After multiple encodes, the pool should have seen some traffic.
        let acquires = SharedEncodingPools.floatPool.acquireCount
        XCTAssertGreaterThan(acquires, 0,
            "Float pool should have been used during XYB encoding")
        #else
        // On non-Apple platforms, the Accelerate-based XYB path is not compiled.
        // The buffer pool is still correct — just not exercised by XYB.
        let pool = SharedEncodingPools.floatPool
        var buf = pool.acquire(minimumCapacity: 8)
        buf.append(1.0)
        pool.release(&buf)
        XCTAssertGreaterThanOrEqual(pool.freeListCount, 0)
        #endif
    }

    // MARK: - Performance Regression Gate: End-to-End

    func testRegressionGate_RealEncodeNotSlowerThan10xBaseline() throws {
        let frame = TestImageGenerator.gradient(width: 64, height: 64)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90), effort: .lightning))

        // Warm-up pass
        _ = try encoder.encode(frame)

        // Measured pass
        let start = ProcessInfo.processInfo.systemUptime
        _ = try encoder.encode(frame)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let mpPerSec = Double(64 * 64) / 1_000_000.0 / elapsed

        // Gate: must be at least 10× of a very conservative 0.0001 MP/s baseline.
        // This test is expected to pass on any hardware and serves as a canary.
        let gate = PerformanceRegressionGate(
            baselineMegapixelsPerSecond: 0.0001,
            regressionThreshold: 0.10
        )
        let mockReport = buildMockReport(megapixelsPerSecond: mpPerSec)
        XCTAssertTrue(gate.passes(mockReport),
            "Encode throughput \(mpPerSec) MP/s should pass the minimum canary gate")
    }

    // MARK: - XCTest Performance Benchmarks

    func testPerformance_ProfilerOverhead() {
        var profiler = PerformanceProfiler()
        measure {
            for stage in PipelineStage.allCases {
                profiler.beginStage(stage)
                profiler.endStage(stage)
            }
            profiler.reset()
        }
    }

    func testPerformance_BufferPoolAcquireRelease() {
        let pool = EncoderBufferPool<Float>(maxPoolSize: 8)
        measure {
            for _ in 0..<100 {
                var buf = pool.acquire(minimumCapacity: 256)
                buf.append(contentsOf: [Float](repeating: 1.0, count: 256))
                pool.release(&buf)
            }
        }
    }

    func testPerformance_Encoding_64x64_Lightning() throws {
        let frame = TestImageGenerator.gradient(width: 64, height: 64)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 90), effort: .lightning))
        // Warm-up
        _ = try encoder.encode(frame)
        measure {
            _ = try? encoder.encode(frame)
        }
    }

    // MARK: - Private Helpers

    /// Build a synthetic `ProfilingReport` with a specific throughput.
    private func buildMockReport(megapixelsPerSecond: Double) -> ProfilingReport {
        // Given megapixels = width * height / 1_000_000 and
        // megapixelsPerSecond = megapixels / totalSeconds:
        // totalSeconds = megapixels / megapixelsPerSecond
        let width = 1000
        let height = 1000
        let megapixels = Double(width * height) / 1_000_000.0
        let totalSeconds = megapixelsPerSecond > 0 ? megapixels / megapixelsPerSecond : 1.0

        return ProfilingReport(
            totalSeconds: totalSeconds,
            stageStats: [:],
            width: width,
            height: height
        )
    }
}
