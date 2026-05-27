// `Brotli/BrotliInsertCopy.swift` — insert-and-copy command alphabet
// decoder (RFC 7932 §5). Ports the `kCmdLut` build from
// `google/brotli` `c/dec/prefix.c::BrotliDecoderInitCmdLut`.
//
// The 704-symbol IC alphabet encodes a (insert_length_code,
// copy_length_code, distance_flag) triple per symbol. From those:
//   - `insert_length_offset` + `insert_len_extra_bits` → actual
//     insert length (after reading extra bits).
//   - `copy_length_offset` + `copy_len_extra_bits` → actual copy
//     length.
//   - `distance_code = 0` (cell_idx 0..1, "use cached distance") vs
//     `-1` (cell_idx 2..10, "read distance code separately").
//   - `context` ∈ 0..3 — copy-length context for the distance decode.
//
// Phase J step 5g. v0.12.0gl.

import Foundation

/// One row of the 704-entry insert-and-copy command lookup table.
/// Mirrors libjxl/brotli's `CmdLutElement`.
public struct BrotliCmdLutElement: Sendable, Equatable {
    public let insertLenExtraBits: UInt8
    public let copyLenExtraBits: UInt8
    /// 0 = use last distance from cache; -1 = read a fresh distance.
    public let distanceCode: Int8
    /// Distance context 0..3 (RFC 7932 §4 distance prefix code uses
    /// this as a sub-stream selector).
    public let context: UInt8
    public let insertLenOffset: UInt16
    public let copyLenOffset: UInt16
}

public enum BrotliInsertCopy {

    /// Number of IC alphabet symbols (BROTLI_NUM_COMMAND_SYMBOLS).
    public static let alphabetSize: Int = 704

    /// Extra-bits tables from RFC 7932 §5 / libjxl `prefix.c`.
    static let kInsertLengthExtraBits: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01,
        0x02, 0x02, 0x03, 0x03, 0x04, 0x04, 0x05, 0x05,
        0x06, 0x07, 0x08, 0x09, 0x0A, 0x0C, 0x0E, 0x18,
    ]
    static let kCopyLengthExtraBits: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x01, 0x02, 0x02, 0x03, 0x03, 0x04, 0x04,
        0x05, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x18,
    ]
    /// 11 cells × 64 = 704 symbols. `kCellPos[cell_idx]` provides
    /// the (insert_code_high, copy_code_high) packed nibble.
    static let kCellPos: [UInt8] = [
        0, 1, 0, 1, 8, 9, 2, 16, 10, 17, 18,
    ]

    /// Precomputed 704-entry table. Built lazily on first access.
    public static let cmdLut: [BrotliCmdLutElement] = {
        var insertOffsets = [UInt16](repeating: 0, count: 24)
        var copyOffsets   = [UInt16](repeating: 0, count: 24)
        copyOffsets[0] = 2
        for i in 0..<23 {
            insertOffsets[i + 1] = insertOffsets[i]
                &+ (1 << kInsertLengthExtraBits[i])
            copyOffsets[i + 1] = copyOffsets[i]
                &+ (1 << kCopyLengthExtraBits[i])
        }
        var result: [BrotliCmdLutElement] = []
        result.reserveCapacity(alphabetSize)
        for symbol in 0..<alphabetSize {
            let cellIdx = symbol >> 6
            let cellPos = Int(kCellPos[cellIdx])
            let copyCode = ((cellPos << 3) & 0x18) | (symbol & 0x7)
            let copyLenOffset = copyOffsets[copyCode]
            let insertCode = (cellPos & 0x18)
                | ((symbol >> 3) & 0x7)
            let copyExtraBits = kCopyLengthExtraBits[copyCode]
            let insertExtraBits =
                kInsertLengthExtraBits[insertCode]
            let context: UInt8 = (copyLenOffset > 4)
                ? 3 : UInt8(copyLenOffset - 2)
            let distanceCode: Int8 = (cellIdx >= 2) ? -1 : 0
            result.append(BrotliCmdLutElement(
                insertLenExtraBits: insertExtraBits,
                copyLenExtraBits: copyExtraBits,
                distanceCode: distanceCode,
                context: context,
                insertLenOffset: insertOffsets[insertCode],
                copyLenOffset: copyLenOffset))
        }
        return result
    }()

    /// Decode one IC command from `r` using the supplied prefix
    /// code (read from the bitstream just before the LZ77 loop).
    /// Returns:
    ///   - `insertLength` — number of literals to insert
    ///   - `copyLength` — number of bytes to copy from a previous
    ///     position
    ///   - `distanceFlag` — 0 ("use cached distance") or
    ///     `-1` ("read distance separately")
    ///   - `distanceContext` — 0..3, used as the sub-stream selector
    ///     for the distance prefix code
    public static func decodeCommand(
        from r: inout BitReader,
        prefixCode: BrotliPrefixCode
    ) throws -> (insertLength: UInt32, copyLength: UInt32,
                 distanceFlag: Int8, distanceContext: UInt8) {
        let symbol = Int(try prefixCode.decodeSymbol(from: &r))
        guard symbol >= 0 && symbol < alphabetSize else {
            throw BrotliError.malformedPrefixCode(
                "IC symbol \(symbol) outside [0, \(alphabetSize))")
        }
        let entry = cmdLut[symbol]
        let extraInsert: UInt32
        let extraCopy: UInt32
        do {
            extraInsert = try r.read(
                bits: Int(entry.insertLenExtraBits))
            extraCopy = try r.read(
                bits: Int(entry.copyLenExtraBits))
        } catch let e as BitstreamError {
            throw BrotliError.bitstream(e)
        }
        return (
            insertLength: UInt32(entry.insertLenOffset) &+ extraInsert,
            copyLength: UInt32(entry.copyLenOffset) &+ extraCopy,
            distanceFlag: entry.distanceCode,
            distanceContext: entry.context)
    }
}
