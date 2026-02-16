/// PixelBuffer — Memory-bounded, backend-agnostic pixel data container
///
/// Provides tiled access to pixel data for memory-bounded processing.
/// Supports zero-copy wrapping of existing memory where possible.

import Foundation

/// A memory-bounded container for pixel data that supports tiled processing.
///
/// `PixelBuffer` is the canonical type for passing pixel data through the
/// encode/decode pipeline. It supports:
/// - Tiled iteration for memory-bounded processing
/// - Planar pixel storage format
/// - Multiple pixel types (UInt8, UInt16, Float32)
///
/// # Example
/// ```swift
/// var buffer = PixelBuffer(width: 1920, height: 1080, channels: 3)
/// for tile in buffer.tiles(size: 256) {
///     // Process each 256×256 tile independently
/// }
/// ```
public struct PixelBuffer: Sendable {
    /// Image width in pixels
    public let width: Int

    /// Image height in pixels
    public let height: Int

    /// Number of color channels
    public let channels: Int

    /// Pixel data type
    public let pixelType: PixelType

    /// Raw pixel data (planar format)
    public var data: [UInt8]

    // MARK: - Initialization

    /// Create a new pixel buffer with zeroed data.
    ///
    /// - Parameters:
    ///   - width: Image width in pixels. Must be > 0.
    ///   - height: Image height in pixels. Must be > 0.
    ///   - channels: Number of color channels. Must be >= 1.
    ///   - pixelType: Pixel data type (default: `.uint8`).
    public init(width: Int, height: Int, channels: Int, pixelType: PixelType = .uint8) {
        precondition(width > 0, "Width must be positive")
        precondition(height > 0, "Height must be positive")
        precondition(channels >= 1, "Must have at least one channel")

        self.width = width
        self.height = height
        self.channels = channels
        self.pixelType = pixelType

        let totalSamples = width * height * channels
        self.data = [UInt8](repeating: 0, count: totalSamples * pixelType.bytesPerSample)
    }

    /// Create a pixel buffer wrapping existing data (zero-copy when possible).
    ///
    /// - Parameters:
    ///   - data: Raw pixel data in planar format.
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - channels: Number of color channels.
    ///   - pixelType: Pixel data type.
    /// - Throws: `PixelBufferError.dataSizeMismatch` if data size doesn't match dimensions.
    public init(data: [UInt8], width: Int, height: Int, channels: Int,
                pixelType: PixelType = .uint8) throws {
        let expectedSize = width * height * channels * pixelType.bytesPerSample
        guard data.count == expectedSize else {
            throw PixelBufferError.dataSizeMismatch(
                expected: expectedSize, actual: data.count)
        }
        precondition(width > 0, "Width must be positive")
        precondition(height > 0, "Height must be positive")
        precondition(channels >= 1, "Must have at least one channel")

        self.width = width
        self.height = height
        self.channels = channels
        self.pixelType = pixelType
        self.data = data
    }

    // MARK: - Tiled Access

    /// A rectangular tile within a pixel buffer.
    public struct Tile: Sendable {
        /// Tile origin X within the parent buffer
        public let originX: Int
        /// Tile origin Y within the parent buffer
        public let originY: Int
        /// Tile width in pixels
        public let width: Int
        /// Tile height in pixels
        public let height: Int

        /// Create a tile descriptor.
        public init(originX: Int, originY: Int, width: Int, height: Int) {
            self.originX = originX
            self.originY = originY
            self.width = width
            self.height = height
        }
    }

    /// Generate tile descriptors that cover the entire buffer.
    ///
    /// Tiles at the right and bottom edges may be smaller than `tileSize`
    /// to avoid exceeding the image bounds.
    ///
    /// - Parameter tileSize: The maximum width and height of each tile.
    /// - Returns: An array of `Tile` descriptors covering the full image.
    public func tiles(size tileSize: Int) -> [Tile] {
        precondition(tileSize > 0, "Tile size must be positive")

        var result: [Tile] = []
        var y = 0
        while y < height {
            let tileH = min(tileSize, height - y)
            var x = 0
            while x < width {
                let tileW = min(tileSize, width - x)
                result.append(Tile(originX: x, originY: y, width: tileW, height: tileH))
                x += tileSize
            }
            y += tileSize
        }
        return result
    }

    /// Extract pixel data for a single tile and channel.
    ///
    /// - Parameters:
    ///   - tile: The tile descriptor.
    ///   - channel: The channel index.
    /// - Returns: A flat array of bytes for the tile region in the specified channel.
    public func extractTileData(tile: Tile, channel: Int) -> [UInt8] {
        precondition(channel >= 0 && channel < channels, "Channel out of range")

        let bps = pixelType.bytesPerSample
        let planeOffset = channel * (width * height) * bps
        var tileData = [UInt8](repeating: 0, count: tile.width * tile.height * bps)

        for row in 0..<tile.height {
            let srcY = tile.originY + row
            let srcOffset = planeOffset + (srcY * width + tile.originX) * bps
            let dstOffset = row * tile.width * bps
            let count = tile.width * bps

            tileData.replaceSubrange(dstOffset..<(dstOffset + count),
                                     with: data[srcOffset..<(srcOffset + count)])
        }

        return tileData
    }

    /// Write pixel data back into a tile region for a single channel.
    ///
    /// - Parameters:
    ///   - tileData: The pixel data to write.
    ///   - tile: The tile descriptor.
    ///   - channel: The channel index.
    public mutating func writeTileData(_ tileData: [UInt8], tile: Tile, channel: Int) {
        precondition(channel >= 0 && channel < channels, "Channel out of range")

        let bps = pixelType.bytesPerSample
        let planeOffset = channel * (width * height) * bps

        for row in 0..<tile.height {
            let dstY = tile.originY + row
            let dstOffset = planeOffset + (dstY * width + tile.originX) * bps
            let srcOffset = row * tile.width * bps
            let count = tile.width * bps

            data.replaceSubrange(dstOffset..<(dstOffset + count),
                                 with: tileData[srcOffset..<(srcOffset + count)])
        }
    }

    // MARK: - Conversion

    /// Convert this pixel buffer to an `ImageFrame`.
    ///
    /// - Parameters:
    ///   - colorSpace: The color space to assign (default: `.sRGB`).
    ///   - hasAlpha: Whether the buffer includes an alpha channel (default: `false`).
    ///   - alphaMode: Alpha channel mode (default: `.straight`).
    /// - Returns: An `ImageFrame` with the same pixel data.
    public func toImageFrame(colorSpace: ColorSpace = .sRGB,
                             hasAlpha: Bool = false,
                             alphaMode: AlphaMode = .straight) -> ImageFrame {
        var frame = ImageFrame(
            width: width,
            height: height,
            channels: channels,
            pixelType: pixelType,
            colorSpace: colorSpace,
            hasAlpha: hasAlpha,
            alphaMode: alphaMode,
            bitsPerSample: pixelType.bytesPerSample * 8
        )
        frame.data = data
        return frame
    }

    /// Create a pixel buffer from an `ImageFrame`.
    ///
    /// - Parameter frame: The image frame to convert.
    /// - Returns: A `PixelBuffer` wrapping the frame's pixel data.
    public static func from(frame: ImageFrame) -> PixelBuffer {
        var buffer = PixelBuffer(
            width: frame.width,
            height: frame.height,
            channels: frame.channels,
            pixelType: frame.pixelType
        )
        buffer.data = frame.data
        return buffer
    }
}

// MARK: - Errors

/// Errors related to pixel buffer operations.
public enum PixelBufferError: Error, LocalizedError {
    /// The provided data size doesn't match the expected size for the given dimensions.
    case dataSizeMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .dataSizeMismatch(let expected, let actual):
            return "Data size mismatch: expected \(expected) bytes, got \(actual)"
        }
    }
}
