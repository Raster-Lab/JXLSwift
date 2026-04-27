// MinimalLosslessCodec — Phase M0 vertical slice.
//
// **Status: project-internal.** This file exists to prove that the
// entropy-primitive layer can encode real pixel data end-to-end and
// round-trip it back losslessly. It is **not** a JPEG-XL-spec-
// compliant file format. The actual JXL frame header (§C.8.1) and
// Modular sub-codec (§C.7) are still ahead — implementing those is
// the next milestone after this.
//
// What this proves:
//   • The bitstream + integer-coding layer can pack a real header.
//   • `SimpleEntropyStream` correctly encodes an arbitrary `[UInt32]`
//     stream of pixel values into bytes.
//   • The decoder recovers the exact same pixel values.
//
// Buffer layout:
//
//     signature           u(16)        // "FF 0A" (spec — also used by the real codestream)
//     SizeHeader                       // §C.3.2 (spec)
//     ImageMetadata                    // §C.3.3 (spec)
//     'M0' marker         u(16)        // 0x4D30, makes the placeholder explicit
//     SimpleEntropyStream              // pixel-value stream
//     align to byte
//
// The 'M0' marker exists so the future spec-compliant decoder can
// distinguish a placeholder buffer from a real codestream and refuse
// to silently treat one as the other. When the real frame header
// lands, this file should either be deleted or kept as a
// regression-test fixture.
//
// Pixel encoding strategy (lossless):
//   • Pixel values are treated as `UInt32` and fed into the
//     `SimpleEntropyStream` together with the default
//     `HybridUintConfig` (split=4, msb=2, lsb=0). The HybridUint layer
//     compresses each value to a small token (alphabet bounded by
//     `HybridUintConfig.defaultConfig.maxToken + 1` — 128 in this
//     setup) plus zero or more extra bits, so the rANS alphabet stays
//     small regardless of the input bit depth. This is the standard
//     JXL lossless-Modular pattern: small fixed-alphabet entropy
//     coder + per-token extra-bits dispatch.
//   • Uint8 and uint16 (up to 32-bit values, really) all flow through
//     the same alphabet. Float32 is not supported by M0.
//
// This is intentionally simple — no prediction, no MA-tree, no
// squeeze. Compression ratio is poor but lossless.

import Foundation

public enum MinimalLosslessError: Error, Sendable {
    case unsupportedPixelType
    case missingSignature
    case missingMarker
    case truncated
    case bitstream(BitstreamError)
    case container(ContainerError)
    case entropyStream(SimpleEntropyStreamError)
    case anscode(ANSError)
    case ansdist(ANSDistributionFormatError)
}

public struct MinimalLosslessCodec {

    /// Marker constant: 'M' '0' = 0x4D, 0x30 — placed in the header so
    /// a future spec-compliant decoder can recognise this is *not* a
    /// real JXL codestream.
    public static let placeholderMarker: UInt32 = 0x4D30

    /// Encode a frame to the M0 placeholder buffer format. Throws
    /// `unsupportedPixelType` for `.float32` (not yet supported by M0).
    public static func encode(_ frame: ImageFrame) throws -> Data {
        guard frame.pixelType == .uint8 || frame.pixelType == .uint16 else {
            throw MinimalLosslessError.unsupportedPixelType
        }

        // 1. JXL signature (spec — `FF 0A`).
        var w = BitWriter()
        w.write(bits: 8, value: 0xFF)
        w.write(bits: 8, value: 0x0A)

        // 2. SizeHeader.
        let size = SizeHeader(xsize: UInt32(frame.width),
                              ysize: UInt32(frame.height))
        do { try size.write(to: &w) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }

        // 3. ImageMetadata.
        let bd = BitDepth(
            floatingPoint: false,
            bitsPerSample: UInt32(frame.pixelType.bitsPerSample)
        )
        let meta = ImageMetadata(
            allDefault: false,
            orientation: 1,
            intrinsicSize: nil,
            preview: nil,
            animation: nil,
            bitDepth: bd,
            modular16BitBufferSufficient: frame.pixelType == .uint8 || frame.pixelType == .uint16,
            extraChannels: [],
            xybEncoded: false,
            colorEncoding: ColorEncoding.grayscaleD65,
            intensityTarget: 255.0,
            minNits: 0.0,
            relativeToMaxDisplay: false,
            linearBelow: 0.0
        )
        do { try meta.write(to: &w) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }

        // 4. Placeholder marker. Align before writing so the marker
        // sits on a byte boundary — this lets external tools (and our
        // tests) find it by scanning the buffer for the literal bytes.
        w.alignToByte()
        w.write(bits: 16, value: placeholderMarker)

        // 5. Pixel stream. Convert ImageFrame samples to a flat
        // [UInt32] in row-major channel-interleaved order. Alphabet is
        // sized to `HybridUintConfig.defaultConfig.maxToken + 1`, not
        // to the value range — the HybridUint layer compresses values
        // to small tokens + extra bits.
        let values = pixelStream(from: frame)
        let alphabetSize = HybridUintConfig.defaultConfig.maxToken + 1
        // Build a flat distribution (we don't yet have full-mode
        // distribution serialisation — see Phase E4b-full).
        var distBits = BitWriter()
        do { try ANSDistributionFormat.encodeFlat(alphabetSize: alphabetSize, to: &distBits) }
        catch let e as ANSDistributionFormatError {
            throw MinimalLosslessError.ansdist(e)
        }
        var distReader = BitReader(distBits.finishToData())
        let dist: ANSDistribution
        do { dist = try ANSDistributionFormat.decode(
            alphabetSize: alphabetSize, from: &distReader
        ) }
        catch let e as ANSDistributionFormatError {
            throw MinimalLosslessError.ansdist(e)
        }
        let ctx = SimpleEntropyContext(
            alphabetSize: alphabetSize,
            hybridConfig: HybridUintConfig.defaultConfig,
            distribution: dist
        )
        let streamData: Data
        do {
            streamData = try SimpleEntropyStream.encode(
                values: values, context: ctx, shape: .flat
            )
        } catch let e as SimpleEntropyStreamError {
            throw MinimalLosslessError.entropyStream(e)
        }

        var out = w.finishToData()
        out.append(streamData)
        return out
    }

    /// Decode an M0 placeholder buffer produced by `encode(_:)`.
    public static func decode(_ data: Data) throws -> ImageFrame {
        var r = BitReader(data)
        // 1. Signature.
        let sig0: UInt32
        let sig1: UInt32
        do {
            sig0 = try r.read(bits: 8)
            sig1 = try r.read(bits: 8)
        } catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        guard sig0 == 0xFF && sig1 == 0x0A else {
            throw MinimalLosslessError.missingSignature
        }
        // 2. SizeHeader.
        let size: SizeHeader
        do { size = try SizeHeader.read(from: &r) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        // 3. ImageMetadata.
        let meta: ImageMetadata
        do { meta = try ImageMetadata.read(from: &r) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        // 4. Marker — encoder aligned-then-wrote, so we align-then-read.
        do { try r.alignToByte() }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        let marker: UInt32
        do { marker = try r.read(bits: 16) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        guard marker == placeholderMarker else {
            throw MinimalLosslessError.missingMarker
        }
        // 5. Pixel stream — slice out the remaining bytes.
        let bytePosition = r.position / 8
        let streamSlice = data.subdata(
            in: (data.startIndex + bytePosition)..<data.endIndex
        )
        let values: [UInt32]
        do {
            values = try SimpleEntropyStream.decode(streamSlice)
        } catch let e as SimpleEntropyStreamError {
            throw MinimalLosslessError.entropyStream(e)
        }

        // Reconstruct ImageFrame.
        let pixelType: PixelType =
            meta.bitDepth.bitsPerSample == 8 ? .uint8 :
            (meta.bitDepth.floatingPoint ? .float32 : .uint16)
        guard pixelType != .float32 else {
            throw MinimalLosslessError.unsupportedPixelType
        }
        // Channels: in M0 we only encode the colour channels; alpha and
        // extra channels aren't carried.
        let channels = (meta.colorEncoding.colorSpace == .grayscale) ? 1 : 3
        var frame = ImageFrame(
            width: Int(size.xsize),
            height: Int(size.ysize),
            channels: channels,
            pixelType: pixelType,
            colorSpace: pixelType == .uint8 ? .sRGB : .grayscale,
            alphaChannels: 0,
            iccProfile: nil
        )
        writePixelStream(values: values, into: &frame)
        return frame
    }

    // MARK: - Pixel ↔ value-stream conversion

    private static func pixelStream(from frame: ImageFrame) -> [UInt32] {
        let n = frame.width * frame.height * frame.channels
        var out = [UInt32](); out.reserveCapacity(n)
        let bps = frame.pixelType.bytesPerSample
        for i in 0..<n {
            switch bps {
            case 1:
                out.append(UInt32(frame.data[i]))
            case 2:
                let lo = UInt32(frame.data[i * 2])
                let hi = UInt32(frame.data[i * 2 + 1])
                out.append((hi << 8) | lo)
            default:
                out.append(0)   // unsupported; encoder rejected upstream
            }
        }
        return out
    }

    private static func writePixelStream(
        values: [UInt32], into frame: inout ImageFrame
    ) {
        let bps = frame.pixelType.bytesPerSample
        for (i, v) in values.enumerated() {
            switch bps {
            case 1:
                frame.data[i] = UInt8(v & 0xFF)
            case 2:
                frame.data[i * 2]     = UInt8(v & 0xFF)
                frame.data[i * 2 + 1] = UInt8((v >> 8) & 0xFF)
            default:
                break
            }
        }
    }
}

