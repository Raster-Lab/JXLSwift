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
public enum JBRDAppMarkerType: UInt32, Sendable {
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
public struct JBRDBox: Sendable {
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

            // Remaining fields (Huffman tables, scan info, restart
            // interval, intermarker/tail data sizes, padding bits)
            // are the next bite — surface what we have so far.
        } catch let e as BitstreamError {
            throw JBRDError.bitstream(e)
        }
        return box
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

/// Bundle writer for the `jbrd` box payload. Inverse of
/// `JBRDBoxReader`. Used by the forward bridge once we start emitting
/// `jbrd` boxes for byte-identical round-trip support.
public enum JBRDBoxWriter {

    /// Write a jbrd Bundle. The Brotli-compressed payload follows
    /// at byte boundary — written separately by callers.
    ///
    /// **Status (v0.12.0g0 scaffold)**. Throws `notImplemented`.
    public static func write(
        _ box: JBRDBox, to w: inout BitWriter
    ) throws {
        throw JBRDError.notImplemented(
            "JBRDBoxWriter.write — full Bundle walk pending")
    }
}
