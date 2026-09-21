// Shared-storage seam for the contract module.
//
// `package` rather than `public`: JXLSwiftContract needs these, nothing
// outside the package does, and JXLSwift's public API is unchanged.
//
// The codec-touching work lives here, where it can reach the Modular encoder
// and decoder. The contract module owns descriptors, owners and lifecycles
// and never sees a codec internal. Caller memory arrives as a buffer borrowed
// for one synchronous call; it is never stored and never crosses an `await`.

import Foundation

/// Row-span walk over a caller plane. `flat` reproduces the packed behaviour
/// exactly, so the shipped paths are unchanged by the refactor.
struct JXLPlaneLayout {
    var spanCount: Int
    var spanSamples: Int
    var spanStrideBytes: Int

    static func flat(sampleCount: Int) -> JXLPlaneLayout {
        JXLPlaneLayout(spanCount: 1, spanSamples: sampleCount, spanStrideBytes: 0)
    }

    static func strided(width: Int, height: Int, rowBytes: Int, bytesPerPixel: Int) -> JXLPlaneLayout {
        rowBytes == width * bytesPerPixel
            ? .flat(sampleCount: width * height)
            : JXLPlaneLayout(spanCount: height, spanSamples: width, spanStrideBytes: rowBytes)
    }

    @inline(__always)
    func forEachRun(_ body: (_ sampleOffset: Int, _ byteOffset: Int, _ count: Int) -> Void) {
        var s = 0
        for span in 0..<spanCount {
            body(s, span * spanStrideBytes, spanSamples)
            s += spanSamples
        }
    }
}

/// Widen little-endian 16-bit samples into the Modular encoder's working
/// buffer. The encoder's whole dependence on caller sample memory for the
/// shared profile; `unpackUInt16ToInt32` calls it with a packed frame, the
/// shared path with the caller's plane. Padding beyond the row payload is
/// never read, so it cannot reach the codestream.
@inline(__always)
func jxlReadUInt16Samples(
    from src: UnsafeRawBufferPointer,
    into dst: UnsafeMutableBufferPointer<Int32>,
    layout: JXLPlaneLayout,
    channelCount: Int,
    channel: Int
) {
    guard let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self),
          let d = dst.baseAddress else { return }
    layout.forEachRun { sampleOffset, byteOffset, count in
        for i in 0..<count {
            let b = byteOffset &+ ((i &* channelCount) &+ channel) &* 2
            d[sampleOffset &+ i] = Int32(UInt16(s[b]) | (UInt16(s[b &+ 1]) << 8))
        }
    }
}

/// Write clamped samples for one channel into an interleaved destination.
/// `assembleImageFrame` calls it with the frame's own buffer and a packed row
/// layout; the shared path with the caller's plane and their row stride.
@inline(__always)
func jxlWriteChannelSamples(
    from src: UnsafeBufferPointer<Int32>,
    into dst: UnsafeMutableRawBufferPointer,
    layout: JXLPlaneLayout,
    byteOffsetInPixel: Int,
    pixelStrideBytes: Int,
    bytesPerSample: Int,
    sampleMax: UInt32
) {
    guard let s = src.baseAddress,
          let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
    layout.forEachRun { sampleOffset, byteOffset, count in
        var o = byteOffset &+ byteOffsetInPixel
        if bytesPerSample == 1 {
            for i in 0..<count {
                d[o] = UInt8(min(UInt32(max(0, s[sampleOffset &+ i])), sampleMax))
                o &+= pixelStrideBytes
            }
        } else {
            for i in 0..<count {
                let v = min(UInt32(max(0, s[sampleOffset &+ i])), sampleMax)
                d[o] = UInt8(v & 0xff)
                d[o &+ 1] = UInt8((v >> 8) & 0xff)
                o &+= pixelStrideBytes
            }
        }
    }
}

// MARK: - Package seam

/// What a decode would produce, without decoding.
package struct JXLSharedInspection: Sendable {
    package let width: Int
    package let height: Int
    package let bitsPerSample: Int
    package let isGreyscale: Bool
    package let isModular: Bool
    package let extraChannelCount: Int
}

package enum JXLSharedPlaneError: Error, Sendable {
    case notSupported(String)
    case malformed(String)
}

extension JXLDecoder {
    /// Describe the output layout, without decoding.
    package func sharedInspect(_ data: Data) throws -> JXLSharedInspection {
        let inspection = try inspect(data)
        guard let metadata = inspection.metadata else {
            throw JXLSharedPlaneError.malformed("codestream headers could not be read")
        }
        return JXLSharedInspection(
            width: Int(inspection.xsize), height: Int(inspection.ysize),
            bitsPerSample: Int(metadata.bitDepth.bitsPerSample),
            isGreyscale: metadata.colorEncoding.colorSpace == .grayscale
                && !metadata.bitDepth.floatingPoint,
            isModular: inspectFrameStructure(data).encoding != FrameEncoding.varDCT,
            extraChannelCount: metadata.extraChannels.count)
    }

    /// Decode a lossless 16-bit greyscale codestream into `plane`.
    ///
    /// Stops before `assembleImageFrame` and writes the Modular channel
    /// samples straight into the caller's buffer. Routing through `decode(_:)`
    /// would build a full `ImageFrame` and copy it in, which is the hidden
    /// shortcut MEM-10 names.
    package func decodeGreyscale16(
        _ data: Data, into plane: UnsafeMutableRawBufferPointer, rowBytes: Int
    ) throws {
        let info = try sharedInspect(data)
        guard info.isGreyscale else {
            throw JXLSharedPlaneError.notSupported("shared decode is single-channel greyscale")
        }
        guard info.bitsPerSample > 8, info.bitsPerSample <= 16 else {
            throw JXLSharedPlaneError.notSupported(
                "shared profile is 16-bit storage; codestream is \(info.bitsPerSample)-bit")
        }
        guard info.isModular else {
            throw JXLSharedPlaneError.notSupported(
                "shared decode covers the lossless Modular path; this frame is VarDCT")
        }
        guard info.extraChannelCount == 0 else {
            throw JXLSharedPlaneError.notSupported(
                "shared decode is one plane; codestream has \(info.extraChannelCount) extra channel(s)")
        }
        let modular = try decodeModular(data)
        guard let channel = modular.channels.first,
              channel.pixels.count >= info.width * info.height else {
            throw JXLSharedPlaneError.malformed("decoded plane is shorter than the declared frame")
        }
        let needed = (info.height - 1) * rowBytes + info.width * 2
        guard plane.count >= needed else {
            throw JXLSharedPlaneError.malformed(
                "destination holds \(plane.count) bytes; the layout needs \(needed)")
        }
        let sampleMax = UInt32((1 << info.bitsPerSample) - 1)
        channel.pixels.withUnsafeBufferPointer { src in
            jxlWriteChannelSamples(
                from: src, into: plane,
                layout: .strided(width: info.width, height: info.height,
                                 rowBytes: rowBytes, bytesPerPixel: 2),
                byteOffsetInPixel: 0, pixelStrideBytes: 2,
                bytesPerSample: 2, sampleMax: sampleMax)
        }
    }
}

extension JXLEncoder {
    /// Encode a lossless 16-bit greyscale frame reading samples out of `plane`.
    ///
    /// The caller never builds an `ImageFrame.data` array, so the copy that
    /// construction would force never happens.
    package func encodeGreyscale16(
        from plane: UnsafeRawBufferPointer, width: Int, height: Int, rowBytes: Int
    ) throws -> Data {
        let needed = (height - 1) * rowBytes + width * 2
        guard plane.count >= needed else {
            throw JXLSharedPlaneError.malformed(
                "source holds \(plane.count) bytes; the layout needs \(needed)")
        }
        var pixels = [Int32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBufferPointer { dst in
            jxlReadUInt16Samples(
                from: plane, into: dst,
                layout: .strided(width: width, height: height, rowBytes: rowBytes, bytesPerPixel: 2),
                channelCount: 1, channel: 0)
        }
        let codestream = try SpecModularEncoder.encodeGrayscale16(
            width: width, height: height,
            pixelsInt32: pixels, effort: options.effort.rawValue)
        // Same container decision as `encode(_:)`. Skipping it emits a naked
        // codestream forty bytes shorter than the ordinary path.
        return options.containerWrap ? buildJXLContainer(codestream: codestream) : codestream
    }

    /// The workspace the shared encode owns, for MEM-10's stated bound: the
    /// Modular encoder's Int32 working buffer, four bytes per sample.
    package static func greyscale16WorkspaceBytes(width: Int, height: Int) -> Int {
        width * height * MemoryLayout<Int32>.size
    }
}
