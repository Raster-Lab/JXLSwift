// VarLenUint — variable-length unsigned integer codings used in
// libjxl's entropy section bodies (`DecodeVarLenUint8` /
// `DecodeVarLenUint16` in `lib/jxl/dec_ans.cc`).
//
// **Both follow the same pattern:**
//
//     if u(1) == 0: value = 0
//     else:
//         nbits = u(3) for VarLenUint8, u(4) for VarLenUint16
//         if nbits == 0: value = 1
//         else:           value = u(nbits) + (1 << nbits)
//
// Range: VarLenUint8 covers 0..255 (1..9 bits on the wire);
// VarLenUint16 covers 0..65535 (1..21 bits).
//
// These show up inside `ReadHistogram` (alphabet sizes, the leading
// "length" field of the complex distribution path, the RLE length
// for symbol-17 zero runs) and in the per-cluster Huffman alphabet
// sizes of `DecodeANSCodes`.

import Foundation

extension BitReader {

    /// Decode the variable-length 0..255 integer used by libjxl
    /// `DecodeVarLenUint8`.
    package mutating func readVarLenUint8() throws -> UInt32 {
        if try !readBit() { return 0 }
        let nbits = Int(try read(bits: 3))
        if nbits == 0 { return 1 }
        let extra = try read(bits: nbits)
        return extra &+ (UInt32(1) &<< UInt32(nbits))
    }

    /// Decode the variable-length 0..65535 integer used by libjxl
    /// `DecodeVarLenUint16`.
    package mutating func readVarLenUint16() throws -> UInt32 {
        if try !readBit() { return 0 }
        let nbits = Int(try read(bits: 4))
        if nbits == 0 { return 1 }
        let extra = try read(bits: nbits)
        return extra &+ (UInt32(1) &<< UInt32(nbits))
    }
}

extension BitWriter {

    /// Encode the variable-length 0..255 integer used by libjxl. The
    /// shortest representable encoding is picked: zero takes 1 bit;
    /// 1 takes 5 bits (`1, 0,0,0,0`); larger values take
    /// `1 + 3 + nbits` bits where `nbits = floor(log2(value))`.
    package mutating func writeVarLenUint8(_ value: UInt32) throws {
        guard value <= 0xFF else {
            throw BitstreamError.malformedValue("VarLenUint8 out of range: \(value)")
        }
        if value == 0 {
            writeBit(false)
            return
        }
        writeBit(true)
        if value == 1 {
            write(bits: 3, value: 0)
            return
        }
        // nbits = floor(log2(value)); value range [2^nbits, 2^(nbits+1) - 1].
        let nbits = 31 - Int(value.leadingZeroBitCount)
        write(bits: 3, value: UInt32(nbits))
        write(bits: nbits, value: value &- (UInt32(1) &<< UInt32(nbits)))
    }

    /// Encode the variable-length 0..65535 integer.
    package mutating func writeVarLenUint16(_ value: UInt32) throws {
        guard value <= 0xFFFF else {
            throw BitstreamError.malformedValue("VarLenUint16 out of range: \(value)")
        }
        if value == 0 {
            writeBit(false)
            return
        }
        writeBit(true)
        if value == 1 {
            write(bits: 4, value: 0)
            return
        }
        let nbits = 31 - Int(value.leadingZeroBitCount)
        write(bits: 4, value: UInt32(nbits))
        write(bits: nbits, value: value &- (UInt32(1) &<< UInt32(nbits)))
    }
}
