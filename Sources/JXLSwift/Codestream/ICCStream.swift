// ICCStream — decoder for JPEG XL's compressed ICC-profile stream.
//
// ISO/IEC 18181-1 §C.3.4. When `ColorEncoding.useICC` is set, the
// codestream carries the ICC profile compressed with a bespoke
// predictor + ANS scheme (libjxl `icc_codec.cc` / `icc_codec_common.cc`):
//
//   1. `enc_size` — U64, the *decompressed command/data buffer* size.
//   2. An entropy section (`kNumICCContexts == 41` contexts) — header
//      + per-cluster codebook, read exactly like any other JXL ANS
//      section.
//   3. `enc_size` ANS symbols (one byte each) read with the
//      position/neighbour context `ICCANSContext(i, prev1, prev2)`.
//   4. `UnpredictICC` — a command interpreter that reconstructs the
//      real ICC profile bytes from the decoded buffer.
//
// This is a faithful port of the libjxl reference; the output is the
// exact original ICC profile, which the JPEG reverse-transcode path
// splices back into the APP2 `ICC_PROFILE` marker.

import Foundation

package enum ICCStreamError: Error, Sendable {
    case bitstream(BitstreamError)
    case malformed(String)
    case entropy(String)
}

package enum ICCStream {

    package static let headerSize = 128
    package static let numContexts = 41

    // MARK: - Command / flag constants (libjxl icc_codec_common.h)

    private static let kCommandTagUnknown = 1
    private static let kCommandTagTRC = 2
    private static let kCommandTagXYZ = 3
    private static let kCommandTagStringFirst = 4
    private static let kCommandInsert = 1
    private static let kCommandShuffle2 = 2
    private static let kCommandShuffle4 = 3
    private static let kCommandPredict = 4
    private static let kCommandXYZ = 10
    private static let kCommandTypeStartFirst = 16
    private static let kFlagBitOffset = 64
    private static let kFlagBitSize = 128

    // MARK: - Tag keywords

    private static func tag(_ s: String) -> [UInt8] { Array(s.utf8) }
    private static let kRtrcTag = tag("rTRC")
    private static let kGtrcTag = tag("gTRC")
    private static let kBtrcTag = tag("bTRC")
    private static let kRxyzTag = tag("rXYZ")
    private static let kGxyzTag = tag("gXYZ")
    private static let kBxyzTag = tag("bXYZ")
    private static let kKxyzTag = tag("kXYZ")
    private static let kWtptTag = tag("wtpt")
    private static let kBkptTag = tag("bkpt")
    private static let kLumiTag = tag("lumi")
    private static let kXyz_Tag = tag("XYZ ")

    /// Tag-name table (libjxl `kTagStrings`, 17 entries).
    private static let kTagStrings: [[UInt8]] = [
        tag("cprt"), tag("wtpt"), tag("bkpt"), tag("rXYZ"), tag("gXYZ"),
        tag("bXYZ"), tag("kXYZ"), tag("rTRC"), tag("gTRC"), tag("bTRC"),
        tag("kTRC"), tag("chad"), tag("desc"), tag("chrm"), tag("dmnd"),
        tag("dmdd"), tag("lumi"),
    ]
    /// Tag-type table (libjxl `kTypeStrings`, 8 entries).
    private static let kTypeStrings: [[UInt8]] = [
        tag("XYZ "), tag("desc"), tag("text"), tag("mluc"),
        tag("para"), tag("curv"), tag("sf32"), tag("gbd "),
    ]

    /// libjxl `kIccInitialHeaderPrediction` (128 bytes).
    private static let initialHeaderPrediction: [UInt8] = [
        0,0,0,0, 0,0,0,0, 4,0,0,0, 0x6d,0x6e,0x74,0x72,       // "mntr"
        0x52,0x47,0x42,0x20, 0x58,0x59,0x5a,0x20, 0,0,0,0, 0,0,0,0, // "RGB XYZ "
        0,0,0,0, 0x61,0x63,0x73,0x70, 0,0,0,0, 0,0,0,0,        // "acsp"
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
        0,0,0,0, 0,0,246,214, 0,1,0,0, 0,0,211,45,
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
    ]

    // MARK: - Public entry

    /// Decode the ICC stream at the reader's current position,
    /// returning the reconstructed ICC profile bytes. Advances the
    /// reader past the ANS stream (the caller byte-aligns afterwards,
    /// mirroring libjxl `JumpToByteBoundary`).
    package static func decode(
        from r: inout BitReader
    ) throws -> Data {
        let encSize: UInt64
        do { encSize = try r.readU64() }
        catch let e as BitstreamError { throw ICCStreamError.bitstream(e) }
        guard encSize <= 268_435_456 else {
            throw ICCStreamError.malformed("encoded ICC too large")
        }
        // Entropy section (header + per-cluster codebook), 41 contexts.
        let header: EntropySectionHeader
        let codebook: MultiClusterCodebook
        do {
            header = try EntropySectionHeader.read(
                from: &r, numContexts: numContexts)
            codebook = try MultiClusterCodebook.read(
                from: &r, header: header)
        } catch {
            throw ICCStreamError.entropy("\(error)")
        }
        var stream = TokenStreamReader(header: header, codebook: codebook)
        var decompressed = [UInt8]()
        let n = Int(encSize)
        decompressed.reserveCapacity(n)
        for i in 0..<n {
            let b1 = i >= 1 ? Int(decompressed[i - 1]) : 0
            let b2 = i >= 2 ? Int(decompressed[i - 2]) : 0
            let ctx = iccANSContext(i: i, b1: b1, b2: b2)
            let v: UInt32
            do { v = try stream.readToken(context: ctx, from: &r) }
            catch { throw ICCStreamError.entropy("byte \(i): \(error)") }
            decompressed.append(UInt8(truncatingIfNeeded: v))
        }
        return try unpredictICC(decompressed)
    }

    // MARK: - Context model (libjxl icc_codec_common.cc)

    private static func byteKind1(_ b: Int) -> Int {
        if (97...122).contains(b) || (65...90).contains(b) { return 0 } // a-z A-Z
        if (48...57).contains(b) { return 1 }                           // 0-9
        if b == 46 || b == 44 { return 1 }                             // . ,
        if b == 0 { return 2 }
        if b == 1 { return 3 }
        if b < 16 { return 4 }
        if b == 255 { return 6 }
        if b > 240 { return 5 }
        return 7
    }
    private static func byteKind2(_ b: Int) -> Int {
        if (97...122).contains(b) || (65...90).contains(b) { return 0 }
        if (48...57).contains(b) { return 1 }
        if b == 46 || b == 44 { return 1 }
        if b < 16 { return 2 }
        if b > 240 { return 3 }
        return 4
    }
    private static func iccANSContext(i: Int, b1: Int, b2: Int) -> Int {
        if i <= 128 { return 0 }
        return 1 + byteKind1(b1) + byteKind2(b2) * 8
    }

    // MARK: - VarInt + BE helpers

    /// libjxl `DecodeVarInt` — LEB128-ish, max 10 payload bytes.
    private static func decodeVarInt(
        _ input: [UInt8], _ pos: inout Int
    ) -> UInt64 {
        var ret: UInt64 = 0
        var i = 0
        while pos + i < input.count && i < 10 {
            ret |= UInt64(input[pos + i] & 127) << UInt64(7 * i)
            if (input[pos + i] & 128) == 0 { break }
            i += 1
        }
        pos += i + 1
        return ret
    }

    private static func decodeUint32(
        _ data: [UInt8], _ size: Int, _ pos: Int
    ) -> UInt32 {
        if pos + 4 > size { return 0 }
        return (UInt32(data[pos]) << 24) | (UInt32(data[pos + 1]) << 16)
            | (UInt32(data[pos + 2]) << 8) | UInt32(data[pos + 3])
    }
    private static func appendUint32(_ value: UInt32, _ data: inout [UInt8]) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
    private static func decodeKeyword(
        _ data: [UInt8], _ size: Int, _ pos: Int
    ) -> [UInt8] {
        if pos + 4 > size { return [32, 32, 32, 32] }
        return [data[pos], data[pos + 1], data[pos + 2], data[pos + 3]]
    }

    private static func check32(_ v: UInt64) throws {
        if (v & ~UInt64(0xFFFFFFFF)) != 0 {
            throw ICCStreamError.malformed("32-bit value expected")
        }
    }
    private static func checkOOB(_ a: Int, _ b: Int, _ size: Int) throws {
        let pos = a + b
        if pos > size || pos < a {
            throw ICCStreamError.malformed("out of bounds")
        }
    }

    // MARK: - Predictors

    private static func predictValue(
        _ p1: Int, _ p2: Int, _ p3: Int, _ order: Int
    ) -> Int {
        if order == 0 { return p1 }
        if order == 1 { return 2 * p1 - p2 }
        if order == 2 { return 3 * p1 - 3 * p2 + p3 }
        return 0
    }

    private static func iccPredictHeader(
        _ icc: [UInt8], _ size: Int, _ header: inout [UInt8], _ pos: Int
    ) {
        if pos == 8 && size >= 8 {
            header[80] = icc[4]; header[81] = icc[5]
            header[82] = icc[6]; header[83] = icc[7]
        }
        if pos == 41 && size >= 41 {
            if icc[40] == 0x41 {  // 'A'
                header[41] = 0x50; header[42] = 0x50; header[43] = 0x4C // "PPL"
            }
            if icc[40] == 0x4D {  // 'M'
                header[41] = 0x53; header[42] = 0x46; header[43] = 0x54 // "SFT"
            }
        }
        if pos == 42 && size >= 42 {
            if icc[40] == 0x53 && icc[41] == 0x47 {  // "SG"
                header[42] = 0x49; header[43] = 0x20 // "I "
            }
            if icc[40] == 0x53 && icc[41] == 0x55 {  // "SU"
                header[42] = 0x4E; header[43] = 0x57 // "NW"
            }
        }
    }

    /// libjxl `LinearPredictICCValue`.
    private static func linearPredict(
        _ data: [UInt8], _ start: Int, _ i: Int,
        _ stride: Int, _ width: Int, _ order: Int
    ) -> UInt8 {
        let pos = start + i
        if width == 1 {
            let p1 = Int(data[pos - stride])
            let p2 = Int(data[pos - stride * 2])
            let p3 = Int(data[pos - stride * 3])
            return UInt8(truncatingIfNeeded: predictValue(p1, p2, p3, order))
        } else if width == 2 {
            let p = start + (i & ~1)
            let p1 = (Int(data[p - stride]) << 8) + Int(data[p - stride + 1])
            let p2 = (Int(data[p - stride * 2]) << 8)
                + Int(data[p - stride * 2 + 1])
            let p3 = (Int(data[p - stride * 3]) << 8)
                + Int(data[p - stride * 3 + 1])
            let pred = predictValue(p1, p2, p3, order)
            return UInt8(truncatingIfNeeded:
                (i & 1) != 0 ? (pred & 255) : ((pred >> 8) & 255))
        } else {
            let p = start + (i & ~3)
            let p1 = Int(decodeUint32(data, pos, p - stride))
            let p2 = Int(decodeUint32(data, pos, p - stride * 2))
            let p3 = Int(decodeUint32(data, pos, p - stride * 3))
            let pred = predictValue(p1, p2, p3, order)
            let shiftbytes = 3 - (i & 3)
            return UInt8(truncatingIfNeeded: (pred >> (shiftbytes * 8)) & 255)
        }
    }

    /// libjxl `Shuffle` — transpose interleave of `width` rows.
    private static func shuffle(_ data: inout [UInt8], _ size: Int, _ width: Int) {
        let height = (size + width - 1) / width
        var result = [UInt8](repeating: 0, count: size)
        var s = 0, j = 0
        for i in 0..<size {
            result[i] = data[j]
            j += height
            if j >= size { s += 1; j = s }
        }
        for i in 0..<size { data[i] = result[i] }
    }

    // MARK: - UnpredictICC (libjxl icc_codec.cc)

    private static func unpredictICC(_ enc: [UInt8]) throws -> Data {
        let size = enc.count
        var result = [UInt8]()
        var pos = 0
        guard pos < size else { throw ICCStreamError.malformed("OOB") }
        let osize = decodeVarInt(enc, &pos)        // output size
        try check32(osize)
        guard pos < size else { throw ICCStreamError.malformed("OOB") }
        let csize = decodeVarInt(enc, &pos)        // commands size
        try check32(csize)
        var cpos = pos                              // commands stream
        try checkOOB(pos, Int(csize), size)
        let commandsEnd = cpos + Int(csize)
        pos = commandsEnd                           // data stream

        let osizeI = Int(osize)

        // Header (128 bytes) with initial prediction.
        var header = initialHeaderPrediction
        // StoreBE32(osize) into header[0..3].
        header[0] = UInt8((osize >> 24) & 0xFF)
        header[1] = UInt8((osize >> 16) & 0xFF)
        header[2] = UInt8((osize >> 8) & 0xFF)
        header[3] = UInt8(osize & 0xFF)
        var i = 0
        while i <= headerSize {
            if result.count == osizeI {
                if cpos != commandsEnd {
                    throw ICCStreamError.malformed("not all commands used")
                }
                if pos != size {
                    throw ICCStreamError.malformed("not all data used")
                }
                return Data(result)
            }
            if i == headerSize { break }
            iccPredictHeader(result, result.count, &header, i)
            guard pos < size else { throw ICCStreamError.malformed("OOB") }
            result.append(enc[pos] &+ header[i])
            pos += 1
            i += 1
        }
        guard cpos < commandsEnd else {
            throw ICCStreamError.malformed("OOB after header")
        }

        // Tag list.
        let numtagsRaw = decodeVarInt(enc, &cpos)
        if numtagsRaw != 0 {
            let numtags = numtagsRaw - 1
            try check32(numtags)
            appendUint32(UInt32(numtags), &result)
            var prevtagstart = UInt64(headerSize) + numtags * 12
            var prevtagsize: UInt64 = 0
            while true {
                if result.count > osizeI {
                    throw ICCStreamError.malformed("invalid result size")
                }
                if cpos > commandsEnd {
                    throw ICCStreamError.malformed("OOB tag")
                }
                if cpos == commandsEnd { break }
                let command = Int(enc[cpos]); cpos += 1
                let tagcode = command & 63
                var t: [UInt8]
                if tagcode == 0 {
                    break
                } else if tagcode == kCommandTagUnknown {
                    try checkOOB(pos, 4, size)
                    t = decodeKeyword(enc, size, pos)
                    pos += 4
                } else if tagcode == kCommandTagTRC {
                    t = kRtrcTag
                } else if tagcode == kCommandTagXYZ {
                    t = kRxyzTag
                } else {
                    let idx = tagcode - kCommandTagStringFirst
                    guard idx >= 0 && idx < kTagStrings.count else {
                        throw ICCStreamError.malformed("unknown tagcode")
                    }
                    t = kTagStrings[idx]
                }
                result.append(contentsOf: t)

                var tagstart: UInt64
                var tagsize = prevtagsize
                if t == kRxyzTag || t == kGxyzTag || t == kBxyzTag
                    || t == kKxyzTag || t == kWtptTag || t == kBkptTag
                    || t == kLumiTag {
                    tagsize = 20
                }
                if (command & kFlagBitOffset) != 0 {
                    guard cpos < commandsEnd else {
                        throw ICCStreamError.malformed("OOB")
                    }
                    tagstart = decodeVarInt(enc, &cpos)
                } else {
                    try check32(prevtagstart)
                    tagstart = prevtagstart + prevtagsize
                }
                try check32(tagstart)
                appendUint32(UInt32(tagstart), &result)
                if (command & kFlagBitSize) != 0 {
                    guard cpos < commandsEnd else {
                        throw ICCStreamError.malformed("OOB")
                    }
                    tagsize = decodeVarInt(enc, &cpos)
                }
                try check32(tagsize)
                appendUint32(UInt32(tagsize), &result)
                prevtagstart = tagstart
                prevtagsize = tagsize

                if tagcode == kCommandTagTRC {
                    result.append(contentsOf: kGtrcTag)
                    appendUint32(UInt32(tagstart), &result)
                    appendUint32(UInt32(tagsize), &result)
                    result.append(contentsOf: kBtrcTag)
                    appendUint32(UInt32(tagstart), &result)
                    appendUint32(UInt32(tagsize), &result)
                }
                if tagcode == kCommandTagXYZ {
                    try check32(tagstart + tagsize * 2)
                    result.append(contentsOf: kGxyzTag)
                    appendUint32(UInt32(tagstart + tagsize), &result)
                    appendUint32(UInt32(tagsize), &result)
                    result.append(contentsOf: kBxyzTag)
                    appendUint32(UInt32(tagstart + tagsize * 2), &result)
                    appendUint32(UInt32(tagsize), &result)
                }
            }
        }

        // Main content.
        while true {
            if result.count > osizeI {
                throw ICCStreamError.malformed("invalid result size")
            }
            if cpos > commandsEnd { throw ICCStreamError.malformed("OOB") }
            if cpos == commandsEnd { break }
            let command = Int(enc[cpos]); cpos += 1
            if command == kCommandInsert {
                guard cpos < commandsEnd else {
                    throw ICCStreamError.malformed("OOB")
                }
                let num = Int(decodeVarInt(enc, &cpos))
                try checkOOB(pos, num, size)
                for _ in 0..<num { result.append(enc[pos]); pos += 1 }
            } else if command == kCommandShuffle2 || command == kCommandShuffle4 {
                guard cpos < commandsEnd else {
                    throw ICCStreamError.malformed("OOB")
                }
                let num = Int(decodeVarInt(enc, &cpos))
                try checkOOB(pos, num, size)
                var shuffled = [UInt8](repeating: 0, count: num)
                for k in 0..<num { shuffled[k] = enc[pos + k] }
                shuffle(&shuffled, num, command == kCommandShuffle2 ? 2 : 4)
                for k in 0..<num { result.append(shuffled[k]); pos += 1 }
            } else if command == kCommandPredict {
                try checkOOB(cpos, 2, commandsEnd)
                let flags = Int(enc[cpos]); cpos += 1
                let width = (flags & 3) + 1
                if width == 3 { throw ICCStreamError.malformed("invalid width") }
                let order = (flags & 12) >> 2
                if order == 3 { throw ICCStreamError.malformed("invalid order") }
                var stride = width
                if (flags & 16) != 0 {
                    guard cpos < commandsEnd else {
                        throw ICCStreamError.malformed("OOB")
                    }
                    stride = Int(decodeVarInt(enc, &cpos))
                    if stride < width {
                        throw ICCStreamError.malformed("invalid stride")
                    }
                }
                if result.isEmpty || ((result.count - 1) >> 2) < stride {
                    throw ICCStreamError.malformed("invalid stride")
                }
                guard cpos < commandsEnd else {
                    throw ICCStreamError.malformed("OOB")
                }
                let num = Int(decodeVarInt(enc, &cpos))
                try checkOOB(pos, num, size)
                var shuffled = [UInt8](repeating: 0, count: num)
                for k in 0..<num { shuffled[k] = enc[pos + k] }
                if width > 1 { shuffle(&shuffled, num, width) }
                let start = result.count
                for k in 0..<num {
                    let predicted = linearPredict(
                        result, start, k, stride, width, order)
                    result.append(predicted &+ shuffled[k])
                }
                pos += num
            } else if command == kCommandXYZ {
                result.append(contentsOf: kXyz_Tag)
                for _ in 0..<4 { result.append(0) }
                try checkOOB(pos, 12, size)
                for _ in 0..<12 { result.append(enc[pos]); pos += 1 }
            } else if command >= kCommandTypeStartFirst
                && command < kCommandTypeStartFirst + kTypeStrings.count {
                result.append(contentsOf:
                    kTypeStrings[command - kCommandTypeStartFirst])
                for _ in 0..<4 { result.append(0) }
            } else {
                throw ICCStreamError.malformed("unknown command \(command)")
            }
        }

        if pos != size { throw ICCStreamError.malformed("not all data used") }
        if result.count != osizeI {
            throw ICCStreamError.malformed("invalid result size")
        }
        return Data(result)
    }
}
