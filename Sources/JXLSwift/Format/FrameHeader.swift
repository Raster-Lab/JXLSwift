/// JPEG XL Frame Header — ISO/IEC 18181-1 §10
///
/// Implements the frame header serialisation for individual frames
/// within a JPEG XL codestream.

import Foundation

// MARK: - Frame Type

/// Frame type per ISO/IEC 18181-1 §10.1
public enum FrameType: UInt32, Sendable, Equatable {
    /// Regular frame (most common)
    case regularFrame = 0
    /// LF frame (low-frequency layer for progressive)
    case lfFrame = 1
    /// Reference-only frame (not displayed)
    case referenceOnly = 2
    /// Skip-progressive frame
    case skipProgressive = 3
}

// MARK: - Blend Mode

/// Blend mode for combining frames — ISO/IEC 18181-1 §10.2
public enum BlendMode: UInt32, Sendable, Equatable {
    /// Replace (overwrite) — default
    case replace = 0
    /// Alpha-blend
    case blend = 1
    /// Additive
    case add = 2
    /// Multiplicative
    case multiply = 3
}

// MARK: - Frame Header

/// Frame header per ISO/IEC 18181-1 §10
///
/// Contains per-frame encoding parameters such as type, blend mode,
/// duration (for animation), and section/group layout information.
public struct FrameHeader: Sendable, Equatable {
    /// Frame type
    public var frameType: FrameType

    /// Encoding mode for this frame
    public var encoding: FrameEncoding

    /// Blend mode
    public var blendMode: BlendMode

    /// Frame duration in ticks (0 for still images)
    public var duration: UInt32

    /// Whether the frame is the last frame in the codestream
    public var isLast: Bool

    /// Whether the frame can be saved as a reference
    public var saveAsReference: UInt32

    /// Frame name (optional, empty if not set)
    public var name: String

    /// Horizontal offset for cropped frames (0 = no crop)
    public var cropX0: Int32

    /// Vertical offset for cropped frames (0 = no crop)
    public var cropY0: Int32

    /// Frame width (0 = use image width)
    public var frameWidth: UInt32

    /// Frame height (0 = use image height)
    public var frameHeight: UInt32

    /// Number of groups in this frame
    public var numGroups: UInt32

    /// Number of passes (for progressive rendering)
    public var numPasses: UInt32

    /// Creates a frame header with default values suitable for a single still image.
    public init(
        frameType: FrameType = .regularFrame,
        encoding: FrameEncoding = .varDCT,
        blendMode: BlendMode = .replace,
        duration: UInt32 = 0,
        isLast: Bool = true,
        saveAsReference: UInt32 = 0,
        name: String = "",
        cropX0: Int32 = 0,
        cropY0: Int32 = 0,
        frameWidth: UInt32 = 0,
        frameHeight: UInt32 = 0,
        numGroups: UInt32 = 1,
        numPasses: UInt32 = 1
    ) {
        self.frameType = frameType
        self.encoding = encoding
        self.blendMode = blendMode
        self.duration = duration
        self.isLast = isLast
        self.saveAsReference = saveAsReference
        self.name = name
        self.cropX0 = cropX0
        self.cropY0 = cropY0
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.numGroups = numGroups
        self.numPasses = numPasses
    }

    /// Creates a frame header appropriate for a single lossless still image.
    public static func lossless(isLast: Bool = true) -> FrameHeader {
        FrameHeader(
            frameType: .regularFrame,
            encoding: .modular,
            blendMode: .replace,
            duration: 0,
            isLast: isLast
        )
    }

    /// Creates a frame header appropriate for a single lossy still image.
    public static func lossy(isLast: Bool = true) -> FrameHeader {
        FrameHeader(
            frameType: .regularFrame,
            encoding: .varDCT,
            blendMode: .replace,
            duration: 0,
            isLast: isLast
        )
    }

    /// Creates a frame header suitable for an animation frame.
    /// - Parameters:
    ///   - duration: Duration of this frame in ticks.
    ///   - isLast: Whether this is the last frame.
    public static func animation(duration: UInt32, isLast: Bool = false) -> FrameHeader {
        FrameHeader(
            frameType: .regularFrame,
            encoding: .varDCT,
            blendMode: .blend,
            duration: duration,
            isLast: isLast
        )
    }

    /// Serialise the frame header into the given bitstream writer.
    func serialise(to writer: inout BitstreamWriter) {
        // all_default flag: true for the simplest case
        let allDefault = isAllDefault
        writer.writeBit(allDefault)
        if allDefault { return }

        // Frame type (2 bits)
        writer.writeBits(frameType.rawValue, count: 2)

        // Encoding (1 bit: 0 = VarDCT, 1 = Modular)
        writer.writeBits(encoding.rawValue, count: 1)

        // Flags (2 bits reserved, §10.1.1)
        writer.writeBits(0, count: 2)

        // Blend mode
        let hasBlendInfo = (blendMode != .replace)
        writer.writeBit(hasBlendInfo)
        if hasBlendInfo {
            writer.writeBits(blendMode.rawValue, count: 2)
        }

        // Duration (for animation frames)
        let hasDuration = (duration > 0)
        writer.writeBit(hasDuration)
        if hasDuration {
            writer.writeBits(duration, count: 32)
        }

        // Is last frame
        writer.writeBit(isLast)

        // Save as reference
        let hasSaveRef = (saveAsReference > 0)
        writer.writeBit(hasSaveRef)
        if hasSaveRef {
            writer.writeBits(saveAsReference, count: 2)
        }

        // Frame name
        let hasName = !name.isEmpty
        writer.writeBit(hasName)
        if hasName {
            // Write name length + bytes
            let nameData = Data(name.utf8)
            writer.writeBits(UInt32(nameData.count), count: 16)
            writer.flushByte()
            writer.writeData(nameData)
        }

        // Crop region
        let hasCrop = (cropX0 != 0 || cropY0 != 0 ||
                       frameWidth != 0 || frameHeight != 0)
        writer.writeBit(hasCrop)
        if hasCrop {
            writer.writeBits(UInt32(bitPattern: cropX0), count: 32)
            writer.writeBits(UInt32(bitPattern: cropY0), count: 32)
            writer.writeBits(frameWidth, count: 32)
            writer.writeBits(frameHeight, count: 32)
        }

        // Passes
        let hasMultiplePasses = (numPasses > 1)
        writer.writeBit(hasMultiplePasses)
        if hasMultiplePasses {
            writer.writeBits(numPasses, count: 8)
        }

        // Groups
        writer.writeBits(numGroups, count: 16)

        writer.flushByte()
    }

    /// Whether this frame header can use the all-default shortcut.
    private var isAllDefault: Bool {
        frameType == .regularFrame &&
        encoding == .varDCT &&
        blendMode == .replace &&
        duration == 0 &&
        isLast &&
        saveAsReference == 0 &&
        name.isEmpty &&
        cropX0 == 0 && cropY0 == 0 &&
        frameWidth == 0 && frameHeight == 0 &&
        numPasses == 1 &&
        numGroups == 1
    }
}

// MARK: - Frame Encoding

/// Frame encoding mode per ISO/IEC 18181-1 §10
public enum FrameEncoding: UInt32, Sendable, Equatable {
    /// VarDCT (lossy transform coding)
    case varDCT = 0
    /// Modular (lossless/near-lossless)
    case modular = 1
}

// MARK: - Section Header

/// Section header for byte-aligned framing — ISO/IEC 18181-1 §10.3
///
/// Each frame is divided into one or more sections (groups/passes).
/// Each section is preceded by a length field for random-access seeking.
public struct SectionHeader: Sendable, Equatable {
    /// Section payload length in bytes
    public let length: UInt32

    /// Creates a section header.
    /// - Parameter length: Payload length in bytes.
    public init(length: UInt32) {
        self.length = length
    }

    /// Serialise the section header into the given bitstream writer.
    func serialise(to writer: inout BitstreamWriter) {
        writer.flushByte()
        // 32-bit little-endian section length
        writer.writeByte(UInt8(length & 0xFF))
        writer.writeByte(UInt8((length >> 8) & 0xFF))
        writer.writeByte(UInt8((length >> 16) & 0xFF))
        writer.writeByte(UInt8((length >> 24) & 0xFF))
    }
}

// MARK: - Group Header

/// Group header — organises data within a frame section.
///
/// Groups allow parallel encoding/decoding of independent image regions.
public struct GroupHeader: Sendable, Equatable {
    /// Group index within the frame
    public let groupIndex: UInt32

    /// Whether this group contains a global section
    public let isGlobal: Bool

    /// Creates a group header.
    public init(groupIndex: UInt32, isGlobal: Bool = false) {
        self.groupIndex = groupIndex
        self.isGlobal = isGlobal
    }

    /// Serialise the group header into the given bitstream writer.
    func serialise(to writer: inout BitstreamWriter) {
        writer.writeBit(isGlobal)
        writer.writeBits(groupIndex, count: 16)
        writer.flushByte()
    }
}

// MARK: - Frame Data

/// A complete encoded frame consisting of header + section data.
///
/// This struct encapsulates a frame header together with its byte-aligned
/// section payloads, ready to be written into a codestream or container.
public struct FrameData: Sendable {
    /// Frame header
    public let header: FrameHeader

    /// Section payloads (each section is individually byte-aligned)
    public let sections: [Data]

    /// Creates frame data.
    public init(header: FrameHeader, sections: [Data]) {
        self.header = header
        self.sections = sections
    }

    /// Serialise the entire frame (header + sections with section headers).
    /// - Returns: The serialised frame bytes.
    public func serialise() -> Data {
        var writer = BitstreamWriter()

        // Frame header
        header.serialise(to: &writer)

        // Table of contents: section lengths
        for section in sections {
            let sectionHeader = SectionHeader(length: UInt32(section.count))
            sectionHeader.serialise(to: &writer)
        }

        // Section payloads
        for section in sections {
            writer.flushByte()
            writer.writeData(section)
        }

        writer.flushByte()
        return writer.data
    }
}
