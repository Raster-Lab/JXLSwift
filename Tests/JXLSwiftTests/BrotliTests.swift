// `BrotliTests.swift` — unit tests for the Brotli decoder primitives.
// Phase J step 5. v0.12.0fz scaffold.
//
// At this stage we test the prefix-code reader in isolation. The
// end-to-end decoder tests against `brotli` CLI output land once
// the meta-block + LZ77 layers ship.

import XCTest
@testable import JXLSwift

final class BrotliPrefixCodeTests: XCTestCase {

    /// Construct a `BitReader` from a list of bytes for tests.
    private func bitReader(_ bytes: [UInt8]) -> BitReader {
        return BitReader(Data(bytes))
    }

    // MARK: - Canonical-Huffman construction

    func testPrefixCode_SingleSymbol() throws {
        // 1 symbol, length 0 — singleSymbol fast path.
        let code = try BrotliPrefixCode(
            alphabetSize: 4, codeLengths: [0, 1, 0, 0])
        XCTAssertEqual(code.singleSymbol, 1)
    }

    func testPrefixCode_TwoSymbols_OneBitEach() throws {
        // 2 symbols at length 1 → canonical codes 0, 1.
        let code = try BrotliPrefixCode(
            alphabetSize: 4, codeLengths: [1, 0, 1, 0])
        XCTAssertEqual(code.singleSymbol, nil)
        XCTAssertEqual(code.codes[0], 0)
        XCTAssertEqual(code.codes[2], 1)
    }

    func testPrefixCode_KraftViolation_Throws() {
        // 3 symbols all at length 1 → Kraft sum = 3 * 2^14 = 49152
        // ≠ 32768. Should throw.
        XCTAssertThrowsError(
            try BrotliPrefixCode(
                alphabetSize: 3, codeLengths: [1, 1, 1])
        ) { error in
            guard case BrotliError.malformedPrefixCode = error else {
                XCTFail("expected malformedPrefixCode; got \(error)")
                return
            }
        }
    }

    func testPrefixCode_LengthOver15_Throws() {
        XCTAssertThrowsError(
            try BrotliPrefixCode(
                alphabetSize: 2, codeLengths: [16, 0])
        ) { error in
            guard case BrotliError.malformedPrefixCode = error else {
                XCTFail("expected malformedPrefixCode; got \(error)")
                return
            }
        }
    }

    // MARK: - Decode round-trip

    func testPrefixCode_DecodeSingleSymbol_ConsumesZeroBits() throws {
        let code = try BrotliPrefixCode(
            alphabetSize: 3, codeLengths: [0, 1, 0])
        var r = bitReader([0xFF, 0xFF])
        let s = try code.decodeSymbol(from: &r)
        XCTAssertEqual(s, 1)
        XCTAssertEqual(r.position, 0,
            "single-symbol code should consume 0 bits")
    }

    func testPrefixCode_DecodeTwoSymbol_OneBitEach() throws {
        // Symbols 0, 1 each at length 1. Canonical codes: 0→0, 1→1.
        // The decoder reads bits LSB-first from the stream.
        let code = try BrotliPrefixCode(
            alphabetSize: 2, codeLengths: [1, 1])
        // Stream: 0, 1, 0, 1, 1, 0  (LSB-first within byte = 0b00101010)
        var r = bitReader([0b00101010])
        XCTAssertEqual(try code.decodeSymbol(from: &r), 0)
        XCTAssertEqual(try code.decodeSymbol(from: &r), 1)
        XCTAssertEqual(try code.decodeSymbol(from: &r), 0)
        XCTAssertEqual(try code.decodeSymbol(from: &r), 1)
        XCTAssertEqual(try code.decodeSymbol(from: &r), 0)
        XCTAssertEqual(try code.decodeSymbol(from: &r), 1)
    }

    // MARK: - Simple-format reader

    func testReadSimple_OneSymbol_TwoBitNSYM() throws {
        // NSYM=0 (2 bits = 01 selector + 00 NSYM) + symbol bits.
        // alphabetSize = 4, so 2 bits per symbol.
        // Bits in stream (LSB-first):
        //   01 (selector = simple)  00 (NSYM = 0 ⇒ 1 symbol)  10 (symbol = 2)
        // Composed: write low-to-high → 01 00 10
        //   bit  0..1: 01
        //   bit  2..3: 00
        //   bit  4..5: 10
        // Byte (MSB at left, LSB at right): 10 00 01 = 0b00100001 = 0x21
        var r = bitReader([0x21])
        let code = try BrotliPrefixCodeReader.read(
            from: &r, alphabetSize: 4)
        XCTAssertEqual(code.singleSymbol, 2)
    }

    func testReadSimple_TwoSymbols() throws {
        // alphabetSize = 8, bitsPerSymbol = 3.
        // selector=01, NSYM=01 (2 symbols), symbols=[1, 5] (each 3 bits)
        // Bits LSB-first: 01 01 001 101
        //   pos 0..1: 01
        //   pos 2..3: 01
        //   pos 4..6: 001 (= 1)
        //   pos 7..9: 101 (= 5)
        // Total 10 bits. Pack into 2 bytes.
        //   byte 0 (bits 0..7): bit 0=1, bit 1=0, bit 2=1, bit 3=0,
        //                        bit 4=1, bit 5=0, bit 6=0, bit 7=1
        //                        ⇒ 0b1001 0101 = 0x95
        //   byte 1 (bits 8..15): bit 8=0, bit 9=1, rest 0
        //                        ⇒ 0b0000 0010 = 0x02
        var r = bitReader([0x95, 0x02])
        let code = try BrotliPrefixCodeReader.read(
            from: &r, alphabetSize: 8)
        XCTAssertNil(code.singleSymbol)
        XCTAssertEqual(code.codeLengths[1], 1)
        XCTAssertEqual(code.codeLengths[5], 1)
    }

    // Complex-format reader test deferred until end-to-end Brotli
    // stream is wired in — easier to validate against `brotli` CLI
    // output than to hand-construct a complex code by bit.
}
