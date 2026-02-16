/// JPEG XL Container Format — ISO/IEC 18181-2
///
/// Implements the ISOBMFF-based container format for `.jxl` files.
/// The container wraps a JPEG XL codestream and optional metadata boxes
/// (EXIF, XMP, ICC profiles, thumbnails, animation).

import Foundation

// MARK: - Box Type

/// ISOBMFF box type identifiers per ISO/IEC 18181-2 §3
///
/// Each box type is identified by a 4-byte ASCII tag.
public enum BoxType: String, Sendable, Equatable, CaseIterable {
    /// JPEG XL container signature box
    case jxlSignature = "JXL "

    /// File type box
    case fileType = "ftyp"

    /// JPEG XL level box
    case jxlLevel = "jxll"

    /// JPEG XL codestream box (partial, can appear multiple times)
    case jxlCodestream = "jxlc"

    /// JPEG XL partial codestream box (for large files)
    case jxlPartialCodestream = "jxlp"

    /// EXIF metadata box
    case exif = "Exif"

    /// XMP metadata box
    case xml = "xml "

    /// JUMBF (JPEG Universal Metadata Box Format)
    case jumb = "jumb"

    /// ICC colour profile box
    case colourProfile = "colr"

    /// Frame index box (for seeking in animations)
    case frameIndex = "jxli"

    /// Brotli-compressed data box
    case brotliCompressed = "brob"

    /// Unknown box type
    case unknown = "????"

    /// The 4-byte ASCII representation of this box type.
    public var bytes: [UInt8] {
        Array(rawValue.utf8)
    }
}

// MARK: - Box

/// An ISOBMFF box per ISO/IEC 18181-2 §3
///
/// Boxes are the fundamental units of the container format.
/// Each box has a type tag and a payload.
public struct Box: Sendable, Equatable {
    /// Box type
    public let type: BoxType

    /// Box payload data
    public let payload: Data

    /// Creates a box with the given type and payload.
    public init(type: BoxType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    /// Serialise the box to bytes.
    ///
    /// Standard ISOBMFF encoding:
    /// - 4-byte big-endian size (total box size including header)
    /// - 4-byte ASCII type tag
    /// - Payload bytes
    ///
    /// If total size exceeds `UInt32.max`, an extended size (8-byte) header is used.
    public func serialise() -> Data {
        let headerSize = 8
        let totalSize = headerSize + payload.count

        var result = Data(capacity: totalSize)

        if totalSize <= Int(UInt32.max) {
            // Standard 4-byte size
            let size32 = UInt32(totalSize)
            result.append(UInt8((size32 >> 24) & 0xFF))
            result.append(UInt8((size32 >> 16) & 0xFF))
            result.append(UInt8((size32 >> 8) & 0xFF))
            result.append(UInt8(size32 & 0xFF))
        } else {
            // Extended size: size field = 1, followed by 8-byte size
            result.append(contentsOf: [0, 0, 0, 1] as [UInt8])
        }

        // Box type (4 bytes ASCII)
        result.append(contentsOf: type.bytes)

        if totalSize > Int(UInt32.max) {
            // Extended 8-byte size (total including this field)
            let extendedTotal = UInt64(totalSize + 8)
            for shift in stride(from: 56, through: 0, by: -8) {
                result.append(UInt8((extendedTotal >> shift) & 0xFF))
            }
        }

        // Payload
        result.append(payload)

        return result
    }
}

// MARK: - EXIF Metadata

/// EXIF metadata for embedding in a JPEG XL container.
///
/// EXIF data is stored as raw bytes (typically a TIFF-structured blob)
/// preceded by a 4-byte big-endian offset value (usually 0).
public struct EXIFMetadata: Sendable, Equatable {
    /// Raw EXIF data (TIFF header + IFDs)
    public let data: Data

    /// Creates EXIF metadata from raw bytes.
    public init(data: Data) {
        self.data = data
    }

    /// Creates the EXIF box payload (4-byte offset + raw data).
    public func boxPayload() -> Data {
        var payload = Data(capacity: 4 + data.count)
        // 4-byte big-endian offset (0 = data starts immediately)
        payload.append(contentsOf: [0, 0, 0, 0] as [UInt8])
        payload.append(data)
        return payload
    }
}

// MARK: - XMP Metadata

/// XMP metadata for embedding in a JPEG XL container.
///
/// XMP is stored as a UTF-8 XML document.
public struct XMPMetadata: Sendable, Equatable {
    /// Raw XMP XML data
    public let data: Data

    /// Creates XMP metadata from a UTF-8 XML string.
    public init(xmlString: String) {
        self.data = Data(xmlString.utf8)
    }

    /// Creates XMP metadata from raw bytes.
    public init(data: Data) {
        self.data = data
    }
}

// MARK: - ICC Profile

/// ICC colour profile for embedding in a JPEG XL container.
///
/// The ICC profile is stored as raw bytes per ICC specification.
public struct ICCProfile: Sendable, Equatable {
    /// Raw ICC profile data
    public let data: Data

    /// Creates an ICC profile from raw bytes.
    public init(data: Data) {
        self.data = data
    }

    /// Creates the colour profile box payload.
    ///
    /// Per ISO/IEC 18181-2 §3.5, the colr box contains:
    /// - 4-byte colour type (`prof` for ICC)
    /// - ICC profile bytes
    public func boxPayload() -> Data {
        var payload = Data(capacity: 4 + data.count)
        // Colour type: "prof" (ICC profile)
        payload.append(contentsOf: Array("prof".utf8))
        payload.append(data)
        return payload
    }
}

// MARK: - Thumbnail

/// Thumbnail image for embedding in a JPEG XL container.
///
/// A small preview image encoded as a JPEG XL codestream.
public struct Thumbnail: Sendable, Equatable {
    /// Encoded thumbnail codestream
    public let codestreamData: Data

    /// Thumbnail width
    public let width: UInt32

    /// Thumbnail height
    public let height: UInt32

    /// Creates a thumbnail from pre-encoded codestream data.
    public init(codestreamData: Data, width: UInt32, height: UInt32) {
        self.codestreamData = codestreamData
        self.width = width
        self.height = height
    }
}

// MARK: - Frame Index Entry

/// A single entry in the frame index for seekable animations.
public struct FrameIndexEntry: Sendable, Equatable {
    /// Frame number (0-based)
    public let frameNumber: UInt32

    /// Byte offset of the frame within the codestream
    public let byteOffset: UInt64

    /// Duration of this frame in ticks
    public let duration: UInt32

    /// Creates a frame index entry.
    public init(frameNumber: UInt32, byteOffset: UInt64, duration: UInt32) {
        self.frameNumber = frameNumber
        self.byteOffset = byteOffset
        self.duration = duration
    }
}

// MARK: - Frame Index

/// Frame index for seekable animations — ISO/IEC 18181-2 §3.6
///
/// Provides random-access seeking within multi-frame codestreams.
public struct FrameIndex: Sendable, Equatable {
    /// Frame index entries
    public let entries: [FrameIndexEntry]

    /// Creates a frame index from entries.
    public init(entries: [FrameIndexEntry]) {
        self.entries = entries
    }

    /// Serialise the frame index into a box payload.
    public func boxPayload() -> Data {
        var payload = Data()

        // Number of entries
        let count = UInt32(entries.count)
        payload.append(UInt8((count >> 24) & 0xFF))
        payload.append(UInt8((count >> 16) & 0xFF))
        payload.append(UInt8((count >> 8) & 0xFF))
        payload.append(UInt8(count & 0xFF))

        for entry in entries {
            // Frame number (4 bytes BE)
            payload.append(UInt8((entry.frameNumber >> 24) & 0xFF))
            payload.append(UInt8((entry.frameNumber >> 16) & 0xFF))
            payload.append(UInt8((entry.frameNumber >> 8) & 0xFF))
            payload.append(UInt8(entry.frameNumber & 0xFF))

            // Byte offset (8 bytes BE)
            for shift in stride(from: 56, through: 0, by: -8) {
                payload.append(UInt8((entry.byteOffset >> shift) & 0xFF))
            }

            // Duration (4 bytes BE)
            payload.append(UInt8((entry.duration >> 24) & 0xFF))
            payload.append(UInt8((entry.duration >> 16) & 0xFF))
            payload.append(UInt8((entry.duration >> 8) & 0xFF))
            payload.append(UInt8(entry.duration & 0xFF))
        }

        return payload
    }
}

// MARK: - JXL Container

/// JPEG XL container (.jxl file) — ISO/IEC 18181-2
///
/// The container wraps a JPEG XL codestream with optional metadata boxes.
///
/// ## Container Structure
/// ```
/// ┌──────────────────────────┐
/// │ JXL Signature Box        │
/// ├──────────────────────────┤
/// │ File Type Box (ftyp)     │
/// ├──────────────────────────┤
/// │ [Optional] Level Box     │
/// ├──────────────────────────┤
/// │ [Optional] ICC Box       │
/// ├──────────────────────────┤
/// │ [Optional] EXIF Box      │
/// ├──────────────────────────┤
/// │ [Optional] XMP Box       │
/// ├──────────────────────────┤
/// │ [Optional] Frame Index   │
/// ├──────────────────────────┤
/// │ Codestream Box (jxlc)    │
/// └──────────────────────────┘
/// ```
public struct JXLContainer: Sendable {
    /// The JPEG XL codestream data
    public var codestream: Data

    /// Optional EXIF metadata
    public var exif: EXIFMetadata?

    /// Optional XMP metadata
    public var xmp: XMPMetadata?

    /// Optional ICC colour profile
    public var iccProfile: ICCProfile?

    /// Optional thumbnail
    public var thumbnail: Thumbnail?

    /// Frame index for animations
    public var frameIndex: FrameIndex?

    /// JPEG XL level (5 = baseline, 10 = extended)
    public var level: UInt32

    /// Creates a container with a codestream.
    /// - Parameter codestream: The JPEG XL codestream data.
    public init(codestream: Data) {
        self.codestream = codestream
        self.level = 5
    }

    /// Creates a container from an encoded image result.
    /// - Parameter encodedImage: The encoded image from `JXLEncoder`.
    public init(encodedImage: EncodedImage) {
        self.codestream = encodedImage.data
        self.level = 5
    }

    /// Whether this container has any metadata beyond the codestream.
    public var hasMetadata: Bool {
        exif != nil || xmp != nil || iccProfile != nil ||
        thumbnail != nil || frameIndex != nil
    }

    /// Serialise the full `.jxl` container file.
    /// - Returns: The complete container file data.
    public func serialise() -> Data {
        var boxes: [Box] = []

        // 1. JXL Signature Box
        boxes.append(Box(
            type: .jxlSignature,
            payload: Data(JXLContainer.signaturePayload)
        ))

        // 2. File Type Box (ftyp)
        boxes.append(Box(
            type: .fileType,
            payload: JXLContainer.fileTypePayload(level: level)
        ))

        // 3. JXL Level Box (if not baseline level 5)
        if level != 5 {
            boxes.append(Box(
                type: .jxlLevel,
                payload: Data([UInt8(level)])
            ))
        }

        // 4. ICC Colour Profile Box
        if let icc = iccProfile {
            boxes.append(Box(
                type: .colourProfile,
                payload: icc.boxPayload()
            ))
        }

        // 5. EXIF Metadata Box
        if let exifData = exif {
            boxes.append(Box(
                type: .exif,
                payload: exifData.boxPayload()
            ))
        }

        // 6. XMP Metadata Box
        if let xmpData = xmp {
            boxes.append(Box(
                type: .xml,
                payload: xmpData.data
            ))
        }

        // 7. Frame Index Box (for animations)
        if let index = frameIndex {
            boxes.append(Box(
                type: .frameIndex,
                payload: index.boxPayload()
            ))
        }

        // 8. Codestream Box
        boxes.append(Box(
            type: .jxlCodestream,
            payload: codestream
        ))

        // Concatenate all boxes
        var result = Data()
        for box in boxes {
            result.append(box.serialise())
        }
        return result
    }

    // MARK: - Constants

    /// JXL container signature payload (per ISO/IEC 18181-2 §2):
    /// `0x0000000C 4A584C20 0D0A870A`
    static let signaturePayload: [UInt8] = [
        0x0D, 0x0A, 0x87, 0x0A
    ]

    /// Build the file type box payload.
    ///
    /// ftyp box:
    /// - Major brand: "jxl " (4 bytes)
    /// - Minor version: 0 (4 bytes)
    /// - Compatible brands: "jxl " (4 bytes)
    static func fileTypePayload(level: UInt32) -> Data {
        var payload = Data(capacity: 12)
        // Major brand: "jxl "
        payload.append(contentsOf: Array("jxl ".utf8))
        // Minor version: 0
        payload.append(contentsOf: [0, 0, 0, 0] as [UInt8])
        // Compatible brands: "jxl "
        payload.append(contentsOf: Array("jxl ".utf8))
        return payload
    }

    /// MIME type for JPEG XL files
    public static let mimeType = "image/jxl"

    /// File extension for JPEG XL container files
    public static let fileExtension = "jxl"
}

// MARK: - Container Builder

/// Fluent builder for constructing JXL containers with metadata.
///
/// ## Example
/// ```swift
/// let container = JXLContainerBuilder(codestream: encodedData)
///     .withEXIF(exifData)
///     .withXMP(xmpString: "<x:xmpmeta .../>")
///     .withICCProfile(profileData)
///     .build()
/// let fileData = container.serialise()
/// ```
public struct JXLContainerBuilder: Sendable {
    private var container: JXLContainer

    /// Creates a builder with the given codestream data.
    public init(codestream: Data) {
        self.container = JXLContainer(codestream: codestream)
    }

    /// Creates a builder from an encoded image.
    public init(encodedImage: EncodedImage) {
        self.container = JXLContainer(encodedImage: encodedImage)
    }

    /// Add EXIF metadata.
    public func withEXIF(_ data: Data) -> JXLContainerBuilder {
        var copy = self
        copy.container.exif = EXIFMetadata(data: data)
        return copy
    }

    /// Add XMP metadata from an XML string.
    public func withXMP(xmlString: String) -> JXLContainerBuilder {
        var copy = self
        copy.container.xmp = XMPMetadata(xmlString: xmlString)
        return copy
    }

    /// Add XMP metadata from raw data.
    public func withXMP(data: Data) -> JXLContainerBuilder {
        var copy = self
        copy.container.xmp = XMPMetadata(data: data)
        return copy
    }

    /// Add an ICC colour profile.
    public func withICCProfile(_ data: Data) -> JXLContainerBuilder {
        var copy = self
        copy.container.iccProfile = ICCProfile(data: data)
        return copy
    }

    /// Add a thumbnail.
    public func withThumbnail(codestreamData: Data, width: UInt32, height: UInt32) -> JXLContainerBuilder {
        var copy = self
        copy.container.thumbnail = Thumbnail(
            codestreamData: codestreamData,
            width: width,
            height: height
        )
        return copy
    }

    /// Add a frame index for seekable animations.
    public func withFrameIndex(_ entries: [FrameIndexEntry]) -> JXLContainerBuilder {
        var copy = self
        copy.container.frameIndex = FrameIndex(entries: entries)
        return copy
    }

    /// Set the JPEG XL level.
    public func withLevel(_ level: UInt32) -> JXLContainerBuilder {
        var copy = self
        copy.container.level = level
        return copy
    }

    /// Build the final container.
    public func build() -> JXLContainer {
        container
    }
}
