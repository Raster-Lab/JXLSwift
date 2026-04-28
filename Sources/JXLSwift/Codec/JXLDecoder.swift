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

/// Deeper inspection that walks past the image headers into the
/// frame structure. Reports what we can pull from the first frame —
/// the FrameHeader fields, the TOC entry sizes, and (for Modular
/// frames) the MA-tree structure if one is present. Fields are
/// nil-able so a caller can use this even on files where our
/// reader stops at an unsupported branch.
public struct JXLFrameInspection: Sendable {
    /// Encoding mode of the first frame.
    public let encoding: FrameEncoding?
    /// True if `is_last` was set on the first frame.
    public let isLast: Bool?
    /// Frame `flags` U64.
    public let flags: UInt64?
    /// Number of progressive passes.
    public let numPasses: UInt32?
    /// TOC entry sizes (one per group, plus DC if present).
    public let tocSizes: [UInt32]?
    /// True if the Modular global has a non-trivial MA-tree.
    public let hasModularTree: Bool?
    /// Number of leaves in the MA-tree (when `hasModularTree`).
    public let modularTreeLeafCount: Int?
    /// Whether the post-tree pixel-data section uses prefix codes
    /// (true) or rANS (false).
    public let usePrefixCode: Bool?
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

    /// Inspect frame-level structure of a JXL byte stream — the
    /// FrameHeader, TOC, and (for Modular frames) the MA-tree
    /// statistics. Best-effort: each field is `nil` if our reader
    /// hit an unsupported pattern at that layer or earlier. The
    /// fields-up-to-the-error path always works through whatever
    /// it could read.
    ///
    /// Useful as `jxl-tool info` material, and for diagnostics
    /// without running the full pixel decoder.
    public func inspectFrameStructure(_ data: Data) -> JXLFrameInspection {
        // Walk the headers we already know how to read.
        guard let inspection = try? inspect(data),
              let m = inspection.metadata else {
            return JXLFrameInspection(
                encoding: nil, isLast: nil, flags: nil,
                numPasses: nil, tocSizes: nil,
                hasModularTree: nil, modularTreeLeafCount: nil,
                usePrefixCode: nil
            )
        }
        // Re-position a reader at the start of the codestream and
        // walk past the headers.
        let codestream: Data
        if case .naked = inspection.form {
            codestream = data
        } else {
            // Container form — re-extract the codestream slice.
            guard let parsed = try? parseJXLContainer(data),
                  case let .iso(boxes) = parsed,
                  let cs = try? extractCodestream(from: boxes, in: data) else {
                return JXLFrameInspection(
                    encoding: nil, isLast: nil, flags: nil,
                    numPasses: nil, tocSizes: nil,
                    hasModularTree: nil, modularTreeLeafCount: nil,
                    usePrefixCode: nil
                )
            }
            codestream = cs
        }
        var r = BitReader(codestream, startingAt: 16)
        // Re-read SizeHeader + ImageMetadata to sync the reader.
        guard let _ = try? SizeHeader.read(from: &r),
              let _ = try? ImageMetadata.read(from: &r) else {
            return JXLFrameInspection(
                encoding: nil, isLast: nil, flags: nil,
                numPasses: nil, tocSizes: nil,
                hasModularTree: nil, modularTreeLeafCount: nil,
                usePrefixCode: nil
            )
        }
        try? r.alignToByte()
        let ctx = FrameHeaderContext(
            xybEncoded: m.xybEncoded,
            numExtraChannels: m.extraChannels.count,
            haveAnimation: m.animation != nil,
            haveTimecodes: m.animation?.haveTimecodes ?? false
        )
        guard let fh = try? FrameHeader.read(from: &r, context: ctx) else {
            return JXLFrameInspection(
                encoding: nil, isLast: nil, flags: nil,
                numPasses: nil, tocSizes: nil,
                hasModularTree: nil, modularTreeLeafCount: nil,
                usePrefixCode: nil
            )
        }
        // TOC (assumes single-group single-pass — what cjxl emits for
        // simple inputs).
        let entries = TOC.numEntries(
            numGroups: 1, numDcGroups: 0,
            numPasses: Int(fh.passes.numPasses)
        )
        let toc = try? TOC.read(from: &r, numEntries: entries)
        let tocSizes = toc?.entrySizes

        // For Modular frames, try to walk into the MA-tree section.
        var hasTree: Bool? = nil
        var leafCount: Int? = nil
        var usePrefix: Bool? = nil
        if fh.encoding == .modular {
            // Skip matrices.DecodeDC bit (1 if default).
            guard let matrixDcDefault = try? r.readBit() else {
                return JXLFrameInspection(
                    encoding: fh.encoding, isLast: fh.isLast,
                    flags: fh.flags, numPasses: fh.passes.numPasses,
                    tocSizes: tocSizes,
                    hasModularTree: nil, modularTreeLeafCount: nil,
                    usePrefixCode: nil
                )
            }
            if !matrixDcDefault {
                // Skip 3 × F16.
                for _ in 0..<3 {
                    guard let _ = try? r.read(bits: 16) else { break }
                }
            }
            if let ht = try? r.readBit() {
                hasTree = ht
                if ht {
                    if let treeHdr = try? EntropySectionHeader.read(
                        from: &r, numContexts: 6
                    ),
                    let treeCB = try? MultiClusterCodebook.read(
                        from: &r, header: treeHdr
                    ) {
                        var treeStream = TokenStreamReader(
                            header: treeHdr, codebook: treeCB
                        )
                        if let tree = try? ModularTree.decode(
                            from: &r, stream: &treeStream
                        ) {
                            leafCount = tree.leafCount
                            // Try the post-tree section for usePrefix info.
                            if let postHdr = try? EntropySectionHeader.read(
                                from: &r, numContexts: tree.leafCount
                            ) {
                                usePrefix = postHdr.usePrefixCode
                            }
                        }
                    }
                }
            }
        }

        return JXLFrameInspection(
            encoding: fh.encoding, isLast: fh.isLast,
            flags: fh.flags, numPasses: fh.passes.numPasses,
            tocSizes: tocSizes,
            hasModularTree: hasTree, modularTreeLeafCount: leafCount,
            usePrefixCode: usePrefix
        )
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
