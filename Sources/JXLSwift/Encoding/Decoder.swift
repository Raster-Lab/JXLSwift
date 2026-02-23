/// JPEG XL Decoder - Main decoding interface
///
/// Provides the primary API for decompressing JPEG XL images.
/// Supports both bare codestream and container format inputs.

import Foundation

// MARK: - Decoder Errors

/// Errors that can occur during JPEG XL decoding.
public enum DecoderError: Error, LocalizedError, Equatable {
    /// The data does not start with the JPEG XL codestream signature (0xFF 0x0A).
    case invalidSignature
    /// The data is too short to contain a valid codestream.
    case truncatedData
    /// The image header could not be parsed.
    case invalidImageHeader(String)
    /// The frame header could not be parsed.
    case invalidFrameHeader(String)
    /// The frame encoding mode is not supported by this decoder.
    case unsupportedEncoding(String)
    /// The decoded image dimensions are invalid.
    case invalidDimensions(width: UInt32, height: UInt32)
    /// The frame data could not be decoded.
    case decodingFailed(String)
    /// The container format is invalid.
    case invalidContainer(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSignature:
            return "Invalid JPEG XL codestream signature"
        case .truncatedData:
            return "Data is too short for a valid JPEG XL codestream"
        case .invalidImageHeader(let reason):
            return "Invalid image header: \(reason)"
        case .invalidFrameHeader(let reason):
            return "Invalid frame header: \(reason)"
        case .unsupportedEncoding(let mode):
            return "Unsupported encoding mode: \(mode)"
        case .invalidDimensions(let w, let h):
            return "Invalid image dimensions: \(w)×\(h)"
        case .decodingFailed(let reason):
            return "Decoding failed: \(reason)"
        case .invalidContainer(let reason):
            return "Invalid container format: \(reason)"
        }
    }
}

// MARK: - Decoded Image Header

/// Parsed image header from a JPEG XL codestream.
///
/// Contains all the metadata needed to decode the image payload:
/// dimensions, bit depth, channel count, color space, and alpha flag.
public struct DecodedImageHeader: Sendable, Equatable {
    /// Image width in pixels
    public let width: UInt32
    /// Image height in pixels
    public let height: UInt32
    /// Bits per sample (e.g. 8, 16)
    public let bitsPerSample: UInt8
    /// Number of colour channels (e.g. 1, 3, 4)
    public let channels: UInt8
    /// Colour space indicator (0 = sRGB)
    public let colorSpaceIndicator: UInt8
    /// Whether the image has an alpha channel
    public let hasAlpha: Bool

    /// Total number of bytes consumed by the signature + image header
    /// in the codestream, so the caller knows where the payload starts.
    public let headerSize: Int
}

// MARK: - Decoded Frame Header

/// Parsed frame header from a JPEG XL codestream.
public struct DecodedFrameHeader: Sendable, Equatable {
    /// Frame type
    public let frameType: FrameType
    /// Encoding mode
    public let encoding: FrameEncoding
    /// Blend mode
    public let blendMode: BlendMode
    /// Duration in ticks (0 for still images)
    public let duration: UInt32
    /// Whether this is the last frame
    public let isLast: Bool
    /// Reference frame slot (0 = none)
    public let saveAsReference: UInt32
    /// Frame name (empty if not set)
    public let name: String
    /// Number of groups
    public let numGroups: UInt32
    /// Number of passes
    public let numPasses: UInt32
    /// Whether the all_default shortcut was used
    public let isAllDefault: Bool
    /// Number of bytes consumed by this frame header
    public let headerSize: Int
}

// MARK: - JXLDecoder

/// Main JPEG XL Decoder.
///
/// Decodes JPEG XL codestream data back into ``ImageFrame`` instances.
/// Currently supports lossless (Modular) mode decoding.
///
/// ## Usage
/// ```swift
/// let decoder = JXLDecoder()
/// let frame = try decoder.decode(data)
/// ```
public class JXLDecoder {
    /// Hardware capabilities
    private let hardware: HardwareCapabilities

    /// Creates a decoder with the given hardware capabilities.
    /// - Parameter hardware: Hardware capabilities for acceleration. Defaults to shared instance.
    public init(hardware: HardwareCapabilities = HardwareCapabilities.shared) {
        self.hardware = hardware
    }

    // MARK: - Public API

    /// Decode a JPEG XL codestream into an ``ImageFrame``.
    ///
    /// The input must be a bare codestream (starting with 0xFF 0x0A).
    /// Container-wrapped data should be unwrapped first with
    /// ``parseContainer(_:)``.
    ///
    /// - Parameter data: The JPEG XL codestream data.
    /// - Returns: The decoded image frame.
    /// - Throws: ``DecoderError`` if the data is invalid or uses an
    ///   unsupported encoding mode.
    public func decode(_ data: Data) throws -> ImageFrame {
        // 1. Parse the image header
        let header = try parseImageHeader(data)

        // 2. Extract the payload (everything after the header)
        guard data.count > header.headerSize else {
            throw DecoderError.truncatedData
        }
        let payload = data.subdata(in: header.headerSize..<data.count)

        // 3. Check the first bit of the payload to determine encoding mode
        //    false = VarDCT, true = Modular
        guard payload.count >= 1 else {
            throw DecoderError.truncatedData
        }
        let firstBit = (payload[payload.startIndex] & 0x80) != 0

        let width = Int(header.width)
        let height = Int(header.height)
        let channels = Int(header.channels)
        let bitsPerSample = Int(header.bitsPerSample)
        let pixelType: PixelType = bitsPerSample <= 8 ? .uint8 : .uint16

        if firstBit {
            // Modular mode
            let options = EncodingOptions(
                mode: .lossless,
                effort: .squirrel,
                modularMode: true
            )
            let modularDecoder = ModularDecoder(
                hardware: hardware,
                options: options
            )

            return try modularDecoder.decode(
                data: payload,
                width: width,
                height: height,
                channels: channels,
                bitsPerSample: bitsPerSample,
                pixelType: pixelType
            )
        } else {
            // VarDCT mode
            let varDCTDecoder = VarDCTDecoder(hardware: hardware)
            return try varDCTDecoder.decode(
                data: payload,
                width: width,
                height: height,
                channels: channels,
                bitsPerSample: bitsPerSample,
                pixelType: pixelType
            )
        }
    }

    /// Decode a JPEG XL codestream progressively with a callback for each pass.
    ///
    /// This method is designed for progressive VarDCT-encoded data. The callback
    /// is invoked after each decoding pass with an intermediate ``ImageFrame``
    /// that progressively improves in quality:
    /// - Pass 0: DC coefficients only (low-resolution preview)
    /// - Pass 1: Low-frequency AC coefficients (medium quality)
    /// - Pass 2: High-frequency AC coefficients (full quality)
    ///
    /// For non-progressive or Modular-encoded data, this method falls back to
    /// regular decoding and invokes the callback once with the final frame.
    ///
    /// - Parameters:
    ///   - data: The JPEG XL codestream data (starting with 0xFF 0x0A).
    ///   - callback: Called after each pass with (frame, passIndex).
    /// - Returns: The final decoded frame (same as last callback).
    /// - Throws: ``DecoderError`` if the data is invalid.
    public func decodeProgressive(
        _ data: Data,
        callback: @escaping (ImageFrame, Int) -> Void
    ) throws -> ImageFrame {
        // 1. Parse the image header
        let header = try parseImageHeader(data)

        // 2. Extract the payload
        guard data.count > header.headerSize else {
            throw DecoderError.truncatedData
        }
        let payload = data.subdata(in: header.headerSize..<data.count)

        // 3. Check encoding mode
        guard payload.count >= 1 else {
            throw DecoderError.truncatedData
        }
        let firstBit = (payload[payload.startIndex] & 0x80) != 0

        let width = Int(header.width)
        let height = Int(header.height)
        let channels = Int(header.channels)
        let bitsPerSample = Int(header.bitsPerSample)
        let pixelType: PixelType = bitsPerSample <= 8 ? .uint8 : .uint16

        if firstBit {
            // Modular mode: no progressive support, decode once and callback
            let options = EncodingOptions(
                mode: .lossless,
                effort: .squirrel,
                modularMode: true
            )
            let modularDecoder = ModularDecoder(
                hardware: hardware,
                options: options
            )

            let frame = try modularDecoder.decode(
                data: payload,
                width: width,
                height: height,
                channels: channels,
                bitsPerSample: bitsPerSample,
                pixelType: pixelType
            )
            callback(frame, 0)
            return frame
        } else {
            // VarDCT mode: use progressive decoding
            let varDCTDecoder = VarDCTDecoder(hardware: hardware)
            return try varDCTDecoder.decodeProgressive(
                data: payload,
                width: width,
                height: height,
                channels: channels,
                bitsPerSample: bitsPerSample,
                pixelType: pixelType,
                callback: callback
            )
        }
    }

    // MARK: - Codestream Header Parsing

    /// Parse the JPEG XL codestream signature.
    ///
    /// Verifies that the data starts with the 2-byte JXL signature
    /// `0xFF 0x0A`.
    ///
    /// - Parameter data: The data to check.
    /// - Throws: ``DecoderError/invalidSignature`` if the bytes don't match,
    ///   or ``DecoderError/truncatedData`` if there are fewer than 2 bytes.
    public func parseSignature(_ data: Data) throws {
        guard data.count >= 2 else {
            throw DecoderError.truncatedData
        }
        guard data[data.startIndex] == 0xFF,
              data[data.startIndex + 1] == 0x0A else {
            throw DecoderError.invalidSignature
        }
    }

    /// Parse the image header from a JPEG XL codestream.
    ///
    /// Reads the signature followed by the simplified image header:
    /// - 4-byte big-endian width
    /// - 4-byte big-endian height
    /// - 1-byte bits per sample
    /// - 1-byte channel count
    /// - 1-byte colour space indicator
    /// - 1-bit alpha flag (then flush to byte boundary)
    ///
    /// - Parameter data: The codestream data starting from the signature.
    /// - Returns: A ``DecodedImageHeader`` with all parsed fields.
    /// - Throws: ``DecoderError`` if the data is malformed or too short.
    public func parseImageHeader(_ data: Data) throws -> DecodedImageHeader {
        // Minimum: 2 (sig) + 4 (w) + 4 (h) + 1 (bps) + 1 (ch) + 1 (cs) + 1 (alpha byte) = 14
        guard data.count >= 14 else {
            throw DecoderError.truncatedData
        }

        try parseSignature(data)

        var reader = BitstreamReader(data: data)

        // Skip signature bytes (2 bytes = 16 bits)
        for _ in 0..<16 {
            _ = reader.readBit()
        }

        // Read width (4 bytes big-endian)
        let width = try readU32(&reader)
        // Read height (4 bytes big-endian)
        let height = try readU32(&reader)

        guard width >= 1, height >= 1,
              width <= SizeHeader.maximumDimension,
              height <= SizeHeader.maximumDimension else {
            throw DecoderError.invalidDimensions(width: width, height: height)
        }
        // Prevent OOM from malformed data: cap total pixel count at 256 megapixels
        let totalPixels = UInt64(width) * UInt64(height)
        guard totalPixels <= 256 * 1024 * 1024 else {
            throw DecoderError.invalidDimensions(width: width, height: height)
        }

        // Bits per sample (1 byte)
        guard let bitsPerSample = reader.readByte() else {
            throw DecoderError.invalidImageHeader("missing bits per sample")
        }

        // Number of channels (1 byte)
        guard let channels = reader.readByte() else {
            throw DecoderError.invalidImageHeader("missing channel count")
        }

        // Color space indicator (1 byte)
        guard let colorSpace = reader.readByte() else {
            throw DecoderError.invalidImageHeader("missing color space")
        }

        // Has alpha (1 bit)
        guard let hasAlpha = reader.readBit() else {
            throw DecoderError.invalidImageHeader("missing alpha flag")
        }

        // The encoder calls flushByte() after the alpha bit, so the header
        // occupies a whole number of bytes: 2 + 4 + 4 + 1 + 1 + 1 + 1 = 14
        let headerSize = 14

        return DecodedImageHeader(
            width: width,
            height: height,
            bitsPerSample: bitsPerSample,
            channels: channels,
            colorSpaceIndicator: colorSpace,
            hasAlpha: hasAlpha,
            headerSize: headerSize
        )
    }

    // MARK: - Frame Header Parsing

    /// Parse a frame header from codestream data at the given offset.
    ///
    /// Reads the frame header fields written by
    /// ``FrameHeader/serialise(to:)``, starting with the `all_default`
    /// flag.
    ///
    /// - Parameters:
    ///   - data: The codestream data.
    ///   - offset: Byte offset where the frame header starts.
    /// - Returns: A ``DecodedFrameHeader`` with all parsed fields.
    /// - Throws: ``DecoderError`` if the data is malformed.
    public func parseFrameHeader(_ data: Data, at offset: Int = 0) throws -> DecodedFrameHeader {
        guard offset < data.count else {
            throw DecoderError.truncatedData
        }

        let subdata = data.subdata(in: offset..<data.count)
        var reader = BitstreamReader(data: subdata)

        // all_default flag
        guard let allDefault = reader.readBit() else {
            throw DecoderError.invalidFrameHeader("missing all_default flag")
        }

        if allDefault {
            // All-default frame: regular VarDCT, replace, no duration, isLast,
            // no reference, no name, no crop, 1 pass, 1 group.
            return DecodedFrameHeader(
                frameType: .regularFrame,
                encoding: .varDCT,
                blendMode: .replace,
                duration: 0,
                isLast: true,
                saveAsReference: 0,
                name: "",
                numGroups: 1,
                numPasses: 1,
                isAllDefault: true,
                headerSize: 1  // just the all_default bit (flushed to 1 byte)
            )
        }

        // Frame type (2 bits)
        guard let ftBit1 = reader.readBit(),
              let ftBit0 = reader.readBit() else {
            throw DecoderError.invalidFrameHeader("missing frame type")
        }
        let frameTypeRaw = UInt32(ftBit1 ? 1 : 0) << 1 | UInt32(ftBit0 ? 1 : 0)
        let frameType = FrameType(rawValue: frameTypeRaw) ?? .regularFrame

        // Encoding (1 bit: 0 = VarDCT, 1 = Modular)
        guard let encBit = reader.readBit() else {
            throw DecoderError.invalidFrameHeader("missing encoding bit")
        }
        let encoding: FrameEncoding = encBit ? .modular : .varDCT

        // Reserved flags (2 bits)
        _ = reader.readBit()
        _ = reader.readBit()

        // Blend mode
        guard let hasBlendInfo = reader.readBit() else {
            throw DecoderError.invalidFrameHeader("missing blend info flag")
        }
        var blendMode: BlendMode = .replace
        if hasBlendInfo {
            guard let bm1 = reader.readBit(),
                  let bm0 = reader.readBit() else {
                throw DecoderError.invalidFrameHeader("missing blend mode bits")
            }
            let blendRaw = UInt32(bm1 ? 1 : 0) << 1 | UInt32(bm0 ? 1 : 0)
            blendMode = BlendMode(rawValue: blendRaw) ?? .replace
        }

        // Duration
        guard let hasDuration = reader.readBit() else {
            throw DecoderError.invalidFrameHeader("missing duration flag")
        }
        var duration: UInt32 = 0
        if hasDuration {
            duration = try readU32FromBits(&reader)
        }

        // Is last frame
        guard let isLast = reader.readBit() else {
            throw DecoderError.invalidFrameHeader("missing isLast flag")
        }

        // Save as reference
        guard let hasSaveRef = reader.readBit() else {
            throw DecoderError.invalidFrameHeader("missing save reference flag")
        }
        var saveAsReference: UInt32 = 0
        if hasSaveRef {
            guard let ref1 = reader.readBit(),
                  let ref0 = reader.readBit() else {
                throw DecoderError.invalidFrameHeader("missing reference bits")
            }
            saveAsReference = UInt32(ref1 ? 1 : 0) << 1 | UInt32(ref0 ? 1 : 0)
        }

        // Frame name
        guard let hasName = reader.readBit() else {
            throw DecoderError.invalidFrameHeader("missing name flag")
        }
        var name = ""
        if hasName {
            let nameLen = try readBits(&reader, count: 16)
            // Flush to byte boundary before reading name bytes
            flushReaderToByte(&reader)
            var nameBytes = [UInt8]()
            for _ in 0..<nameLen {
                guard let b = reader.readByte() else {
                    throw DecoderError.invalidFrameHeader("truncated frame name")
                }
                nameBytes.append(b)
            }
            name = String(bytes: nameBytes, encoding: .utf8) ?? ""
        }

        // Crop region
        guard let hasCrop = reader.readBit() else {
            throw DecoderError.invalidFrameHeader("missing crop flag")
        }
        if hasCrop {
            // Skip crop fields: 4 × 32-bit values
            _ = try readU32FromBits(&reader)
            _ = try readU32FromBits(&reader)
            _ = try readU32FromBits(&reader)
            _ = try readU32FromBits(&reader)
        }

        // Passes
        guard let hasMultiplePasses = reader.readBit() else {
            throw DecoderError.invalidFrameHeader("missing passes flag")
        }
        var numPasses: UInt32 = 1
        if hasMultiplePasses {
            numPasses = UInt32(try readBits(&reader, count: 8))
        }

        // Groups (16 bits)
        let numGroups = UInt32(try readBits(&reader, count: 16))

        // The encoder calls flushByte() at the end — we need to account
        // for how many bytes were consumed. We don't track the reader
        // position precisely through bits, so compute the consumed byte
        // count from the remaining data length.
        // For simplicity, approximate the header size based on what was read.
        // The reader consumed subdata; we'll report the size as the
        // current byte position.
        let headerSize = readerBytePosition(&reader, dataLength: subdata.count)

        return DecodedFrameHeader(
            frameType: frameType,
            encoding: encoding,
            blendMode: blendMode,
            duration: duration,
            isLast: isLast,
            saveAsReference: saveAsReference,
            name: name,
            numGroups: numGroups,
            numPasses: numPasses,
            isAllDefault: false,
            headerSize: headerSize
        )
    }

    // MARK: - Container Parsing

    /// Extract the codestream from a JPEG XL container.
    ///
    /// If the data starts with the codestream signature (0xFF 0x0A), it is
    /// returned as-is. If it starts with an ISOBMFF container, the
    /// `jxlc` box payload is extracted and returned.
    ///
    /// - Parameter data: The raw file data.
    /// - Returns: The bare codestream data.
    /// - Throws: ``DecoderError`` if the container is malformed.
    public func extractCodestream(_ data: Data) throws -> Data {
        guard data.count >= 2 else {
            throw DecoderError.truncatedData
        }

        // Bare codestream?
        if data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0x0A {
            return data
        }

        // Try ISOBMFF container
        return try parseContainerForCodestream(data)
    }

    /// Parse a JPEG XL container and extract all metadata.
    ///
    /// Iterates over every ISOBMFF box in the container and populates
    /// the returned ``JXLContainer`` with the codestream and any
    /// EXIF, XMP, ICC, and frame-index metadata found.
    ///
    /// If the data is a bare codestream (starts with 0xFF 0x0A), a
    /// container with only the codestream is returned (no metadata).
    ///
    /// - Parameter data: The raw file data (container or bare codestream).
    /// - Returns: A ``JXLContainer`` with all extracted metadata.
    /// - Throws: ``DecoderError`` if the data is malformed.
    public func parseContainer(_ data: Data) throws -> JXLContainer {
        guard data.count >= 2 else {
            throw DecoderError.truncatedData
        }

        // Bare codestream — no metadata to extract
        if data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0x0A {
            return JXLContainer(codestream: data)
        }

        var container = JXLContainer(codestream: Data())
        var foundCodestream = false
        var offset = 0

        while offset + 8 <= data.count {
            // Box size (4 bytes big-endian)
            let size = UInt32(data[offset]) << 24
                     | UInt32(data[offset + 1]) << 16
                     | UInt32(data[offset + 2]) << 8
                     | UInt32(data[offset + 3])

            // Box type (4 bytes ASCII)
            let typeBytes = data.subdata(in: (offset + 4)..<(offset + 8))
            let typeString = String(data: typeBytes, encoding: .ascii) ?? ""

            let boxSize = Int(size)
            guard boxSize >= 8 else {
                throw DecoderError.invalidContainer("invalid box size \(boxSize)")
            }
            guard offset + boxSize <= data.count else {
                throw DecoderError.invalidContainer("box extends past end of data")
            }

            let payload = data.subdata(in: (offset + 8)..<(offset + boxSize))

            switch typeString {
            case BoxType.jxlCodestream.rawValue:
                container.codestream = payload
                foundCodestream = true

            case BoxType.exif.rawValue:
                // EXIF box: 4-byte offset prefix + raw TIFF data
                if payload.count >= 4 {
                    let exifData = payload.subdata(in: 4..<payload.count)
                    container.exif = EXIFMetadata(data: exifData)
                }

            case BoxType.xml.rawValue:
                container.xmp = XMPMetadata(data: payload)

            case BoxType.colourProfile.rawValue:
                // colr box: 4-byte colour type ("prof") + ICC data
                if payload.count >= 4 {
                    let iccData = payload.subdata(in: 4..<payload.count)
                    container.iccProfile = ICCProfile(data: iccData)
                }

            case BoxType.frameIndex.rawValue:
                container.frameIndex = parseFrameIndexPayload(payload)

            case BoxType.jxlLevel.rawValue:
                if let levelByte = payload.first {
                    container.level = UInt32(levelByte)
                }

            default:
                break // Skip signature, ftyp, and unknown boxes
            }

            offset += boxSize
        }

        if !foundCodestream {
            throw DecoderError.invalidContainer("no jxlc box found")
        }

        return container
    }

    /// Extract metadata from a JPEG XL container without decoding pixels.
    ///
    /// This is a convenience method that parses the container and returns
    /// only the metadata (EXIF, XMP, ICC profile). For bare codestreams,
    /// all metadata fields will be `nil`.
    ///
    /// - Parameter data: The raw file data.
    /// - Returns: A tuple containing optional EXIF, XMP, and ICC metadata.
    /// - Throws: ``DecoderError`` if the container is malformed.
    public func extractMetadata(_ data: Data) throws -> (
        exif: EXIFMetadata?,
        xmp: XMPMetadata?,
        iccProfile: ICCProfile?
    ) {
        let container = try parseContainer(data)
        return (
            exif: container.exif,
            xmp: container.xmp,
            iccProfile: container.iccProfile
        )
    }

    // MARK: - Private Helpers

    /// Read a big-endian UInt32 from the reader (4 consecutive bytes).
    private func readU32(_ reader: inout BitstreamReader) throws -> UInt32 {
        guard let b0 = reader.readByte(),
              let b1 = reader.readByte(),
              let b2 = reader.readByte(),
              let b3 = reader.readByte() else {
            throw DecoderError.truncatedData
        }
        return (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
    }

    /// Read a 32-bit value from individual bits (used in frame header parsing
    /// where the reader may not be byte-aligned).
    private func readU32FromBits(_ reader: inout BitstreamReader) throws -> UInt32 {
        return UInt32(try readBits(reader: &reader, count: 32))
    }

    /// Read `count` bits from the reader and return them as a UInt32.
    /// Bits are read MSB-first matching ``BitstreamWriter/writeBits(_:count:)``.
    private func readBits(_ reader: inout BitstreamReader, count: Int) throws -> UInt32 {
        return UInt32(try readBits(reader: &reader, count: count))
    }

    /// Read `count` bits from the reader and return them as a UInt64.
    private func readBits(reader: inout BitstreamReader, count: Int) throws -> UInt64 {
        var result: UInt64 = 0
        for _ in 0..<count {
            guard let bit = reader.readBit() else {
                throw DecoderError.truncatedData
            }
            result = (result << 1) | (bit ? 1 : 0)
        }
        return result
    }

    /// Advance the reader past any remaining bits in the current byte
    /// to reach the next byte boundary. Mirrors the encoder's `flushByte()`.
    private func flushReaderToByte(_ reader: inout BitstreamReader) {
        reader.skipToByteAlignment()
    }

    /// Estimate the current byte position of the reader.
    ///
    /// Since BitstreamReader doesn't expose position tracking, we compute
    /// a conservative estimate from the data length.
    private func readerBytePosition(
        _ reader: inout BitstreamReader,
        dataLength: Int
    ) -> Int {
        // Count how many bytes we can still read
        var copy = reader
        var remaining = 0
        while copy.readByte() != nil {
            remaining += 1
        }
        return dataLength - remaining
    }

    /// Parse a frame index box payload into a ``FrameIndex``.
    ///
    /// Format: 4-byte BE entry count, then per entry:
    /// 4-byte BE frame number, 8-byte BE byte offset, 4-byte BE duration.
    private func parseFrameIndexPayload(_ payload: Data) -> FrameIndex? {
        guard payload.count >= 4 else { return nil }

        let entryCount = Int(
            UInt32(payload[payload.startIndex]) << 24
            | UInt32(payload[payload.startIndex + 1]) << 16
            | UInt32(payload[payload.startIndex + 2]) << 8
            | UInt32(payload[payload.startIndex + 3])
        )

        guard entryCount > 0 else { return FrameIndex(entries: []) }

        let entrySize = 16 // 4 + 8 + 4 bytes per entry
        guard payload.count >= 4 + entryCount * entrySize else { return nil }

        var entries: [FrameIndexEntry] = []
        entries.reserveCapacity(entryCount)

        for i in 0..<entryCount {
            let base = payload.startIndex + 4 + i * entrySize

            let frameNumber = UInt32(payload[base]) << 24
                | UInt32(payload[base + 1]) << 16
                | UInt32(payload[base + 2]) << 8
                | UInt32(payload[base + 3])

            var byteOffset: UInt64 = 0
            for j in 0..<8 {
                byteOffset = (byteOffset << 8) | UInt64(payload[base + 4 + j])
            }

            let duration = UInt32(payload[base + 12]) << 24
                | UInt32(payload[base + 13]) << 16
                | UInt32(payload[base + 14]) << 8
                | UInt32(payload[base + 15])

            entries.append(FrameIndexEntry(
                frameNumber: frameNumber,
                byteOffset: byteOffset,
                duration: duration
            ))
        }

        return FrameIndex(entries: entries)
    }

    /// Parse an ISOBMFF container for the jxlc box.
    private func parseContainerForCodestream(_ data: Data) throws -> Data {
        var offset = 0

        while offset + 8 <= data.count {
            // Box size (4 bytes big-endian)
            let size = UInt32(data[offset]) << 24
                     | UInt32(data[offset + 1]) << 16
                     | UInt32(data[offset + 2]) << 8
                     | UInt32(data[offset + 3])

            // Box type (4 bytes ASCII)
            let typeBytes = data.subdata(in: (offset + 4)..<(offset + 8))
            let typeString = String(data: typeBytes, encoding: .ascii) ?? ""

            let boxSize = Int(size)
            guard boxSize >= 8 else {
                throw DecoderError.invalidContainer("invalid box size \(boxSize)")
            }
            guard offset + boxSize <= data.count else {
                throw DecoderError.invalidContainer("box extends past end of data")
            }

            if typeString == BoxType.jxlCodestream.rawValue {
                // Extract the payload (skip 8-byte box header)
                return data.subdata(in: (offset + 8)..<(offset + boxSize))
            }

            offset += boxSize
        }

        throw DecoderError.invalidContainer("no jxlc box found")
    }
}

// MARK: - RasterImageDecoder Conformance

extension JXLDecoder: RasterImageDecoder {

    /// Decode image bytes to an image frame, satisfying the `RasterImageDecoder` protocol.
    ///
    /// Delegates to ``decode(_:)``. Use that method directly when you need the
    /// full ``JXLDecoder`` API (e.g., progressive decoding or container parsing).
    ///
    /// - Parameter data: Encoded JPEG XL codestream bytes.
    /// - Returns: Decoded image frame.
    /// - Throws: ``DecoderError`` if the data is invalid or unsupported.
    public func decode(data imageData: Data) throws -> ImageFrame {
        return try decode(imageData)
    }
}

