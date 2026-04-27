// JPEG XL decoder: thin Swift wrapper around the libjxl C API.

import Foundation
import Cjxl

public enum DecoderError: Error, LocalizedError {
    case libjxlSetup(String)
    case libjxlDecode(String)
    case unexpectedStatus(JxlDecoderStatus)
    case missingBasicInfo

    public var errorDescription: String? {
        switch self {
        case .libjxlSetup(let m):     return "libjxl setup failed: \(m)"
        case .libjxlDecode(let m):    return "libjxl decode failed: \(m)"
        case .unexpectedStatus(let s): return "libjxl unexpected status: \(s.rawValue)"
        case .missingBasicInfo:       return "libjxl never produced basic info"
        }
    }
}

public final class JXLDecoder {
    public init() {}

    /// Decode a JPEG XL byte stream into an `ImageFrame`. For multi-frame
    /// bitstreams this returns the first frame; use `decodeAll(_:)` to get
    /// every frame.
    public func decode(_ data: Data) throws -> ImageFrame {
        let frames = try decodeAll(data)
        guard let first = frames.first else {
            throw DecoderError.libjxlDecode("decoder produced no frames")
        }
        return first
    }

    /// Decode every frame of a (possibly multi-frame) JPEG XL bitstream.
    /// Single-frame files return a 1-element array.
    public func decodeAll(_ data: Data) throws -> [ImageFrame] {
        guard let dec = JxlDecoderCreate(nil) else {
            throw DecoderError.libjxlSetup("JxlDecoderCreate returned NULL")
        }
        defer { JxlDecoderDestroy(dec) }

        // Threaded runner.
        let workerCount = JxlThreadParallelRunnerDefaultNumWorkerThreads()
        guard let runner = JxlThreadParallelRunnerCreate(nil, workerCount) else {
            throw DecoderError.libjxlSetup("JxlThreadParallelRunnerCreate")
        }
        defer { JxlThreadParallelRunnerDestroy(runner) }

        if JxlDecoderSetParallelRunner(dec, JxlThreadParallelRunner, runner) != JXL_DEC_SUCCESS {
            throw DecoderError.libjxlSetup("JxlDecoderSetParallelRunner")
        }

        let events = JXL_DEC_BASIC_INFO.rawValue
                   | JXL_DEC_COLOR_ENCODING.rawValue
                   | JXL_DEC_FULL_IMAGE.rawValue
        if JxlDecoderSubscribeEvents(dec, Int32(events)) != JXL_DEC_SUCCESS {
            throw DecoderError.libjxlSetup("JxlDecoderSubscribeEvents")
        }

        // Feed the input buffer to libjxl.
        let setStatus = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> JxlDecoderStatus in
            guard let base = raw.baseAddress else { return JXL_DEC_ERROR }
            return JxlDecoderSetInput(dec, base.assumingMemoryBound(to: UInt8.self), data.count)
        }
        if setStatus != JXL_DEC_SUCCESS {
            throw DecoderError.libjxlDecode("JxlDecoderSetInput")
        }
        JxlDecoderCloseInput(dec)

        // State machine. We collect a list of decoded frames; each
        // JXL_DEC_NEED_IMAGE_OUT_BUFFER + JXL_DEC_FULL_IMAGE pair yields
        // one frame.
        var basicInfo: JxlBasicInfo?
        var icc: Data?
        var pendingPixels: [UInt8] = []
        var pixelType: PixelType = .uint8
        var channels: Int = 0
        var collected: [ImageFrame] = []

        loop: while true {
            let status = JxlDecoderProcessInput(dec)
            switch status {
            case JXL_DEC_BASIC_INFO:
                var info = JxlBasicInfo()
                if JxlDecoderGetBasicInfo(dec, &info) != JXL_DEC_SUCCESS {
                    throw DecoderError.libjxlDecode("JxlDecoderGetBasicInfo")
                }
                basicInfo = info
                channels = Int(info.num_color_channels) + (info.alpha_bits > 0 ? 1 : 0)
                if info.exponent_bits_per_sample > 0 {
                    pixelType = .float32
                } else if info.bits_per_sample > 8 {
                    pixelType = .uint16
                } else {
                    pixelType = .uint8
                }

            case JXL_DEC_COLOR_ENCODING:
                var iccSize: Int = 0
                if JxlDecoderGetICCProfileSize(dec, JXL_COLOR_PROFILE_TARGET_DATA, &iccSize) == JXL_DEC_SUCCESS,
                   iccSize > 0 {
                    var buf = [UInt8](repeating: 0, count: iccSize)
                    let got = buf.withUnsafeMutableBufferPointer { mp -> JxlDecoderStatus in
                        JxlDecoderGetColorAsICCProfile(dec, JXL_COLOR_PROFILE_TARGET_DATA, mp.baseAddress, iccSize)
                    }
                    if got == JXL_DEC_SUCCESS { icc = Data(buf) }
                }

            case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                guard basicInfo != nil else { throw DecoderError.missingBasicInfo }
                let format = JxlPixelFormat(
                    num_channels: UInt32(channels),
                    data_type: cdataType(for: pixelType),
                    endianness: JXL_NATIVE_ENDIAN,
                    align: 0
                )
                var size: Int = 0
                var fmt = format
                if JxlDecoderImageOutBufferSize(dec, &fmt, &size) != JXL_DEC_SUCCESS {
                    throw DecoderError.libjxlDecode("JxlDecoderImageOutBufferSize")
                }
                pendingPixels = [UInt8](repeating: 0, count: size)
                let setOut = pendingPixels.withUnsafeMutableBufferPointer { buf -> JxlDecoderStatus in
                    var f = format
                    return JxlDecoderSetImageOutBuffer(dec, &f, buf.baseAddress, size)
                }
                if setOut != JXL_DEC_SUCCESS {
                    throw DecoderError.libjxlDecode("JxlDecoderSetImageOutBuffer")
                }

            case JXL_DEC_FULL_IMAGE:
                // Capture the just-decoded frame and continue (more frames
                // may follow for multi-frame bitstreams).
                guard let info = basicInfo else { throw DecoderError.missingBasicInfo }
                let cs: ColorSpace = (info.num_color_channels == 1) ? .grayscale : .sRGB
                var frame = ImageFrame(
                    width: Int(info.xsize),
                    height: Int(info.ysize),
                    channels: channels,
                    pixelType: pixelType,
                    colorSpace: cs,
                    alphaChannels: info.alpha_bits > 0 ? 1 : 0,
                    iccProfile: icc
                )
                frame.data = pendingPixels
                collected.append(frame)
                pendingPixels = []

            case JXL_DEC_SUCCESS:
                break loop

            case JXL_DEC_ERROR:
                throw DecoderError.libjxlDecode("JxlDecoderProcessInput returned ERROR")

            case JXL_DEC_NEED_MORE_INPUT:
                throw DecoderError.libjxlDecode("truncated bitstream")

            default:
                throw DecoderError.unexpectedStatus(status)
            }
        }

        guard !collected.isEmpty else { throw DecoderError.libjxlDecode("decoder produced no frames") }
        return collected
    }
}

@inline(__always)
private func cdataType(for pixelType: PixelType) -> JxlDataType {
    switch pixelType {
    case .uint8:   return JXL_TYPE_UINT8
    case .uint16:  return JXL_TYPE_UINT16
    case .float32: return JXL_TYPE_FLOAT
    }
}
