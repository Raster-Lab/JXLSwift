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
///
/// **Status (v0.12.0g0 scaffold)**. The reader signature is in
/// place; the implementation is the next bite.
public enum JBRDBoxReader {

    /// Read a jbrd Bundle. Stops at the byte boundary after the
    /// Bundle's `padding_bits` field; the caller continues with
    /// `BrotliDecoder.decode(...)` over the remaining bytes.
    ///
    /// **Status (v0.12.0g0 scaffold)**. Throws `notImplemented` —
    /// the full Field-by-Field walk lands in the next bite.
    public static func read(
        from r: inout BitReader
    ) throws -> JBRDBox {
        throw JBRDError.notImplemented(
            "JBRDBoxReader.read — full Bundle walk pending; see "
            + "libjxl/jpeg/jpeg_data.cc::JPEGData::VisitFields")
    }
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
