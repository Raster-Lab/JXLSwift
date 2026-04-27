// JXLEncoder — pure-Swift JPEG XL encoder.
//
// STATUS: foundation only. The codec layers (Modular tree, VarDCT,
// rANS entropy coding, color transforms) are not yet implemented.
// Calling `encode(_:)` currently throws `EncoderError.notImplemented`.
//
// What works today:
//   • Bitstream primitives (BitReader / BitWriter)
//   • Spec-defined integer encodings (U32 / U64)
//   • ISOBMFF container build/parse
//   • Codestream signature + SizeHeader read/write
//
// Track progress in ROADMAP.md.

import Foundation

public enum EncoderError: Error, LocalizedError, Sendable {
    /// A code path is not implemented yet. The string identifies which.
    case notImplemented(String)
    /// The frame's geometry / channels / bit depth violate codec
    /// invariants the encoder can't reconcile.
    case unsupportedFrame(String)
    /// Bitstream-level error during encoding.
    case bitstream(BitstreamError)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let path):
            return "JXLEncoder: \(path) is not yet implemented in pure Swift. " +
                   "See ROADMAP.md for status; or use the libjxl-backend branch."
        case .unsupportedFrame(let m):  return "JXLEncoder: unsupported frame — \(m)"
        case .bitstream(let e):         return "JXLEncoder bitstream error: \(e)"
        }
    }
}

public final class JXLEncoder {
    public let options: EncodingOptions

    public init(options: EncodingOptions = EncodingOptions()) {
        self.options = options
    }

    /// Encode a single frame. When
    /// `EncodingOptions.useM0Placeholder == true`, routes through
    /// `MinimalLosslessCodec` and returns an M0-format buffer.
    /// **Otherwise throws `.notImplemented`** — the real codec
    /// layer is still in development.
    public func encode(_ frame: ImageFrame) throws -> EncodedImage {
        if options.useM0Placeholder {
            let start = Date()
            let data: Data
            do { data = try MinimalLosslessCodec.encode(frame, effort: options.m0Effort) }
            catch { throw EncoderError.unsupportedFrame("M0 encode failed: \(error)") }
            let originalSize = frame.data.count
            return EncodedImage(
                data: data,
                stats: CompressionStats(
                    originalSize: originalSize,
                    compressedSize: data.count,
                    encodingTime: Date().timeIntervalSince(start)
                )
            )
        }
        throw EncoderError.notImplemented("frame encoding (Modular + VarDCT)")
    }

    /// Encode multiple frames as a multi-frame .jxl. **Not yet implemented.**
    public func encode(_ frames: [ImageFrame]) throws -> EncodedImage {
        throw EncoderError.notImplemented("multi-frame encoding")
    }
}
