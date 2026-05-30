// CPerfBridgeTests — proves the SwiftPM C target (`JXLPerfC`) compiles,
// links, and exchanges data with Swift correctly. Real hot-path C code
// (BitWriter, rANS) will land alongside dedicated byte-identity tests
// against the scalar Swift reference; this file is the scaffolding gate that
// keeps the C target alive across rebuilds.

import XCTest
import JXLPerfC

final class CPerfBridgeTests: XCTestCase {

    /// Proof of life: the C target's ABI version probe is callable.
    func testCPerfBridge_VersionProbe() {
        XCTAssertEqual(jxlperf_c_version(), 1,
            "JXLPerfC ABI version probe should return 1")
    }

    /// Byte buffers cross the C↔Swift bridge intact: hash a known input,
    /// confirm determinism + avalanche. (Pre-computed FNV-1a value lives
    /// here too — if the bridge corrupts the buffer or returns the wrong
    /// integer width, this test catches it.)
    func testCPerfBridge_BufferRoundTrip() {
        let bytes: [UInt8] = Array("JXLSwift".utf8)
        let h = bytes.withUnsafeBufferPointer {
            jxlperf_fnv1a($0.baseAddress, $0.count)
        }
        // Non-trivial output (FNV-1a of a non-empty input is never 0).
        XCTAssertNotEqual(h, 0, "FNV-1a of \"JXLSwift\" should be non-zero")

        // Deterministic: same input → same hash.
        let h2 = bytes.withUnsafeBufferPointer {
            jxlperf_fnv1a($0.baseAddress, $0.count)
        }
        XCTAssertEqual(h, h2, "FNV-1a should be deterministic")

        // Avalanche: a one-bit change produces a different hash (one ASCII
        // case flip = one bit).
        let altered: [UInt8] = Array("jXLSwift".utf8)
        let ho = altered.withUnsafeBufferPointer {
            jxlperf_fnv1a($0.baseAddress, $0.count)
        }
        XCTAssertNotEqual(h, ho,
            "FNV-1a should differ for inputs that differ by one bit")

        // Empty buffer is the canonical FNV-1a offset basis (no iterations).
        let empty: [UInt8] = []
        let h0 = empty.withUnsafeBufferPointer {
            jxlperf_fnv1a($0.baseAddress, $0.count)
        }
        XCTAssertEqual(h0, 14_695_981_039_346_656_037,
            "FNV-1a of an empty buffer must equal the 64-bit offset basis")
    }
}
