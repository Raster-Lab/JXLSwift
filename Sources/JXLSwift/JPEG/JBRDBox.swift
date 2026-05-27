// `JPEG/JBRDBox.swift` — `jbrd` box reader + builder.
//
// The `jbrd` (JPEG Bitstream Reconstruction Data) box is the ISOBMFF
// container box JXL writes alongside a coefficient-bridged frame
// when the goal is byte-identical JPEG reconstruction (JXL → JPEG).
// Without `jbrd`, `djxl --output_format=jpeg` falls back to
// `--pixels_to_jpeg` (re-encoding from decoded pixels), which is
// lossy at the second JPEG quantisation step.
//
// Structure (per libjxl `lib/jxl/jpeg/jpeg_data.{h,cc}` +
// `dec_jpeg_data.cc`):
//
// ```
// jbrd-box-payload:
//   Bundle-serialised JPEGData (Fields::VisitFields traversal)
//     ─ is_gray            1 bit
//     ─ marker_order       sequence of 6-bit marker codes
//                          (0xc0..0xff range), terminated by 0xd9 (EOI)
//     ─ app_marker_type[]  U32 enum per app marker (kUnknown/kICC/kExif/kXMP)
//     ─ app/com_marker_len 16-bit length per APP / COM marker
//     ─ quant tables       precision, slot index, is_last
//     ─ component metadata kGray/kYCbCr/kRGB/kCustom + ids
//     ─ huffman_code       counts[17] + values[N] per Huffman table
//     ─ scan_info          per-scan Ss/Se/Al/Ah + comp_idx/dc/ac
//     ─ restart_interval, reset_points, extra_zero_runs (per scan)
//     ─ inter_marker_data sizes, tail_data length
//     ─ padding_bits flag + bits
//   <byte alignment>
//   Brotli-compressed blob carrying the marker payloads
//     (app_data, com_data, inter_marker_data, tail_data)
//     decompressed using the sizes from the Bundle.
// ```
//
// Phase J step 5h. v0.12.0g0 scaffold — Bundle reader/writer pending,
// Brotli payload deferred until the Brotli decoder ships.

import Foundation

/// Errors specific to `jbrd` parsing.
public enum JBRDError: Error, Sendable {
    /// Wrapper around a bit-reader error.
    case bitstream(BitstreamError)
    /// Marker order exceeded the libjxl-imposed 16384-entry cap.
    case tooManyMarkers(Int)
    /// Number of quantisation tables was the reserved value 4
    /// (libjxl `jpeg_data.cc:133`).
    case invalidQuantTableCount
    /// Quant-table precision > 1 (16-bit tables not supported by
    /// JPEG XL transcoding per libjxl `jpeg_data.cc:140-142`).
    case invalidQuantPrecision
    /// Number of components was neither 1 nor 3 in custom mode.
    case invalidComponentCount(UInt32)
    /// Component referenced a quant index out of range.
    case invalidQuantIndex(comp: Int, idx: UInt32)
    /// Huffman-table EOI symbol mismatch (libjxl
    /// `jpeg_data.cc:248-250`).
    case missingEOISymbol
    /// Duplicate Huffman symbols in a single table.
    case duplicateHuffmanSymbols
    /// DC Huffman table contained AC-range symbols (libjxl
    /// `jpeg_data.cc:259-262`).
    case dcHuffmanOutOfRange
    /// Scan SOS-marker num_components > 3 (libjxl
    /// `jpeg_data.cc:268-270`).
    case invalidScanComponentCount(UInt32)
    /// Block-index field out of range
    /// (libjxl `jpeg_data.cc:308-313`).
    case invalidBlockIndex(UInt32)
    /// Tail-data length exceeded the 4 260 096-byte cap (libjxl
    /// `jpeg_data.cc:349-352`).
    case tailDataTooLarge(UInt32)
    /// Reading hit unexpected end-of-data.
    case truncated
    /// A feature in jbrd we haven't implemented yet.
    case notImplemented(String)
}

/// One quantisation table entry from the jbrd Bundle. Maps directly
/// to libjxl's `JPEGQuantTable`. `values` are the unpacked 64-element
/// natural-order matrix; the Brotli-compressed payload carries the
/// actual integer values (this struct just records the metadata).
public struct JBRDQuantTable: Sendable, Equatable {
    /// Precision flag: 0 = 8-bit table, 1 = 16-bit. We accept only
    /// precision=0 per libjxl's transcode restriction.
    public var precision: UInt32
    /// Slot index 0..3.
    public var index: UInt32
    /// True if this is the last table in its DQT marker.
    public var isLast: Bool
    /// 64 natural-order coefficients (decoded from the JPEG DQT
    /// payload, not stored in the jbrd Bundle itself — the bridge
    /// fills these from the JXL frame's quant matrices).
    public var values: [Int32]
    public init(
        precision: UInt32 = 0, index: UInt32 = 0,
        isLast: Bool = true, values: [Int32] = []
    ) {
        self.precision = precision
        self.index = index
        self.isLast = isLast
        self.values = values
    }
}

/// One Huffman table entry from the jbrd Bundle. Maps to libjxl's
/// `JPEGHuffmanCode`.
public struct JBRDHuffmanCode: Sendable, Equatable {
    /// Length histogram: counts[i] is the number of codes of bit
    /// length `i` (i ∈ 0..16). counts[0] is always 0.
    public var counts: [UInt32]
    /// Symbol values sorted by ascending bit length.
    public var values: [UInt32]
    /// Slot id: high nibble = AC flag (1=AC, 0=DC), low nibble =
    /// slot index 0..3.
    public var slotId: Int
    /// True if this is the last table in its DHT marker.
    public var isLast: Bool
    public init(
        counts: [UInt32] = Array(repeating: 0, count: 17),
        values: [UInt32] = [],
        slotId: Int = 0, isLast: Bool = true
    ) {
        self.counts = counts
        self.values = values
        self.slotId = slotId
        self.isLast = isLast
    }
}

/// Per-scan info (SOS marker contents + progressive-mode state).
public struct JBRDScanInfo: Sendable, Equatable {
    public var ss: UInt32        // Spectral start (Ss)
    public var se: UInt32        // Spectral end (Se)
    public var ah: UInt32        // Approximation high
    public var al: UInt32        // Approximation low
    public var numComponents: UInt32
    public var components: [JBRDScanComponent]
    public var lastNeededPass: UInt32
    public var resetPoints: [UInt32]
    public var extraZeroRuns: [JBRDExtraZeroRun]
    public init(
        ss: UInt32 = 0, se: UInt32 = 63,
        ah: UInt32 = 0, al: UInt32 = 0,
        numComponents: UInt32 = 1,
        components: [JBRDScanComponent] = [],
        lastNeededPass: UInt32 = 0,
        resetPoints: [UInt32] = [],
        extraZeroRuns: [JBRDExtraZeroRun] = []
    ) {
        self.ss = ss; self.se = se
        self.ah = ah; self.al = al
        self.numComponents = numComponents
        self.components = components
        self.lastNeededPass = lastNeededPass
        self.resetPoints = resetPoints
        self.extraZeroRuns = extraZeroRuns
    }
}

public struct JBRDScanComponent: Sendable, Equatable {
    public var compIdx: UInt32
    public var dcTblIdx: UInt32
    public var acTblIdx: UInt32
    public init(
        compIdx: UInt32 = 0, dcTblIdx: UInt32 = 0,
        acTblIdx: UInt32 = 0
    ) {
        self.compIdx = compIdx
        self.dcTblIdx = dcTblIdx
        self.acTblIdx = acTblIdx
    }
}

public struct JBRDExtraZeroRun: Sendable, Equatable {
    public var blockIdx: UInt32
    public var numExtraZeroRuns: UInt32
    public init(blockIdx: UInt32 = 0, numExtraZeroRuns: UInt32 = 1) {
        self.blockIdx = blockIdx
        self.numExtraZeroRuns = numExtraZeroRuns
    }
}

/// App-marker classification (libjxl `AppMarkerType`).
public enum JBRDAppMarkerType: UInt32, Sendable, Equatable {
    case unknown = 0
    case icc = 1
    case exif = 2
    case xmp = 3
}

/// One JPEG component (id + sampling factors + quant table).
public struct JBRDComponent: Sendable, Equatable {
    public var id: UInt32             // 1-byte component id
    public var hSampFactor: Int       // horizontal sampling factor
    public var vSampFactor: Int       // vertical sampling factor
    public var quantIdx: UInt32       // quant table 0..3
    public var widthInBlocks: UInt32
    public var heightInBlocks: UInt32
    public init(
        id: UInt32 = 0,
        hSampFactor: Int = 1, vSampFactor: Int = 1,
        quantIdx: UInt32 = 0,
        widthInBlocks: UInt32 = 0, heightInBlocks: UInt32 = 0
    ) {
        self.id = id
        self.hSampFactor = hSampFactor
        self.vSampFactor = vSampFactor
        self.quantIdx = quantIdx
        self.widthInBlocks = widthInBlocks
        self.heightInBlocks = heightInBlocks
    }
}

/// Full jbrd-Bundle payload. Mirrors libjxl's `JPEGData` struct at
/// the field level; reading + writing is via `JBRDBox.read`/`write`.
public struct JBRDBox: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var restartInterval: UInt32
    public var appData: [Data]
    public var appMarkerType: [JBRDAppMarkerType]
    public var comData: [Data]
    public var quant: [JBRDQuantTable]
    public var huffmanCode: [JBRDHuffmanCode]
    public var components: [JBRDComponent]
    public var scanInfo: [JBRDScanInfo]
    public var markerOrder: [UInt8]
    public var interMarkerData: [Data]
    public var tailData: Data
    public var hasZeroPaddingBit: Bool
    public var paddingBits: [UInt8]

    public init(
        width: Int = 0, height: Int = 0,
        restartInterval: UInt32 = 0,
        appData: [Data] = [],
        appMarkerType: [JBRDAppMarkerType] = [],
        comData: [Data] = [],
        quant: [JBRDQuantTable] = [],
        huffmanCode: [JBRDHuffmanCode] = [],
        components: [JBRDComponent] = [],
        scanInfo: [JBRDScanInfo] = [],
        markerOrder: [UInt8] = [],
        interMarkerData: [Data] = [],
        tailData: Data = Data(),
        hasZeroPaddingBit: Bool = false,
        paddingBits: [UInt8] = []
    ) {
        self.width = width; self.height = height
        self.restartInterval = restartInterval
        self.appData = appData
        self.appMarkerType = appMarkerType
        self.comData = comData
        self.quant = quant
        self.huffmanCode = huffmanCode
        self.components = components
        self.scanInfo = scanInfo
        self.markerOrder = markerOrder
        self.interMarkerData = interMarkerData
        self.tailData = tailData
        self.hasZeroPaddingBit = hasZeroPaddingBit
        self.paddingBits = paddingBits
    }
}

/// Bundle reader for the `jbrd` box payload. Implements the Field-
/// style serialisation libjxl's `JPEGData::VisitFields` produces.
/// The Brotli-compressed payload that follows the Bundle is read
/// separately by `JBRDBox.readBrotliPayload(:)` once the Brotli
/// decoder ships (phase J step 5g).
public enum JBRDBoxReader {

    /// Read a jbrd Bundle. Stops at the byte boundary after the
    /// Bundle's `padding_bits` field; the caller continues with
    /// `BrotliDecoder.decode(...)` over the remaining bytes.
    ///
    /// **Status (v0.12.0g7 — partial).** Implements the first portion
    /// of `JPEGData::VisitFields`: is_gray, marker_order walk,
    /// app_data / com_data / scan_info sizing, app marker types,
    /// app/com marker lengths, quant table count + metadata,
    /// component type + ids + quant_idx. The Huffman-code,
    /// scan-info, restart-interval, intermarker, tail, padding-bits,
    /// and final cross-check sections are the next bite.
    public static func read(
        from r: inout BitReader
    ) throws -> JBRDBox {
        var box = JBRDBox()
        do {
            // 1. is_gray
            let isGray = try r.readBit()
            // 2. marker_order walk (6-bit code + 0xc0 offset).
            //    Terminates at 0xd9 (EOI).
            var markers: [UInt8] = []
            var info = JPEGInfo()
            while true {
                let raw = try r.read(bits: 6)
                let marker = UInt8(raw + 0xC0)
                markers.append(marker)
                if marker & 0xF0 == 0xE0 { info.numAppMarkers += 1 }
                if marker == 0xFE { info.numComMarkers += 1 }
                if marker == 0xDA { info.numScans += 1 }
                if marker == 0xFF { info.numInterMarker += 1 }
                if marker == 0xDD { info.hasDRI = true }
                if markers.count > 16384 {
                    throw JBRDError.tooManyMarkers(markers.count)
                }
                if marker == 0xD9 { break }  // EOI terminator
            }
            box.markerOrder = markers

            // Size the per-section vectors from marker counts.
            box.appData = Array(repeating: Data(),
                count: info.numAppMarkers)
            box.appMarkerType = Array(
                repeating: .unknown, count: info.numAppMarkers)
            box.comData = Array(repeating: Data(),
                count: info.numComMarkers)
            box.scanInfo = Array(
                repeating: JBRDScanInfo(),
                count: info.numScans)

            // Set up component count from is_gray (will be refined
            // by the component_type field below).
            if isGray {
                box.components = [JBRDComponent()]
            } else {
                box.components = [
                    JBRDComponent(), JBRDComponent(),
                    JBRDComponent(),
                ]
            }

            // 3. Per app marker: marker_type (Enum 4-way) + 16-bit
            //    length.
            for i in 0..<info.numAppMarkers {
                // libjxl `U32(Val(0), Val(1), BitsOffset(1, 2),
                // BitsOffset(2, 4), 0, ...)`. Encodes 4 distinct
                // marker-type cases.
                let t = try r.readU32((
                    .literal(0),                  // kUnknown
                    .literal(1),                  // kICC
                    .offset(constant: 2, extraBits: 1),
                                                   // kExif (2..3)
                    .offset(constant: 4, extraBits: 2)
                                                   // kXMP (4..7)
                ))
                guard let mt = JBRDAppMarkerType(rawValue: t)
                else {
                    throw JBRDError.notImplemented(
                        "app_marker_type \(t) outside known enum")
                }
                box.appMarkerType[i] = mt
                let len = try r.read(bits: 16)
                // Allocate the marker storage at the recorded
                // length + 1 (length-field convention: stored
                // value is total bytes - 1).
                box.appData[i] = Data(
                    count: Int(len) + 1)
            }
            // 4. Per com marker: 16-bit length.
            for i in 0..<info.numComMarkers {
                let len = try r.read(bits: 16)
                box.comData[i] = Data(count: Int(len) + 1)
            }
            // 5. num_quant_tables — U32(Val(1), Val(2), Val(3),
            //    Val(4), default=2).
            let nQuant = try r.readU32((
                .literal(1), .literal(2),
                .literal(3), .literal(4)))
            if nQuant == 4 {
                throw JBRDError.invalidQuantTableCount
            }
            box.quant = Array(
                repeating: JBRDQuantTable(),
                count: Int(nQuant))
            for i in 0..<Int(nQuant) {
                let precision = try r.read(bits: 1)
                if precision > 1 {
                    throw JBRDError.invalidQuantPrecision
                }
                let index = try r.read(bits: 2)
                let isLast = try r.readBit()
                box.quant[i] = JBRDQuantTable(
                    precision: precision, index: index,
                    isLast: isLast)
            }
            // 6. component_type — Bits(2, default=kYCbCr=1).
            //    Values: 0=kGray, 1=kYCbCr, 2=kRGB, 3=kCustom.
            let compType = try r.read(bits: 2)
            var numComponents: UInt32
            switch compType {
            case 0:  // kGray
                numComponents = 1
            case 1, 2:  // kYCbCr or kRGB
                numComponents = 3
            case 3:  // kCustom — read num_components
                numComponents = try r.readU32((
                    .literal(1), .literal(2),
                    .literal(3), .literal(4)))
                if numComponents != 1 && numComponents != 3 {
                    throw JBRDError.invalidComponentCount(
                        numComponents)
                }
            default:
                throw JBRDError.invalidComponentCount(compType)
            }
            // Resize components and assign canonical ids.
            if box.components.count != Int(numComponents) {
                box.components = Array(
                    repeating: JBRDComponent(),
                    count: Int(numComponents))
            }
            switch compType {
            case 0:
                box.components[0].id = 1
            case 1:  // YCbCr
                box.components[0].id = 1
                box.components[1].id = 2
                box.components[2].id = 3
            case 2:  // RGB
                box.components[0].id = UInt32(UInt8(ascii: "R"))
                box.components[1].id = UInt32(UInt8(ascii: "G"))
                box.components[2].id = UInt32(UInt8(ascii: "B"))
            case 3:  // Custom — read ids
                for i in 0..<Int(numComponents) {
                    box.components[i].id = try r.read(bits: 8)
                }
            default:
                break
            }
            // Per-component quant_idx (2 bits each).
            for i in 0..<Int(numComponents) {
                let qIdx = try r.read(bits: 2)
                if qIdx >= UInt32(box.quant.count) {
                    throw JBRDError.invalidQuantIndex(
                        comp: i, idx: qIdx)
                }
                box.components[i].quantIdx = qIdx
            }

            // 7. Huffman tables.
            //    num_huff: U32(Val(4), BitsOffset(3, 2), BitsOffset(4, 10),
            //                  BitsOffset(6, 26), default=4)
            let numHuff = try r.readU32((
                .literal(4),
                .offset(constant: 2, extraBits: 3),
                .offset(constant: 10, extraBits: 4),
                .offset(constant: 26, extraBits: 6)))
            box.huffmanCode = Array(
                repeating: JBRDHuffmanCode(),
                count: Int(numHuff))
            for i in 0..<Int(numHuff) {
                let isAC = try r.readBit()
                let id = try r.read(bits: 2)
                let isLast = try r.readBit()
                var counts = [UInt32](repeating: 0, count: 17)
                var numSymbols = 0
                for k in 0...16 {
                    // U32(Val(0), Val(1), BitsOffset(3, 2), Bits(8),
                    //     default=0)
                    let v = try r.readU32((
                        .literal(0), .literal(1),
                        .offset(constant: 2, extraBits: 3),
                        .bits(8)))
                    counts[k] = v
                    numSymbols += Int(v)
                }
                if numSymbols < 1 {
                    throw JBRDError.notImplemented(
                        "empty Huffman table at huffman_code[\(i)]")
                }
                if numSymbols > 257 {
                    // kJpegHuffmanAlphabetSize+1 = 257 (256 plus EOI
                    // sentinel).
                    throw JBRDError.notImplemented(
                        "Huffman code too large at huffman_code[\(i)]"
                        + ": \(numSymbols)")
                }
                var values = [UInt32](repeating: 0, count: numSymbols)
                var valueSlots: [UInt64] = [0, 0, 0, 0, 0]
                for k in 0..<numSymbols {
                    // U32(Bits(2), BitsOffset(2, 4), BitsOffset(4, 8),
                    //     BitsOffset(8, 1), default=0)
                    let v = try r.readU32((
                        .bits(2),
                        .offset(constant: 4, extraBits: 2),
                        .offset(constant: 8, extraBits: 4),
                        .offset(constant: 1, extraBits: 8)))
                    values[k] = v
                    let slot = Int(v >> 6)
                    let bit = UInt64(1) << UInt64(v & 0x3F)
                    valueSlots[slot] |= bit
                }
                if values[numSymbols - 1] != 256 {
                    // libjxl kJpegHuffmanAlphabetSize = 256.
                    throw JBRDError.missingEOISymbol
                }
                // valueSlots[4] should have exactly bit 0 set (for
                // the EOI sentinel 256 itself).
                // Duplicate check.
                var distinctCount = 1   // EOI sentinel
                for s in 0..<4 {
                    distinctCount += valueSlots[s].nonzeroBitCount
                }
                if distinctCount != numSymbols {
                    throw JBRDError.duplicateHuffmanSymbols
                }
                if !isAC {
                    // DC range check: kJpegDCAlphabetSize = 12. The
                    // bits in valueSlots above 12 (in slot 0) and
                    // any bits in slots 1, 2, 3 indicate out-of-DC-
                    // range symbols.
                    let outOfRange = (valueSlots[0] >> 12)
                        | valueSlots[1]
                        | valueSlots[2]
                        | valueSlots[3]
                    if outOfRange != 0 {
                        throw JBRDError.dcHuffmanOutOfRange
                    }
                }
                let slotId = (Int(isAC ? 1 : 0) << 4) | Int(id)
                box.huffmanCode[i] = JBRDHuffmanCode(
                    counts: counts, values: values,
                    slotId: slotId, isLast: isLast)
            }

            // 8. Per-scan info (Ss/Se/Ah/Al + per-component bindings).
            for i in 0..<box.scanInfo.count {
                let numComps = try r.readU32((
                    .literal(1), .literal(2),
                    .literal(3), .literal(4)))
                if numComps >= 4 {
                    throw JBRDError.invalidScanComponentCount(
                        numComps)
                }
                let ss = try r.read(bits: 6)
                let se = try r.read(bits: 6)
                let al = try r.read(bits: 4)
                let ah = try r.read(bits: 4)
                var comps: [JBRDScanComponent] = []
                comps.reserveCapacity(Int(numComps))
                for _ in 0..<Int(numComps) {
                    let compIdx = try r.read(bits: 2)
                    let acIdx = try r.read(bits: 2)
                    let dcIdx = try r.read(bits: 2)
                    comps.append(JBRDScanComponent(
                        compIdx: compIdx,
                        dcTblIdx: dcIdx, acTblIdx: acIdx))
                }
                // last_needed_pass — U32(Val(0), Val(1), Val(2),
                //   BitsOffset(3, 3), default=kMaxNumPasses-1=10)
                let lastNeededPass = try r.readU32((
                    .literal(0), .literal(1),
                    .literal(2),
                    .offset(constant: 3, extraBits: 3)))
                box.scanInfo[i] = JBRDScanInfo(
                    ss: ss, se: se, ah: ah, al: al,
                    numComponents: numComps,
                    components: comps,
                    lastNeededPass: lastNeededPass)
            }

            // 9. restart_interval (only if any marker was 0xDD).
            if info.hasDRI {
                box.restartInterval = try r.read(bits: 16)
            }

            // 10. Per-scan reset_points + extra_zero_runs (the
            //     bit-exact reconstruction extras).
            for i in 0..<box.scanInfo.count {
                // num_reset_points: U32(Val(0), BitsOffset(2, 1),
                //   BitsOffset(4, 4), BitsOffset(16, 20), default=0)
                let numResetPoints = try r.readU32((
                    .literal(0),
                    .offset(constant: 1, extraBits: 2),
                    .offset(constant: 4, extraBits: 4),
                    .offset(constant: 20, extraBits: 16)))
                var resetPoints: [UInt32] = []
                resetPoints.reserveCapacity(Int(numResetPoints))
                var lastBlockIdx: Int = -1
                for _ in 0..<Int(numResetPoints) {
                    // Block index encoded as delta from
                    // last_block_idx + 1.
                    let delta = try r.readU32((
                        .literal(0),
                        .offset(constant: 1, extraBits: 3),
                        .offset(constant: 9, extraBits: 5),
                        .offset(constant: 41, extraBits: 28)))
                    let blockIdx =
                        UInt32(lastBlockIdx + 1) &+ delta
                    if blockIdx >= (3 << 26) {
                        throw JBRDError.invalidBlockIndex(blockIdx)
                    }
                    resetPoints.append(blockIdx)
                    lastBlockIdx = Int(blockIdx)
                }
                box.scanInfo[i].resetPoints = resetPoints

                // num_extra_zero_runs: same distribution as
                // num_reset_points.
                let numEZR = try r.readU32((
                    .literal(0),
                    .offset(constant: 1, extraBits: 2),
                    .offset(constant: 4, extraBits: 4),
                    .offset(constant: 20, extraBits: 16)))
                var extraZeroRuns: [JBRDExtraZeroRun] = []
                extraZeroRuns.reserveCapacity(Int(numEZR))
                lastBlockIdx = -1
                for _ in 0..<Int(numEZR) {
                    // num_extra_zero_runs: U32(Val(1),
                    //   BitsOffset(2, 2), BitsOffset(4, 5),
                    //   BitsOffset(8, 20), default=1)
                    let numEZRThis = try r.readU32((
                        .literal(1),
                        .offset(constant: 2, extraBits: 2),
                        .offset(constant: 5, extraBits: 4),
                        .offset(constant: 20, extraBits: 8)))
                    // Block-idx delta (same encoding as reset).
                    let delta = try r.readU32((
                        .literal(0),
                        .offset(constant: 1, extraBits: 3),
                        .offset(constant: 9, extraBits: 5),
                        .offset(constant: 41, extraBits: 28)))
                    let blockIdx =
                        UInt32(lastBlockIdx + 1) &+ delta
                    if blockIdx > (3 << 26) {
                        throw JBRDError.invalidBlockIndex(blockIdx)
                    }
                    extraZeroRuns.append(JBRDExtraZeroRun(
                        blockIdx: blockIdx,
                        numExtraZeroRuns: numEZRThis))
                    lastBlockIdx = Int(blockIdx)
                }
                box.scanInfo[i].extraZeroRuns = extraZeroRuns
            }

            // 11. Inter-marker data sizes (16 bits each).
            var interMarkerSizes: [Int] = []
            for _ in 0..<info.numInterMarker {
                let s = try r.read(bits: 16)
                interMarkerSizes.append(Int(s))
            }

            // 12. tail_data_len — U32(Val(0), BitsOffset(8, 1),
            //     BitsOffset(16, 257), BitsOffset(22, 65793), default=0)
            let tailDataLen = try r.readU32((
                .literal(0),
                .offset(constant: 1, extraBits: 8),
                .offset(constant: 257, extraBits: 16),
                .offset(constant: 65793, extraBits: 22)))
            if tailDataLen > 4_260_096 {
                throw JBRDError.tailDataTooLarge(tailDataLen)
            }

            // 13. has_zero_padding_bit + padding bits.
            box.hasZeroPaddingBit = try r.readBit()
            if box.hasZeroPaddingBit {
                let nbit = try r.read(bits: 24)
                // Sanity: 1024 is libjxl's reserve cap for the
                // padding bits vector; the actual encoded count
                // can be larger but a runaway nbit suggests
                // corrupted input.
                if r.bitsRemaining < Int(nbit) {
                    throw JBRDError.truncated
                }
                var padding: [UInt8] = []
                padding.reserveCapacity(Int(min(nbit, 1024)))
                for _ in 0..<Int(nbit) {
                    padding.append(try r.readBit() ? 1 : 0)
                }
                box.paddingBits = padding
            }

            // Apply postponed actions (libjxl `if (visitor->IsReading())`):
            //   tail_data has its size now, but its actual bytes are
            //   in the Brotli payload (not the Bundle). We carry the
            //   size only; the bytes get filled in once the Brotli
            //   decoder lands.
            box.tailData = Data(count: Int(tailDataLen))
            // Same for inter_marker_data — we allocate the sized
            // empty slots ready to be filled by the Brotli reader.
            box.interMarkerData = interMarkerSizes.map {
                Data(count: $0)
            }

            // 14. Validation cross-checks (libjxl jpeg_data.cc:378-415).
            //     For each DHT in marker_order, walk the huffman_code
            //     entries up to is_last; record which DC/AC slot ids
            //     have been defined. For each SOS, verify the
            //     referenced DC/AC tables are already defined.
            try validateMarkerOrderTablesPrecedeSOS(box: box)
        } catch let e as BitstreamError {
            throw JBRDError.bitstream(e)
        }
        return box
    }

    /// libjxl `jpeg_data.cc:378-415` cross-check: for every SOS marker
    /// in `marker_order`, the DHT markers that precede it must define
    /// every DC + AC table the SOS references. Progressive frames
    /// (SOF2 = 0xC2) relax the DC check for spectral-non-zero scans
    /// and the AC check for DC-only scans.
    private static func validateMarkerOrderTablesPrecedeSOS(
        box: JBRDBox
    ) throws {
        var dhtIndex = 0
        var scanIndex = 0
        var isProgressive = false
        // 4 DC + 4 AC table slots.
        var dcOk = [Bool](repeating: false, count: 4)
        var acOk = [Bool](repeating: false, count: 4)
        for marker in box.markerOrder {
            if marker == 0xC2 {
                isProgressive = true
            } else if marker == 0xC4 {
                // DHT segment — consume Huffman codes until
                // is_last fires.
                while dhtIndex < box.huffmanCode.count {
                    let hc = box.huffmanCode[dhtIndex]
                    dhtIndex += 1
                    let isAC = (hc.slotId & 0x10) != 0
                    let id = hc.slotId & 0x0F
                    if isAC {
                        acOk[id] = true
                    } else {
                        dcOk[id] = true
                    }
                    if hc.isLast { break }
                }
            } else if marker == 0xDA {
                // SOS segment — verify referenced tables.
                if scanIndex >= box.scanInfo.count { break }
                let si = box.scanInfo[scanIndex]
                scanIndex += 1
                for k in 0..<Int(si.numComponents) {
                    let csi = si.components[k]
                    let dcId = Int(csi.dcTblIdx)
                    let acId = Int(csi.acTblIdx)
                    let wantDC = !isProgressive || (si.ss == 0)
                    if wantDC && !dcOk[dcId] {
                        throw JBRDError.notImplemented(
                            "DC Huffman table \(dcId) used before "
                            + "defined (scan \(scanIndex-1))")
                    }
                    let wantAC = !isProgressive
                        || (si.ss != 0) || (si.se != 0)
                    if wantAC && !acOk[acId] {
                        throw JBRDError.notImplemented(
                            "AC Huffman table \(acId) used before "
                            + "defined (scan \(scanIndex-1))")
                    }
                }
            }
        }
    }
}

/// Internal — running counts derived from the marker_order walk.
/// Mirrors libjxl's anonymous `JPEGInfo` struct in jpeg_data.cc.
private struct JPEGInfo {
    var numAppMarkers: Int = 0
    var numComMarkers: Int = 0
    var numScans: Int = 0
    var numInterMarker: Int = 0
    var hasDRI: Bool = false
}

extension JBRDBox {

    /// External metadata payloads (Exif/xml/jumb/ICC) carried in
    /// the JXL container, used to fill `kExif`/`kXMP`/`kICC` app
    /// markers during `distributeBrotliPayload`.
    ///
    /// libjxl convention:
    /// - `exif` carries the EXIF box payload, which is
    ///   `tiff_header_offset (4 bytes)` + TIFF data. For canonical
    ///   marker reconstruction the 4-byte offset is dropped and the
    ///   TIFF data is spliced at marker offset 9 (right after the
    ///   "Exif\0\0" tag).
    /// - `xmp` carries the XMP XML, spliced at marker offset 32
    ///   (right after the namespace URL).
    /// - `icc` carries the full ICC profile, which is **split**
    ///   across multiple `kICC` markers in the order they appear in
    ///   the source JPEG. Each marker has a 1-indexed sequence
    ///   number at byte 15 (set by the canonical template) and a
    ///   total count at byte 16 (set after all kICC markers are
    ///   sized). The ICC payload fragment at each marker fills bytes
    ///   17 onwards.
    public struct ExternalMetadata: Sendable {
        public var exif: Data?
        public var xmp: Data?
        public var icc: Data?
        public init(
            exif: Data? = nil, xmp: Data? = nil, icc: Data? = nil
        ) {
            self.exif = exif; self.xmp = xmp; self.icc = icc
        }
    }

    /// Distribute the Brotli-decompressed payload bytes into the
    /// `app_data`, `com_data`, `inter_marker_data`, and `tail_data`
    /// slots of `self`.
    ///
    /// libjxl `dec_jpeg_data.cc:65-117` walks these in a specific
    /// order:
    ///   1. For each `app_data[i]` with `app_marker_type[i] !=
    ///      kUnknown`: rather than reading from Brotli, the bytes
    ///      are reconstructed from canonical templates (JFIF/Exif/
    ///      XMP/ICC headers) — only the length field is set from
    ///      the Bundle.
    ///   2. For each `app_data[i]` with `app_marker_type[i] ==
    ///      kUnknown`: read the full marker payload from Brotli
    ///      and assert the length-field matches.
    ///   3. For each `com_data[i]`: read full payload from Brotli.
    ///   4. For each `inter_marker_data[i]`: read full payload.
    ///   5. Tail data: read `tail_data.count` bytes from Brotli.
    ///
    /// **Status (v0.12.0gj).** Implements:
    /// - `kUnknown` app markers (the common JFIF/COM-style) — full
    ///   payload from Brotli.
    /// - `kExif` / `kXMP` / `kICC` app markers — canonical marker
    ///   template fill (marker byte, length field, tag). Bodies are
    ///   spliced from the optional `external` parameter (caller
    ///   supplies the EXIF/XMP/ICC bytes from the JXL container's
    ///   metadata boxes).
    /// - `com_data`, `inter_marker_data`, `tail_data` — full payload
    ///   from Brotli.
    public mutating func distributeBrotliPayload(
        _ decoded: Data,
        external: ExternalMetadata = ExternalMetadata()
    ) throws {
        // Constants from libjxl `lib/jxl/jpeg/jpeg_data.h:35-37`.
        let kIccProfileTag: [UInt8] = [
            0x49, 0x43, 0x43, 0x5F, 0x50, 0x52, 0x4F, 0x46,
            0x49, 0x4C, 0x45, 0x00,   // "ICC_PROFILE\0" — 12 bytes
        ]
        let kExifTag: [UInt8] = [
            0x45, 0x78, 0x69, 0x66, 0x00, 0x00,   // "Exif\0\0" — 6 bytes
        ]
        let kXMPTag: [UInt8] = [
            0x68, 0x74, 0x74, 0x70, 0x3A, 0x2F, 0x2F, 0x6E,
            0x73, 0x2E, 0x61, 0x64, 0x6F, 0x62, 0x65, 0x2E,
            0x63, 0x6F, 0x6D, 0x2F, 0x78, 0x61, 0x70, 0x2F,
            0x31, 0x2E, 0x30, 0x2F, 0x00,
            // "http://ns.adobe.com/xap/1.0/\0" — 29 bytes
        ]

        var cursor = decoded.startIndex
        // First pass: kUnknown markers read from Brotli; kICC sets
        // its prefix (marker byte + length + tag + seq number);
        // kExif/kXMP do nothing here (their prefixes are set in
        // the second pass, libjxl convention).
        var numICC: UInt8 = 0
        for i in 0..<appData.count {
            let needed = appData[i].count
            switch appMarkerType[i] {
            case .unknown:
                guard cursor + needed <= decoded.endIndex else {
                    throw JBRDError.truncated
                }
                appData[i] = Data(decoded[cursor..<(cursor + needed)])
                cursor += needed
                if appData[i].count >= 3 {
                    let lenField =
                        (Int(appData[i][appData[i].startIndex + 1]) << 8)
                        | Int(appData[i][appData[i].startIndex + 2])
                    if lenField + 1 != appData[i].count {
                        throw JBRDError.notImplemented(
                            "app_data[\(i)] length field "
                            + "\(lenField) doesn't match "
                            + "size \(appData[i].count - 1)")
                    }
                }
            case .icc:
                guard appData[i].count >= 17 else {
                    throw JBRDError.notImplemented(
                        "kICC marker[\(i)] too small "
                        + "(\(appData[i].count) bytes < 17 needed)")
                }
                // Length field, marker byte, ICC tag, sequence #.
                numICC += 1
                var marker = appData[i]
                let sizeMinus1 = marker.count - 1
                marker[marker.startIndex + 0] = 0xE2     // APP2
                marker[marker.startIndex + 1] = UInt8(
                    (sizeMinus1 >> 8) & 0xFF)
                marker[marker.startIndex + 2] = UInt8(
                    sizeMinus1 & 0xFF)
                for k in 0..<12 {
                    marker[marker.startIndex + 3 + k] =
                        kIccProfileTag[k]
                }
                marker[marker.startIndex + 15] = numICC
                // marker[16] = total count, set in second pass.
                appData[i] = marker
            case .exif, .xmp:
                // Length-field set here (libjxl jpeg_data.cc:69-73).
                // marker byte + tag come in the second pass below.
                var marker = appData[i]
                let sizeMinus1 = marker.count - 1
                marker[marker.startIndex + 1] = UInt8(
                    (sizeMinus1 >> 8) & 0xFF)
                marker[marker.startIndex + 2] = UInt8(
                    sizeMinus1 & 0xFF)
                appData[i] = marker
            }
        }
        // Second pass: kICC sets total count; kExif/kXMP set marker
        // byte + tag (length field already done above). Bodies are
        // filled from `external` if supplied (after the canonical
        // prefix bytes).
        var iccCursor = 0
        for i in 0..<appData.count {
            switch appMarkerType[i] {
            case .icc:
                var marker = appData[i]
                marker[marker.startIndex + 16] = numICC
                // Fill ICC payload fragment for this marker (bytes 17+).
                if let icc = external.icc {
                    let chunkLen = marker.count - 17
                    let start = iccCursor
                    let end = min(start + chunkLen, icc.count)
                    if start < icc.count {
                        let chunk = icc[
                            (icc.startIndex + start)
                                ..< (icc.startIndex + end)]
                        for (k, b) in chunk.enumerated() {
                            marker[marker.startIndex + 17 + k] = b
                        }
                    }
                    iccCursor += chunkLen
                }
                appData[i] = marker
            case .exif:
                var marker = appData[i]
                guard marker.count >= 3 + kExifTag.count else {
                    throw JBRDError.notImplemented(
                        "kExif marker[\(i)] too small")
                }
                marker[marker.startIndex + 0] = 0xE1   // APP1
                for k in 0..<kExifTag.count {
                    marker[marker.startIndex + 3 + k] = kExifTag[k]
                }
                // Fill body from external.exif (after dropping the
                // 4-byte tiff_header_offset in the Exif box).
                if let exif = external.exif, exif.count >= 4 {
                    let tiffData = exif.suffix(
                        from: exif.startIndex + 4)
                    let bodyOffset = 3 + kExifTag.count
                    let bodyCapacity = marker.count - bodyOffset
                    let copyCount = min(tiffData.count, bodyCapacity)
                    for k in 0..<copyCount {
                        marker[marker.startIndex + bodyOffset + k] =
                            tiffData[tiffData.startIndex + k]
                    }
                }
                appData[i] = marker
            case .xmp:
                var marker = appData[i]
                guard marker.count >= 3 + kXMPTag.count else {
                    throw JBRDError.notImplemented(
                        "kXMP marker[\(i)] too small")
                }
                marker[marker.startIndex + 0] = 0xE1   // APP1
                for k in 0..<kXMPTag.count {
                    marker[marker.startIndex + 3 + k] = kXMPTag[k]
                }
                if let xmp = external.xmp {
                    let bodyOffset = 3 + kXMPTag.count
                    let bodyCapacity = marker.count - bodyOffset
                    let copyCount = min(xmp.count, bodyCapacity)
                    for k in 0..<copyCount {
                        marker[marker.startIndex + bodyOffset + k] =
                            xmp[xmp.startIndex + k]
                    }
                }
                appData[i] = marker
            case .unknown:
                break
            }
        }

        // 3. Com markers — full Brotli read.
        for i in 0..<comData.count {
            let needed = comData[i].count
            guard cursor + needed <= decoded.endIndex else {
                throw JBRDError.truncated
            }
            comData[i] = Data(decoded[cursor..<(cursor + needed)])
            cursor += needed
        }
        // 4. Inter-marker data.
        for i in 0..<interMarkerData.count {
            let needed = interMarkerData[i].count
            guard cursor + needed <= decoded.endIndex else {
                throw JBRDError.truncated
            }
            interMarkerData[i] = Data(
                decoded[cursor..<(cursor + needed)])
            cursor += needed
        }
        // 5. Tail data.
        let tailNeeded = tailData.count
        guard cursor + tailNeeded <= decoded.endIndex else {
            throw JBRDError.truncated
        }
        tailData = Data(decoded[cursor..<(cursor + tailNeeded)])
        cursor += tailNeeded

        if cursor != decoded.endIndex {
            // libjxl is strict about this — extra Brotli bytes
            // indicate a malformed jbrd.
            throw JBRDError.notImplemented(
                "Brotli payload had \(decoded.endIndex - cursor) "
                + "trailing bytes after distribution")
        }
    }
}

/// Bundle writer for the `jbrd` box payload. Inverse of
/// `JBRDBoxReader.read`. Each field uses the same U32 distribution
/// the reader expects.
///
/// **Status (v0.12.0g9)**. Full Bundle walk implemented — exact
/// inverse of the reader, verified via round-trip test.
public enum JBRDBoxWriter {

    /// Write a jbrd Bundle. The Brotli-compressed payload follows
    /// at byte boundary — written separately by callers (gated on
    /// the Brotli encoder, not yet shipped).
    public static func write(
        _ box: JBRDBox, to w: inout BitWriter
    ) throws {
        do {
            // 1. is_gray.
            let isGray = box.components.count == 1
            w.writeBit(isGray)

            // 2. marker_order walk — 6-bit codes (marker - 0xC0).
            if box.markerOrder.count > 16384 {
                throw JBRDError.tooManyMarkers(box.markerOrder.count)
            }
            for m in box.markerOrder {
                let code = UInt32(m) &- 0xC0
                w.write(bits: 6, value: code)
            }

            // 3. App marker metadata.
            for i in 0..<box.appData.count {
                let t = box.appMarkerType[i].rawValue
                try w.writeU32(t, distributions: (
                    .literal(0), .literal(1),
                    .offset(constant: 2, extraBits: 1),
                    .offset(constant: 4, extraBits: 2)))
                let len = UInt32(box.appData[i].count) - 1
                w.write(bits: 16, value: len)
            }
            // 4. Com marker lengths.
            for com in box.comData {
                let len = UInt32(com.count) - 1
                w.write(bits: 16, value: len)
            }
            // 5. Quant tables.
            let nQuant = UInt32(box.quant.count)
            if nQuant == 4 {
                throw JBRDError.invalidQuantTableCount
            }
            try w.writeU32(nQuant, distributions: (
                .literal(1), .literal(2),
                .literal(3), .literal(4)))
            for q in box.quant {
                if q.precision > 1 {
                    throw JBRDError.invalidQuantPrecision
                }
                w.write(bits: 1, value: q.precision)
                w.write(bits: 2, value: q.index)
                w.writeBit(q.isLast)
            }
            // 6. Component type.
            //    Classify based on box.components ids — mirrors the
            //    libjxl reader's component_type detection. Wire format
            //    is Bits(2, default=1).
            let componentType: UInt32
            if box.components.count == 1 && box.components[0].id == 1
            {
                componentType = 0  // kGray
            } else if box.components.count == 3
                && box.components[0].id == 1
                && box.components[1].id == 2
                && box.components[2].id == 3
            {
                componentType = 1  // kYCbCr
            } else if box.components.count == 3
                && box.components[0].id == UInt32(UInt8(ascii: "R"))
                && box.components[1].id == UInt32(UInt8(ascii: "G"))
                && box.components[2].id == UInt32(UInt8(ascii: "B"))
            {
                componentType = 2  // kRGB
            } else {
                componentType = 3  // kCustom
            }
            w.write(bits: 2, value: componentType)
            if componentType == 3 {
                let nc = UInt32(box.components.count)
                try w.writeU32(nc, distributions: (
                    .literal(1), .literal(2),
                    .literal(3), .literal(4)))
                for comp in box.components {
                    w.write(bits: 8, value: comp.id)
                }
            }
            // Per-component quant_idx.
            for comp in box.components {
                w.write(bits: 2, value: comp.quantIdx)
            }

            // 7. Huffman codes.
            try w.writeU32(
                UInt32(box.huffmanCode.count),
                distributions: (
                    .literal(4),
                    .offset(constant: 2, extraBits: 3),
                    .offset(constant: 10, extraBits: 4),
                    .offset(constant: 26, extraBits: 6)))
            for hc in box.huffmanCode {
                let isAC = (hc.slotId & 0x10) != 0
                let id = UInt32(hc.slotId & 0x0F)
                w.writeBit(isAC)
                w.write(bits: 2, value: id)
                w.writeBit(hc.isLast)
                var numSymbols = 0
                for k in 0...16 {
                    try w.writeU32(hc.counts[k], distributions: (
                        .literal(0), .literal(1),
                        .offset(constant: 2, extraBits: 3),
                        .bits(8)))
                    numSymbols += Int(hc.counts[k])
                }
                if numSymbols > hc.values.count {
                    throw JBRDError.notImplemented(
                        "Huffman values undersized: numSymbols="
                        + "\(numSymbols), values.count="
                        + "\(hc.values.count)")
                }
                for k in 0..<numSymbols {
                    try w.writeU32(hc.values[k], distributions: (
                        .bits(2),
                        .offset(constant: 4, extraBits: 2),
                        .offset(constant: 8, extraBits: 4),
                        .offset(constant: 1, extraBits: 8)))
                }
            }

            // 8. Scan info.
            for scan in box.scanInfo {
                if scan.numComponents >= 4 {
                    throw JBRDError.invalidScanComponentCount(
                        scan.numComponents)
                }
                try w.writeU32(scan.numComponents,
                    distributions: (
                        .literal(1), .literal(2),
                        .literal(3), .literal(4)))
                w.write(bits: 6, value: scan.ss)
                w.write(bits: 6, value: scan.se)
                w.write(bits: 4, value: scan.al)
                w.write(bits: 4, value: scan.ah)
                for k in 0..<Int(scan.numComponents) {
                    let c = scan.components[k]
                    w.write(bits: 2, value: c.compIdx)
                    w.write(bits: 2, value: c.acTblIdx)
                    w.write(bits: 2, value: c.dcTblIdx)
                }
                try w.writeU32(scan.lastNeededPass,
                    distributions: (
                        .literal(0), .literal(1),
                        .literal(2),
                        .offset(constant: 3, extraBits: 3)))
            }

            // 9. Restart interval (only if has_dri).
            let hasDRI = box.markerOrder.contains(0xDD)
            if hasDRI {
                w.write(bits: 16, value: box.restartInterval)
            }

            // 10. Reset points + extra zero runs per scan.
            for scan in box.scanInfo {
                try w.writeU32(
                    UInt32(scan.resetPoints.count),
                    distributions: (
                        .literal(0),
                        .offset(constant: 1, extraBits: 2),
                        .offset(constant: 4, extraBits: 4),
                        .offset(constant: 20, extraBits: 16)))
                var lastBlockIdx: Int = -1
                for b in scan.resetPoints {
                    let delta = b &- UInt32(lastBlockIdx + 1)
                    if b >= (3 << 26) {
                        throw JBRDError.invalidBlockIndex(b)
                    }
                    try w.writeU32(delta, distributions: (
                        .literal(0),
                        .offset(constant: 1, extraBits: 3),
                        .offset(constant: 9, extraBits: 5),
                        .offset(constant: 41, extraBits: 28)))
                    lastBlockIdx = Int(b)
                }
                try w.writeU32(
                    UInt32(scan.extraZeroRuns.count),
                    distributions: (
                        .literal(0),
                        .offset(constant: 1, extraBits: 2),
                        .offset(constant: 4, extraBits: 4),
                        .offset(constant: 20, extraBits: 16)))
                lastBlockIdx = -1
                for ezr in scan.extraZeroRuns {
                    try w.writeU32(ezr.numExtraZeroRuns,
                        distributions: (
                            .literal(1),
                            .offset(constant: 2, extraBits: 2),
                            .offset(constant: 5, extraBits: 4),
                            .offset(constant: 20, extraBits: 8)))
                    let delta = ezr.blockIdx
                        &- UInt32(lastBlockIdx + 1)
                    if ezr.blockIdx > (3 << 26) {
                        throw JBRDError.invalidBlockIndex(
                            ezr.blockIdx)
                    }
                    try w.writeU32(delta, distributions: (
                        .literal(0),
                        .offset(constant: 1, extraBits: 3),
                        .offset(constant: 9, extraBits: 5),
                        .offset(constant: 41, extraBits: 28)))
                    lastBlockIdx = Int(ezr.blockIdx)
                }
            }

            // 11. Inter-marker sizes.
            for data in box.interMarkerData {
                w.write(bits: 16, value: UInt32(data.count))
            }

            // 12. Tail data length.
            let tailLen = UInt32(box.tailData.count)
            if tailLen > 4_260_096 {
                throw JBRDError.tailDataTooLarge(tailLen)
            }
            try w.writeU32(tailLen, distributions: (
                .literal(0),
                .offset(constant: 1, extraBits: 8),
                .offset(constant: 257, extraBits: 16),
                .offset(constant: 65793, extraBits: 22)))

            // 13. Padding bits.
            w.writeBit(box.hasZeroPaddingBit)
            if box.hasZeroPaddingBit {
                let nbit = UInt32(box.paddingBits.count)
                w.write(bits: 24, value: nbit)
                for b in box.paddingBits {
                    w.writeBit(b != 0)
                }
            }
        } catch let e as BitstreamError {
            throw JBRDError.bitstream(e)
        } catch let e as JBRDError {
            throw e
        }
    }
}
