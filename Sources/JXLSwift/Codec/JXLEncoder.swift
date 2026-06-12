// JXLEncoder — pure-Swift JPEG XL encoder.
//
// STATUS: both halves of the codec are wired up.
//   • Lossless Modular — 8-bit and 16-bit integer samples (grayscale,
//     RGB, RGBA), single-pass, any size up to the encoder's 8K cap.
//   • Lossy VarDCT — 8-bit RGB / RGBA via `VarDCTBitstreamWriter`
//     (DCT8×8, multi-DC-group, ≤ 8192 px).
// Output round-trips through `djxl 0.11.2`.
//
// Routing: `encode(_:)` picks the codec from `options.mode`.
// `.lossless` always uses the Modular path. Lossy modes
// (`.lossy` / `.distance`) use the VarDCT path when the frame is one
// VarDCT can take; for frames it can't (grayscale, 16-bit, oversized)
// the encoder **falls back to lossless Modular** so `encode` always
// yields a valid codestream rather than failing. The Modular path
// deinterleaves the caller's channel-interleaved `ImageFrame.data`
// into per-channel buffers and dispatches into `SpecModularEncoder`.
// `EncodingOptions.useM0Placeholder` still routes to the legacy M0
// vertical slice for benchmark continuity.
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
            return "JXLEncoder: \(path) is not yet implemented. See ROADMAP.md for status."
        case .unsupportedFrame(let m):  return "JXLEncoder: unsupported frame — \(m)"
        case .bitstream(let e):         return "JXLEncoder bitstream error: \(e)"
        }
    }
}

/// JPEG XL encoder. `Sendable`-by-default value type — copies are
/// independent. Mirrors J2KSwift's `J2KEncoder` shape for family
/// API parity (Phase B.6 of the alignment plan; see
/// [Documentation/FAMILY-API-PARITY.md](../../../Documentation/FAMILY-API-PARITY.md)).
///
/// Pre-Phase-B JXLSwift defined this as a `final class`; the
/// conversion to `struct` is a soft source change. Existing callers
/// using `JXLEncoder()` continue to work; the only breakage is for
/// callers who relied on REFERENCE semantics (storing a ref +
/// expecting mutation across copies). For an encoder, that pattern
/// is rare in practice.
public struct JXLEncoder: Sendable {
    public let options: EncodingOptions

    public init(options: EncodingOptions = EncodingOptions()) {
        self.options = options
    }

    /// Encode a single frame.
    ///
    /// - `EncodingOptions.useM0Placeholder == true` routes through
    ///   `MinimalLosslessCodec` (the legacy M0 vertical slice).
    /// - A lossy `mode` (`.lossy` / `.distance`) routes to the VarDCT
    ///   encoder when the frame is 8-bit RGB/RGBA within VarDCT's
    ///   size limits; otherwise it **falls back** to the lossless
    ///   Modular path (so the call still produces a valid codestream).
    /// - `.lossless` always uses the Modular path, dispatched on the
    ///   frame's `pixelType`, `channels`, and `alphaChannels`.
    ///
    /// Produces a real spec-compliant codestream `djxl` can decode.
    /// `float32` and frames with `iccProfile` set throw
    /// `.notImplemented` for now.
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
        if frame.iccProfile != nil {
            throw EncoderError.notImplemented(
                "encode with embedded ICC profile (use raw colour space)"
            )
        }
        let start = Date()

        // Lossy modes encode through the VarDCT codec. When the frame
        // is one VarDCT can't take (non-8-bit, <3 or >4 channels,
        // beyond the writer's size limits) `VarDCTBitstreamWriter` /
        // `VarDCTEncoder` throw their `unsupported` case — caught here
        // so the encode falls back to the lossless Modular path below.
        if case .lossless = options.mode {
            // Lossless — skip VarDCT, use Modular directly.
        } else {
            do {
                let cs = try VarDCTBitstreamWriter.encode(
                    frame: frame, distance: options.distance,
                    gaborish: options.gaborish,
                    adaptiveQF: options.adaptiveQF)
                let wrapped = options.containerWrap
                    ? buildJXLContainer(codestream: cs) : cs
                return EncodedImage(
                    data: wrapped,
                    stats: CompressionStats(
                        originalSize: frame.data.count,
                        compressedSize: wrapped.count,
                        encodingTime: Date().timeIntervalSince(start),
                        wasLossless: false   // lossy VarDCT
                    )
                )
            } catch is VarDCTBitstreamWriter.WriterError {
                // VarDCT can't take this frame — fall through to
                // the lossless Modular dispatch below.
            } catch is VarDCTEncoder.EncoderError {
                // Likewise (non-8-bit / wrong channel count).
            }
        }

        let bytes: Data
        // High-bit-depth encoders accept 9..16; clamp to the spec
        // range. ImageFrame's `pixelType.bitsPerSample` is always
        // 8/16/32, but callers may want to record a non-byte-aligned
        // depth (10, 12, …) — for now we only honour the byte-
        // aligned case via the `BitDepth` field, since `ImageFrame`
        // doesn't expose a sub-byte depth knob.
        switch (frame.pixelType, frame.channels, frame.alphaChannels) {
        case (.uint8, 1, 0):
            bytes = try wrapModular {
                try SpecModularEncoder.encodeGrayscale8(
                    width: frame.width, height: frame.height,
                    pixels: frame.data, effort: options.effort.rawValue
                )
            }
        case (.uint16, 1, 0):
            // One pass interleaved bytes → Int32 (the encoder's working
            // type): the [UInt16] intermediate cost a third full-image
            // copy on the 16-bit grayscale medical path.
            let pixels = unpackUInt16ToInt32(
                from: frame, channelCount: 1, channel: 0)
            bytes = try wrapModular {
                try SpecModularEncoder.encodeGrayscale16(
                    width: frame.width, height: frame.height,
                    pixelsInt32: pixels, effort: options.effort.rawValue
                )
            }
        case (.uint8, 2, 1):
            let (gray, alpha) = deinterleave2(frame: frame)
            bytes = try wrapModular {
                try SpecModularEncoder.encodeGrayscaleAlpha8(
                    width: frame.width, height: frame.height,
                    gray: gray, alpha: alpha, effort: options.effort.rawValue
                )
            }
        case (.uint16, 2, 1):
            let gray = unpackUInt16(from: frame, channelCount: 2, channel: 0)
            let alpha = unpackUInt16(from: frame, channelCount: 2, channel: 1)
            bytes = try wrapModular {
                try SpecModularEncoder.encodeGrayscaleAlpha16(
                    width: frame.width, height: frame.height,
                    gray: gray, alpha: alpha, effort: options.effort.rawValue
                )
            }
        case (.uint8, 3, 0):
            let (r, g, b) = deinterleave3(frame: frame)
            bytes = try wrapModular {
                try SpecModularEncoder.encodeRGB8(
                    width: frame.width, height: frame.height,
                    r: r, g: g, b: b, effort: options.effort.rawValue
                )
            }
        case (.uint16, 3, 0):
            let r = unpackUInt16(from: frame, channelCount: 3, channel: 0)
            let g = unpackUInt16(from: frame, channelCount: 3, channel: 1)
            let b = unpackUInt16(from: frame, channelCount: 3, channel: 2)
            bytes = try wrapModular {
                try SpecModularEncoder.encodeRGB16(
                    width: frame.width, height: frame.height,
                    r: r, g: g, b: b, effort: options.effort.rawValue
                )
            }
        case (.uint8, 4, 1):
            let (r, g, b, a) = deinterleave4(frame: frame)
            bytes = try wrapModular {
                try SpecModularEncoder.encodeRGBA8(
                    width: frame.width, height: frame.height,
                    r: r, g: g, b: b, a: a, effort: options.effort.rawValue
                )
            }
        case (.uint16, 4, 1):
            let r = unpackUInt16(from: frame, channelCount: 4, channel: 0)
            let g = unpackUInt16(from: frame, channelCount: 4, channel: 1)
            let b = unpackUInt16(from: frame, channelCount: 4, channel: 2)
            let a = unpackUInt16(from: frame, channelCount: 4, channel: 3)
            bytes = try wrapModular {
                try SpecModularEncoder.encodeRGBA16(
                    width: frame.width, height: frame.height,
                    r: r, g: g, b: b, a: a, effort: options.effort.rawValue
                )
            }
        default:
            throw EncoderError.notImplemented(
                "Modular encode for "
                + "\(frame.pixelType)/\(frame.channels)ch/"
                + "\(frame.alphaChannels) alpha — supported today: "
                + "8-bit and 16-bit grayscale/RGB/RGBA"
            )
        }
        let wrapped = options.containerWrap
            ? buildJXLContainer(codestream: bytes)
            : bytes
        return EncodedImage(
            data: wrapped,
            stats: CompressionStats(
                originalSize: frame.data.count,
                compressedSize: wrapped.count,
                encodingTime: Date().timeIntervalSince(start)
            )
        )
    }

    /// Run a SpecModular encode and rewrap any thrown error into an
    /// `EncoderError`. Keeps the dispatch table in `encode(_:)` tidy
    /// and ensures callers see a consistent error surface.
    /// Multi-frame lossless Modular encode. All frames must be
    /// the same shape and 8-bit RGB or RGBA (the two Modular
    /// content types currently exposed by
    /// `SpecModularEncoder.encodeModularAnimation8`).
    private func encodeLosslessAnimation(
        frames: [ImageFrame], start: Date
    ) throws -> EncodedImage {
        let first = frames[0]
        for (i, f) in frames.enumerated() where i > 0 {
            guard f.width == first.width, f.height == first.height,
                  f.channels == first.channels,
                  f.pixelType == first.pixelType else {
                throw EncoderError.unsupportedFrame(
                    "multi-frame lossless: frame \(i) shape "
                    + "(\(f.width)×\(f.height)/"
                    + "\(f.channels)ch/\(f.pixelType)) "
                    + "differs from frame 0")
            }
        }
        // Dispatch on (pixelType, channels). Supported today:
        // 8-bit and 16-bit grayscale / RGB / RGBA frames. Other
        // shapes throw `notImplemented`.
        let bitsPerSample: UInt32
        switch first.pixelType {
        case .uint8: bitsPerSample = 8
        case .uint16: bitsPerSample = 16
        default:
            throw EncoderError.notImplemented(
                "multi-frame lossless for \(first.pixelType) — "
                + "only uint8 / uint16 grayscale / RGB / RGBA "
                + "supported in animation")
        }
        let colorSpace: ColorSpaceID
        let colorChans: Int
        let hasAlpha: Bool
        switch first.channels {
        case 1: colorSpace = .grayscale; colorChans = 1
            hasAlpha = false
        case 2: colorSpace = .grayscale; colorChans = 1
            hasAlpha = true
        case 3: colorSpace = .rgb; colorChans = 3
            hasAlpha = false
        case 4: colorSpace = .rgb; colorChans = 3
            hasAlpha = true
        default:
            throw EncoderError.notImplemented(
                "multi-frame lossless for "
                + "\(first.channels) channels — only grayscale / "
                + "grayscale+alpha / RGB / RGBA supported")
        }
        // Per-frame durations. Same logic as the lossy path.
        let durations: [UInt32]
        if let perFrame = options.frameDurations {
            guard perFrame.count == frames.count else {
                throw EncoderError.unsupportedFrame(
                    "EncodingOptions.frameDurations.count "
                    + "(\(perFrame.count)) ≠ frames.count "
                    + "(\(frames.count))")
            }
            durations = perFrame
        } else {
            durations = [UInt32](
                repeating: options.defaultFrameDuration,
                count: frames.count)
        }
        // Convert each frame to per-channel Int32 arrays. Layout
        // matches encodeModularAnimation's frames parameter: 1ch
        // grayscale, 2ch grayscale+alpha, 3ch RGB, 4ch RGBA.
        var framesChannels: [[[Int32]]] = []
        framesChannels.reserveCapacity(frames.count)
        for f in frames {
            var chans: [[Int32]] = []
            chans.reserveCapacity(colorChans + (hasAlpha ? 1 : 0))
            if bitsPerSample == 8 {
                for c in 0..<(colorChans + (hasAlpha ? 1 : 0)) {
                    var arr = [Int32](repeating: 0,
                        count: f.width * f.height)
                    let totalCh = colorChans + (hasAlpha ? 1 : 0)
                    for i in 0..<(f.width * f.height) {
                        arr[i] = Int32(f.data[i * totalCh + c])
                    }
                    chans.append(arr)
                }
            } else {
                // 16-bit: unpack pairs of bytes per channel.
                let totalCh = colorChans + (hasAlpha ? 1 : 0)
                for c in 0..<totalCh {
                    let arr = unpackUInt16(
                        from: f, channelCount: totalCh, channel: c)
                    chans.append(arr.map { Int32($0) })
                }
            }
            framesChannels.append(chans)
        }
        let cs: Data
        do {
            cs = try SpecModularEncoder.encodeModularAnimation(
                width: first.width, height: first.height,
                bitsPerSample: bitsPerSample,
                colorSpace: colorSpace, hasAlpha: hasAlpha,
                frames: framesChannels,
                durations: durations)
        } catch let e as SpecModularEncoderError {
            throw EncoderError.unsupportedFrame(
                "encodeModularAnimation: \(e)")
        } catch {
            throw EncoderError.unsupportedFrame(
                "encodeModularAnimation: \(error)")
        }
        let wrapped = options.containerWrap
            ? buildJXLContainer(codestream: cs) : cs
        let originalSize = frames.reduce(0) { $0 + $1.data.count }
        return EncodedImage(
            data: wrapped,
            stats: CompressionStats(
                originalSize: originalSize,
                compressedSize: wrapped.count,
                encodingTime: Date().timeIntervalSince(start)
            )
        )
    }

    private func wrapModular(_ body: () throws -> Data) throws -> Data {
        do { return try body() }
        catch let e as SpecModularEncoderError {
            throw EncoderError.unsupportedFrame("SpecModular: \(e)")
        } catch let e as BitstreamError {
            throw EncoderError.bitstream(e)
        } catch {
            throw EncoderError.unsupportedFrame("SpecModular: \(error)")
        }
    }

    /// Encode multiple `ImageFrame`s into a single multi-frame
    /// `.jxl` (animation). All frames must share the same
    /// dimensions and alpha presence; the encoder declares
    /// libjxl-default 100 tps timestamp resolution and writes
    /// each frame at 10 tps (= 100 ms / frame) by default. Lossy
    /// VarDCT only — Modular doesn't carry animation metadata in
    /// our writer yet.
    ///
    /// - Empty array: throws `EncoderError.unsupportedFrame`.
    /// - Single-element array: delegates to `encode(_ frame:)`.
    /// - Multi-element array: encodes each frame through
    ///   `VarDCTBitstreamWriter.encodeAnimation`, with `isLast`
    ///   flipped on the final frame only.
    public func encode(_ frames: [ImageFrame]) throws -> EncodedImage {
        switch frames.count {
        case 0:
            throw EncoderError.unsupportedFrame(
                "encode(_:) on empty frame array")
        case 1:
            return try encode(frames[0])
        default:
            break // fall through to multi-frame
        }
        let start = Date()
        if case .lossless = options.mode {
            return try encodeLosslessAnimation(
                frames: frames, start: start)
        }
        // Validate per-frame durations: must match frame count.
        let cs: Data
        do {
            let durations: [UInt32]
            if let perFrame = options.frameDurations {
                guard perFrame.count == frames.count else {
                    throw EncoderError.unsupportedFrame(
                        "EncodingOptions.frameDurations.count "
                        + "(\(perFrame.count)) ≠ frames.count "
                        + "(\(frames.count))")
                }
                durations = perFrame
            } else {
                durations = [UInt32](
                    repeating: options.defaultFrameDuration,
                    count: frames.count)
            }
            cs = try VarDCTBitstreamWriter.encodeAnimation(
                frames: frames, distance: options.distance,
                gaborish: options.gaborish,
                adaptiveQF: options.adaptiveQF,
                frameDurations: durations)
        } catch let e as VarDCTBitstreamWriter.WriterError {
            throw EncoderError.unsupportedFrame(
                "encodeAnimation: \(e)")
        } catch {
            throw EncoderError.unsupportedFrame(
                "encodeAnimation: \(error)")
        }
        let wrapped = options.containerWrap
            ? buildJXLContainer(codestream: cs) : cs
        let originalSize = frames.reduce(0) { $0 + $1.data.count }
        return EncodedImage(
            data: wrapped,
            stats: CompressionStats(
                originalSize: originalSize,
                compressedSize: wrapped.count,
                encodingTime: Date().timeIntervalSince(start)
            )
        )
    }

    /// **Phase J coefficient bridge (v0.12.0g — API stub).**
    ///
    /// Encode a JPEG decoded as quantised DCT coefficients
    /// (`JPEGCoefficientImage`, from `JPEGDecoder.decodeToCoefficients`)
    /// directly into a JXL VarDCT frame **without** running the
    /// pixel pipeline (no IDCT → re-DCT round-trip, no XYB
    /// transformation, no Gaborish / adaptive-QF pre-pass). Output
    /// JXL decodes to pixels matching the source JPEG exactly.
    ///
    /// **Status (v0.12.0ee).** Wired to the JXL bridge encoder.
    /// Delegates to `JXLBridgeEncoder.prepareFromJPEG(_:)` to build
    /// the intermediate state, then `JXLBridgeEncoder.write(state:)`
    /// to emit the codestream. Bridge errors surface as
    /// `EncoderError.unsupportedFrame` (input the bridge cannot
    /// accept) or `EncoderError.notImplemented` (a downstream step
    /// not yet covered).
    ///
    /// The bridge today supports 1- or 3-component, 4:4:4-sampled,
    /// 8-bit, baseline-DCT JPEG coefficient images. Forward bridge
    /// only — the reverse (`JXLDecoder.decodeToJPEG(_:)`) lands
    /// later, gated on a pure-Swift Brotli decompressor for the
    /// `jbrd` box that carries JPEG-side metadata.
    ///
    /// `originalSize` in the returned `CompressionStats` reports
    /// the JPEG-coefficient surface area in bytes (3 × 64 × blocks
    /// at 16 bpc), not a source-JPEG byte count — there's no
    /// source bytestream available at this entry point. Callers
    /// who need a true compression-ratio against the originating
    /// JPEG bytes should compute it externally from their own
    /// source size and the returned `data.count`.
    package func encodeFromJPEGCoefficients(
        _ jpeg: JPEGCoefficientImage
    ) throws -> EncodedImage {
        // Validate the input shape against the bridge's contract.
        // These three checks duplicate `prepareFromJPEG`'s
        // pre-validation so callers get an `EncoderError` (the
        // expected error family on this entry point) instead of
        // a `JPEGToJXLAdapterError`.
        guard jpeg.precision == 8 else {
            throw EncoderError.unsupportedFrame(
                "JPEG coefficient bridge: only 8-bit precision "
                + "supported (got \(jpeg.precision)-bit)")
        }
        // Baseline, extended-sequential, and progressive DCT frames
        // all hand off the same quantised-coefficient grids — the
        // bridge encodes the coefficients, not the entropy layout, so
        // the source scan structure is irrelevant here. Lossless
        // (SOF3) and hierarchical frames have no DCT grid to bridge.
        switch jpeg.frameKind {
        case .baselineDCT, .extendedSequential, .progressiveDCT:
            break
        default:
            throw EncoderError.unsupportedFrame(
                "JPEG coefficient bridge: only DCT frames supported "
                + "(got \(jpeg.frameKind.label))")
        }
        let nComponents = jpeg.frameComponents.count
        guard nComponents == 1 || nComponents == 3 else {
            throw EncoderError.unsupportedFrame(
                "JPEG coefficient bridge: only 1- or 3-component "
                + "frames supported (got \(nComponents))")
        }
        let start = Date()
        let state: JXLBridgeEncoderState
        do { state = try JXLBridgeEncoder.prepareFromJPEG(jpeg) }
        catch let e as JPEGToJXLAdapterError {
            throw EncoderError.unsupportedFrame(
                "JPEG coefficient bridge prepareFromJPEG: \(e)")
        }
        let bytes: Data
        do { bytes = try JXLBridgeEncoder.write(state: state) }
        catch let e as JXLBridgeEncoderError {
            // The bridge writer surfaces unimplemented downstream
            // steps as `.notImplemented`; preserve that channel.
            switch e {
            case .notImplemented(let m):
                throw EncoderError.notImplemented(
                    "JPEG coefficient bridge write: \(m)")
            }
        }
        // Approximate original-coefficient surface area: per the
        // bridge contract, 3 channels × blocks × 64 × 2 bytes
        // (16-bit signed coefficients). Grayscale uses 1 channel.
        let blockCount = state.planes.blocksX * state.planes.blocksY
        let chBytes = nComponents * blockCount * 64 * 2
        return EncodedImage(
            data: bytes,
            stats: CompressionStats(
                originalSize: chBytes,
                compressedSize: bytes.count,
                encodingTime: Date().timeIntervalSince(start)))
    }

    /// Encode a JPEG into a **lossless-JPEG JXL** — a complete ISOBMFF
    /// container (signature + `ftyp` + `jbrd` + `jxlc`) from which the
    /// source JPEG reconstructs **byte-for-byte**. Combines the forward
    /// coefficient-bridge VarDCT frame (`encodeFromJPEGCoefficients`)
    /// with `JBRDBox.extract` (the reconstruction data) and
    /// `buildJXLContainerWithReconstruction`. The reverse transcode —
    /// or `djxl --jpeg` — recovers the original JPEG exactly.
    ///
    /// Same input scope as `encodeFromJPEGCoefficients`: baseline-DCT,
    /// 8-bit, 1- or 3-component JPEGs. Progressive input is not yet
    /// supported (`decodeToCoefficients` is baseline-only).
    ///
    /// `originalSize` in the returned stats is the true source-JPEG
    /// byte count (this entry point *has* the source bytes).
    public func encodeLosslessJPEG(
        _ jpegBytes: Data
    ) throws -> EncodedImage {
        let start = Date()
        let coefs: JPEGCoefficientImage
        do { coefs = try JPEGDecoder.decodeToCoefficients(jpegBytes) }
        catch let e as JPEGDecoderError {
            throw EncoderError.unsupportedFrame(
                "lossless-JPEG bridge: \(e.errorDescription ?? "\(e)")")
        }
        let bridged = try encodeFromJPEGCoefficients(coefs)
        // Reconstruction data: jbrd Bundle bytes + (Brotli) payload.
        let box: JBRDBox
        let brotliPayload: Data
        do {
            (box, brotliPayload) = try JBRDBox.extract(
                fromJPEG: jpegBytes)
        } catch {
            throw EncoderError.notImplemented(
                "lossless-JPEG bridge jbrd extract: \(error)")
        }
        var w = BitWriter()
        do { try JBRDBoxWriter.write(box, to: &w) }
        catch {
            throw EncoderError.notImplemented(
                "lossless-JPEG bridge jbrd serialise: \(error)")
        }
        var jbrdPayload = w.finishToData()
        jbrdPayload.append(brotliPayload)
        let container = buildJXLContainerWithReconstruction(
            codestream: bridged.data, jbrdPayload: jbrdPayload)
        return EncodedImage(
            data: container,
            stats: CompressionStats(
                originalSize: jpegBytes.count,
                compressedSize: container.count,
                encodingTime: Date().timeIntervalSince(start)))
    }
}

/// Split a 3-channel interleaved uint8 `ImageFrame` into per-channel
/// row-major buffers. Operates on `frame.data` directly; one full
/// allocation per channel.
private func deinterleave2(
    frame: ImageFrame
) -> (gray: [UInt8], alpha: [UInt8]) {
    let n = frame.width * frame.height
    var gray = [UInt8](repeating: 0, count: n)
    var alpha = [UInt8](repeating: 0, count: n)
    for i in 0..<n {
        gray[i] = frame.data[i * 2 + 0]
        alpha[i] = frame.data[i * 2 + 1]
    }
    return (gray, alpha)
}

private func deinterleave3(
    frame: ImageFrame
) -> (r: [UInt8], g: [UInt8], b: [UInt8]) {
    let n = frame.width * frame.height
    var r = [UInt8](repeating: 0, count: n)
    var g = [UInt8](repeating: 0, count: n)
    var b = [UInt8](repeating: 0, count: n)
    for i in 0..<n {
        r[i] = frame.data[i * 3 + 0]
        g[i] = frame.data[i * 3 + 1]
        b[i] = frame.data[i * 3 + 2]
    }
    return (r, g, b)
}

/// Pull one `uint16` channel out of a `channelCount`-channel
/// interleaved `ImageFrame` into a `[UInt16]` buffer.
/// `ImageFrame.setPixel` stores 16-bit samples little-endian within
/// the data buffer (see ImageFrame.swift), so we reassemble each
/// sample from `(lo, hi)` here.
private func unpackUInt16(
    from frame: ImageFrame, channelCount: Int, channel: Int
) -> [UInt16] {
    let n = frame.width * frame.height
    var out = [UInt16](repeating: 0, count: n)
    for i in 0..<n {
        let base = (i * channelCount + channel) * 2
        let lo = UInt16(frame.data[base])
        let hi = UInt16(frame.data[base + 1])
        out[i] = (hi << 8) | lo
    }
    return out
}

/// `unpackUInt16` widened straight to `Int32` (the modular encoder's
/// working type) — one pass, no `[UInt16]` intermediate.
private func unpackUInt16ToInt32(
    from frame: ImageFrame, channelCount: Int, channel: Int
) -> [Int32] {
    let n = frame.width * frame.height
    var out = [Int32](repeating: 0, count: n)
    frame.data.withUnsafeBytes { raw in
        out.withUnsafeMutableBufferPointer { dst in
            for i in 0..<n {
                let base = (i * channelCount + channel) * 2
                let lo = Int32(raw[base])
                let hi = Int32(raw[base + 1])
                dst[i] = (hi << 8) | lo
            }
        }
    }
    return out
}

/// Same as `deinterleave3` for 4-channel (RGBA) input.
private func deinterleave4(
    frame: ImageFrame
) -> (r: [UInt8], g: [UInt8], b: [UInt8], a: [UInt8]) {
    let n = frame.width * frame.height
    var r = [UInt8](repeating: 0, count: n)
    var g = [UInt8](repeating: 0, count: n)
    var b = [UInt8](repeating: 0, count: n)
    var a = [UInt8](repeating: 0, count: n)
    for i in 0..<n {
        r[i] = frame.data[i * 4 + 0]
        g[i] = frame.data[i * 4 + 1]
        b[i] = frame.data[i * 4 + 2]
        a[i] = frame.data[i * 4 + 3]
    }
    return (r, g, b, a)
}
