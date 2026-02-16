/// JPEG XL Encoder - Main encoding interface
///
/// Provides the primary API for compressing images to JPEG XL format

import Foundation

/// JPEG XL Encoder errors
public enum EncoderError: Error, LocalizedError {
    case invalidImageDimensions
    case invalidConfiguration
    case unsupportedPixelFormat
    case encodingFailed(String)
    case insufficientMemory
    case hardwareAccelerationUnavailable
    
    public var errorDescription: String? {
        switch self {
        case .invalidImageDimensions:
            return "Invalid image dimensions"
        case .invalidConfiguration:
            return "Invalid encoding configuration"
        case .unsupportedPixelFormat:
            return "Unsupported pixel format"
        case .encodingFailed(let reason):
            return "Encoding failed: \(reason)"
        case .insufficientMemory:
            return "Insufficient memory for encoding"
        case .hardwareAccelerationUnavailable:
            return "Hardware acceleration not available"
        }
    }
}

/// Main JPEG XL Encoder
public class JXLEncoder {
    /// Encoding options
    public let options: EncodingOptions
    
    /// Hardware capabilities
    private let hardware: HardwareCapabilities
    
    /// Initialize encoder with options
    public init(options: EncodingOptions = EncodingOptions()) {
        self.options = options
        self.hardware = HardwareCapabilities.shared
    }
    
    /// Encode an image frame to JPEG XL format
    /// - Parameter frame: Image frame to encode
    /// - Returns: Encoded image data with statistics
    /// - Throws: EncoderError if encoding fails
    public func encode(_ frame: ImageFrame) throws -> EncodedImage {
        let startTime = Date()
        
        // Validate input
        try validateFrame(frame)
        
        // Select encoding pipeline based on mode
        let encodedData: Data
        switch options.mode {
        case .lossless:
            encodedData = try encodeLossless(frame)
        case .lossy(let quality):
            encodedData = try encodeLossy(frame, quality: quality)
        case .distance(let distance):
            encodedData = try encodeLossy(frame, distance: distance)
        }
        
        let encodingTime = Date().timeIntervalSince(startTime)
        
        // Calculate statistics
        let originalSize = frame.data.count
        let compressedSize = encodedData.count
        let stats = CompressionStats(
            originalSize: originalSize,
            compressedSize: compressedSize,
            encodingTime: encodingTime,
            peakMemory: 0 // TODO: Implement memory tracking
        )
        
        return EncodedImage(data: encodedData, stats: stats)
    }
    
    // MARK: - Validation
    
    private func validateFrame(_ frame: ImageFrame) throws {
        // Check dimensions
        guard frame.width > 0 && frame.height > 0 else {
            throw EncoderError.invalidImageDimensions
        }
        
        guard frame.width <= 262144 && frame.height <= 262144 else {
            throw EncoderError.invalidImageDimensions
        }
        
        // Check channels
        guard frame.channels >= 1 && frame.channels <= 4 else {
            throw EncoderError.unsupportedPixelFormat
        }
    }
    
    // MARK: - Lossless Encoding (Modular Mode)
    
    private func encodeLossless(_ frame: ImageFrame) throws -> Data {
        var writer = BitstreamWriter()
        
        // Write JPEG XL signature
        try writer.writeSignature()
        
        // Write image header
        try writer.writeImageHeader(frame: frame)
        
        // Use modular mode encoder
        let modularEncoder = ModularEncoder(
            hardware: hardware,
            options: options
        )
        
        let compressedData = try modularEncoder.encode(frame: frame)
        writer.writeData(compressedData)
        
        return writer.data
    }
    
    // MARK: - Lossy Encoding (VarDCT Mode)
    
    private func encodeLossy(_ frame: ImageFrame, quality: Float) throws -> Data {
        // Convert quality to distance
        let distance = qualityToDistance(quality)
        return try encodeLossy(frame, distance: distance)
    }
    
    private func encodeLossy(_ frame: ImageFrame, distance: Float) throws -> Data {
        var writer = BitstreamWriter()
        
        // Write JPEG XL signature
        try writer.writeSignature()
        
        // Write image header
        try writer.writeImageHeader(frame: frame)
        
        // Use VarDCT encoder
        let dctEncoder = VarDCTEncoder(
            hardware: hardware,
            options: options,
            distance: distance
        )
        
        let compressedData = try dctEncoder.encode(frame: frame)
        writer.writeData(compressedData)
        
        return writer.data
    }
    
    // MARK: - Helper Functions
    
    private func qualityToDistance(_ quality: Float) -> Float {
        // Convert quality (0-100) to distance parameter
        // This is a simplified conversion; actual JPEG XL uses a more complex formula
        let clampedQuality = max(0, min(100, quality))
        
        if clampedQuality >= 100 {
            return 0.0
        } else if clampedQuality >= 30 {
            return 0.1 + (100 - clampedQuality) / 10.0
        } else {
            return 7.0 + (30 - clampedQuality) / 3.75
        }
    }
}
