// JXLDecoder — pure-Swift JPEG XL decoder.
//
// STATUS: foundation only. The codec layers (Modular tree, VarDCT,
// rANS entropy coding, color transforms) are not yet implemented.
// Calling `decode(_:)` currently throws `DecoderError.notImplemented`,
// but the foundation can already:
//   • Parse a JXL ISOBMFF container into its boxes
//   • Locate / concatenate the codestream
//   • Verify the codestream signature
//   • Read a SizeHeader (xsize, ysize) — useful for `info`-style
//     workflows that don't need pixels
//
// `inspect(_:)` exposes the foundation work without the codec layer.

import Foundation

public enum DecoderError: Error, LocalizedError, Sendable {
    case notImplemented(String)
    case container(ContainerError)
    case bitstream(BitstreamError)
    case missingSignature

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let p):
            return "JXLDecoder: \(p) is not yet implemented in pure Swift. " +
                   "See ROADMAP.md."
        case .container(let e):  return "JXLDecoder container error: \(e)"
        case .bitstream(let e):  return "JXLDecoder bitstream error: \(e)"
        case .missingSignature:  return "JXLDecoder: input is not a JPEG XL file"
        }
    }
}

/// A best-effort summary of a JXL file produced from header inspection
/// alone — does not require the full codec.
public struct JXLInspection: Sendable {
    public enum Form: Sendable, Equatable {
        case naked
        case container
    }
    public let form: Form
    public let xsize: UInt32
    public let ysize: UInt32
    /// Box types found in container form (empty for naked codestreams).
    public let boxTypes: [String]
    /// Parsed image metadata. Nil if inspection failed before this point
    /// (e.g. SizeHeader-only inspection on truncated files).
    public let metadata: ImageMetadata?
}

public final class JXLDecoder {
    public init() {}

    /// Decode a JPEG XL byte stream into an `ImageFrame`. If the
    /// input carries the project-internal `0x4D30` 'M0' marker
    /// (produced by `EncodingOptions.useM0Placeholder = true`),
    /// routes through `MinimalLosslessCodec.decode(_:)`. Otherwise
    /// throws `.notImplemented` — the real Phase M codec layer
    /// isn't done yet.
    public func decode(_ data: Data) throws -> ImageFrame {
        if MinimalLosslessCodec.isM0(data) {
            do { return try MinimalLosslessCodec.decode(data) }
            catch { throw DecoderError.notImplemented("M0 decode failed: \(error)") }
        }
        throw DecoderError.notImplemented("frame decoding (Modular + VarDCT)")
    }

    public func decodeAll(_ data: Data) throws -> [ImageFrame] {
        throw DecoderError.notImplemented("multi-frame decoding")
    }

    /// Inspect a JXL byte stream's container and codestream-header
    /// metadata without decoding any pixels. This *is* implemented.
    public func inspect(_ data: Data) throws -> JXLInspection {
        let form: JXLInspection.Form
        var codestream: Data
        var boxTypes: [String] = []
        do {
            switch try parseJXLContainer(data) {
            case .naked:
                form = .naked
                codestream = data
            case .iso(let boxes):
                form = .container
                boxTypes = boxes.map { $0.type }
                codestream = try extractCodestream(from: boxes, in: data)
            }
        } catch let e as ContainerError {
            throw DecoderError.container(e)
        }

        guard hasCodestreamSignature(codestream) else {
            throw DecoderError.missingSignature
        }
        var reader = BitReader(codestream, startingAt: 16) // skip 2-byte signature
        do {
            let size = try SizeHeader.read(from: &reader)
            // Best-effort: try to read ImageMetadata. If the spec branches
            // we don't yet handle (e.g. exotic extensions) trip us up,
            // fall back to size-only inspection — that's still useful.
            let metadata: ImageMetadata?
            do {
                metadata = try ImageMetadata.read(from: &reader)
            } catch {
                metadata = nil
            }
            return JXLInspection(form: form, xsize: size.xsize, ysize: size.ysize,
                                 boxTypes: boxTypes, metadata: metadata)
        } catch let e as BitstreamError {
            throw DecoderError.bitstream(e)
        }
    }
}
