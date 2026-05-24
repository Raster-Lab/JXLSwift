// Phase J — JPEG ↔ JXL reversible transcoding foundation tests.
// Covers `JPEGSegmentReader` (segment walking, byte-stuffing,
// stand-alone vs payload-bearing markers, malformed-input
// rejection) and `JPEGStructure` (high-level field extraction).
//
// Real-JPEG fixtures generated at test time via the system `sips`
// utility (built-in on macOS) so the test suite stays
// dependency-free.

import XCTest
import Foundation
@testable import JXLSwift

final class JPEGFoundationTests: XCTestCase {

    // MARK: - JPEGMarkerKind

    func testJPEGMarker_StandalonesIdentified() {
        XCTAssertTrue(JPEGMarkerKind.from(markerByte: 0xD8)
            .isStandalone)  // SOI
        XCTAssertTrue(JPEGMarkerKind.from(markerByte: 0xD9)
            .isStandalone)  // EOI
        XCTAssertTrue(JPEGMarkerKind.from(markerByte: 0xD3)
            .isStandalone)  // RST3
        XCTAssertTrue(JPEGMarkerKind.from(markerByte: 0x01)
            .isStandalone)  // TEM
        XCTAssertFalse(JPEGMarkerKind.from(markerByte: 0xDB)
            .isStandalone)  // DQT — has payload
        XCTAssertFalse(JPEGMarkerKind.from(markerByte: 0xC0)
            .isStandalone)  // SOF0 — has payload
    }

    func testJPEGMarker_SOFnNibbleExtraction() {
        if case let .startOfFrame(n) =
            JPEGMarkerKind.from(markerByte: 0xC0) {
            XCTAssertEqual(n, 0)
        } else { XCTFail("expected SOF0") }
        if case let .startOfFrame(n) =
            JPEGMarkerKind.from(markerByte: 0xC2) {
            XCTAssertEqual(n, 2)
        } else { XCTFail("expected SOF2") }
        // 0xC4 is DHT, not a SOF.
        if case .defineHuffmanTable =
            JPEGMarkerKind.from(markerByte: 0xC4) {} else {
            XCTFail("expected DHT")
        }
    }

    func testJPEGMarker_APPnAndRestartRange() {
        if case let .applicationSegment(n) =
            JPEGMarkerKind.from(markerByte: 0xE0) {
            XCTAssertEqual(n, 0)
        } else { XCTFail("expected APP0") }
        if case let .applicationSegment(n) =
            JPEGMarkerKind.from(markerByte: 0xEF) {
            XCTAssertEqual(n, 15)
        } else { XCTFail("expected APP15") }
        if case let .restart(n) =
            JPEGMarkerKind.from(markerByte: 0xD7) {
            XCTAssertEqual(n, 7)
        } else { XCTFail("expected RST7") }
    }

    func testJPEGMarker_UnknownFallsThroughToOther() {
        let m = JPEGMarkerKind.from(markerByte: 0xAA)
        if case .other(let b) = m {
            XCTAssertEqual(b, 0xAA)
        } else {
            XCTFail("expected .other(0xAA), got \(m)")
        }
    }

    // MARK: - JPEGSegmentReader on hand-crafted streams

    /// Minimal JPEG: SOI + APP0 (JFIF) + SOF0 (1×1 1-component
    /// 8-bit) + DQT + DHT + SOS (empty entropy data) + EOI.
    private func minimalJPEG() -> Data {
        var d = Data()
        // SOI
        d.append(contentsOf: [0xFF, 0xD8])
        // APP0 "JFIF\0" length 16 (=2+14 payload)
        d.append(contentsOf: [0xFF, 0xE0, 0x00, 0x10])
        d.append(contentsOf: [0x4A, 0x46, 0x49, 0x46, 0x00])  // JFIF\0
        d.append(contentsOf: [0x01, 0x01])  // v1.1
        d.append(0x00)                       // density units = no units
        d.append(contentsOf: [0x00, 0x01, 0x00, 0x01]) // Xdensity, Ydensity
        d.append(contentsOf: [0x00, 0x00])  // thumbnail w, h
        // DQT length 67 (=2+65), table 0, all-zero 64-byte 8-bit quant
        var dqtLen = 67
        d.append(contentsOf: [0xFF, 0xDB,
                              UInt8(dqtLen >> 8),
                              UInt8(dqtLen & 0xFF)])
        d.append(0x00)  // 8-bit precision, table id 0
        d.append(Data(repeating: 1, count: 64))
        // DHT length 20 (=2+18): 1 class+id + 16 BITS + 1 symbol.
        var dhtLen = 20
        d.append(contentsOf: [0xFF, 0xC4,
                              UInt8(dhtLen >> 8),
                              UInt8(dhtLen & 0xFF)])
        d.append(0x00)  // class 0 (DC), id 0
        // Bit-length counts: 1 symbol with code length 1.
        d.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, 0, 0, 0, 0])
        d.append(0x00)  // the single symbol
        // SOF0 length 11 (=2+9): P=8, Y=0x0001 (1 line), X=0x0001
        // (1 sample), Nf=1, then (Ci=0, H/V=0x11, Tq=0).
        d.append(contentsOf: [0xFF, 0xC0, 0x00, 0x0B])
        d.append(contentsOf: [0x08, 0x00, 0x01, 0x00, 0x01,
                              0x01, 0x00, 0x11, 0x00])
        // SOS length 8 (=2+6): Ns=1, then (Ci=0, Td/Ta=0x00), then
        // Ss=0, Se=63, Ah/Al=0x00.
        d.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08])
        d.append(contentsOf: [0x01, 0x00, 0x00,
                              0x00, 0x3F, 0x00])
        // Entropy data: just a stuffed-FF and an RST0 to exercise
        // skipEntropyData.
        d.append(contentsOf: [0xFF, 0x00])    // stuffed FF
        d.append(contentsOf: [0xFF, 0xD0])    // RST0
        d.append(0x55)                          // one more entropy byte
        // EOI
        d.append(contentsOf: [0xFF, 0xD9])
        _ = dqtLen; _ = dhtLen
        return d
    }

    func testJPEGSegmentReader_WalksMinimalFixture() throws {
        let data = minimalJPEG()
        var reader = JPEGSegmentReader(data)
        let segs = try reader.readAll()
        let kinds = segs.map(\.kind)
        // Expected sequence: SOI, APP0, DQT, DHT, SOF0, SOS, EOI.
        XCTAssertEqual(kinds.count, 7)
        XCTAssertEqual(kinds[0], .startOfImage)
        XCTAssertEqual(kinds[1], .applicationSegment(n: 0))
        XCTAssertEqual(kinds[2], .defineQuantizationTable)
        XCTAssertEqual(kinds[3], .defineHuffmanTable)
        XCTAssertEqual(kinds[4], .startOfFrame(nibble: 0))
        XCTAssertEqual(kinds[5], .startOfScan)
        XCTAssertEqual(kinds[6], .endOfImage)
    }

    func testJPEGSegmentReader_PayloadLengthsCorrect() throws {
        let data = minimalJPEG()
        var reader = JPEGSegmentReader(data)
        let segs = try reader.readAll()
        // APP0 = 14 bytes payload (16 - 2 length-field).
        XCTAssertEqual(segs[1].payload.count, 14)
        XCTAssertEqual(segs[1].payload.prefix(5),
            Data([0x4A, 0x46, 0x49, 0x46, 0x00]))
        // DQT = 65 bytes (1 precision + 64 quant entries).
        XCTAssertEqual(segs[2].payload.count, 65)
        // DHT = 18 bytes (1 class+id + 16 bit-length-counts + 1 sym).
        XCTAssertEqual(segs[3].payload.count, 18)
        // SOF0 = 9 bytes.
        XCTAssertEqual(segs[4].payload.count, 9)
        // SOS = 6 bytes.
        XCTAssertEqual(segs[5].payload.count, 6)
    }

    func testJPEGSegmentReader_RejectsNonJPEG() {
        let bogus = Data([0x42, 0x6F, 0x67, 0x75, 0x73])  // "Bogus"
        var reader = JPEGSegmentReader(bogus)
        XCTAssertThrowsError(try reader.next()) { err in
            guard let e = err as? JPEGParseError else {
                XCTFail("expected JPEGParseError, got \(err)")
                return
            }
            XCTAssertEqual(e, .missingSOI)
        }
    }

    func testJPEGSegmentReader_LooksLikeJPEG() {
        XCTAssertTrue(JPEGSegmentReader.looksLikeJPEG(
            Data([0xFF, 0xD8, 0xFF, 0xE0])))
        XCTAssertFalse(JPEGSegmentReader.looksLikeJPEG(
            Data([0x89, 0x50])))  // PNG magic
        XCTAssertFalse(JPEGSegmentReader.looksLikeJPEG(Data()))
    }

    // MARK: - JPEGStructure

    func testJPEGStructure_OnMinimalFixture() throws {
        let s = try JPEGStructure.read(minimalJPEG())
        XCTAssertEqual(s.width, 1)
        XCTAssertEqual(s.height, 1)
        XCTAssertEqual(s.componentCount, 1)
        XCTAssertEqual(s.precision, 8)
        XCTAssertEqual(s.frameKind, .baselineDCT)
        XCTAssertEqual(s.dqtSegmentCount, 1)
        XCTAssertEqual(s.dhtSegmentCount, 1)
        XCTAssertTrue(s.hasJFIF)
        XCTAssertFalse(s.hasEXIF)
        XCTAssertFalse(s.hasAdobe)
        XCTAssertFalse(s.usesArithmeticCoding)
        XCTAssertFalse(s.hasRestartInterval)
    }

    // MARK: - Real JPEG via `sips`

    /// macOS-built-in `sips` converts a PNM-style image to JPEG.
    /// We synthesise a tiny PPM, run sips, and parse the result.
    /// Skipped if sips is unavailable (non-Darwin or stripped
    /// install).
    func testJPEGStructure_OnRealJPEGFromSIPS() throws {
        guard FileManager.default.isExecutableFile(
            atPath: "/usr/bin/sips") else {
            throw XCTSkip("sips not available on this host")
        }
        let tmp = NSTemporaryDirectory()
        let ppmPath = tmp + "jpegtest-\(UUID().uuidString).ppm"
        let jpgPath = tmp + "jpegtest-\(UUID().uuidString).jpg"
        defer {
            try? FileManager.default.removeItem(atPath: ppmPath)
            try? FileManager.default.removeItem(atPath: jpgPath)
        }
        // 8×8 RGB ramp.
        var ppm = Data("P6\n8 8\n255\n".utf8)
        for y in 0..<8 {
            for x in 0..<8 {
                ppm.append(contentsOf: [
                    UInt8(20 + x * 25),
                    UInt8(40 + y * 25),
                    UInt8(100)
                ])
            }
        }
        try ppm.write(to: URL(fileURLWithPath: ppmPath))

        // Convert: PPM → JPEG via sips. Quality 75 default.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-s", "format", "jpeg", "-s",
                          "formatOptions", "75",
                          ppmPath, "--out", jpgPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("sips conversion failed "
                + "(status \(proc.terminationStatus))")
        }
        let jpg = try Data(contentsOf:
            URL(fileURLWithPath: jpgPath))
        XCTAssertTrue(JPEGSegmentReader.looksLikeJPEG(jpg),
                      "sips output should be a JPEG")
        let s = try JPEGStructure.read(jpg)
        XCTAssertEqual(s.width, 8)
        XCTAssertEqual(s.height, 8)
        XCTAssertEqual(s.componentCount, 3)
        XCTAssertEqual(s.precision, 8)
        // sips uses baseline DCT by default.
        XCTAssertEqual(s.frameKind, .baselineDCT)
        XCTAssertGreaterThan(s.dqtSegmentCount, 0)
        XCTAssertGreaterThan(s.dhtSegmentCount, 0)
        XCTAssertFalse(s.usesArithmeticCoding)
    }

    // MARK: - byte-stuffing + RST skip stress

    func testJPEGSegmentReader_HandlesByteStuffing() throws {
        // Construct: SOI + SOS (length=8, dummy body) + entropy
        // data containing several 0xFF 0x00 stuffed pairs and
        // a couple of RSTn markers + then EOI.
        var d = Data([0xFF, 0xD8])
        d.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08])
        d.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x3F, 0x00])
        // Entropy data: byte-stuffed FFs + RST markers + body.
        d.append(contentsOf: [0x11, 0xFF, 0x00, 0x22,
                              0xFF, 0xD1, 0x33,
                              0xFF, 0x00, 0xFF, 0xD2, 0x44])
        d.append(contentsOf: [0xFF, 0xD9])  // EOI
        var reader = JPEGSegmentReader(d)
        let segs = try reader.readAll()
        let kinds = segs.map(\.kind)
        XCTAssertEqual(kinds, [
            .startOfImage, .startOfScan, .endOfImage
        ])
    }
}
