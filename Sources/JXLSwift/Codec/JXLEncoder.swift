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
            return "JXLEncoder: \(path) is not yet implemented in pure Swift. " +
                   "See ROADMAP.md for status; or use the libjxl-backend branch."
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
                        encodingTime: Date().timeIntervalSince(start)
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
                    pixels: frame.data
                )
            }
        case (.uint16, 1, 0):
            let pixels = unpackUInt16(from: frame, channelCount: 1, channel: 0)
            bytes = try wrapModular {
                try SpecModularEncoder.encodeGrayscale16(
                    width: frame.width, height: frame.height,
                    pixels: pixels
                )
            }
        case (.uint8, 3, 0):
            let (r, g, b) = deinterleave3(frame: frame)
            bytes = try wrapModular {
                try SpecModularEncoder.encodeRGB8(
                    width: frame.width, height: frame.height,
                    r: r, g: g, b: b
                )
            }
        case (.uint16, 3, 0):
            let r = unpackUInt16(from: frame, channelCount: 3, channel: 0)
            let g = unpackUInt16(from: frame, channelCount: 3, channel: 1)
            let b = unpackUInt16(from: frame, channelCount: 3, channel: 2)
            bytes = try wrapModular {
                try SpecModularEncoder.encodeRGB16(
                    width: frame.width, height: frame.height,
                    r: r, g: g, b: b
                )
            }
        case (.uint8, 4, 1):
            let (r, g, b, a) = deinterleave4(frame: frame)
            bytes = try wrapModular {
                try SpecModularEncoder.encodeRGBA8(
                    width: frame.width, height: frame.height,
                    r: r, g: g, b: b, a: a
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
                    r: r, g: g, b: b, a: a
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
        guard first.pixelType == .uint8 else {
            throw EncoderError.notImplemented(
                "multi-frame lossless for \(first.pixelType) — "
                + "only .uint8 RGB/RGBA supported in animation")
        }
        let hasAlpha: Bool
        switch first.channels {
        case 3:
            hasAlpha = false
        case 4:
            hasAlpha = true
        default:
            throw EncoderError.notImplemented(
                "multi-frame lossless for "
                + "\(first.channels) channels — only RGB / RGBA "
                + "supported in animation")
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
        // Convert each frame to [r, g, b]/[r, g, b, a] Int32 arrays.
        var framesChannels: [[[Int32]]] = []
        framesChannels.reserveCapacity(frames.count)
        for f in frames {
            if hasAlpha {
                let (r, g, b, a) = deinterleave4(frame: f)
                framesChannels.append([
                    r.map { Int32($0) }, g.map { Int32($0) },
                    b.map { Int32($0) }, a.map { Int32($0) },
                ])
            } else {
                let (r, g, b) = deinterleave3(frame: f)
                framesChannels.append([
                    r.map { Int32($0) }, g.map { Int32($0) },
                    b.map { Int32($0) },
                ])
            }
        }
        let cs: Data
        do {
            cs = try SpecModularEncoder.encodeModularAnimation8(
                width: first.width, height: first.height,
                hasAlpha: hasAlpha,
                frames: framesChannels,
                durations: durations)
        } catch let e as SpecModularEncoderError {
            throw EncoderError.unsupportedFrame(
                "encodeModularAnimation8: \(e)")
        } catch {
            throw EncoderError.unsupportedFrame(
                "encodeModularAnimation8: \(error)")
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
}

/// Split a 3-channel interleaved uint8 `ImageFrame` into per-channel
/// row-major buffers. Operates on `frame.data` directly; one full
/// allocation per channel.
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
