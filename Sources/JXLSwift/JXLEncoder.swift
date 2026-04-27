// JPEG XL encoder: thin Swift wrapper around the libjxl C API.

import Foundation
import Cjxl

public enum EncoderError: Error, LocalizedError {
    case libjxlSetup(String)
    case libjxlEncode(String)
    case unsupportedFrame(String)

    public var errorDescription: String? {
        switch self {
        case .libjxlSetup(let m):  return "libjxl setup failed: \(m)"
        case .libjxlEncode(let m): return "libjxl encode failed: \(m)"
        case .unsupportedFrame(let m): return "unsupported frame: \(m)"
        }
    }
}

public final class JXLEncoder {
    public var options: EncodingOptions

    public init(options: EncodingOptions = EncodingOptions()) {
        self.options = options
    }

    /// Encode a single frame to JPEG XL.
    public func encode(_ frame: ImageFrame) throws -> EncodedImage {
        let start = Date()
        let bytes = try encodeRaw(frame: frame)
        let stats = CompressionStats(
            originalSize: frame.data.count,
            compressedSize: bytes.count,
            encodingTime: Date().timeIntervalSince(start)
        )
        return EncodedImage(data: bytes, stats: stats)
    }

    // MARK: - Internal

    private func encodeRaw(frame: ImageFrame) throws -> Data {
        guard let encoder = JxlEncoderCreate(nil) else {
            throw EncoderError.libjxlSetup("JxlEncoderCreate returned NULL")
        }
        defer { JxlEncoderDestroy(encoder) }

        // Parallel runner — spin up N threads (0 lets libjxl pick a default).
        let threads: Int = options.numThreads > 0
            ? options.numThreads
            : Int(JxlThreadParallelRunnerDefaultNumWorkerThreads())
        guard let runner = JxlThreadParallelRunnerCreate(nil, size_t(threads)) else {
            throw EncoderError.libjxlSetup("JxlThreadParallelRunnerCreate returned NULL")
        }
        defer { JxlThreadParallelRunnerDestroy(runner) }

        if JxlEncoderSetParallelRunner(encoder, JxlThreadParallelRunner, runner) != JXL_ENC_SUCCESS {
            throw EncoderError.libjxlSetup("JxlEncoderSetParallelRunner")
        }

        // Basic image metadata.
        var basicInfo = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&basicInfo)
        basicInfo.xsize = UInt32(frame.width)
        basicInfo.ysize = UInt32(frame.height)
        basicInfo.bits_per_sample = UInt32(frame.pixelType.bitsPerSample)
        basicInfo.exponent_bits_per_sample = (frame.pixelType == .float32) ? 8 : 0
        basicInfo.uses_original_profile = (options.mode == .lossless) ? 1 : 0
        basicInfo.num_color_channels = UInt32(frame.channels - frame.alphaChannels)
        basicInfo.num_extra_channels = UInt32(frame.alphaChannels)
        if frame.alphaChannels > 0 {
            basicInfo.alpha_bits = UInt32(frame.pixelType.bitsPerSample)
            basicInfo.alpha_exponent_bits = (frame.pixelType == .float32) ? 8 : 0
        }

        if JxlEncoderSetBasicInfo(encoder, &basicInfo) != JXL_ENC_SUCCESS {
            throw EncoderError.libjxlSetup("JxlEncoderSetBasicInfo")
        }

        // Colour encoding: either an embedded ICC profile or one of the named spaces.
        if let icc = frame.iccProfile {
            let ok = icc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> JxlEncoderStatus in
                guard let base = raw.baseAddress else { return JXL_ENC_ERROR }
                return JxlEncoderSetICCProfile(encoder, base.assumingMemoryBound(to: UInt8.self), icc.count)
            }
            if ok != JXL_ENC_SUCCESS {
                throw EncoderError.libjxlSetup("JxlEncoderSetICCProfile")
            }
        } else {
            var color = JxlColorEncoding()
            switch frame.colorSpace {
            case .grayscale:
                JxlColorEncodingSetToSRGB(&color, /*is_gray=*/1)
            case .sRGB:
                JxlColorEncodingSetToSRGB(&color, /*is_gray=*/0)
            case .linearRGB:
                JxlColorEncodingSetToLinearSRGB(&color, /*is_gray=*/0)
            case .displayP3:
                color.color_space = JXL_COLOR_SPACE_RGB
                color.white_point = JXL_WHITE_POINT_D65
                color.primaries = JXL_PRIMARIES_P3
                color.transfer_function = JXL_TRANSFER_FUNCTION_SRGB
                color.rendering_intent = JXL_RENDERING_INTENT_PERCEPTUAL
            case .rec2020:
                color.color_space = JXL_COLOR_SPACE_RGB
                color.white_point = JXL_WHITE_POINT_D65
                color.primaries = JXL_PRIMARIES_2100
                color.transfer_function = JXL_TRANSFER_FUNCTION_SRGB
                color.rendering_intent = JXL_RENDERING_INTENT_PERCEPTUAL
            }
            if JxlEncoderSetColorEncoding(encoder, &color) != JXL_ENC_SUCCESS {
                throw EncoderError.libjxlSetup("JxlEncoderSetColorEncoding")
            }
        }

        // Per-frame settings: distance + effort.
        guard let frameSettings = JxlEncoderFrameSettingsCreate(encoder, nil) else {
            throw EncoderError.libjxlSetup("JxlEncoderFrameSettingsCreate")
        }

        let distance = options.distance
        if options.mode == .lossless {
            if JxlEncoderSetFrameLossless(frameSettings, JXL_TRUE) != JXL_ENC_SUCCESS {
                throw EncoderError.libjxlSetup("JxlEncoderSetFrameLossless")
            }
        } else {
            if JxlEncoderSetFrameDistance(frameSettings, distance) != JXL_ENC_SUCCESS {
                throw EncoderError.libjxlSetup("JxlEncoderSetFrameDistance(\(distance))")
            }
        }

        if JxlEncoderFrameSettingsSetOption(
            frameSettings,
            JXL_ENC_FRAME_SETTING_EFFORT,
            Int64(options.effort.rawValue)
        ) != JXL_ENC_SUCCESS {
            throw EncoderError.libjxlSetup("JxlEncoderFrameSettingsSetOption(EFFORT)")
        }

        if options.progressive {
            // Enable progressive DC reconstruction.
            _ = JxlEncoderFrameSettingsSetOption(
                frameSettings,
                JXL_ENC_FRAME_SETTING_PROGRESSIVE_DC,
                1
            )
        }

        // Pixel format describing the input buffer layout.
        let format = JxlPixelFormat(
            num_channels: UInt32(frame.channels),
            data_type: dataType(for: frame.pixelType),
            endianness: JXL_NATIVE_ENDIAN,
            align: 0
        )

        let addStatus = frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> JxlEncoderStatus in
            guard let base = raw.baseAddress else { return JXL_ENC_ERROR }
            var fmt = format
            return JxlEncoderAddImageFrame(frameSettings, &fmt, base, frame.data.count)
        }
        if addStatus != JXL_ENC_SUCCESS {
            throw EncoderError.libjxlEncode("JxlEncoderAddImageFrame")
        }
        JxlEncoderCloseInput(encoder)

        // Drain output buffer.
        var compressed = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let processStatus: JxlEncoderStatus = chunk.withUnsafeMutableBufferPointer { buf in
                var nextOut: UnsafeMutablePointer<UInt8>? = buf.baseAddress
                var avail = buf.count
                let s = JxlEncoderProcessOutput(encoder, &nextOut, &avail)
                let written = buf.count - avail
                if written > 0, let base = buf.baseAddress {
                    compressed.append(base, count: written)
                }
                return s
            }
            switch processStatus {
            case JXL_ENC_NEED_MORE_OUTPUT:
                continue
            case JXL_ENC_SUCCESS:
                return compressed
            case JXL_ENC_ERROR:
                throw EncoderError.libjxlEncode("JxlEncoderProcessOutput error")
            default:
                throw EncoderError.libjxlEncode("JxlEncoderProcessOutput unexpected status \(processStatus.rawValue)")
            }
        }
    }
}

@inline(__always)
private func dataType(for pixelType: PixelType) -> JxlDataType {
    switch pixelType {
    case .uint8:   return JXL_TYPE_UINT8
    case .uint16:  return JXL_TYPE_UINT16
    case .float32: return JXL_TYPE_FLOAT
    }
}
