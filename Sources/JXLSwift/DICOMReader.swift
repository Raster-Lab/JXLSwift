// Minimal DICOM (Digital Imaging and Communications in Medicine) reader.
//
// Scope: enough of DICOM to ingest the uncompressed monochrome scans that
// dominate radiology archives — what `magick` would otherwise have to read
// and downsample to 8-bit before cjxl can consume it.
//
// Supported transfer syntaxes:
//   • 1.2.840.10008.1.2     — Implicit VR Little Endian
//   • 1.2.840.10008.1.2.1   — Explicit VR Little Endian
//   • 1.2.840.10008.1.2.2   — Explicit VR Big Endian (pixel-byte-swap on read)
//
// NOT supported (will throw): JPEG / JPEG-LS / JPEG 2000 / RLE encapsulated
// transfer syntaxes. Those require a separate decompression step which is
// out of scope; in practice they are rare in modern PACS archives.

import Foundation

/// Metadata extracted from the DICOM dataset alongside the pixel buffer.
/// The Modality LUT (`rescaleSlope`/`rescaleIntercept`) maps stored pixel
/// values to "modality output" values like Hounsfield units; we surface
/// it but do not apply it at read time so lossless round-trips preserve
/// the original stored values.
public struct DICOMMetadata: Sendable {
    public let modality: String?
    public let photometricInterpretation: String
    /// Number of meaningful bits per pixel (e.g. 12 for 12-bit-stored).
    public let bitsStored: Int
    /// 0 = unsigned, 1 = signed. The reader biases signed pixels by
    /// `2^(bitsStored-1)` so the resulting `ImageFrame` is always
    /// unsigned. Recover original signed values via `signedBias`.
    public let pixelRepresentation: Int
    public var signedBias: Int { pixelRepresentation == 1 ? (1 << (bitsStored - 1)) : 0 }
    /// `output_value = stored_value * rescaleSlope + rescaleIntercept`.
    /// Default 1.0 / 0.0 means values are already in display units.
    public let rescaleSlope: Double
    public let rescaleIntercept: Double
    /// SOP-instance grouping. Useful for batch tools that bundle slices
    /// of the same volume.
    public let seriesInstanceUID: String?
    public let studyInstanceUID: String?
    /// Slice ordering hint (DICOM (0020,1041) "Slice Location"). NaN if absent.
    public let sliceLocation: Double
    public let instanceNumber: Int?
}

public enum DICOMError: Error, LocalizedError {
    case invalidFile(String)
    case unsupportedTransferSyntax(String)
    case missingTag(String)
    case malformedPixelData

    public var errorDescription: String? {
        switch self {
        case .invalidFile(let m):              return "DICOM: \(m)"
        case .unsupportedTransferSyntax(let u): return "DICOM: unsupported transfer syntax \(u) (compressed pixel data not handled)"
        case .missingTag(let n):               return "DICOM: missing required tag \(n)"
        case .malformedPixelData:              return "DICOM: pixel data is malformed for the declared geometry"
        }
    }
}

public enum DICOMReader {

    /// Read a `.dcm` file from disk and produce an `ImageFrame` whose
    /// pixel buffer carries the original bit depth (8 → uint8, ≥9 → uint16).
    /// The photometric interpretation (`MONOCHROME1` vs `MONOCHROME2`) is
    /// honoured: MONOCHROME1 means "min sample = white", which we invert
    /// at read time so the caller always sees the standard "min = black"
    /// convention.
    public static func read(_ url: URL) throws -> ImageFrame {
        try readWithMetadata(url).frame
    }

    /// Read both the pixel buffer and the medical metadata. The metadata
    /// includes the signed-pixel bias and Modality LUT (RescaleSlope /
    /// Intercept) — necessary for correct interpretation of CT / dose maps
    /// where the encoded pixel values aren't directly displayable.
    public static func readWithMetadata(_ url: URL) throws -> (frame: ImageFrame, metadata: DICOMMetadata) {
        let data = try Data(contentsOf: url)
        return try parseWithMetadata(data)
    }

    /// Parse an already-loaded DICOM byte stream (frame only).
    public static func parse(_ data: Data) throws -> ImageFrame {
        try parseWithMetadata(data).frame
    }

    /// Parse an already-loaded DICOM byte stream returning frame + metadata.
    public static func parseWithMetadata(_ data: Data) throws -> (frame: ImageFrame, metadata: DICOMMetadata) {
        guard data.count > 132 else { throw DICOMError.invalidFile("too small") }
        // Preamble (128 bytes) + DICM magic.
        let magic = data.subdata(in: 128..<132)
        guard magic == Data([0x44, 0x49, 0x43, 0x4D]) else {
            throw DICOMError.invalidFile("missing DICM magic")
        }

        var cursor = 132
        // The File Meta Information group is always Explicit VR Little Endian
        // and is bounded by element (0002,0000) which carries the group length.
        var transferSyntaxUID = "1.2.840.10008.1.2" // implicit VR LE default
        let metaEnd: Int
        do {
            // First element is required to be (0002,0000) UL FileMetaInformationGroupLength.
            let (group, element, _, valueRange, next) = try readExplicitElement(data, at: cursor)
            guard group == 0x0002 && element == 0x0000 else {
                throw DICOMError.invalidFile("File Meta does not start with (0002,0000)")
            }
            cursor = next
            // The value at valueRange is a 4-byte little-endian UL.
            let groupLength = Int(uleU32(data, at: valueRange.lowerBound))
            metaEnd = cursor + groupLength
        }
        while cursor < metaEnd {
            let (group, element, _, valueRange, next) = try readExplicitElement(data, at: cursor)
            if group == 0x0002 && element == 0x0010 {
                transferSyntaxUID = readASCII(data, range: valueRange).trimmingCharacters(in: .whitespacesAndNewlines).trimmingNullBytes()
            }
            cursor = next
        }

        // Choose dataset parser based on transfer syntax.
        let isExplicitVR: Bool
        let isBigEndian: Bool
        switch transferSyntaxUID {
        case "1.2.840.10008.1.2":     isExplicitVR = false; isBigEndian = false
        case "1.2.840.10008.1.2.1":   isExplicitVR = true;  isBigEndian = false
        case "1.2.840.10008.1.2.2":   isExplicitVR = true;  isBigEndian = true
        default:
            throw DICOMError.unsupportedTransferSyntax(transferSyntaxUID)
        }

        // Walk the dataset, collecting required tags.
        var rows: Int? = nil
        var cols: Int? = nil
        var bitsAllocated: Int? = nil
        var bitsStored: Int? = nil
        var pixelRepresentation: Int = 0      // 0 = unsigned, 1 = signed
        var samplesPerPixel: Int = 1
        var photometric = "MONOCHROME2"
        var pixelDataRange: Range<Int>? = nil
        // Medical-imaging metadata (Phase 3a):
        var modality: String? = nil
        var rescaleSlope: Double = 1.0
        var rescaleIntercept: Double = 0.0
        var seriesUID: String? = nil
        var studyUID: String? = nil
        var sliceLocation: Double = .nan
        var instanceNumber: Int? = nil

        while cursor < data.count {
            let group: UInt16
            let element: UInt16
            let valueRange: Range<Int>
            let nextCursor: Int

            if isExplicitVR {
                let r = try readExplicitElement(data, at: cursor, bigEndian: isBigEndian)
                group = r.group; element = r.element
                valueRange = r.valueRange; nextCursor = r.next
            } else {
                let r = try readImplicitElement(data, at: cursor)
                group = r.group; element = r.element
                valueRange = r.valueRange; nextCursor = r.next
            }

            switch (group, element) {
            case (0x0008, 0x0060):
                modality = readASCII(data, range: valueRange).trimmingCharacters(in: .whitespacesAndNewlines).trimmingNullBytes()
            case (0x0020, 0x000D):
                studyUID = readASCII(data, range: valueRange).trimmingNullBytes()
            case (0x0020, 0x000E):
                seriesUID = readASCII(data, range: valueRange).trimmingNullBytes()
            case (0x0020, 0x0013):
                instanceNumber = Int(readASCII(data, range: valueRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines).trimmingNullBytes())
            case (0x0020, 0x1041):
                sliceLocation = Double(readASCII(data, range: valueRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines).trimmingNullBytes()) ?? .nan
            case (0x0028, 0x0002):
                samplesPerPixel = Int(u16(data, at: valueRange.lowerBound, bigEndian: isBigEndian))
            case (0x0028, 0x0004):
                photometric = readASCII(data, range: valueRange).trimmingCharacters(in: .whitespacesAndNewlines).trimmingNullBytes()
            case (0x0028, 0x0010):
                rows = Int(u16(data, at: valueRange.lowerBound, bigEndian: isBigEndian))
            case (0x0028, 0x0011):
                cols = Int(u16(data, at: valueRange.lowerBound, bigEndian: isBigEndian))
            case (0x0028, 0x0100):
                bitsAllocated = Int(u16(data, at: valueRange.lowerBound, bigEndian: isBigEndian))
            case (0x0028, 0x0101):
                bitsStored = Int(u16(data, at: valueRange.lowerBound, bigEndian: isBigEndian))
            case (0x0028, 0x0103):
                pixelRepresentation = Int(u16(data, at: valueRange.lowerBound, bigEndian: isBigEndian))
            case (0x0028, 0x1052):
                rescaleIntercept = Double(readASCII(data, range: valueRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines).trimmingNullBytes()) ?? 0.0
            case (0x0028, 0x1053):
                rescaleSlope = Double(readASCII(data, range: valueRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines).trimmingNullBytes()) ?? 1.0
            case (0x7FE0, 0x0010):
                pixelDataRange = valueRange
                cursor = nextCursor
                // Continue scanning so we don't break early on encapsulated data;
                // for plain LE/BE the pixel data is just the rest.
                continue
            default:
                break
            }
            cursor = nextCursor
        }

        guard let w = cols, let h = rows,
              let ba = bitsAllocated,
              let pdr = pixelDataRange else {
            throw DICOMError.missingTag("Rows/Columns/BitsAllocated/PixelData")
        }
        guard samplesPerPixel == 1 else {
            throw DICOMError.unsupportedTransferSyntax("samplesPerPixel=\(samplesPerPixel) (this reader is monochrome-only)")
        }
        let stored = bitsStored ?? ba
        let isMonochrome1 = (photometric == "MONOCHROME1")
        let isSigned = (pixelRepresentation == 1)

        // Bit depth selects pixel type. 8-bit fits in uint8; 9-16 in uint16.
        let pixelType: PixelType = (ba <= 8) ? .uint8 : .uint16
        let bytesPerSample = pixelType.bytesPerSample
        let expected = w * h * bytesPerSample
        let pixelBytes = data.subdata(in: pdr)
        guard pixelBytes.count >= expected else {
            throw DICOMError.malformedPixelData
        }

        var frame = ImageFrame(
            width: w, height: h, channels: 1,
            pixelType: pixelType, colorSpace: .grayscale
        )

        if pixelType == .uint8 {
            var bytes = [UInt8](pixelBytes.prefix(expected))
            if isMonochrome1 {
                for i in 0..<bytes.count { bytes[i] = 255 - bytes[i] }
            }
            frame.data = bytes
        } else {
            // 16-bit little-endian samples (the common case). For BE
            // transfer syntaxes the bytes are big-endian.
            var samples = [UInt16](repeating: 0, count: w * h)
            pixelBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for i in 0..<samples.count {
                    let lo = UInt16(base[i * 2])
                    let hi = UInt16(base[i * 2 + 1])
                    let v: UInt16 = isBigEndian ? (lo << 8) | hi : (hi << 8) | lo
                    samples[i] = v
                }
            }
            // Mask off bits beyond `bitsStored` (DICOM allows the high bits
            // to be unused/junk in the allocated 16-bit container).
            if stored < 16 {
                let mask: UInt16 = (1 << UInt16(stored)) - 1
                for i in 0..<samples.count { samples[i] &= mask }
            }
            // Signed pixel handling (PixelRepresentation = 1). DICOM stores
            // signed values as two's-complement of `bitsStored` bits, sign-
            // extended to BitsAllocated. We bias by 2^(stored-1) so the
            // resulting buffer is always unsigned in [0, 2^stored). The
            // bias is recorded in DICOMMetadata.signedBias so downstream
            // tools can recover the original signed value.
            if isSigned {
                // Sign-extend `stored` bits, then add bias.
                let signBit: UInt16 = 1 << UInt16(stored - 1)
                let bias = signBit
                let mask: UInt16 = (stored < 16) ? ((1 << UInt16(stored)) - 1) : .max
                for i in 0..<samples.count {
                    let s = samples[i] & mask
                    let signed: Int32 = (s & signBit) != 0
                        ? Int32(s) - Int32(1 << stored)
                        : Int32(s)
                    let biased = signed + Int32(bias)
                    samples[i] = UInt16(clamping: biased)
                }
            }
            if isMonochrome1 {
                let maxValue: UInt16 = (stored < 16) ? ((1 << UInt16(stored)) - 1) : .max
                for i in 0..<samples.count { samples[i] = maxValue - samples[i] }
            }
            // Pack as little-endian raw bytes for ImageFrame.data.
            var bytes = [UInt8](repeating: 0, count: w * h * 2)
            for i in 0..<samples.count {
                bytes[i * 2]     = UInt8(samples[i] & 0xFF)
                bytes[i * 2 + 1] = UInt8((samples[i] >> 8) & 0xFF)
            }
            frame.data = bytes
        }

        let metadata = DICOMMetadata(
            modality: modality,
            photometricInterpretation: photometric,
            bitsStored: stored,
            pixelRepresentation: pixelRepresentation,
            rescaleSlope: rescaleSlope,
            rescaleIntercept: rescaleIntercept,
            seriesInstanceUID: seriesUID,
            studyInstanceUID: studyUID,
            sliceLocation: sliceLocation,
            instanceNumber: instanceNumber
        )
        return (frame, metadata)
    }

    // MARK: - Explicit VR LE/BE

    /// Returns (group, element, vr, valueRange, nextCursor).
    private static func readExplicitElement(
        _ data: Data, at start: Int, bigEndian: Bool = false
    ) throws -> (group: UInt16, element: UInt16, vr: String, valueRange: Range<Int>, next: Int) {
        guard start + 8 <= data.count else { throw DICOMError.invalidFile("truncated explicit-VR header") }
        let group = u16(data, at: start, bigEndian: bigEndian)
        let element = u16(data, at: start + 2, bigEndian: bigEndian)
        let vr = readASCII(data, range: (start + 4)..<(start + 6))

        // OB / OD / OF / OL / OW / OV / SQ / UC / UN / UR / UT use 4-byte length
        // preceded by a 2-byte reserved field. Others use a 2-byte length.
        let longVR: Set<String> = ["OB","OD","OF","OL","OW","OV","SQ","UC","UN","UR","UT"]
        let length: Int
        let valueStart: Int
        if longVR.contains(vr) {
            guard start + 12 <= data.count else { throw DICOMError.invalidFile("truncated long-VR header") }
            length = Int(u32(data, at: start + 8, bigEndian: bigEndian))
            valueStart = start + 12
        } else {
            length = Int(u16(data, at: start + 6, bigEndian: bigEndian))
            valueStart = start + 8
        }

        // Undefined length (0xFFFFFFFF) means item-delimited (sequences,
        // encapsulated pixel data). For pixel data this signals an
        // encapsulated transfer syntax, which we don't support; for SQ
        // we'd have to walk items. Throw rather than mis-read.
        if length == 0xFFFFFFFF {
            // Encapsulated pixel data shows up as (7FE0,0010) OB len=undefined.
            // Treat any undefined-length tag as unsupported here.
            throw DICOMError.unsupportedTransferSyntax("undefined-length element \(String(format: "(%04X,%04X)", group, element)) (encapsulated/sequence data not supported)")
        }
        let valueEnd = valueStart + length
        guard valueEnd <= data.count else { throw DICOMError.invalidFile("element value extends past end of file") }
        return (group, element, vr, valueStart..<valueEnd, valueEnd)
    }

    // MARK: - Implicit VR LE

    private static func readImplicitElement(
        _ data: Data, at start: Int
    ) throws -> (group: UInt16, element: UInt16, valueRange: Range<Int>, next: Int) {
        guard start + 8 <= data.count else { throw DICOMError.invalidFile("truncated implicit-VR header") }
        let group   = u16(data, at: start, bigEndian: false)
        let element = u16(data, at: start + 2, bigEndian: false)
        let length  = Int(u32(data, at: start + 4, bigEndian: false))
        if length == 0xFFFFFFFF {
            throw DICOMError.unsupportedTransferSyntax("undefined-length implicit-VR element \(String(format: "(%04X,%04X)", group, element))")
        }
        let valueStart = start + 8
        let valueEnd = valueStart + length
        guard valueEnd <= data.count else { throw DICOMError.invalidFile("implicit-VR element extends past end of file") }
        return (group, element, valueStart..<valueEnd, valueEnd)
    }

    // MARK: - Byte-level helpers

    @inline(__always)
    private static func u16(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt16 {
        let lo = UInt16(data[offset])
        let hi = UInt16(data[offset + 1])
        return bigEndian ? (lo << 8) | hi : (hi << 8) | lo
    }

    @inline(__always)
    private static func u32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return bigEndian
            ? (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            : (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }

    @inline(__always)
    private static func uleU32(_ data: Data, at offset: Int) -> UInt32 {
        u32(data, at: offset, bigEndian: false)
    }

    private static func readASCII(_ data: Data, range: Range<Int>) -> String {
        String(data: data.subdata(in: range), encoding: .ascii) ?? ""
    }
}

private extension String {
    func trimmingNullBytes() -> String {
        var s = self
        while s.last == "\0" { s.removeLast() }
        return s
    }
}
