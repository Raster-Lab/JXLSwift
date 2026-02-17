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
    
    /// Encode multiple image frames to create an animated JPEG XL file
    /// - Parameter frames: Array of image frames to encode as animation
    /// - Returns: Encoded animation data with statistics
    /// - Throws: EncoderError if encoding fails
    public func encode(_ frames: [ImageFrame]) throws -> EncodedImage {
        guard !frames.isEmpty else {
            throw EncoderError.invalidConfiguration
        }
        
        // For single frame, use single-frame encoder
        if frames.count == 1 {
            return try encode(frames[0])
        }
        
        // Validate animation configuration
        guard let animConfig = options.animationConfig else {
            throw EncoderError.encodingFailed("Animation configuration required for multi-frame encoding")
        }
        
        let startTime = Date()
        
        // Validate all frames
        for (index, frame) in frames.enumerated() {
            do {
                try validateFrame(frame)
            } catch {
                throw EncoderError.encodingFailed("Frame \(index) validation failed: \(error.localizedDescription)")
            }
        }
        
        // Validate consistent dimensions
        let firstFrame = frames[0]
        for (index, frame) in frames.enumerated().dropFirst() {
            guard frame.width == firstFrame.width && frame.height == firstFrame.height else {
                throw EncoderError.encodingFailed("Frame \(index) dimensions (\(frame.width)×\(frame.height)) differ from first frame (\(firstFrame.width)×\(firstFrame.height))")
            }
        }
        
        // Encode animation
        let encodedData = try encodeAnimation(frames: frames, config: animConfig)
        
        let encodingTime = Date().timeIntervalSince(startTime)
        
        // Calculate statistics
        let originalSize = frames.reduce(0) { $0 + $1.data.count }
        let compressedSize = encodedData.count
        let stats = CompressionStats(
            originalSize: originalSize,
            compressedSize: compressedSize,
            encodingTime: encodingTime,
            peakMemory: 0
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
    
    private func encodeAnimation(frames: [ImageFrame], config: AnimationConfig) throws -> Data {
        var writer = BitstreamWriter()
        
        // Write JPEG XL signature
        try writer.writeSignature()
        
        // Create codestream header with animation metadata
        let firstFrame = frames[0]
        let size = try SizeHeader(
            width: UInt32(firstFrame.width),
            height: UInt32(firstFrame.height)
        )
        
        let metadata = ImageMetadata(
            bitsPerSample: UInt32(firstFrame.bitsPerSample),
            hasAlpha: firstFrame.hasAlpha,
            extraChannelCount: firstFrame.hasAlpha ? 1 : 0,
            xybEncoded: false,
            colourEncoding: ColourEncoding.from(colorSpace: firstFrame.colorSpace),
            orientation: firstFrame.orientation,
            haveAnimation: true,
            animationTpsNumerator: config.fps,
            animationTpsDenominator: config.tpsDenominator,
            animationLoopCount: config.loopCount
        )
        
        let header = CodestreamHeader(size: size, metadata: metadata)
        
        // Write codestream header (includes signature)
        let headerData = header.serialise()
        writer = BitstreamWriter() // Reset writer since header includes signature
        writer.writeData(headerData)
        
        // Initialize reference frame tracker if configured
        let refTracker: ReferenceFrameTracker? = options.referenceFrameConfig.map { 
            ReferenceFrameTracker(config: $0) 
        }
        
        // Encode each frame
        for (index, frame) in frames.enumerated() {
            let isLast = (index == frames.count - 1)
            let duration = config.duration(for: index)
            
            // Determine if this should be a keyframe or use reference
            let isKeyframe: Bool
            let saveAsReference: UInt32
            
            if let tracker = refTracker {
                isKeyframe = tracker.shouldBeKeyframe(frameIndex: index)
                
                if isKeyframe {
                    // Mark this frame as a reference (slot 0, 1, 2, or 3)
                    saveAsReference = UInt32((index % 4) + 1)
                    tracker.recordKeyframe(frameIndex: index)
                } else {
                    saveAsReference = 0
                    tracker.recordDeltaFrame()
                }
            } else {
                // No reference frame encoding
                isKeyframe = true
                saveAsReference = 0
            }
            
            // Write frame header
            try writeFrameHeader(
                to: &writer,
                frame: frame,
                duration: duration,
                isLast: isLast,
                index: index,
                saveAsReference: saveAsReference
            )
            
            // Encode frame data
            let frameData = try encodeFrameData(frame)
            writer.writeData(frameData)
        }
        
        return writer.data
    }
    
    private func writeFrameHeader(
        to writer: inout BitstreamWriter,
        frame: ImageFrame,
        duration: UInt32,
        isLast: Bool,
        index: Int,
        saveAsReference: UInt32 = 0
    ) throws {
        let encoding: FrameEncoding
        switch options.mode {
        case .lossless:
            encoding = .modular
        case .lossy, .distance:
            encoding = .varDCT
        }
        
        let frameHeader = FrameHeader(
            frameType: .regularFrame,
            encoding: encoding,
            blendMode: .blend,
            duration: duration,
            isLast: isLast,
            saveAsReference: saveAsReference,
            name: "",
            cropX0: 0,
            cropY0: 0,
            frameWidth: 0,
            frameHeight: 0,
            numGroups: 1,
            numPasses: options.progressive ? 3 : 1
        )
        
        frameHeader.serialise(to: &writer)
    }
    
    private func encodeFrameData(_ frame: ImageFrame) throws -> Data {
        switch options.mode {
        case .lossless:
            return try encodeFrameDataLossless(frame)
        case .lossy(let quality):
            let distance = qualityToDistance(quality)
            return try encodeFrameDataLossy(frame, distance: distance)
        case .distance(let distance):
            return try encodeFrameDataLossy(frame, distance: distance)
        }
    }
    
    private func encodeFrameDataLossless(_ frame: ImageFrame) throws -> Data {
        let modularEncoder = ModularEncoder(
            hardware: hardware,
            options: options
        )
        return try modularEncoder.encode(frame: frame)
    }
    
    private func encodeFrameDataLossy(_ frame: ImageFrame, distance: Float) throws -> Data {
        let dctEncoder = VarDCTEncoder(
            hardware: hardware,
            options: options,
            distance: distance
        )
        return try dctEncoder.encode(frame: frame)
    }
    
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

// MARK: - Reference Frame Management

/// Helper class for managing reference frames during animation encoding
private class ReferenceFrameTracker {
    /// Configuration
    private let config: ReferenceFrameConfig
    
    /// Number of consecutive delta frames since last keyframe
    private var deltaFrameCount: Int = 0
    
    /// Last keyframe index
    private var lastKeyframeIndex: Int = -1
    
    init(config: ReferenceFrameConfig) {
        self.config = config
    }
    
    /// Determine if a frame should be a keyframe
    func shouldBeKeyframe(frameIndex: Int) -> Bool {
        // First frame is always a keyframe
        if frameIndex == 0 {
            return true
        }
        
        // Force keyframe if we've exceeded max delta frames
        if deltaFrameCount >= config.maxDeltaFrames {
            return true
        }
        
        // Force keyframe if we've exceeded the keyframe interval
        if frameIndex - lastKeyframeIndex >= config.keyframeInterval {
            return true
        }
        
        return false
    }
    
    /// Record that a frame was encoded as a keyframe
    func recordKeyframe(frameIndex: Int) {
        deltaFrameCount = 0
        lastKeyframeIndex = frameIndex
    }
    
    /// Record that a frame was encoded as a delta frame
    func recordDeltaFrame() {
        deltaFrameCount += 1
    }
}
