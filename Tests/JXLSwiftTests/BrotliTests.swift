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

/// Brotli stream-header WBITS decode, verified against `brotli`
/// CLI output (`brotli --lgwin=N` for N ∈ {10..24}).
final class BrotliStreamHeaderTests: XCTestCase {

    private func wbitsFromFirstByte(_ b: UInt8) throws -> Int {
        var r = BitReader(Data([b, 0, 0, 0]))  // pad so reads don't OOB
        let h = try BrotliMetaBlockReader.readStreamHeader(from: &r)
        return h.windowBits
    }

    func testWBITS_16() throws {
        XCTAssertEqual(try wbitsFromFirstByte(0x00), 16)
    }

    func testWBITS_17() throws {
        XCTAssertEqual(try wbitsFromFirstByte(0x01), 17)
    }

    func testWBITS_18_to_24() throws {
        // 0x03, 0x05, 0x07, 0x09, 0x0B, 0x0D, 0x0F → 18..24
        XCTAssertEqual(try wbitsFromFirstByte(0x03), 18)
        XCTAssertEqual(try wbitsFromFirstByte(0x05), 19)
        XCTAssertEqual(try wbitsFromFirstByte(0x07), 20)
        XCTAssertEqual(try wbitsFromFirstByte(0x09), 21)
        XCTAssertEqual(try wbitsFromFirstByte(0x0B), 22)
        XCTAssertEqual(try wbitsFromFirstByte(0x0D), 23)
        XCTAssertEqual(try wbitsFromFirstByte(0x0F), 24)
    }

    func testWBITS_10_to_15() throws {
        // 0x21, 0x31, 0x41, 0x51, 0x61, 0x71 → 10..15
        XCTAssertEqual(try wbitsFromFirstByte(0x21), 10)
        XCTAssertEqual(try wbitsFromFirstByte(0x31), 11)
        XCTAssertEqual(try wbitsFromFirstByte(0x41), 12)
        XCTAssertEqual(try wbitsFromFirstByte(0x51), 13)
        XCTAssertEqual(try wbitsFromFirstByte(0x61), 14)
        XCTAssertEqual(try wbitsFromFirstByte(0x71), 15)
    }

    func testWBITS_ReservedN1_Throws() {
        // bit0=1, M=0, N=1 → WBITS=9, reserved.
        // Byte: bit0=1 (LSB), bits 1..3=000, bits 4..6=100 (N=1).
        // bit pattern: 1,0,0,0,1,0,0,0 = 0b00010001 = 0x11
        XCTAssertThrowsError(try wbitsFromFirstByte(0x11)) { error in
            guard case BrotliError.invalidWindowSize = error else {
                XCTFail("expected invalidWindowSize; got \(error)")
                return
            }
        }
    }
}

/// Brotli meta-block header — simple end-to-end check: parse the
/// stream header + first meta-block header for an empty stream
/// (`brotli < /dev/null > out.br`) and confirm the ISLAST + ISLAST_EMPTY
/// path fires.
final class BrotliMetaBlockHeaderTests: XCTestCase {

    func testEmptyStream_IsLastEmpty() throws {
        // From `brotli` CLI on empty stdin: 1 byte = 0x3F.
        // bits LSB-first: 1,1,1,1,1,1,0,0
        // Stream header: bit0=1, M=111 (=7) → WBITS=17+7=24.
        // Meta-block: ISLAST (bit 4)=1, ISLAST_EMPTY (bit 5)=1.
        var r = BitReader(Data([0x3F, 0x00]))
        let sh = try BrotliMetaBlockReader.readStreamHeader(from: &r)
        XCTAssertEqual(sh.windowBits, 24)
        let mh = try BrotliMetaBlockReader.readMetaBlockHeader(from: &r)
        XCTAssertTrue(mh.isLast)
        XCTAssertTrue(mh.isLastEmpty)
        XCTAssertEqual(mh.payloadSize, 0)
    }
}

/// Brotli variable-length integer reader (§9.2 NBLTYPES / similar).
final class BrotliVarLenU8Tests: XCTestCase {

    private func readVarLenU8(_ bits: [Int]) throws -> UInt32 {
        // Pack the bit list into a Data buffer LSB-first within
        // each byte (matching Brotli's bit order).
        var bytes: [UInt8] = []
        var current: UInt8 = 0
        var n = 0
        for b in bits {
            current |= UInt8(b) << UInt8(n)
            n += 1
            if n == 8 { bytes.append(current); current = 0; n = 0 }
        }
        if n > 0 { bytes.append(current) }
        if bytes.isEmpty { bytes.append(0) }
        // pad
        bytes.append(0)
        var r = BitReader(Data(bytes))
        return try BrotliBitReader.readVarLenU8(from: &r)
    }

    func testVarLenU8_FirstBitZero_Returns1() throws {
        XCTAssertEqual(try readVarLenU8([0]), 1)
    }
    func testVarLenU8_Nnn0_Returns2() throws {
        // 1 000 → 2
        XCTAssertEqual(try readVarLenU8([1, 0, 0, 0]), 2)
    }
    func testVarLenU8_Nnn1_Range3To4() throws {
        // 1 001 0 → 3
        XCTAssertEqual(try readVarLenU8([1, 1, 0, 0, 0]), 3)
        // 1 001 1 → 4
        XCTAssertEqual(try readVarLenU8([1, 1, 0, 0, 1]), 4)
    }
    func testVarLenU8_Nnn3_Range9To16() throws {
        // 1 011 000 → 9
        XCTAssertEqual(try readVarLenU8(
            [1, 1, 1, 0, 0, 0, 0]), 9)
        // 1 011 111 → 16
        XCTAssertEqual(try readVarLenU8(
            [1, 1, 1, 0, 1, 1, 1]), 16)
    }
    func testVarLenU8_Nnn7_Range129To256() throws {
        // 1 111 0000000 → 129
        XCTAssertEqual(try readVarLenU8(
            [1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]), 129)
        // 1 111 1111111 → 256
        XCTAssertEqual(try readVarLenU8(
            [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), 256)
    }
}

/// Brotli compressed-body meta-block header tests using a real
/// cjxl brob-box payload as the test vector.
final class BrotliCompressedMetaBlockHeaderTests: XCTestCase {

    /// The 16-byte Brotli stream from the cjxl `brob` box wrapping
    /// the Exif metadata of `/tmp/cjxl-exif-420.jxl`. Decodes to
    /// 18 bytes per `brotli --decompress`.
    private let cjxlExifBrotliBody: [UInt8] = [
        0x1b, 0x11, 0x00, 0x00, 0xa4, 0x01, 0x92, 0x54,
        0x10, 0x96, 0x0d, 0x89, 0x04, 0x12, 0x75, 0x03,
    ]

    func testCompressedMetaBlockHeader_RealCjxlBrob() throws {
        var r = BitReader(Data(cjxlExifBrotliBody))
        // Skip WBITS + meta-block header (matches what
        // BrotliDecoder.decode does up to the "compressed body
        // dispatch").
        let sh = try BrotliMetaBlockReader.readStreamHeader(from: &r)
        XCTAssertEqual(sh.windowBits, 22,
            "expected WBITS=22 (cjxl default)")
        let mh = try BrotliMetaBlockReader.readMetaBlockHeader(
            from: &r)
        XCTAssertTrue(mh.isLast)
        XCTAssertFalse(mh.isLastEmpty)
        XCTAssertFalse(mh.isUncompressed,
            "expected compressed meta-block")
        XCTAssertEqual(mh.payloadSize, 18,
            "expected 18-byte payload (matches brotli -d output)")

        // Now read the compressed-body header.
        let body = try BrotliCompressedMetaBlockHeader.read(
            from: &r)
        // For a small uniform-ish payload, cjxl should choose:
        //   NBLTYPESL/I/D = 1 (single block type each)
        //   NPOSTFIX = 0, NDIRECT = 0
        //   1 context mode (for the 1 literal block type)
        //   NTREESL = NTREESD = 1 (no context map needed)
        XCTAssertEqual(body.literal.nbltypes, 1,
            "NBLTYPESL")
        XCTAssertEqual(body.insertCopy.nbltypes, 1,
            "NBLTYPESI")
        XCTAssertEqual(body.distance.nbltypes, 1,
            "NBLTYPESD")
        XCTAssertEqual(body.npostfix, 0, "NPOSTFIX")
        XCTAssertEqual(body.ndirect, 0, "NDIRECT")
        XCTAssertEqual(body.contextModes.count, 1,
            "1 context mode for 1 literal block type")
        XCTAssertGreaterThanOrEqual(body.ntreesl, 1, "NTREESL")
        XCTAssertGreaterThanOrEqual(body.ntreesd, 1, "NTREESD")
        print("[brob header] WBITS=\(sh.windowBits) "
            + "MLEN+1=\(mh.payloadSize) "
            + "NBLTYPESL=\(body.literal.nbltypes) "
            + "NBLTYPESI=\(body.insertCopy.nbltypes) "
            + "NBLTYPESD=\(body.distance.nbltypes) "
            + "NPOSTFIX=\(body.npostfix) "
            + "NDIRECT=\(body.ndirect) "
            + "contextMode[0]=\(body.contextModes[0]) "
            + "NTREESL=\(body.ntreesl) "
            + "NTREESD=\(body.ntreesd)")
    }
}

/// Brotli IC alphabet command LUT — verify the table builds with
/// the expected structure.
final class BrotliInsertCopyLutTests: XCTestCase {

    func testCmdLut_HasCorrectSize() {
        XCTAssertEqual(BrotliInsertCopy.cmdLut.count, 704)
    }

    func testCmdLut_Symbol0_ZeroInsertCopy2() {
        // Symbol 0: cell_idx=0, cell_pos=0.
        //   copy_code  = ((0<<3) & 0x18) | (0 & 0x7) = 0
        //   insert_code = (0 & 0x18) | ((0>>3) & 0x7) = 0
        //   copy_len_offset = 2 (the copy_offsets[0] starting value)
        //   insert_len_offset = 0
        let e = BrotliInsertCopy.cmdLut[0]
        XCTAssertEqual(e.insertLenOffset, 0)
        XCTAssertEqual(e.copyLenOffset, 2)
        XCTAssertEqual(e.insertLenExtraBits, 0)
        XCTAssertEqual(e.copyLenExtraBits, 0)
        XCTAssertEqual(e.distanceCode, 0)
        XCTAssertEqual(e.context, 0)
    }

    func testCmdLut_Symbol127_StillInCellIdx1() {
        // Symbols 64..127 are in cell_idx=1 (kCellPos[1]=1).
        // distance_code should still be 0 (use cached distance).
        let e = BrotliInsertCopy.cmdLut[127]
        XCTAssertEqual(e.distanceCode, 0,
            "cell_idx=1 → distance_code=0 (cached)")
    }

    func testCmdLut_Symbol128_FirstReadDistance() {
        // Symbols 128..191 are in cell_idx=2 → distance_code = -1.
        let e = BrotliInsertCopy.cmdLut[128]
        XCTAssertEqual(e.distanceCode, -1,
            "cell_idx=2 → distance_code=-1 (read fresh)")
    }
}

/// End-to-end BrotliDecoder tests using crafted streams.
final class BrotliDecoderTests: XCTestCase {

    func testDecode_EmptyStream() throws {
        // `brotli` CLI on empty stdin: 1 byte = 0x06 (WBITS=16,
        // ISLAST=1, ISLAST_EMPTY=1).
        // Wait — actually `brotli` defaults to WBITS=22 even on empty
        // input. Let me use 0x06 = the WBITS=16 version:
        //   bit 0 = 0 (WBITS=16)
        //   bit 1 = 1 (ISLAST=1)
        //   bit 2 = 1 (ISLAST_EMPTY=1)
        //   bits 3..7 = 0 padding
        let out = try BrotliDecoder.decode(Data([0x06]))
        XCTAssertEqual(out.count, 0)
    }

    func testDecode_BrotliCLI_EmptyDefault() throws {
        // `brotli < /dev/null` emits 0x3F (WBITS=24 + empty).
        let out = try BrotliDecoder.decode(Data([0x3F]))
        XCTAssertEqual(out.count, 0)
    }

    func testDecode_UncompressedHello_FromBrotliCLI() throws {
        // `echo -n hello | brotli --lgwin=16 --quality=0` produces
        // `03028068656c6c6f03` (9 bytes):
        //   - WBITS=18 (from --lgwin in cli default; actually we see
        //     bit 0=1, M=001 (LSB-first) → WBITS=18)
        //   - ISLAST=0, MNIBBLES=4, MLEN=4 (payload=5), ISUNCOMPRESSED=1
        //   - byte-aligned payload: "hello"
        //   - second meta-block: ISLAST=1, ISLAST_EMPTY=1
        let input = Data([
            0x03, 0x02, 0x80,
            0x68, 0x65, 0x6C, 0x6C, 0x6F,  // "hello"
            0x03,
        ])
        let out = try BrotliDecoder.decode(input)
        XCTAssertEqual(out, Data([0x68, 0x65, 0x6C, 0x6C, 0x6F]),
            "uncompressed `hello` payload should round-trip exactly")
        XCTAssertEqual(String(data: out, encoding: .utf8), "hello")
    }

    func testDecode_UncompressedABC_FromBrotliCLI() throws {
        // `echo -n abc | brotli --lgwin=16 --quality=0` produces
        // `03018061626303` (7 bytes).
        let input = Data([
            0x03, 0x01, 0x80,
            0x61, 0x62, 0x63,  // "abc"
            0x03,
        ])
        let out = try BrotliDecoder.decode(input)
        XCTAssertEqual(out, Data([0x61, 0x62, 0x63]))
    }

    func testDecode_CompressedStream_ThrowsNotImplemented() {
        // `echo -n hello | brotli --quality=11` produces a compressed
        // (entropy-coded) stream we don't yet decode. Confirm we
        // surface `notImplemented` cleanly rather than misdecoding.
        // From earlier brotli-test fixture: 0f028068656c6c6f03 with
        // WBITS=24. But that's also uncompressed actually — at q=11
        // brotli still emits uncompressed for tiny inputs.
        // Use a longer input that genuinely needs compression.
        // For now, test the explicit not-implemented path with a
        // hand-crafted compressed meta-block start.
        // Stream: WBITS=16, ISLAST=1, ISLAST_EMPTY=0, MNIBBLES=4,
        // MLEN=X, ... — but ISLAST=1 means ISUNCOMPRESSED is NOT
        // read, so the body is always compressed.
        //   bit 0 = 0  (WBITS=16)
        //   bit 1 = 1  (ISLAST)
        //   bit 2 = 0  (NOT empty)
        //   bits 3..4 = 00 (MNIBBLES=4)
        //   bits 5..20 = MLEN — let's say MLEN=0 (1-byte payload)
        // Byte 0: bit pattern 0,1,0,0,0,0,0,0 (LSB) = 0b00000010 = 0x02
        // Bytes 1-2: MLEN = 0 (16 bits all 0)
        // Then compressed body starts → we throw notImplemented.
        let input = Data([0x02, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try BrotliDecoder.decode(input))
        { error in
            guard case BrotliError.notImplemented(let msg) = error
            else {
                XCTFail("expected notImplemented; got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("compressed meta-block"),
                "expected message to mention compressed meta-block")
        }
    }
}
