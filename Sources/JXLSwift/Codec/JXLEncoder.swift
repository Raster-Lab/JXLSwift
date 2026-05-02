// JXLEncoder — pure-Swift JPEG XL encoder.
//
// STATUS: lossless Modular path is wired up for 8-bit and 16-bit
// integer samples (single channel grayscale, RGB, RGBA), single-pass,
// any size up to the encoder's 8K cap. Output round-trips through
// `djxl 0.11.2`. VarDCT (lossy) is still pending; calling
// `encode(_:)` with a `float32` frame throws `EncoderError.notImplemented`.
//
// Routing: `encode(_:)` deinterleaves the caller's
// channel-interleaved `ImageFrame.data` into per-channel `[UInt8]`
// (or `[UInt16]`) buffers and dispatches into `SpecModularEncoder`'s
// 8-bit/16-bit, grayscale/RGB/RGBA paths. `EncodingOptions.
// useM0Placeholder` still routes to the legacy M0 vertical slice
// for benchmark continuity.
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
    /// `MinimalLosslessCodec` (the legacy M0 vertical slice).
    /// Otherwise dispatches into `SpecModularEncoder` based on the
    /// frame's `pixelType`, `channels`, and `alphaChannels` —
    /// produces a real spec-compliant codestream `djxl` can decode.
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

    /// Encode multiple frames as a multi-frame .jxl. **Not yet implemented.**
    public func encode(_ frames: [ImageFrame]) throws -> EncodedImage {
        throw EncoderError.notImplemented("multi-frame encoding")
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
