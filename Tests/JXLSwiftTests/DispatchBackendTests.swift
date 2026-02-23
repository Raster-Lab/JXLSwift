import XCTest
@testable import JXLSwift

final class DispatchBackendTests: XCTestCase {

    // MARK: - Auto-Detection Tests

    func testDispatchBackend_Current_ReturnsNonScalar() {
        let current = DispatchBackend.current
        #if canImport(Accelerate)
        // Accelerate takes priority on any Apple platform (ARM64 or x86_64)
        XCTAssertEqual(current, .accelerate,
                       "Expected .accelerate when Accelerate is available")
        #elseif arch(arm64)
        XCTAssertEqual(current, .neon,
                       "Expected .neon on ARM64 without Accelerate")
        #elseif arch(x86_64)
        XCTAssertEqual(current, .avx2,
                       "Expected .avx2 on x86_64 without Accelerate")
        #else
        XCTAssertEqual(current, .scalar,
                       "Expected .scalar on unknown platform")
        #endif
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
        XCTAssertTrue(DispatchBackend.vulkan.requiresGPU)
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

    func testDispatchBackend_AllCases_ContainsSevenBackends() {
        XCTAssertEqual(DispatchBackend.allCases.count, 7)
    }

    // MARK: - Vulkan Tests

    func testDispatchBackend_Vulkan_RequiresGPU() {
        XCTAssertTrue(DispatchBackend.vulkan.requiresGPU,
                      "Vulkan backend must require a GPU")
    }

    func testDispatchBackend_Vulkan_DisplayNameNotEmpty() {
        XCTAssertFalse(DispatchBackend.vulkan.displayName.isEmpty)
    }

    func testDispatchBackend_Vulkan_NotAvailableOnApple() {
        // Vulkan is not available on Apple platforms (Metal is used instead)
        #if canImport(Metal)
        XCTAssertFalse(DispatchBackend.vulkan.isAvailable,
                       "Vulkan should not appear available on Apple platforms")
        #endif
    }
}
