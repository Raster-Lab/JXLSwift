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

    /// Encode a single frame. **Not yet implemented.**
    public func encode(_ frame: ImageFrame) throws -> EncodedImage {
        throw EncoderError.notImplemented("frame encoding (Modular + VarDCT)")
    }

    /// Encode multiple frames as a multi-frame .jxl. **Not yet implemented.**
    public func encode(_ frames: [ImageFrame]) throws -> EncodedImage {
        throw EncoderError.notImplemented("multi-frame encoding")
    }
}
