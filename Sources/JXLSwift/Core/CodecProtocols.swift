/// Shared codec protocols for Raster-Lab image libraries.
///
/// These protocols define the common interface for image encoders and decoders
/// across Raster-Lab codec libraries (JXLSwift, J2KSwift, etc.), enabling
/// developers familiar with one library to quickly adopt another.

import Foundation

// MARK: - RasterImageEncoder

/// A format-agnostic image encoder protocol shared across Raster-Lab codec libraries.
///
/// `JXLEncoder` (JXLSwift) and the equivalent encoder in J2KSwift both conform
/// to this protocol, providing a consistent API surface across codecs.
///
/// The protocol uses the labeled `frame:` and `frames:` argument conventions so
/// that calls are unambiguous on types like `JXLEncoder` that expose additional
/// `encode` overloads returning richer result types.
///
/// ## Usage
/// ```swift
/// let encoder: any RasterImageEncoder = JXLEncoder()
/// let data = try encoder.encode(frame: someFrame)
/// ```
public protocol RasterImageEncoder: AnyObject {

    /// Encode a single image frame to the codec's native byte format.
    ///
    /// - Parameter frame: The source image frame to encode.
    /// - Returns: Encoded image bytes in the codec's native format.
    /// - Throws: A codec-specific error if encoding fails.
    func encode(frame: ImageFrame) throws -> Data

    /// Encode multiple image frames as an animation sequence.
    ///
    /// Codecs that do not support animation may throw an error when more than
    /// one frame is supplied.
    ///
    /// - Parameter frames: An ordered array of image frames to encode.
    /// - Returns: Encoded animation bytes in the codec's native format.
    /// - Throws: A codec-specific error if encoding fails.
    func encode(frames: [ImageFrame]) throws -> Data
}

// MARK: - RasterImageDecoder

/// A format-agnostic image decoder protocol shared across Raster-Lab codec libraries.
///
/// `JXLDecoder` (JXLSwift) and the equivalent decoder in J2KSwift both conform
/// to this protocol, providing a consistent API surface across codecs.
///
/// ## Usage
/// ```swift
/// let decoder: any RasterImageDecoder = JXLDecoder()
/// let frame = try decoder.decode(data: encodedBytes)
/// ```
public protocol RasterImageDecoder: AnyObject {

    /// Decode image bytes to an image frame.
    ///
    /// - Parameter data: Encoded image bytes in the codec's native format.
    /// - Returns: Decoded image frame.
    /// - Throws: A codec-specific error if decoding fails.
    func decode(data: Data) throws -> ImageFrame
}

// MARK: - RasterImageCodec

/// A combined encoder and decoder protocol for codecs that support both operations.
///
/// Conforming types can both encode `ImageFrame` values to bytes and decode bytes
/// back to `ImageFrame` values.
///
/// ## Example
/// ```swift
/// func roundTrip<C: RasterImageCodec>(codec: C, frame: ImageFrame) throws -> ImageFrame {
///     let data = try codec.encode(frame: frame)
///     return try codec.decode(data: data)
/// }
/// ```
public typealias RasterImageCodec = RasterImageEncoder & RasterImageDecoder

