// CompressionFamily conformances for JXLSwift's public types.
//
// The protocols themselves (`CompressionImage`, `CompressionOutput`,
// `CompressionEncoder`, `CompressionDecoder`, `CompressionError`)
// live in the standalone `CompressionFamily` package shared with
// J2KSwift. This file only declares JXLSwift's conformances.
//
// Goal: callers can write codec-agnostic code that works across
// the family. Generic helpers parameterised on these protocols
// pick the right concrete type at the call site:
//
//     func encodeAndExtractBytes<E: CompressionEncoder>(
//         _ encoder: E, image: E.Image
//     ) async throws -> Data {
//         let output = try await encoder.encode(image)
//         return output.data
//     }
//
//     // Works with either:
//     let jxlEnc = JXLEncoder()
//     let j2kEnc = J2KEncoder()    // (once J2KSwift adopts the protocol)
//
// See [Documentation/FAMILY-API-PARITY.md](../../../Documentation/FAMILY-API-PARITY.md).

import Foundation
import CompressionFamily

// MARK: - JXLSwift conformances (additive)

// ImageFrame already has Width / Height — declare conformance.
extension ImageFrame: CompressionImage {}

// EncodedImage already exposes `data: Data` — declare conformance.
extension EncodedImage: CompressionOutput {}

// JXLEncoder's async encode signature already matches.
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
