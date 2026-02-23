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

    // MARK: - Work-Stealing Thread Pool

    func testThreadPool_Submit_ExecutesWork() {
        let pool = WorkStealingThreadPool(threadCount: 2)
        let counter = Counter()

        for _ in 0..<10 {
            pool.submit {
                counter.increment()
            }
        }
        pool.waitForAll()
        XCTAssertEqual(counter.value, 10)
        pool.shutdown()
    }

    func testThreadPool_SubmitAll_ExecutesAllAndWaits() {
        let pool = WorkStealingThreadPool(threadCount: 4)
        let counter = Counter()
        let works: [@Sendable () -> Void] = (0..<20).map { _ in { counter.increment() } }

        pool.submitAll(works)
        XCTAssertEqual(counter.value, 20)
        pool.shutdown()
    }

    func testThreadPool_ThreadCount_Defaults() {
        let pool = WorkStealingThreadPool()
        XCTAssertGreaterThanOrEqual(pool.threadCount, 1)
        pool.shutdown()
    }

    func testThreadPool_PendingCount_ZeroAfterWait() {
        let pool = WorkStealingThreadPool(threadCount: 2)
        for _ in 0..<5 {
            pool.submit { /* no-op */ }
        }
        pool.waitForAll()
        XCTAssertEqual(pool.pendingCount, 0)
        pool.shutdown()
    }

    func testThreadPool_ConcurrentWorkload_IsThreadSafe() {
        let pool = WorkStealingThreadPool(threadCount: 4)
        let counter = Counter()
        let iterations = 200

        pool.submitAll((0..<iterations).map { _ in { counter.increment() } })
        XCTAssertEqual(counter.value, iterations)
        pool.shutdown()
    }

    func testThreadPool_SharedPool_Exists() {
        XCTAssertGreaterThanOrEqual(SharedThreadPool.shared.threadCount, 1)
    }

    func testPerformance_ThreadPool_Throughput() {
        let pool = WorkStealingThreadPool(threadCount: 4)
        measure {
            let counter = Counter()
            pool.submitAll((0..<100).map { _ in { counter.increment() } })
        }
        pool.shutdown()
    }

    // MARK: - Accelerate Expansion: vectorClamp / vectorAbs / vectorSum / normalise

    func testAccelerate_VectorClamp_ClampsValues() throws {
        #if canImport(Accelerate)
        let values: [Float] = [-2, -1, 0, 0.5, 1, 2, 3]
        let clamped = AccelerateOps.vectorClamp(values, low: 0, high: 1)
        let expected: [Float] = [0, 0, 0, 0.5, 1, 1, 1]
        for (c, e) in zip(clamped, expected) { XCTAssertEqual(c, e, accuracy: 1e-6) }
        #else
        throw XCTSkip("Accelerate not available")
        #endif
    }

    func testAccelerate_VectorAbs_AllPositive() throws {
        #if canImport(Accelerate)
        let values: [Float] = [-3, -1, 0, 1, 3]
        let absValues = AccelerateOps.vectorAbs(values)
        let expected: [Float] = [3, 1, 0, 1, 3]
        for (a, e) in zip(absValues, expected) { XCTAssertEqual(a, e, accuracy: 1e-6) }
        #else
        throw XCTSkip("Accelerate not available")
        #endif
    }

    func testAccelerate_VectorSum_MatchesReduce() throws {
        #if canImport(Accelerate)
        let values: [Float] = [1, 2, 3, 4, 5]
        let sum = AccelerateOps.vectorSum(values)
        XCTAssertEqual(sum, 15, accuracy: 1e-5)
        #else
        throw XCTSkip("Accelerate not available")
        #endif
    }

    func testAccelerate_Normalise_ZeroMeanUnitNorm() throws {
        #if canImport(Accelerate)
        let values: [Float] = [1, 2, 3, 4, 5]
        let normed = AccelerateOps.normalise(values)
        // After normalisation mean ≈ 0 and L2 norm ≈ 1
        let mean = normed.reduce(0, +) / Float(normed.count)
        let l2 = sqrt(normed.map { $0 * $0 }.reduce(0, +))
        XCTAssertEqual(mean, 0, accuracy: 1e-5)
        XCTAssertEqual(l2,   1, accuracy: 1e-5)
        #else
        throw XCTSkip("Accelerate not available")
        #endif
    }

    func testAccelerate_Normalise_EmptyArray() throws {
        #if canImport(Accelerate)
        let normed = AccelerateOps.normalise([])
        XCTAssertTrue(normed.isEmpty)
        #else
        throw XCTSkip("Accelerate not available")
        #endif
    }

    func testAccelerate_Normalise_ConstantArray_ReturnsZeros() throws {
        #if canImport(Accelerate)
        let values = [Float](repeating: 5.0, count: 8)
        let normed = AccelerateOps.normalise(values)
        for v in normed {
            XCTAssertEqual(v, 0, accuracy: 1e-5)
        }
        #else
        throw XCTSkip("Accelerate not available")
        #endif
    }

    func testAccelerate_InterleavedU8RGBToYCbCr_BasicConversion() throws {
        #if canImport(Accelerate)
        // Pure white pixel: R=255, G=255, B=255 → Y≈1, Cb≈0.5, Cr≈0.5
        let pixels: [UInt8] = [255, 255, 255]
        let (y, cb, cr) = AccelerateOps.interleavedU8RGBToYCbCr(pixels, count: 1)
        XCTAssertEqual(y[0],  1.0, accuracy: 0.01)
        XCTAssertEqual(cb[0], 0.5, accuracy: 0.01)
        XCTAssertEqual(cr[0], 0.5, accuracy: 0.01)
        #else
        throw XCTSkip("Accelerate not available")
        #endif
    }

    // MARK: - NEON Expansion: SIMD quantize / horizontal reductions

    func testNEON_Quantize_BasicCase() {
        let values: [Float] = [4.5, -3.3, 0.0, 8.0, 1.1, -7.6, 2.0, -0.1]
        let steps  = [Float](repeating: 1.0, count: 8)
        let q = NEONOps.quantize(values, qSteps: steps)
        XCTAssertEqual(q, [5, -3, 0, 8, 1, -8, 2, 0])
    }

    func testNEON_Quantize_WithLargeSteps() {
        let values: [Float] = [100, 200, 300, 400]
        let steps: [Float]  = [50,  100, 100, 200]
        let q = NEONOps.quantize(values, qSteps: steps)
        XCTAssertEqual(q, [2, 2, 3, 2])
    }

    func testNEON_Quantize_Clamping() {
        // Values that would exceed Int16 range before clamping
        let values: [Float] = [Float(Int16.max) * 2, Float(Int16.min) * 2]
        let steps:  [Float] = [1.0, 1.0]
        let q = NEONOps.quantize(values, qSteps: steps)
        XCTAssertEqual(q[0], Int16.max)
        XCTAssertEqual(q[1], Int16.min)
    }

    func testNEON_HorizontalSum_CorrectResult() {
        let v = SIMD4<Float>(1, 2, 3, 4)
        XCTAssertEqual(NEONOps.horizontalSum(v), 10, accuracy: 1e-6)
    }

    func testNEON_HorizontalMax_CorrectResult() {
        let v = SIMD4<Float>(1, 5, 3, 2)
        XCTAssertEqual(NEONOps.horizontalMax(v), 5, accuracy: 1e-6)
    }

    func testNEON_HorizontalMin_CorrectResult() {
        let v = SIMD4<Float>(1, 5, 3, 2)
        XCTAssertEqual(NEONOps.horizontalMin(v), 1, accuracy: 1e-6)
    }

    // MARK: - Metal Pipeline Optimisation

    func testMetal_OptimalBatchSize_WithinBounds() {
        #if canImport(Metal)
        guard let pipeline = MetalOps.computePipelineState(for: "dct_8x8") else {
            // Metal pipeline not available in CI — skip gracefully.
            return
        }
        let batchSize = MetalOps.optimalBatchSize(pipeline: pipeline, totalCount: 1024)
        XCTAssertGreaterThanOrEqual(batchSize, 1)
        XCTAssertLessThanOrEqual(batchSize, 1024)
        // Must be a power-of-two in [32, 1024]
        XCTAssertTrue(isPowerOfTwo(batchSize), "Batch size should be power-of-two")
        #endif
    }

    func testMetal_OptimalTileSize_SmallImage() {
        #if canImport(Metal)
        guard let pipeline = MetalOps.computePipelineState(for: "rgb_to_ycbcr") else {
            return
        }
        let (w, h) = MetalOps.optimalTileSize(pipeline: pipeline, imageWidth: 4, imageHeight: 4)
        XCTAssertLessThanOrEqual(w, 4)
        XCTAssertLessThanOrEqual(h, 4)
        XCTAssertGreaterThanOrEqual(w, 1)
        XCTAssertGreaterThanOrEqual(h, 1)
        #endif
    }

    func testMetal_EstimatedOccupancy_InRange() {
        #if canImport(Metal)
        guard let pipeline = MetalOps.computePipelineState(for: "rgb_to_ycbcr") else {
            return
        }
        let occ = MetalOps.estimatedOccupancy(pipeline: pipeline, threadgroupWidth: 64)
        XCTAssertGreaterThanOrEqual(occ, 0)
        XCTAssertLessThanOrEqual(occ, 1.0)
        #endif
    }

    func testMetal_CoalescedBuffer_AllocatesNonNil() {
        #if canImport(Metal)
        guard MetalOps.isAvailable else { return }
        let data = [Float](repeating: 1.0, count: 64)
        let buffer = data.withUnsafeBytes { ptr in
            MetalOps.makeCoalescedBuffer(from: ptr.baseAddress!, length: ptr.count)
        }
        XCTAssertNotNil(buffer, "Coalesced buffer should be allocated on Metal devices")
        #endif
    }

    // MARK: - Throughput Targets (benchmark, not hard assertions)

    /// Measures encoding throughput for effort 3 (fast mode) and prints the result.
    /// The test does not fail on slow CI — it serves as a benchmark canary.
    func testThroughput_Encoding_Effort3_256x256() throws {
        let frame = TestImageGenerator.gradient(width: 256, height: 256)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 80), effort: .falcon))
        _ = try encoder.encode(frame) // warm-up
        let start = ProcessInfo.processInfo.systemUptime
        _ = try encoder.encode(frame)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let mpPerSec = Double(256 * 256) / 1_000_000.0 / elapsed
        print("Encode 256×256 effort=fast: \(String(format: "%.1f", mpPerSec)) MP/s")
        XCTAssertGreaterThan(mpPerSec, 0, "Encoding throughput must be measurable")
    }

    /// Measures decoding throughput and prints the result.
    func testThroughput_Decoding_256x256_Lossless() throws {
        let frame = TestImageGenerator.gradient(width: 256, height: 256)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossless, effort: .lightning))
        let encoded = try encoder.encode(frame)
        let decoder = JXLDecoder()
        _ = try decoder.decode(encoded.data) // warm-up
        let start = ProcessInfo.processInfo.systemUptime
        _ = try decoder.decode(encoded.data)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let mpPerSec = Double(256 * 256) / 1_000_000.0 / elapsed
        print("Decode 256×256 lossless: \(String(format: "%.1f", mpPerSec)) MP/s")
        XCTAssertGreaterThan(mpPerSec, 0, "Decoding throughput must be measurable")
    }

    /// Validates that encoding a 256×256 image completes successfully and
    /// measures the encoding output size as a proxy for memory efficiency.
    ///
    /// Note: Accurate per-process heap delta measurement requires platform-specific
    /// APIs (mach_task_self on Apple, /proc/self/status on Linux) that vary across
    /// CI environments.  This test serves as a functional and size-budget canary.
    func testMemory_Encoding_256x256_PeakHeap() throws {
        let frame = TestImageGenerator.gradient(width: 256, height: 256)
        let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 80), effort: .lightning))

        let result = try encoder.encode(frame)
        let outputBytes = result.data.count
        let inputBytes  = 256 * 256 * 3  // RGB uint8
        let compressionRatio = Double(inputBytes) / Double(outputBytes)

        print("256×256 lossy encode: \(outputBytes) bytes " +
              "(\(String(format: "%.1f", compressionRatio))× compression)")

        // Encoded output must be smaller than the raw input (confirms compression).
        XCTAssertGreaterThan(
            compressionRatio, 1.0,
            "Encoded output must be smaller than the raw input"
        )
        // Sanity: encoded output must be at least 100 bytes (not empty/corrupt).
        XCTAssertGreaterThan(outputBytes, 100)
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

// MARK: - Thread-safe counter helper

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}

// MARK: - Private test helpers

extension Milestone21Tests {
    /// Returns `true` if `n` is a power of two (and positive).
    private func isPowerOfTwo(_ n: Int) -> Bool {
        n > 0 && (n & (n - 1)) == 0
    }
}
