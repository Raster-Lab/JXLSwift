import XCTest
@testable import JXLSwift

final class DispatchBackendTests: XCTestCase {

    // MARK: - Auto-Detection Tests

    func testDispatchBackend_Current_ReturnsNonScalar() {
        // On any real platform, at least one optimized backend should be available
        let current = DispatchBackend.current
        // On x86_64 Linux (CI), this should be .avx2
        // On Apple Silicon, this should be .accelerate
        XCTAssertNotEqual(current, .scalar,
                          "Expected an optimized backend on a real platform")
    }

    func testDispatchBackend_Current_IsAvailable() {
        let current = DispatchBackend.current
        XCTAssertTrue(current.isAvailable,
                      "The auto-detected backend must be available")
    }

    // MARK: - Availability Tests

    func testDispatchBackend_Available_AlwaysContainsScalar() {
        let available = DispatchBackend.available
        XCTAssertTrue(available.contains(.scalar),
                      "Scalar backend must always be available")
    }

    func testDispatchBackend_Available_PlatformSpecific() {
        let available = DispatchBackend.available

        #if arch(arm64)
        XCTAssertTrue(available.contains(.neon))
        XCTAssertFalse(available.contains(.sse2))
        XCTAssertFalse(available.contains(.avx2))
        #elseif arch(x86_64)
        XCTAssertTrue(available.contains(.sse2))
        XCTAssertTrue(available.contains(.avx2))
        XCTAssertFalse(available.contains(.neon))
        #endif
    }

    func testDispatchBackend_Scalar_IsAlwaysAvailable() {
        XCTAssertTrue(DispatchBackend.scalar.isAvailable)
    }

    // MARK: - Property Tests

    func testDispatchBackend_RequiresGPU() {
        XCTAssertTrue(DispatchBackend.metal.requiresGPU)
        XCTAssertFalse(DispatchBackend.scalar.requiresGPU)
        XCTAssertFalse(DispatchBackend.neon.requiresGPU)
        XCTAssertFalse(DispatchBackend.sse2.requiresGPU)
        XCTAssertFalse(DispatchBackend.avx2.requiresGPU)
        XCTAssertFalse(DispatchBackend.accelerate.requiresGPU)
    }

    func testDispatchBackend_DisplayName_NotEmpty() {
        for backend in DispatchBackend.allCases {
            XCTAssertFalse(backend.displayName.isEmpty,
                           "\(backend) should have a non-empty display name")
        }
    }

    func testDispatchBackend_RawValue_Unique() {
        let rawValues = DispatchBackend.allCases.map { $0.rawValue }
        XCTAssertEqual(rawValues.count, Set(rawValues).count,
                       "All raw values must be unique")
    }

    // MARK: - CaseIterable Tests

    func testDispatchBackend_AllCases_ContainsSixBackends() {
        XCTAssertEqual(DispatchBackend.allCases.count, 6)
    }
}
