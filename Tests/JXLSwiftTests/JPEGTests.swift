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

    // MARK: - JPEGQuantTable

    func testJPEGQuantTable_ParsesSingleEightBitTable() throws {
        // One DQT, 8-bit, table id 2, values 1..64 in zig-zag order.
        var payload = Data([0x02])  // Pq=0, Tq=2
        for k: UInt8 in 1...64 { payload.append(k) }
        let tables = try JPEGQuantTable.parse(dqtPayload: payload)
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].tableId, 2)
        XCTAssertEqual(tables[0].precision, .bits8)
        XCTAssertEqual(tables[0].zigZagValues.count, 64)
        XCTAssertEqual(tables[0].zigZagValues.first, 1)
        XCTAssertEqual(tables[0].zigZagValues.last, 64)
    }

    func testJPEGQuantTable_ParsesSixteenBitTable() throws {
        // One DQT, 16-bit, table id 0, value k stored as
        // (0x01, k) → 0x0100 + k.
        var payload = Data([0x10])  // Pq=1, Tq=0
        for k: UInt8 in 0..<64 {
            payload.append(0x01)
            payload.append(k)
        }
        let tables = try JPEGQuantTable.parse(dqtPayload: payload)
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].precision, .bits16)
        XCTAssertEqual(tables[0].zigZagValues[0], 0x0100)
        XCTAssertEqual(tables[0].zigZagValues[63], 0x0100 + 63)
    }

    func testJPEGQuantTable_ParsesMultipleTablesInOneSegment() throws {
        // Two 8-bit tables back-to-back.
        var payload = Data([0x00])  // table 0
        for k: UInt8 in 1...64 { payload.append(k) }
        payload.append(0x01)        // table 1
        for k: UInt8 in 0..<64 { payload.append(UInt8(100 + Int(k))) }
        let tables = try JPEGQuantTable.parse(dqtPayload: payload)
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(tables[0].tableId, 0)
        XCTAssertEqual(tables[1].tableId, 1)
        XCTAssertEqual(tables[1].zigZagValues[0], 100)
        XCTAssertEqual(tables[1].zigZagValues[63], 163)
    }

    func testJPEGQuantTable_RejectsTruncatedPayload() {
        let payload = Data([0x00, 0x01, 0x02])  // header + 2 bytes
        XCTAssertThrowsError(
            try JPEGQuantTable.parse(dqtPayload: payload))
    }

    func testJPEGQuantTable_RejectsInvalidPrecisionNibble() {
        var payload = Data([0xF0])  // Pq=15, Tq=0
        payload.append(Data(repeating: 0, count: 64))
        XCTAssertThrowsError(
            try JPEGQuantTable.parse(dqtPayload: payload))
    }

    /// `JPEGStructure.quantTables(in:)` against the minimal
    /// fixture returns the all-1s 8-bit table we baked in.
    func testJPEGStructure_QuantTablesOnFixture() throws {
        let tables = try JPEGStructure.quantTables(
            in: minimalJPEG())
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].tableId, 0)
        XCTAssertEqual(tables[0].precision, .bits8)
        XCTAssertEqual(tables[0].zigZagValues,
                       Array(repeating: 1, count: 64))
    }

    /// `JPEGStructure.quantTables(in:)` against a sips-produced
    /// JPEG returns one or more 8-bit tables of 64 values each.
    func testJPEGStructure_QuantTablesOnRealJPEG() throws {
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
            throw XCTSkip("sips conversion failed")
        }
        let jpg = try Data(contentsOf:
            URL(fileURLWithPath: jpgPath))
        let tables = try JPEGStructure.quantTables(in: jpg)
        // sips writes 2 tables (luma + chroma) by default for RGB.
        XCTAssertGreaterThanOrEqual(tables.count, 1)
        for t in tables {
            XCTAssertEqual(t.zigZagValues.count, 64)
            // DC factor (zig-zag index 0) should be a small positive
            // integer for a quality-75 luma table.
            if t.tableId == 0 {
                XCTAssertGreaterThan(t.zigZagValues[0], 0)
                XCTAssertLessThan(t.zigZagValues[0], 100)
            }
        }
    }

    // MARK: - JPEGHuffmanTable

    func testJPEGHuffmanTable_ParsesSingleDCTable() throws {
        // 1 table: class DC (0), id 0, single symbol of code
        // length 1 (so bits = [1, 0, 0, ..., 0], one symbol 0x00).
        var payload = Data([0x00])  // Tc=0, Th=0
        payload.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0, 0, 0, 0])
        payload.append(0x00)
        let tables = try JPEGHuffmanTable.parse(
            dhtPayload: payload)
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].class, .dc)
        XCTAssertEqual(tables[0].tableId, 0)
        XCTAssertEqual(tables[0].bits[0], 1)
        XCTAssertEqual(tables[0].huffvals, [0x00])
    }

    func testJPEGHuffmanTable_ParsesACTable() throws {
        // 1 table: class AC (1), id 1, 3 symbols at length 2:
        // bits = [0, 3, 0, ..., 0], huffvals = [0x11, 0x21, 0x31].
        var payload = Data([0x11])  // Tc=1, Th=1
        payload.append(contentsOf: [0, 3, 0, 0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0, 0, 0, 0])
        payload.append(contentsOf: [0x11, 0x21, 0x31])
        let tables = try JPEGHuffmanTable.parse(
            dhtPayload: payload)
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].class, .ac)
        XCTAssertEqual(tables[0].tableId, 1)
        XCTAssertEqual(tables[0].huffvals, [0x11, 0x21, 0x31])
    }

    func testJPEGHuffmanTable_ParsesMultipleTablesInOneSegment()
        throws
    {
        // Two tables: DC0 with 1 symbol, AC0 with 2 symbols.
        var payload = Data([0x00])
        payload.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0, 0, 0, 0])
        payload.append(0x05)
        payload.append(0x10)  // Tc=1, Th=0
        payload.append(contentsOf: [0, 2, 0, 0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0, 0, 0, 0])
        payload.append(contentsOf: [0xAA, 0xBB])
        let tables = try JPEGHuffmanTable.parse(
            dhtPayload: payload)
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(tables[0].class, .dc)
        XCTAssertEqual(tables[0].huffvals, [0x05])
        XCTAssertEqual(tables[1].class, .ac)
        XCTAssertEqual(tables[1].huffvals, [0xAA, 0xBB])
    }

    func testJPEGHuffmanTable_RejectsTruncatedSymbolList() {
        var payload = Data([0x00])
        // Claim 5 symbols at length 1.
        payload.append(contentsOf: [5, 0, 0, 0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0, 0, 0, 0])
        // ... but only provide 2.
        payload.append(contentsOf: [0x10, 0x20])
        XCTAssertThrowsError(
            try JPEGHuffmanTable.parse(dhtPayload: payload))
    }

    func testJPEGHuffmanTable_RejectsExcessiveSymbolCount() {
        var payload = Data([0x00])
        // All-255s would claim 16 * 255 = 4080 symbols (>> 256).
        payload.append(Data(repeating: 0xFF, count: 16))
        XCTAssertThrowsError(
            try JPEGHuffmanTable.parse(dhtPayload: payload))
    }

    /// `JPEGStructure.huffmanTables(in:)` on the minimal fixture
    /// returns the single trivial DC table we baked in.
    func testJPEGStructure_HuffmanTablesOnFixture() throws {
        let tables = try JPEGStructure.huffmanTables(
            in: minimalJPEG())
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].class, .dc)
        XCTAssertEqual(tables[0].tableId, 0)
        XCTAssertEqual(tables[0].huffvals, [0x00])
    }

    /// On a real sips-emitted JPEG, expect at least one DC + one
    /// AC table; symbols should be in the 0..255 byte range.
    func testJPEGStructure_HuffmanTablesOnRealJPEG() throws {
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-s", "format", "jpeg",
                          "-s", "formatOptions", "75",
                          ppmPath, "--out", jpgPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("sips conversion failed")
        }
        let jpg = try Data(contentsOf:
            URL(fileURLWithPath: jpgPath))
        let tables = try JPEGStructure.huffmanTables(in: jpg)
        XCTAssertGreaterThanOrEqual(tables.count, 2,
            "expected at least one DC + AC table")
        let hasDC = tables.contains { $0.class == .dc }
        let hasAC = tables.contains { $0.class == .ac }
        XCTAssertTrue(hasDC,
            "no DC Huffman table in sips JPEG")
        XCTAssertTrue(hasAC,
            "no AC Huffman table in sips JPEG")
        for t in tables {
            XCTAssertEqual(t.bits.count, 16)
            XCTAssertEqual(t.huffvals.count,
                t.bits.reduce(0) { $0 + Int($1) })
        }
    }

    // MARK: - SOFn per-component records

    func testJPEGFrameComponents_OnFixture() throws {
        let comps = try JPEGStructure.frameComponents(
            in: minimalJPEG())
        XCTAssertEqual(comps.count, 1)
        // Fixture uses Ci=0 (the bytes are encoder's choice; JFIF
        // typically uses 1=Y but the spec allows 0..255).
        XCTAssertEqual(comps[0].componentId, 0)
        XCTAssertEqual(comps[0].hSamplingFactor, 1)
        XCTAssertEqual(comps[0].vSamplingFactor, 1)
        XCTAssertEqual(comps[0].quantTableId, 0)
    }

    func testJPEGFrameComponents_OnRealJPEG() throws {
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-s", "format", "jpeg",
                          "-s", "formatOptions", "75",
                          ppmPath, "--out", jpgPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("sips conversion failed")
        }
        let jpg = try Data(contentsOf:
            URL(fileURLWithPath: jpgPath))
        let comps = try JPEGStructure.frameComponents(in: jpg)
        XCTAssertEqual(comps.count, 3)  // RGB JPEG → 3 components
        for c in comps {
            XCTAssertTrue((1...4).contains(c.hSamplingFactor))
            XCTAssertTrue((1...4).contains(c.vSamplingFactor))
            XCTAssertTrue((0...3).contains(c.quantTableId))
        }
    }

    // MARK: - SOS scan headers

    func testJPEGScanHeader_OnFixture() throws {
        let scans = try JPEGStructure.scanHeaders(
            in: minimalJPEG())
        XCTAssertEqual(scans.count, 1)
        let s = scans[0]
        XCTAssertEqual(s.components.count, 1)
        // Fixture SOS payload binds the scan to Cs=0 to match the
        // SOF Ci=0 above. (Real JFIF emitters number from 1, but
        // the spec allows 0..255.)
        XCTAssertEqual(s.components[0].componentId, 0)
        XCTAssertEqual(s.components[0].dcTableId, 0)
        XCTAssertEqual(s.components[0].acTableId, 0)
        XCTAssertEqual(s.spectralSelectionStart, 0)
        XCTAssertEqual(s.spectralSelectionEnd, 63)
        XCTAssertTrue(s.isSequential)
    }

    func testJPEGScanHeader_OnRealJPEG() throws {
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-s", "format", "jpeg",
                          "-s", "formatOptions", "75",
                          ppmPath, "--out", jpgPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("sips conversion failed")
        }
        let jpg = try Data(contentsOf:
            URL(fileURLWithPath: jpgPath))
        let scans = try JPEGStructure.scanHeaders(in: jpg)
        XCTAssertGreaterThanOrEqual(scans.count, 1)
        XCTAssertTrue(scans[0].isSequential,
            "baseline sips JPEG should produce a sequential scan")
        // All 3 RGB components present in the single sequential
        // scan.
        XCTAssertEqual(scans[0].components.count, 3)
    }

    func testJPEGScanHeader_RejectsTruncatedPayload() {
        // Ns = 2 but only one component record provided.
        var payload = Data([0x02])
        payload.append(contentsOf: [0x01, 0x00])  // C1 + Td/Ta
        XCTAssertThrowsError(
            try JPEGScanHeader.parse(sosPayload: payload))
    }

    // MARK: - JPEGHuffmanCodebook (§C.2 canonical-code build)

    /// 2-symbol code: lengths [1,1] → codes 0, 1 (both 1-bit).
    func testJPEGHuffmanCodebook_TwoOneBitSymbols() throws {
        let table = JPEGHuffmanTable(
            class: .dc, tableId: 0,
            bits: [2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0xAA, 0xBB])
        let book = try table.buildCodebook()
        XCTAssertEqual(book.codes.count, 2)
        XCTAssertEqual(book.codes[0].code, 0)
        XCTAssertEqual(book.codes[0].length, 1)
        XCTAssertEqual(book.codes[0].symbol, 0xAA)
        XCTAssertEqual(book.codes[1].code, 1)
        XCTAssertEqual(book.codes[1].length, 1)
        XCTAssertEqual(book.codes[1].symbol, 0xBB)
    }

    /// Classic hand example: lengths [0,3,1,...] (3 length-2
    /// codes + 1 length-3 code). Canonical codes are
    /// 00, 01, 10, 110.
    func testJPEGHuffmanCodebook_HandCanonicalCodes() throws {
        let table = JPEGHuffmanTable(
            class: .ac, tableId: 0,
            bits: [0,3,1,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x01, 0x02, 0x03, 0x04])
        let book = try table.buildCodebook()
        XCTAssertEqual(book.codes.map(\.code),  [0b00, 0b01, 0b10, 0b110])
        XCTAssertEqual(book.codes.map(\.length), [2, 2, 2, 3])
        XCTAssertEqual(book.codes.map(\.symbol),
                       [0x01, 0x02, 0x03, 0x04])
    }

    /// Round-trip: encode each symbol's canonical bits, decode
    /// them back with `decodeSymbol`. Exercises maxcode /
    /// mincode / valoffset together.
    func testJPEGHuffmanCodebook_DecodeRoundTrip() throws {
        let table = JPEGHuffmanTable(
            class: .ac, tableId: 0,
            bits: [0,3,1,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x01, 0x02, 0x03, 0x04])
        let book = try table.buildCodebook()
        for entry in book.codes {
            // Emit `length` bits of `code` MSB-first into a queue.
            var bits: [Int] = []
            for i in (0..<entry.length).reversed() {
                bits.append(Int((entry.code >> UInt32(i)) & 1))
            }
            var idx = 0
            let s = book.decodeSymbol(
                nextBit: {
                    defer { idx += 1 }
                    return idx < bits.count ? bits[idx] : nil
                },
                huffvals: table.huffvals)
            XCTAssertEqual(s, entry.symbol,
                "round-trip failed for symbol "
                + "0x\(String(entry.symbol, radix: 16))")
        }
    }

    /// On a real sips JPEG, build codebooks for every DHT and
    /// confirm the maxcode chain is monotone and the per-symbol
    /// lengths sum back to `huffvals.count`.
    func testJPEGHuffmanCodebook_OnRealJPEG() throws {
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-s", "format", "jpeg",
                          "-s", "formatOptions", "75",
                          ppmPath, "--out", jpgPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("sips conversion failed")
        }
        let jpg = try Data(contentsOf:
            URL(fileURLWithPath: jpgPath))
        let tables = try JPEGStructure.huffmanTables(in: jpg)
        XCTAssertFalse(tables.isEmpty)
        for table in tables {
            let book = try table.buildCodebook()
            XCTAssertEqual(book.codes.count, table.huffvals.count)
            // Per-symbol lengths sum back to huffvals.count.
            let totalLen = book.codes.map(\.length).reduce(0, +)
            XCTAssertEqual(book.codes.count, table.huffvals.count)
            XCTAssertGreaterThan(totalLen, 0)
            // maxcode entries that exist are monotone non-decreasing
            // when reinterpreted as left-aligned values
            // (canonical-code invariant).
            var prev = -1
            for L in 1...16 {
                let mc = book.maxcode[L - 1]
                if mc < 0 { continue }
                // Left-align to 16 bits so the comparison is
                // length-independent.
                let leftAligned = mc << (16 - L)
                XCTAssertGreaterThanOrEqual(leftAligned, prev,
                    "maxcode chain not monotone at length \(L)")
                prev = leftAligned
            }
        }
    }

    /// Decoding from a too-short bit stream returns nil cleanly
    /// instead of crashing.
    func testJPEGHuffmanCodebook_DecodeOnExhaustedBits() throws {
        let table = JPEGHuffmanTable(
            class: .dc, tableId: 0,
            bits: [2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x01, 0x02])
        let book = try table.buildCodebook()
        var calls = 0
        let s = book.decodeSymbol(
            nextBit: { calls += 1; return nil },
            huffvals: table.huffvals)
        XCTAssertNil(s)
        XCTAssertEqual(calls, 1)
    }

    // MARK: - JPEGBitReader

    func testJPEGBitReader_ReadsMSBFirst() throws {
        // 0b10110011 = 0xB3 — reading bits one at a time should
        // yield 1, 0, 1, 1, 0, 0, 1, 1.
        var r = JPEGBitReader(Data([0xB3]))
        let bits = (0..<8).map { _ in try! r.readBit() }
        XCTAssertEqual(bits, [1, 0, 1, 1, 0, 0, 1, 1])
    }

    func testJPEGBitReader_ReadBitsAcrossByteBoundary() throws {
        // 0xB3 0x95 = 10110011 10010101. Reading 12 bits MSB-first
        // yields 0b1011_0011_1001 = 0xB39.
        var r = JPEGBitReader(Data([0xB3, 0x95]))
        let v = try r.readBits(12)
        XCTAssertEqual(v, 0xB39)
    }

    func testJPEGBitReader_HandlesStuffedFF() throws {
        // The literal byte 0xFF arrives as 0xFF 0x00; the bit
        // reader should silently consume the 0x00. So 0xFF 0x00
        // 0xC3 streamed bit-by-bit gives the bits of 0xFFC3.
        var r = JPEGBitReader(Data([0xFF, 0x00, 0xC3]))
        let v = try r.readBits(16)
        XCTAssertEqual(v, 0xFFC3)
    }

    func testJPEGBitReader_DetectsRSTMarker() throws {
        // 0x10 0xFF 0xD2 0x20 — second byte is FF D2 (RST2),
        // should be silently skipped and markerSeen set to 0xD2.
        var r = JPEGBitReader(
            Data([0x10, 0xFF, 0xD2, 0x20]))
        _ = try r.readBits(8)       // consume 0x10
        XCTAssertNil(r.markerSeen)
        let v = try r.readBits(8)   // pull next entropy byte
        XCTAssertEqual(v, 0x20)
        XCTAssertEqual(r.markerSeen, 0xD2)
    }

    func testJPEGBitReader_ThrowsOnNonRSTMarker() throws {
        // 0xAA 0xFF 0xD9 — entropy data ends at the EOI marker.
        // Reading past the 8th bit should throw .sawMarker(0xD9).
        var r = JPEGBitReader(Data([0xAA, 0xFF, 0xD9]))
        _ = try r.readBits(8)
        XCTAssertThrowsError(try r.readBit()) { err in
            guard case let JPEGBitReaderError.sawMarker(m) = err
            else {
                XCTFail("expected .sawMarker, got \(err)")
                return
            }
            XCTAssertEqual(m, 0xD9)
        }
        // The marker pair should still be visible at the source
        // cursor for the caller to re-read.
        XCTAssertEqual(r.sourceByteOffset, 1)
    }

    func testJPEGBitReader_ThrowsOnTruncated() throws {
        var r = JPEGBitReader(Data())
        XCTAssertThrowsError(try r.readBit()) { err in
            XCTAssertEqual(err as? JPEGBitReaderError,
                           .truncated)
        }
    }

    // MARK: - JPEGBlockDecoder

    /// All-zero block: DC delta = 0, EOB right after. Single bit
    /// each from a minimal table: huffvals=[0x00], code "0" for
    /// both DC and AC sides.
    func testJPEGBlock_AllZero() throws {
        let dcTable = JPEGHuffmanTable(
            class: .dc, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x00])  // size 0
        let acTable = JPEGHuffmanTable(
            class: .ac, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x00])  // EOB
        let dcBook = try dcTable.buildCodebook()
        let acBook = try acTable.buildCodebook()
        var reader = JPEGBitReader(Data([0x00]))
        var pred = JPEGDCPredictor()
        let block = try JPEGBlockDecoder.decode(
            from: &reader,
            dcCodebook: dcBook, dcHuffvals: dcTable.huffvals,
            acCodebook: acBook, acHuffvals: acTable.huffvals,
            dcPredictor: &pred)
        XCTAssertEqual(block.coefficients,
                       Array(repeating: 0, count: 64))
        XCTAssertEqual(pred.value, 0)
    }

    /// DC = 7. Single DC symbol size=3 at code "0", magnitude
    /// "111" → raw=7, high=1 → value +7. Then EOB.
    func testJPEGBlock_DCOnly_PositiveSeven() throws {
        let dcTable = JPEGHuffmanTable(
            class: .dc, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x03])  // DC size 3
        let acTable = JPEGHuffmanTable(
            class: .ac, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x00])  // EOB
        let dcBook = try dcTable.buildCodebook()
        let acBook = try acTable.buildCodebook()
        // Bit stream: 0 (DC code) + 111 (mag 7) + 0 (EOB) = 01110
        // Padded to 8 bits: 01110000 = 0x70
        var reader = JPEGBitReader(Data([0x70]))
        var pred = JPEGDCPredictor()
        let block = try JPEGBlockDecoder.decode(
            from: &reader,
            dcCodebook: dcBook, dcHuffvals: dcTable.huffvals,
            acCodebook: acBook, acHuffvals: acTable.huffvals,
            dcPredictor: &pred)
        XCTAssertEqual(block.coefficients[0], 7)
        XCTAssertEqual(block.coefficients.dropFirst().reduce(0,+),
                       0)
        XCTAssertEqual(pred.value, 7)
    }

    /// DC = -3: size-2 covers magnitudes ±[2..3]. raw=0
    /// (bit pattern "00") encodes -3 via EXTEND(V=0, T=2):
    /// Vt=2, V<Vt → V + (-4+1) = -3.
    func testJPEGBlock_DCOnly_NegativeThree() throws {
        let dcTable = JPEGHuffmanTable(
            class: .dc, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x02])  // DC size 2
        let acTable = JPEGHuffmanTable(
            class: .ac, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x00])
        let dcBook = try dcTable.buildCodebook()
        let acBook = try acTable.buildCodebook()
        // Bit stream: 0 (DC code) + 00 (raw=0) + 0 (EOB) = 0000
        // Padded: 0x00.
        var reader = JPEGBitReader(Data([0x00]))
        var pred = JPEGDCPredictor()
        let block = try JPEGBlockDecoder.decode(
            from: &reader,
            dcCodebook: dcBook, dcHuffvals: dcTable.huffvals,
            acCodebook: acBook, acHuffvals: acTable.huffvals,
            dcPredictor: &pred)
        XCTAssertEqual(block.coefficients[0], -3)
        XCTAssertEqual(pred.value, -3)
    }

    /// DC predictor accumulates across blocks: block 1 DC=5,
    /// block 2 DC delta=6 → block 2 absolute DC = 11.
    func testJPEGBlock_DCDifferentialAccumulates() throws {
        let dcTable = JPEGHuffmanTable(
            class: .dc, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x03])
        let acTable = JPEGHuffmanTable(
            class: .ac, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x00])
        let dcBook = try dcTable.buildCodebook()
        let acBook = try acTable.buildCodebook()
        // Block 1: "0" + "101" + "0" = 01010 (DC delta +5)
        // Block 2: "0" + "110" + "0" = 01100 (DC delta +6)
        // 10 bits → 0101001100 → 01010011 00000000 = 0x53 0x00
        var reader = JPEGBitReader(Data([0x53, 0x00]))
        var pred = JPEGDCPredictor()
        let b1 = try JPEGBlockDecoder.decode(
            from: &reader,
            dcCodebook: dcBook, dcHuffvals: dcTable.huffvals,
            acCodebook: acBook, acHuffvals: acTable.huffvals,
            dcPredictor: &pred)
        let b2 = try JPEGBlockDecoder.decode(
            from: &reader,
            dcCodebook: dcBook, dcHuffvals: dcTable.huffvals,
            acCodebook: acBook, acHuffvals: acTable.huffvals,
            dcPredictor: &pred)
        XCTAssertEqual(b1.coefficients[0], 5)
        XCTAssertEqual(b2.coefficients[0], 11)
        XCTAssertEqual(pred.value, 11)
    }

    /// ZRL + single AC value: AC table with 3 length-2 codes
    /// (00=ZRL, 01=(run=0 size=1), 10=EOB). Stream produces an
    /// AC value of +1 at zig-zag position 17 (natural index 24).
    func testJPEGBlock_ZRLThenValue() throws {
        let dcTable = JPEGHuffmanTable(
            class: .dc, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x00])  // DC size 0
        let acTable = JPEGHuffmanTable(
            class: .ac, tableId: 0,
            bits: [0,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0xF0, 0x01, 0x00])  // ZRL, (0,1), EOB
        let dcBook = try dcTable.buildCodebook()
        let acBook = try acTable.buildCodebook()
        // Stream: "0" (DC) + "00" (ZRL) + "01" (0,1) + "1" (mag=1)
        // + "10" (EOB) = 8 bits = 00001110 = 0x0E
        var reader = JPEGBitReader(Data([0x0E]))
        var pred = JPEGDCPredictor()
        let block = try JPEGBlockDecoder.decode(
            from: &reader,
            dcCodebook: dcBook, dcHuffvals: dcTable.huffvals,
            acCodebook: acBook, acHuffvals: acTable.huffvals,
            dcPredictor: &pred)
        // Zig-zag pos 0 = DC = 0. ZRL skipped pos 1..16. Pos 17
        // gets +1. zigZag[17] = 24 per Figure A.6.
        // Zig-zag pos 0 = DC = 0. ZRL skipped zig-zag pos 1..16.
        // The (0,1) token writes +1 at zig-zag pos 17 — which
        // JPEGZigZag.order maps to natural index 19.
        let target = JPEGZigZag.order[17]
        XCTAssertEqual(block.coefficients[0], 0)
        XCTAssertEqual(block.coefficients[target], 1,
            "expected +1 at natural index \(target)")
        // No other non-zero coefficients.
        for i in 0..<64 where i != target {
            XCTAssertEqual(block.coefficients[i], 0,
                "non-zero at unexpected index \(i)")
        }
    }

    /// Truncated stream → propagates JPEGBitReaderError up.
    /// Empty input — first DC bit read should throw .truncated.
    func testJPEGBlock_TruncatedThrows() throws {
        let dcTable = JPEGHuffmanTable(
            class: .dc, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x03])
        let acTable = JPEGHuffmanTable(
            class: .ac, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x00])
        let dcBook = try dcTable.buildCodebook()
        let acBook = try acTable.buildCodebook()
        var reader = JPEGBitReader(Data())  // empty
        var pred = JPEGDCPredictor()
        XCTAssertThrowsError(
            try JPEGBlockDecoder.decode(
                from: &reader,
                dcCodebook: dcBook, dcHuffvals: dcTable.huffvals,
                acCodebook: acBook, acHuffvals: acTable.huffvals,
                dcPredictor: &pred))
    }

    /// Zig-zag table is the canonical Figure A.6 layout.
    func testJPEGZigZag_KnownEntries() {
        XCTAssertEqual(JPEGZigZag.order[0], 0)
        XCTAssertEqual(JPEGZigZag.order[1], 1)
        XCTAssertEqual(JPEGZigZag.order[2], 8)
        XCTAssertEqual(JPEGZigZag.order[63], 63)
        XCTAssertEqual(JPEGZigZag.order.count, 64)
        // Every natural index appears exactly once.
        XCTAssertEqual(Set(JPEGZigZag.order).count, 64)
    }

    // MARK: - JPEGDequantiser

    func testJPEGDequantiser_IdentityTable() {
        // Quant table of all 1s → dequantised values match input.
        let table = JPEGQuantTable(
            tableId: 0, precision: .bits8,
            zigZagValues: Array(repeating: 1, count: 64))
        let input = JPEGCoefficientBlock(
            (0..<64).map { Int32($0) - 32 })
        let out = JPEGDequantiser.dequantising(
            input, using: table)
        XCTAssertEqual(out.coefficients, input.coefficients)
    }

    func testJPEGDequantiser_ConstantMultiplier() {
        // Quant table of all 3s → every coefficient × 3.
        let table = JPEGQuantTable(
            tableId: 0, precision: .bits8,
            zigZagValues: Array(repeating: 3, count: 64))
        let input = JPEGCoefficientBlock(
            (0..<64).map { Int32($0) - 32 })
        let out = JPEGDequantiser.dequantising(
            input, using: table)
        for i in 0..<64 {
            XCTAssertEqual(out.coefficients[i],
                           input.coefficients[i] * 3,
                "wrong dequant at index \(i)")
        }
    }

    /// The quant table is stored in zig-zag order, so testing
    /// `zigZagValues[1]` (which multiplies natural index 1) and
    /// `zigZagValues[2]` (natural index 8) must hit different
    /// positions. Catches a transposed mapping.
    func testJPEGDequantiser_ZigZagMappingIsCorrect() {
        var z = Array<UInt16>(repeating: 1, count: 64)
        z[1] = 10   // multiplies the coefficient at zig-zag
                    // position 1, which is natural index 1.
        z[2] = 100  // zig-zag position 2 → natural index 8.
        let table = JPEGQuantTable(
            tableId: 0, precision: .bits8, zigZagValues: z)
        var block = JPEGCoefficientBlock(
            Array(repeating: Int32(1), count: 64))
        JPEGDequantiser.dequantise(&block, using: table)
        XCTAssertEqual(block.coefficients[0], 1)    // DC unchanged
        XCTAssertEqual(block.coefficients[1], 10)
        XCTAssertEqual(block.coefficients[8], 100)
        // Spot-check a position that shouldn't have been touched
        // by the special multipliers above.
        XCTAssertEqual(block.coefficients[16], 1)
    }

    func testJPEGDequantiser_InPlaceMatchesFunctional() {
        let table = JPEGQuantTable(
            tableId: 0, precision: .bits8,
            zigZagValues: (1...64).map { UInt16($0) })
        let input = JPEGCoefficientBlock(
            Array(repeating: Int32(2), count: 64))
        var a = input
        JPEGDequantiser.dequantise(&a, using: table)
        let b = JPEGDequantiser.dequantising(
            input, using: table)
        XCTAssertEqual(a.coefficients, b.coefficients)
    }

    // MARK: - JPEGScanDecoder

    /// Synthetic: 8×8 grayscale, single 1×1-sampled component,
    /// all-zero block. DC predictor returns 0, EOB right after.
    /// Mirrors the block-decoder all-zero test but exercises the
    /// MCU dispatch + per-component output grid wiring.
    func testJPEGScanDecoder_SingleGrayscaleBlock() throws {
        let dcTable = JPEGHuffmanTable(
            class: .dc, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x00])
        let acTable = JPEGHuffmanTable(
            class: .ac, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x00])
        let dcBook = try dcTable.buildCodebook()
        let acBook = try acTable.buildCodebook()

        let frameComps = [JPEGFrameComponent(
            componentId: 1, hSamplingFactor: 1,
            vSamplingFactor: 1, quantTableId: 0)]
        let scanHeader = JPEGScanHeader(
            components: [JPEGScanComponent(
                componentId: 1, dcTableId: 0,
                acTableId: 0)],
            spectralSelectionStart: 0,
            spectralSelectionEnd: 63,
            successiveApproximationHigh: 0,
            successiveApproximationLow: 0)

        // 2 bits (DC code "0" + EOB "0") padded to 0x00.
        var reader = JPEGBitReader(Data([0x00]))
        let dcMap: JPEGHuffmanCodebookMap =
            [0: (dcBook, dcTable.huffvals)]
        let acMap: JPEGHuffmanCodebookMap =
            [0: (acBook, acTable.huffvals)]
        let out = try JPEGScanDecoder.decodeBaselineSequential(
            from: &reader,
            scanHeader: scanHeader,
            frameComponents: frameComps,
            imageWidth: 8, imageHeight: 8,
            dcCodebooks: dcMap, acCodebooks: acMap)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].componentId, 1)
        XCTAssertEqual(out[0].blocksWide, 1)
        XCTAssertEqual(out[0].blocksHigh, 1)
        XCTAssertEqual(out[0].blocks.count, 1)
        XCTAssertEqual(out[0].blocks[0].coefficients,
                       Array(repeating: 0, count: 64))
    }

    /// Synthetic: 16×16 grayscale, 1×1 sampling → 2×2 = 4 blocks,
    /// each with DC = the per-block sequence 5, 11, 17, 23 (each
    /// block's DC delta is +6, predictor accumulates). Verifies
    /// MCU-row × MCU-col walk + DC differential accumulation.
    func testJPEGScanDecoder_Grayscale2x2DCAccumulation() throws {
        let dcTable = JPEGHuffmanTable(
            class: .dc, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x03])  // size 3
        let acTable = JPEGHuffmanTable(
            class: .ac, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x00])  // EOB
        let dcBook = try dcTable.buildCodebook()
        let acBook = try acTable.buildCodebook()

        // Per block: "0" (DC code) + 3 mag bits + "0" (EOB)
        // = 5 bits.
        // Block 0: DC delta +5 → mag bits "101"
        // Block 1: DC delta +6 → mag bits "110"
        // Block 2: DC delta +6 → mag bits "110"
        // Block 3: DC delta +6 → mag bits "110"
        // 4 × 5 = 20 bits packed MSB-first into 3 bytes (24 bits):
        //   "01010" "01100" "01100" "01100" + "0000" pad
        //   = 01010011 00011000 11000000
        //   = 0x53 0x18 0xC0
        var reader = JPEGBitReader(Data([0x53, 0x18, 0xC0]))
        let frameComps = [JPEGFrameComponent(
            componentId: 1, hSamplingFactor: 1,
            vSamplingFactor: 1, quantTableId: 0)]
        let scanHeader = JPEGScanHeader(
            components: [JPEGScanComponent(
                componentId: 1, dcTableId: 0,
                acTableId: 0)],
            spectralSelectionStart: 0,
            spectralSelectionEnd: 63,
            successiveApproximationHigh: 0,
            successiveApproximationLow: 0)
        let dcMap: JPEGHuffmanCodebookMap =
            [0: (dcBook, dcTable.huffvals)]
        let acMap: JPEGHuffmanCodebookMap =
            [0: (acBook, acTable.huffvals)]
        let out = try JPEGScanDecoder.decodeBaselineSequential(
            from: &reader, scanHeader: scanHeader,
            frameComponents: frameComps,
            imageWidth: 16, imageHeight: 16,
            dcCodebooks: dcMap, acCodebooks: acMap)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].blocksWide, 2)
        XCTAssertEqual(out[0].blocksHigh, 2)
        // Block order: row 0 col 0, row 0 col 1, row 1 col 0,
        // row 1 col 1 (raster within MCU walk; here each MCU is
        // one block since H=V=1).
        XCTAssertEqual(out[0].blocks[0].coefficients[0], 5)
        XCTAssertEqual(out[0].blocks[1].coefficients[0], 11)
        XCTAssertEqual(out[0].blocks[2].coefficients[0], 17)
        XCTAssertEqual(out[0].blocks[3].coefficients[0], 23)
    }

    func testJPEGScanDecoder_RejectsProgressive() throws {
        let dcTable = JPEGHuffmanTable(
            class: .dc, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x00])
        let dcBook = try dcTable.buildCodebook()
        let scanHeader = JPEGScanHeader(
            components: [JPEGScanComponent(
                componentId: 1, dcTableId: 0,
                acTableId: 0)],
            spectralSelectionStart: 0,
            spectralSelectionEnd: 5,    // ← partial band
            successiveApproximationHigh: 0,
            successiveApproximationLow: 0)
        let frameComps = [JPEGFrameComponent(
            componentId: 1, hSamplingFactor: 1,
            vSamplingFactor: 1, quantTableId: 0)]
        var reader = JPEGBitReader(Data([0x00]))
        XCTAssertThrowsError(
            try JPEGScanDecoder.decodeBaselineSequential(
                from: &reader, scanHeader: scanHeader,
                frameComponents: frameComps,
                imageWidth: 8, imageHeight: 8,
                dcCodebooks: [0: (dcBook,
                                  dcTable.huffvals)],
                acCodebooks: [:]))
    }

    func testJPEGScanDecoder_RejectsUnknownComponent() throws {
        let dcTable = JPEGHuffmanTable(
            class: .dc, tableId: 0,
            bits: [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
            huffvals: [0x00])
        let dcBook = try dcTable.buildCodebook()
        let scanHeader = JPEGScanHeader(
            components: [JPEGScanComponent(
                componentId: 99, dcTableId: 0,
                acTableId: 0)],
            spectralSelectionStart: 0,
            spectralSelectionEnd: 63,
            successiveApproximationHigh: 0,
            successiveApproximationLow: 0)
        let frameComps = [JPEGFrameComponent(
            componentId: 1, hSamplingFactor: 1,
            vSamplingFactor: 1, quantTableId: 0)]
        var reader = JPEGBitReader(Data([0x00]))
        XCTAssertThrowsError(
            try JPEGScanDecoder.decodeBaselineSequential(
                from: &reader, scanHeader: scanHeader,
                frameComponents: frameComps,
                imageWidth: 8, imageHeight: 8,
                dcCodebooks: [0: (dcBook,
                                  dcTable.huffvals)],
                acCodebooks: [:]))
    }

    // MARK: - real sips JPEG end-to-end

    /// Run the full pipeline on a sips-produced JPEG: parse
    /// segments → build codebooks → locate entropy data → scan
    /// decode → dequantise → sanity-check the result.
    ///
    /// This is the first "raw JPEG bytes → dequantised DCT
    /// coefficients" round-trip on a real-world fixture and the
    /// natural milestone the Phase J foundation is building
    /// toward.
    func testJPEGScanDecoder_RealSIPSFixture() throws {
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
        // 16×16 RGB gradient so DC values vary across blocks.
        var ppm = Data("P6\n16 16\n255\n".utf8)
        for y in 0..<16 {
            for x in 0..<16 {
                ppm.append(contentsOf: [
                    UInt8(100 + x * 4),
                    UInt8(80 + y * 4),
                    UInt8(150)
                ])
            }
        }
        try ppm.write(to: URL(fileURLWithPath: ppmPath))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-s", "format", "jpeg",
                          "-s", "formatOptions", "75",
                          ppmPath, "--out", jpgPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("sips conversion failed")
        }
        let jpg = try Data(contentsOf:
            URL(fileURLWithPath: jpgPath))

        // Walk segments, capturing what the scan decoder needs.
        var reader = JPEGSegmentReader(jpg)
        var dcMap = JPEGHuffmanCodebookMap()
        var acMap = JPEGHuffmanCodebookMap()
        var quantTables: [JPEGQuantTable] = []
        var frameComponents: [JPEGFrameComponent] = []
        var width = 0, height = 0
        var scanHeader: JPEGScanHeader?
        var restartInterval = 0
        var entropyStartOffset = 0

        while let seg = try reader.next() {
            switch seg.kind {
            case .startOfFrame:
                width = (Int(seg.payload[3]) << 8)
                    | Int(seg.payload[4])
                height = (Int(seg.payload[1]) << 8)
                    | Int(seg.payload[2])
                frameComponents = try JPEGFrameComponent
                    .parseSOFComponents(sofPayload: seg.payload)
            case .defineQuantizationTable:
                quantTables.append(contentsOf:
                    try JPEGQuantTable.parse(
                        dqtPayload: seg.payload))
            case .defineHuffmanTable:
                for t in try JPEGHuffmanTable.parse(
                    dhtPayload: seg.payload)
                {
                    let book = try t.buildCodebook()
                    switch t.class {
                    case .dc:
                        dcMap[t.tableId] = (book, t.huffvals)
                    case .ac:
                        acMap[t.tableId] = (book, t.huffvals)
                    }
                }
            case .defineRestartInterval:
                if seg.payload.count == 2 {
                    restartInterval =
                        (Int(seg.payload[0]) << 8)
                        | Int(seg.payload[1])
                }
            case .startOfScan:
                scanHeader = try JPEGScanHeader.parse(
                    sosPayload: seg.payload)
                entropyStartOffset = reader.byteOffset
            case .endOfImage:
                break
            default:
                break
            }
            if seg.kind == .startOfScan { break }
        }
        guard let scan = scanHeader else {
            XCTFail("no SOS segment found")
            return
        }

        var bitReader = JPEGBitReader(jpg,
            startingAt: entropyStartOffset)
        let comps = try JPEGScanDecoder.decodeBaselineSequential(
            from: &bitReader,
            scanHeader: scan,
            frameComponents: frameComponents,
            imageWidth: width, imageHeight: height,
            dcCodebooks: dcMap, acCodebooks: acMap,
            restartInterval: restartInterval)

        XCTAssertEqual(comps.count, 3,
            "expected 3 components for RGB JPEG")
        for c in comps {
            XCTAssertGreaterThan(c.blocks.count, 0,
                "component \(c.componentId) had no blocks")
            // DC of first block is non-zero (gradient content
            // is non-uniform; sips' DCT will produce a sensible
            // DC value even at q=75).
            XCTAssertNotEqual(
                c.blocks[0].coefficients[0], 0,
                "component \(c.componentId): first block DC "
                + "should be non-zero for real content")
        }

        // Dequantise the first block of each component using
        // its quant table. This is the actual "pixel-ready"
        // path the transcoder will later feed into IDCT or the
        // JXL VarDCT bridge.
        for (i, c) in comps.enumerated() {
            let qtId = frameComponents.first(
                where: { $0.componentId == c.componentId
                })?.quantTableId ?? 0
            guard let qt = quantTables.first(
                where: { $0.tableId == qtId }) else {
                XCTFail("missing quant table \(qtId)")
                return
            }
            let dequant = JPEGDequantiser.dequantising(
                c.blocks[0], using: qt)
            // The dequantised DC magnitude should be larger
            // than the quantised one (Q[0] is small but ≥ 1).
            let q = c.blocks[0].coefficients[0]
            let dq = dequant.coefficients[0]
            XCTAssertGreaterThanOrEqual(abs(dq), abs(q),
                "component \(i) dequant didn't enlarge DC")
        }
    }

    // MARK: - JPEGIDCT

    /// DC-only block (DC = 8 × N, all AC = 0) reconstructs to a
    /// flat sample plane of value N + 128 (level shift).
    /// Reasoning: orthonormal DCT of a constant N-value flat plane
    /// is `[8N, 0, 0, …]` (because the DC basis function has
    /// magnitude `1/√64 = 1/8`, so the inner product with a flat
    /// plane of value N is `N · 64 · 1/8 = 8N`). Inverse should
    /// recover the constant plane.
    func testJPEGIDCT_DCOnlyReconstructsFlat() {
        var coeffs = [Int32](repeating: 0, count: 64)
        coeffs[0] = 8 * 50  // 50 above the centred zero
        let block = JPEGCoefficientBlock(coeffs)
        let samples = JPEGIDCT.inverseTransform8Bit(block)
        for s in samples {
            XCTAssertEqual(s, UInt8(50 + 128),
                "DC-only block must reconstruct to a flat plane")
        }
    }

    /// All-zero block reconstructs to a flat mid-grey plane
    /// (the +128 level shift on top of zero is the unsigned
    /// origin in 8-bit JPEG).
    func testJPEGIDCT_AllZeroIsMidGrey() {
        let block = JPEGCoefficientBlock(
            Array(repeating: Int32(0), count: 64))
        let samples = JPEGIDCT.inverseTransform8Bit(block)
        XCTAssertEqual(samples,
            Array(repeating: UInt8(128), count: 64))
    }

    /// Negative DC saturates at zero — confirms the clamp is in
    /// the right direction.
    func testJPEGIDCT_ClampSaturatesLow() {
        var coeffs = [Int32](repeating: 0, count: 64)
        coeffs[0] = 8 * -200  // far below the visible range
        let block = JPEGCoefficientBlock(coeffs)
        let samples = JPEGIDCT.inverseTransform8Bit(block)
        for s in samples { XCTAssertEqual(s, 0) }
    }

    /// Very-large DC saturates at 255 — confirms the other clamp.
    func testJPEGIDCT_ClampSaturatesHigh() {
        var coeffs = [Int32](repeating: 0, count: 64)
        coeffs[0] = 8 * 500
        let block = JPEGCoefficientBlock(coeffs)
        let samples = JPEGIDCT.inverseTransform8Bit(block)
        for s in samples { XCTAssertEqual(s, 255) }
    }

    /// On the sips real-fixture pipeline: take the first Y block
    /// of a sips JPEG, IDCT it, and confirm every sample is in
    /// the visible 0..255 range. The exact values depend on
    /// content + quantisation; the *shape* assertion (no clamps,
    /// no NaN propagation) is what we want here.
    func testJPEGIDCT_RealSIPSPipeline() throws {
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
        // 16×16 mid-grey constant — IDCT should reconstruct
        // something close to (128, 128, 128) for each pixel.
        var ppm = Data("P6\n16 16\n255\n".utf8)
        ppm.append(Data(repeating: 128, count: 16 * 16 * 3))
        try ppm.write(to: URL(fileURLWithPath: ppmPath))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-s", "format", "jpeg",
                          "-s", "formatOptions", "90",
                          ppmPath, "--out", jpgPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("sips conversion failed")
        }
        let jpg = try Data(contentsOf:
            URL(fileURLWithPath: jpgPath))

        // Reuse the walk pattern from
        // testJPEGScanDecoder_RealSIPSFixture but stop at SOS.
        var reader = JPEGSegmentReader(jpg)
        var dcMap = JPEGHuffmanCodebookMap()
        var acMap = JPEGHuffmanCodebookMap()
        var quantTables: [JPEGQuantTable] = []
        var frameComponents: [JPEGFrameComponent] = []
        var width = 0, height = 0
        var scanHeader: JPEGScanHeader?
        var entropyStartOffset = 0
        while let seg = try reader.next() {
            switch seg.kind {
            case .startOfFrame:
                width = (Int(seg.payload[3]) << 8)
                    | Int(seg.payload[4])
                height = (Int(seg.payload[1]) << 8)
                    | Int(seg.payload[2])
                frameComponents = try JPEGFrameComponent
                    .parseSOFComponents(sofPayload: seg.payload)
            case .defineQuantizationTable:
                quantTables.append(contentsOf:
                    try JPEGQuantTable.parse(
                        dqtPayload: seg.payload))
            case .defineHuffmanTable:
                for t in try JPEGHuffmanTable.parse(
                    dhtPayload: seg.payload)
                {
                    let book = try t.buildCodebook()
                    if t.class == .dc {
                        dcMap[t.tableId] = (book, t.huffvals)
                    } else {
                        acMap[t.tableId] = (book, t.huffvals)
                    }
                }
            case .startOfScan:
                scanHeader = try JPEGScanHeader.parse(
                    sosPayload: seg.payload)
                entropyStartOffset = reader.byteOffset
            default: break
            }
            if seg.kind == .startOfScan { break }
        }
        guard let scan = scanHeader else {
            XCTFail("no SOS"); return
        }
        var bitReader = JPEGBitReader(jpg,
            startingAt: entropyStartOffset)
        let comps = try JPEGScanDecoder.decodeBaselineSequential(
            from: &bitReader, scanHeader: scan,
            frameComponents: frameComponents,
            imageWidth: width, imageHeight: height,
            dcCodebooks: dcMap, acCodebooks: acMap)
        // Dequantise + IDCT the first Y block.
        let yc = comps[0]
        let yqt = quantTables.first(where: {
            $0.tableId == frameComponents.first(where: {
                $0.componentId == yc.componentId
            })?.quantTableId ?? 0
        }) ?? quantTables[0]
        let dq = JPEGDequantiser.dequantising(
            yc.blocks[0], using: yqt)
        let samples = JPEGIDCT.inverseTransform8Bit(dq)
        XCTAssertEqual(samples.count, 64)
        // For a mid-grey input at q=90, the Y block samples
        // should land very close to 128 — large clamp deviation
        // would indicate the dequant or IDCT scaling is off.
        for s in samples {
            XCTAssertGreaterThanOrEqual(Int(s), 100,
                "Y sample \(s) unexpectedly low for mid-grey")
            XCTAssertLessThanOrEqual(Int(s), 156,
                "Y sample \(s) unexpectedly high for mid-grey")
        }
    }

    // MARK: - JPEGColorConversion

    /// JFIF identity: Y=128 Cb=128 Cr=128 → grey (128,128,128).
    func testJPEGColor_NeutralGreyIsGrey() {
        let n = 4
        let y = JPEGSamplePlane(
            componentId: 1, width: n, height: n,
            samples: Array(repeating: 128, count: n * n))
        let cb = JPEGSamplePlane(
            componentId: 2, width: n, height: n,
            samples: Array(repeating: 128, count: n * n))
        let cr = JPEGSamplePlane(
            componentId: 3, width: n, height: n,
            samples: Array(repeating: 128, count: n * n))
        let rgb = JPEGColorConversion.ycbcrToRGB8(
            y: y, cb: cb, cr: cr)
        XCTAssertEqual(rgb,
            Array(repeating: UInt8(128), count: n * n * 3))
    }

    /// Pure red — Y=76, Cb=85, Cr=255 → (255, 0, 0) per JFIF.
    /// (Worked from the inverse direction: R=255 G=0 B=0 →
    /// Y ≈ 76, Cb ≈ 85, Cr ≈ 255 via BT.601 forward).
    func testJPEGColor_NeutralReachesPureRed() {
        let y = JPEGSamplePlane(
            componentId: 1, width: 1, height: 1,
            samples: [76])
        let cb = JPEGSamplePlane(
            componentId: 2, width: 1, height: 1,
            samples: [85])
        let cr = JPEGSamplePlane(
            componentId: 3, width: 1, height: 1,
            samples: [255])
        let rgb = JPEGColorConversion.ycbcrToRGB8(
            y: y, cb: cb, cr: cr)
        // R = 76 + 1.402·(255−128) = 254.054 → rounds to 254;
        // G/B near 0. Allow ±2 since the input Y/Cb/Cr were
        // themselves rounded forward-direction.
        XCTAssertGreaterThanOrEqual(Int(rgb[0]), 252)
        XCTAssertLessThanOrEqual(Int(rgb[1]), 2)
        XCTAssertLessThanOrEqual(Int(rgb[2]), 2)
    }

    // MARK: - JPEGPixelAssembler upsampling

    func testJPEGUpsample_NearestDoubleHorizontal() {
        let plane = JPEGSamplePlane(
            componentId: 1, width: 2, height: 2,
            samples: [10, 20, 30, 40])
        let up = JPEGPixelAssembler.upsampleNearest(
            plane, toWidth: 4, height: 2)
        XCTAssertEqual(up.samples, [
            10, 10, 20, 20,
            30, 30, 40, 40,
        ])
    }

    func testJPEGUpsample_NearestDoubleBoth() {
        let plane = JPEGSamplePlane(
            componentId: 1, width: 2, height: 2,
            samples: [10, 20, 30, 40])
        let up = JPEGPixelAssembler.upsampleNearest(
            plane, toWidth: 4, height: 4)
        XCTAssertEqual(up.samples, [
            10, 10, 20, 20,
            10, 10, 20, 20,
            30, 30, 40, 40,
            30, 30, 40, 40,
        ])
    }

    func testJPEGUpsample_NoOpWhenAlreadyTarget() {
        let plane = JPEGSamplePlane(
            componentId: 1, width: 2, height: 2,
            samples: [1, 2, 3, 4])
        let up = JPEGPixelAssembler.upsampleNearest(
            plane, toWidth: 2, height: 2)
        XCTAssertEqual(up.samples, [1, 2, 3, 4])
    }

    // MARK: - JPEGDecoder end-to-end

    /// Round-trip: synthesise a 16×16 grayscale PPM, encode via
    /// sips, decode with our JPEG pipeline, and confirm the
    /// recovered ImageFrame matches the input within a small
    /// per-sample tolerance (JPEG is lossy at q=90).
    func testJPEGDecoder_GrayscaleRoundTrip() throws {
        guard FileManager.default.isExecutableFile(
            atPath: "/usr/bin/sips") else {
            throw XCTSkip("sips not available on this host")
        }
        let tmp = NSTemporaryDirectory()
        let pgmPath = tmp + "jpegdec-\(UUID().uuidString).pgm"
        let jpgPath = tmp + "jpegdec-\(UUID().uuidString).jpg"
        defer {
            try? FileManager.default.removeItem(atPath: pgmPath)
            try? FileManager.default.removeItem(atPath: jpgPath)
        }
        // 16×16 horizontal grey ramp.
        var pgm = Data("P5\n16 16\n255\n".utf8)
        for y in 0..<16 {
            for x in 0..<16 {
                pgm.append(UInt8(20 + x * 14))
                _ = y
            }
        }
        try pgm.write(to: URL(fileURLWithPath: pgmPath))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-s", "format", "jpeg",
                          "-s", "formatOptions", "90",
                          pgmPath, "--out", jpgPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("sips conversion failed")
        }
        let jpg = try Data(contentsOf:
            URL(fileURLWithPath: jpgPath))
        let frame = try JPEGDecoder.decode(jpg)
        XCTAssertEqual(frame.width, 16)
        XCTAssertEqual(frame.height, 16)
        XCTAssertEqual(frame.channels, 1)
        XCTAssertEqual(frame.colorSpace, .grayscale)
        // The decoded ramp should track the input within ±15
        // per sample (q=90 JPEG plus YCbCr round-trip slack).
        // Read original PPM bytes back for comparison.
        let original = Array(pgm.suffix(16 * 16))
        var maxErr = 0
        for i in 0..<(16 * 16) {
            let d = abs(Int(frame.data[i]) - Int(original[i]))
            if d > maxErr { maxErr = d }
        }
        XCTAssertLessThan(maxErr, 16,
            "grayscale max-error \(maxErr) too high for q=90")
    }

    func testJPEGDecoder_RGBRoundTrip() throws {
        guard FileManager.default.isExecutableFile(
            atPath: "/usr/bin/sips") else {
            throw XCTSkip("sips not available on this host")
        }
        let tmp = NSTemporaryDirectory()
        let ppmPath = tmp + "jpegdec-\(UUID().uuidString).ppm"
        let jpgPath = tmp + "jpegdec-\(UUID().uuidString).jpg"
        defer {
            try? FileManager.default.removeItem(atPath: ppmPath)
            try? FileManager.default.removeItem(atPath: jpgPath)
        }
        // 16×16 mid-grey constant — well within JPEG's
        // tolerance regardless of subsampling.
        var ppm = Data("P6\n16 16\n255\n".utf8)
        ppm.append(Data(repeating: 128, count: 16 * 16 * 3))
        try ppm.write(to: URL(fileURLWithPath: ppmPath))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-s", "format", "jpeg",
                          "-s", "formatOptions", "90",
                          ppmPath, "--out", jpgPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("sips conversion failed")
        }
        let jpg = try Data(contentsOf:
            URL(fileURLWithPath: jpgPath))
        let frame = try JPEGDecoder.decode(jpg)
        XCTAssertEqual(frame.width, 16)
        XCTAssertEqual(frame.height, 16)
        XCTAssertEqual(frame.channels, 3)
        XCTAssertEqual(frame.colorSpace, .sRGB)
        // Every recovered RGB pixel should be near (128, 128, 128).
        var maxErr = 0
        for i in 0..<frame.data.count {
            let d = abs(Int(frame.data[i]) - 128)
            if d > maxErr { maxErr = d }
        }
        XCTAssertLessThan(maxErr, 16,
            "RGB max-error \(maxErr) too high for mid-grey q=90")
    }

    func testJPEGDecoder_RejectsProgressive() throws {
        // We don't have an easy progressive-JPEG generator
        // available at test time, but we can construct a minimal
        // SOF2 fixture by mutating the minimal fixture's SOF
        // marker byte. The decoder should reject with .unsupported.
        var data = minimalJPEG()
        // Find the SOF0 byte (0xFF 0xC0) and change to SOF2.
        for i in 0..<(data.count - 1) {
            if data[i] == 0xFF && data[i + 1] == 0xC0 {
                data[i + 1] = 0xC2
                break
            }
        }
        XCTAssertThrowsError(try JPEGDecoder.decode(data)) { err in
            guard let e = err as? JPEGDecoderError else {
                XCTFail("expected JPEGDecoderError, got \(err)")
                return
            }
            if case .unsupported = e {} else {
                XCTFail("expected .unsupported, got \(e)")
            }
        }
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
