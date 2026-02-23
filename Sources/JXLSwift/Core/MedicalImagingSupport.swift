/// Medical imaging support utilities for JPEG XL
///
/// Provides validation helpers, large-image size checks, and multi-frame
/// medical series support for use in DICOM-adjacent workflows.  No DICOM
/// library dependency is introduced; the library remains fully independent.

import Foundation

// MARK: - Constants

/// Maximum dimension (width or height) validated for medical imaging use
public let medicalMaxDimension: Int = 16384

/// Maximum total pixel count validated for medical imaging use (16384×16384)
public let medicalMaxPixelCount: Int = 16384 * 16384

// MARK: - MedicalImageValidator

/// Validates image frames for common medical imaging constraints
///
/// Checks that a frame meets the pixel format, bit depth, and size
/// requirements typical of medical imaging modalities (CT, MR, X-Ray, etc.).
/// All validation is DICOM-independent; the validator does not parse or
/// produce any DICOM data structures.
public struct MedicalImageValidator: Sendable {

    /// Errors that can be thrown during medical image validation
    public enum ValidationError: Error, LocalizedError {
        case dimensionTooLarge(width: Int, height: Int)
        case unsupportedPixelType(PixelType)
        case unsupportedBitDepth(Int)
        case invalidChannelCount(Int)
        case pixelCountExceedsLimit(count: Int, limit: Int)

        public var errorDescription: String? {
            switch self {
            case .dimensionTooLarge(let w, let h):
                return "Image dimension \(w)×\(h) exceeds medical imaging maximum \(medicalMaxDimension)×\(medicalMaxDimension)"
            case .unsupportedPixelType(let t):
                return "Pixel type \(t) is not supported for medical imaging lossless encoding"
            case .unsupportedBitDepth(let b):
                return "Bit depth \(b) is not supported for medical imaging (supported: 8, 12, 16, 32)"
            case .invalidChannelCount(let c):
                return "Channel count \(c) is invalid for medical imaging (expected 1 for grayscale or 3 for colour)"
            case .pixelCountExceedsLimit(let count, let limit):
                return "Pixel count \(count) exceeds medical imaging limit of \(limit)"
            }
        }
    }

    /// Validates an `ImageFrame` for medical imaging use
    ///
    /// Checks dimensions, pixel type, bit depth, and channel count against
    /// common medical imaging requirements.
    ///
    /// - Parameter frame: The image frame to validate
    /// - Throws: `ValidationError` if the frame fails any check
    public static func validate(_ frame: ImageFrame) throws {
        // Dimension check
        if frame.width > medicalMaxDimension || frame.height > medicalMaxDimension {
            throw ValidationError.dimensionTooLarge(width: frame.width, height: frame.height)
        }

        // Pixel count check
        let pixelCount = frame.width * frame.height
        if pixelCount > medicalMaxPixelCount {
            throw ValidationError.pixelCountExceedsLimit(count: pixelCount, limit: medicalMaxPixelCount)
        }

        // Pixel type check
        switch frame.pixelType {
        case .uint8, .uint16, .int16, .float32:
            break  // All supported
        }

        // Bit depth check
        let validBitDepths = [8, 12, 16, 32]
        if !validBitDepths.contains(frame.bitsPerSample) {
            throw ValidationError.unsupportedBitDepth(frame.bitsPerSample)
        }

        // Channel count check — grayscale (1) or colour (3) are typical
        if frame.channels != 1 && frame.channels != 3 {
            throw ValidationError.invalidChannelCount(frame.channels)
        }
    }

    /// Validates a medical image series (array of frames)
    ///
    /// Checks that all frames in the series have consistent dimensions,
    /// pixel type, and channel count, and that each frame individually
    /// passes validation.
    ///
    /// - Parameter frames: The frames to validate as a series
    /// - Throws: `ValidationError` or an `NSError` if consistency checks fail
    public static func validateSeries(_ frames: [ImageFrame]) throws {
        guard let first = frames.first else { return }

        try validate(first)

        for (index, frame) in frames.dropFirst().enumerated() {
            try validate(frame)

            if frame.width != first.width || frame.height != first.height {
                throw NSError(
                    domain: "MedicalImageValidator",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Frame \(index + 1) dimension \(frame.width)×\(frame.height) differs from first frame \(first.width)×\(first.height)"]
                )
            }
            if frame.pixelType != first.pixelType {
                throw NSError(
                    domain: "MedicalImageValidator",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Frame \(index + 1) pixel type differs from first frame"]
                )
            }
            if frame.channels != first.channels {
                throw NSError(
                    domain: "MedicalImageValidator",
                    code: 12,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Frame \(index + 1) channel count \(frame.channels) differs from first frame \(first.channels)"]
                )
            }
        }
    }
}

// MARK: - PixelType equality helper

extension PixelType: Equatable {
    public static func == (lhs: PixelType, rhs: PixelType) -> Bool {
        switch (lhs, rhs) {
        case (.uint8,   .uint8):   return true
        case (.uint16,  .uint16):  return true
        case (.int16,   .int16):   return true
        case (.float32, .float32): return true
        default:                   return false
        }
    }
}

// MARK: - MedicalImageSeries

/// A multi-frame medical image series (e.g., a CT or MR stack)
///
/// Provides convenience accessors and lightweight metadata for encoding
/// and decoding multi-frame medical image data.  This type is
/// DICOM-independent; no DICOM tags are parsed or produced.
public struct MedicalImageSeries: Sendable {

    /// Individual frames in acquisition order
    public let frames: [ImageFrame]

    /// Optional series-level description (e.g., modality, body part)
    public let description: String

    /// Number of frames in the series
    public var frameCount: Int { frames.count }

    /// Width of each frame in pixels (all frames must be identical)
    public var width: Int { frames.first?.width ?? 0 }

    /// Height of each frame in pixels (all frames must be identical)
    public var height: Int { frames.first?.height ?? 0 }

    /// Pixel type of the series (taken from the first frame)
    public var pixelType: PixelType { frames.first?.pixelType ?? .uint16 }

    /// Creates a medical image series from an array of frames
    ///
    /// - Parameters:
    ///   - frames: Frames in acquisition order (must be non-empty and consistent)
    ///   - description: Optional human-readable description of the series
    /// - Throws: `MedicalImageValidator.ValidationError` if any frame is invalid
    ///           or frames are inconsistent
    public init(frames: [ImageFrame], description: String = "") throws {
        guard !frames.isEmpty else {
            throw NSError(
                domain: "MedicalImageSeries",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "A medical image series must contain at least one frame"]
            )
        }
        try MedicalImageValidator.validateSeries(frames)
        self.frames = frames
        self.description = description
    }

    /// Returns the animation configuration suitable for encoding this series
    /// as a multi-frame JPEG XL file.
    ///
    /// Each frame is given equal duration (1 tick at 1 frame per second),
    /// which is appropriate for static medical image stacks where playback
    /// speed is controlled by the viewing application.
    public var animationConfig: AnimationConfig {
        AnimationConfig(fps: 1, tpsDenominator: 1, loopCount: 0)
    }
}

// MARK: - ImageFrame convenience initialiser for medical imaging

extension ImageFrame {

    /// Creates an image frame suitable for 12-bit unsigned medical imaging data
    ///
    /// The frame uses `uint16` storage (2 bytes per sample) with
    /// `bitsPerSample` set to 12, `grayscale` colour space, and a
    /// `monochrome2` photometric interpretation by default.
    ///
    /// - Parameters:
    ///   - width: Frame width in pixels
    ///   - height: Frame height in pixels
    ///   - photometricInterpretation: Photometric interpretation hint (default `.monochrome2`)
    ///   - windowLevels: Optional window/level presets for display
    /// - Returns: A new `ImageFrame` configured for 12-bit medical imaging
    public static func medical12bit(
        width: Int,
        height: Int,
        photometricInterpretation: PhotometricInterpretation = .monochrome2,
        windowLevels: [WindowLevel] = []
    ) -> ImageFrame {
        ImageFrame(
            width: width,
            height: height,
            channels: 1,
            pixelType: .uint16,
            colorSpace: .grayscale,
            bitsPerSample: 12,
            medicalMetadata: MedicalImageMetadata(
                photometricInterpretation: photometricInterpretation,
                windowLevels: windowLevels
            )
        )
    }

    /// Creates an image frame suitable for 16-bit unsigned medical imaging data
    ///
    /// The frame uses `uint16` storage with `bitsPerSample` set to 16,
    /// `grayscale` colour space, and a `monochrome2` photometric
    /// interpretation by default.
    ///
    /// - Parameters:
    ///   - width: Frame width in pixels
    ///   - height: Frame height in pixels
    ///   - photometricInterpretation: Photometric interpretation hint (default `.monochrome2`)
    ///   - windowLevels: Optional window/level presets for display
    /// - Returns: A new `ImageFrame` configured for 16-bit unsigned medical imaging
    public static func medical16bit(
        width: Int,
        height: Int,
        photometricInterpretation: PhotometricInterpretation = .monochrome2,
        windowLevels: [WindowLevel] = []
    ) -> ImageFrame {
        ImageFrame(
            width: width,
            height: height,
            channels: 1,
            pixelType: .uint16,
            colorSpace: .grayscale,
            bitsPerSample: 16,
            medicalMetadata: MedicalImageMetadata(
                photometricInterpretation: photometricInterpretation,
                windowLevels: windowLevels
            )
        )
    }

    /// Creates an image frame suitable for 16-bit signed medical imaging data
    ///
    /// The frame uses `int16` storage with `bitsPerSample` set to 16,
    /// `grayscale` colour space, and a `monochrome2` photometric
    /// interpretation by default.  This format is typical for CT images
    /// encoded in Hounsfield units (−1024 to +3071).
    ///
    /// - Parameters:
    ///   - width: Frame width in pixels
    ///   - height: Frame height in pixels
    ///   - photometricInterpretation: Photometric interpretation hint (default `.monochrome2`)
    ///   - windowLevels: Optional window/level presets for display
    ///   - rescaleIntercept: Rescale intercept for Hounsfield unit conversion (default −1024)
    ///   - rescaleSlope: Rescale slope (default 1.0)
    /// - Returns: A new `ImageFrame` configured for 16-bit signed medical imaging
    public static func medicalSigned16bit(
        width: Int,
        height: Int,
        photometricInterpretation: PhotometricInterpretation = .monochrome2,
        windowLevels: [WindowLevel] = [],
        rescaleIntercept: Double = -1024.0,
        rescaleSlope: Double = 1.0
    ) -> ImageFrame {
        ImageFrame(
            width: width,
            height: height,
            channels: 1,
            pixelType: .int16,
            colorSpace: .grayscale,
            bitsPerSample: 16,
            medicalMetadata: MedicalImageMetadata(
                photometricInterpretation: photometricInterpretation,
                windowLevels: windowLevels,
                rescaleIntercept: rescaleIntercept,
                rescaleSlope: rescaleSlope
            )
        )
    }
}

// MARK: - EncodingOptions medical preset extension

extension EncodingOptions {
    /// Encoding preset optimised for lossless medical imaging
    ///
    /// Uses lossless Modular mode at full effort to guarantee bit-perfect
    /// reproduction of all pixel values — a critical requirement for
    /// diagnostic-quality images.
    public static let medicalLossless = EncodingOptions(
        mode: .lossless,
        effort: .tortoise,
        modularMode: true
    )
}
