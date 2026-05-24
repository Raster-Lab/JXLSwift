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
