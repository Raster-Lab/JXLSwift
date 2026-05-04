// CompressionFamily — shared protocols for the Swift compression-
// library family (JXLSwift, J2KSwift, …). Phase C of the
// family-API-parity migration.
//
// Goal: callers can write codec-agnostic code that works across
// codecs.
//
//     func encodeAll<E: CompressionEncoder>(
//         _ encoder: E, images: [E.Image]
//     ) async throws -> [Data] {
//         var out: [Data] = []
//         for img in images {
//             out.append(try await encoder.encode(img).data)
//         }
//         return out
//     }
//
//     // Works with either:
//     let jxl = JXLEncoder()
//     let j2k = J2KEncoder()    // (once J2KSwift adopts the protocol)
//
// **Adoption status (this repo):** JXLSwift's own types conform.
// J2KSwift will mirror these protocols in a follow-on bidirectional
// alignment release. Until then, generic code parameterised on
// `CompressionEncoder` only works with JXLSwift's encoders, but the
// shape is fixed so adoption is a one-line conformance per type.
//
// See [Documentation/FAMILY-API-PARITY.md](../../../Documentation/FAMILY-API-PARITY.md).

import Foundation

// MARK: - Image protocol

/// Shared shape for image types across the codec family. The
/// minimal common ground is geometry (`width` × `height`); per-
/// codec types add their own pixel-data accessors and metadata.
///
/// Conforming types: ``ImageFrame`` (= ``JXLImage``) in JXLSwift;
/// J2KSwift's `J2KImage` will conform in a follow-on.
public protocol CompressionImage: Sendable {
    /// Width of the image in pixels.
    var width: Int { get }
    /// Height of the image in pixels.
    var height: Int { get }
}

// MARK: - Encoded-output protocol

/// Shared shape for encoded-bitstream output. Codecs may return
/// a richer struct (e.g., JXLSwift's ``EncodedImage`` with
/// `stats`); the LCD is "give me the bytes".
public protocol CompressionOutput: Sendable {
    /// The encoded bitstream bytes.
    var data: Data { get }
}

// MARK: - Encoder protocol

/// Shared shape for codec encoders. Both `async` and sync encode
/// methods are exposed; conforming types implement at least the
/// async form. Each codec brings its own input image type via
/// ``Image`` and its own output via ``Output``.
public protocol CompressionEncoder: Sendable {
    associatedtype Image: CompressionImage
    associatedtype Output: CompressionOutput

    /// Encode a single image to a codec-specific output type.
    func encode(_ image: Image) async throws -> Output
}

// MARK: - Decoder protocol

/// Shared shape for codec decoders. Each codec brings its own
/// reconstructed image type via ``Image``.
public protocol CompressionDecoder: Sendable {
    associatedtype Image: CompressionImage

    /// Decode a codec bitstream into an image.
    func decode(_ data: Data) async throws -> Image
}

// MARK: - Error umbrella

/// Shared shape for codec error types. Each codec keeps its own
/// fine-grained error enum (``EncoderError``, ``DecoderError``,
/// J2KSwift's `J2KError`) but conforms to this umbrella so
/// callers can `catch let e as CompressionError` regardless of
/// which library emitted it.
public protocol CompressionError: Error, LocalizedError, Sendable {}

// MARK: - JXLSwift conformances (additive)

// ImageFrame already has Width / Height — declare conformance.
extension ImageFrame: CompressionImage {}

// EncodedImage already exposes `data: Data` — declare conformance.
extension EncodedImage: CompressionOutput {}

// JXLEncoder's async encode signature already matches — declare it.
extension JXLEncoder: CompressionEncoder {
    public typealias Image = ImageFrame
    public typealias Output = EncodedImage
}

// JXLDecoder's async decode signature already matches.
extension JXLDecoder: CompressionDecoder {
    public typealias Image = ImageFrame
}

// Existing error enums adopt the umbrella protocol.
extension EncoderError: CompressionError {}
extension DecoderError: CompressionError {}
