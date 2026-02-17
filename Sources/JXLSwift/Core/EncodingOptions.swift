/// Encoding configuration and parameters
///
/// Defines configuration options for JPEG XL encoding

import Foundation

/// Responsive encoding configuration for quality-layered progressive delivery
public struct ResponsiveConfig: Sendable {
    /// Number of quality layers (2-8)
    public var layerCount: Int
    
    /// Custom distance values for each layer (must match layerCount)
    /// If empty, layers are automatically calculated from base quality/distance
    /// Layers should be ordered from lowest quality (highest distance) to highest quality (lowest distance)
    public var layerDistances: [Float]
    
    /// Initialize responsive encoding configuration
    /// - Parameters:
    ///   - layerCount: Number of quality layers (default 3)
    ///   - layerDistances: Custom distance values per layer (empty = auto-calculate)
    public init(layerCount: Int = 3, layerDistances: [Float] = []) {
        self.layerCount = max(2, min(8, layerCount))
        self.layerDistances = layerDistances
    }
    
    /// Validate configuration
    /// - Throws: Error if configuration is invalid
    func validate() throws {
        if !layerDistances.isEmpty && layerDistances.count != layerCount {
            throw NSError(
                domain: "ResponsiveConfig",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "layerDistances count (\(layerDistances.count)) must match layerCount (\(layerCount))"]
            )
        }
        
        // Verify layers are in descending order (highest distance first)
        for i in 1..<layerDistances.count {
            if layerDistances[i] >= layerDistances[i-1] {
                throw NSError(
                    domain: "ResponsiveConfig",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "layerDistances must be in descending order (highest distance/lowest quality first)"]
                )
            }
        }
    }
    
    /// Common preset: 2-layer responsive encoding (fast preview + full quality)
    public static let twoLayers = ResponsiveConfig(layerCount: 2)
    
    /// Common preset: 3-layer responsive encoding (preview, medium, full)
    public static let threeLayers = ResponsiveConfig(layerCount: 3)
    
    /// Common preset: 4-layer responsive encoding (maximum progressive refinement)
    public static let fourLayers = ResponsiveConfig(layerCount: 4)
}

/// Compression mode
public enum CompressionMode: Sendable {
    /// Lossless compression using Modular mode
    case lossless
    
    /// Lossy compression using VarDCT mode
    case lossy(quality: Float)  // quality 0.0 - 100.0
    
    /// Distance parameter (alternative to quality)
    /// Lower distance = higher quality
    /// Typical range: 0.0 (lossless) to 15.0 (very lossy)
    case distance(Float)
}

/// Effort level for encoding (1-9)
/// Higher effort = better compression but slower
public enum EncodingEffort: Int, Sendable {
    case lightning = 1  // Fastest
    case thunder = 2
    case falcon = 3
    case cheetah = 4
    case hare = 5
    case wombat = 6
    case squirrel = 7   // Default
    case kitten = 8
    case tortoise = 9   // Slowest, best compression
}

/// Region of Interest (ROI) configuration for selective quality encoding
public struct RegionOfInterest: Sendable, Equatable {
    /// Maximum allowed quality boost value
    public static let maxQualityBoost: Float = 50.0
    
    /// X coordinate of the top-left corner of the ROI (in pixels)
    public var x: Int
    
    /// Y coordinate of the top-left corner of the ROI (in pixels)
    public var y: Int
    
    /// Width of the ROI (in pixels)
    public var width: Int
    
    /// Height of the ROI (in pixels)
    public var height: Int
    
    /// Quality boost for the ROI region (in quality points, 0-50)
    /// This increases the quality/decreases the distance for blocks within the ROI.
    /// Default: 10 (approximately 10% better quality)
    public var qualityBoost: Float
    
    /// Feathering width for smooth quality transition at ROI edges (in pixels)
    /// A value of 0 creates a hard edge, while larger values create a gradual transition.
    /// Default: 16 pixels
    public var featherWidth: Int
    
    /// Initialize region of interest configuration
    /// - Parameters:
    ///   - x: X coordinate of top-left corner
    ///   - y: Y coordinate of top-left corner
    ///   - width: Width of the region
    ///   - height: Height of the region
    ///   - qualityBoost: Quality improvement in points (0-maxQualityBoost, default 10)
    ///   - featherWidth: Transition width in pixels (default 16)
    public init(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        qualityBoost: Float = 10.0,
        featherWidth: Int = 16
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.qualityBoost = max(0, min(Self.maxQualityBoost, qualityBoost))
        self.featherWidth = max(0, featherWidth)
    }
    
    /// Validate ROI against image dimensions
    /// - Parameters:
    ///   - imageWidth: Width of the image
    ///   - imageHeight: Height of the image
    /// - Throws: Error if ROI is invalid or out of bounds
    func validate(imageWidth: Int, imageHeight: Int) throws {
        // Check for non-positive dimensions
        if width <= 0 || height <= 0 {
            throw NSError(
                domain: "RegionOfInterest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ROI width and height must be positive (got \(width)×\(height))"]
            )
        }
        
        // Check if ROI is completely out of bounds
        if x >= imageWidth || y >= imageHeight {
            throw NSError(
                domain: "RegionOfInterest",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "ROI position (\(x), \(y)) is outside image bounds (\(imageWidth)×\(imageHeight))"]
            )
        }
        
        // Check if ROI extends beyond image bounds
        if x + width > imageWidth || y + height > imageHeight {
            throw NSError(
                domain: "RegionOfInterest",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "ROI extends beyond image bounds (ROI: \(x),\(y) \(width)×\(height), Image: \(imageWidth)×\(imageHeight))"]
            )
        }
        
        // Check for negative coordinates
        if x < 0 || y < 0 {
            throw NSError(
                domain: "RegionOfInterest",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "ROI coordinates must be non-negative (got \(x), \(y))"]
            )
        }
    }
    
    /// Calculate distance multiplier for a pixel position
    /// - Parameters:
    ///   - px: X coordinate of the pixel
    ///   - py: Y coordinate of the pixel
    /// - Returns: Distance multiplier (1.0 = no change, <1.0 = higher quality, >1.0 = lower quality)
    public func distanceMultiplier(px: Int, py: Int) -> Float {
        // Check if pixel is completely outside ROI (including feather)
        let maxX = x + width + featherWidth
        let maxY = y + height + featherWidth
        let minX = x - featherWidth
        let minY = y - featherWidth
        
        if px < minX || px >= maxX || py < minY || py >= maxY {
            return 1.0 // No change outside ROI
        }
        
        // Check if pixel is fully inside ROI (no feathering)
        if px >= x && px < x + width && py >= y && py < y + height {
            // Full quality boost inside ROI
            // Convert quality boost to distance multiplier
            // Higher quality = lower distance, so boost of 10 ≈ 0.7× distance
            return 1.0 / (1.0 + qualityBoost / 100.0)
        }
        
        // Pixel is in the feather zone - calculate smooth transition
        guard featherWidth > 0 else {
            return 1.0 // No feathering, treat as outside
        }
        
        // Calculate minimum distance from pixel to ROI rectangle
        let dx: Float
        if px < x {
            dx = Float(x - px)
        } else if px >= x + width {
            dx = Float(px - (x + width - 1))
        } else {
            dx = 0
        }
        
        let dy: Float
        if py < y {
            dy = Float(y - py)
        } else if py >= y + height {
            dy = Float(py - (y + height - 1))
        } else {
            dy = 0
        }
        
        let distance = sqrt(dx * dx + dy * dy)
        
        // Smooth transition using cosine interpolation
        let t = min(1.0, distance / Float(featherWidth))
        let smoothT = (1.0 - cos(t * .pi)) / 2.0 // Smooth S-curve
        
        // Interpolate between full boost (inside) and no boost (outside)
        let fullBoostMultiplier = 1.0 / (1.0 + qualityBoost / 100.0)
        return fullBoostMultiplier + smoothT * (1.0 - fullBoostMultiplier)
    }
}

/// Animation configuration for multi-frame encoding
public struct AnimationConfig: Sendable {
    /// Frames per second (ticks per second numerator)
    public var fps: UInt32
    
    /// Ticks per second denominator (for fractional frame rates)
    public var tpsDenominator: UInt32
    
    /// Loop count (0 = infinite loop)
    public var loopCount: UInt32
    
    /// Frame durations in ticks (one per frame)
    /// If empty, all frames use uniform duration (tps / fps)
    public var frameDurations: [UInt32]
    
    /// Initialize animation configuration
    /// - Parameters:
    ///   - fps: Frames per second (default 30)
    ///   - tpsDenominator: Denominator for fractional fps (default 1)
    ///   - loopCount: Number of loops (0 = infinite, default 0)
    ///   - frameDurations: Custom frame durations in ticks (empty = uniform)
    public init(
        fps: UInt32 = 30,
        tpsDenominator: UInt32 = 1,
        loopCount: UInt32 = 0,
        frameDurations: [UInt32] = []
    ) {
        self.fps = fps
        self.tpsDenominator = tpsDenominator
        self.loopCount = loopCount
        self.frameDurations = frameDurations
    }
    
    /// Get duration in ticks for a specific frame index
    /// - Parameter index: Frame index
    /// - Returns: Duration in ticks
    public func duration(for index: Int) -> UInt32 {
        if !frameDurations.isEmpty && index < frameDurations.count {
            return frameDurations[index]
        }
        // Default: 1 second / fps = tps / fps ticks
        // Ensure fps > 0 to avoid division by zero
        guard fps > 0 else { return 1000 }
        return 1000 / fps
    }
    
    /// Common preset: 30 FPS, infinite loop
    public static let fps30 = AnimationConfig(fps: 30, loopCount: 0)
    
    /// Common preset: 24 FPS (cinematic), infinite loop
    public static let fps24 = AnimationConfig(fps: 24, loopCount: 0)
    
    /// Common preset: 60 FPS (smooth), infinite loop
    public static let fps60 = AnimationConfig(fps: 60, loopCount: 0)
}

/// Reference frame configuration for animation delta encoding
///
/// Enables efficient compression of animations by encoding frames as deltas
/// from previous reference frames, significantly reducing file size for
/// video-like content with temporal coherence.
public struct ReferenceFrameConfig: Sendable {
    /// Minimum keyframe interval in frames
    /// Keyframes are full frames that can be used as reference points
    /// Default: 30 frames (1 second at 30fps)
    public var keyframeInterval: Int
    
    /// Maximum number of consecutive delta frames before forcing a keyframe
    /// Default: 120 frames (4 seconds at 30fps)
    public var maxDeltaFrames: Int
    
    /// Similarity threshold for using reference frame encoding (0.0-1.0)
    /// Higher values = stricter requirements for using delta encoding
    /// 0.0 = always use delta encoding
    /// 1.0 = never use delta encoding (perfect match required)
    /// Default: 0.7 (70% similarity required)
    public var similarityThreshold: Float
    
    /// Maximum number of reference frames to keep in memory
    /// Default: 4 frames
    public var maxReferenceFrames: Int
    
    /// Initialize reference frame configuration
    /// - Parameters:
    ///   - keyframeInterval: Minimum interval between keyframes in frames
    ///   - maxDeltaFrames: Maximum consecutive delta frames
    ///   - similarityThreshold: Similarity threshold for using delta encoding
    ///   - maxReferenceFrames: Maximum reference frames to keep
    public init(
        keyframeInterval: Int = 30,
        maxDeltaFrames: Int = 120,
        similarityThreshold: Float = 0.7,
        maxReferenceFrames: Int = 4
    ) {
        self.keyframeInterval = max(1, keyframeInterval)
        self.maxDeltaFrames = max(1, maxDeltaFrames)
        self.similarityThreshold = max(0.0, min(1.0, similarityThreshold))
        self.maxReferenceFrames = max(1, min(8, maxReferenceFrames))
    }
    
    /// Common preset: Aggressive delta encoding (smaller files, more CPU)
    /// Keyframe every 60 frames, up to 240 consecutive deltas, 60% similarity
    public static let aggressive = ReferenceFrameConfig(
        keyframeInterval: 60,
        maxDeltaFrames: 240,
        similarityThreshold: 0.6,
        maxReferenceFrames: 4
    )
    
    /// Common preset: Balanced delta encoding (default)
    /// Keyframe every 30 frames, up to 120 consecutive deltas, 70% similarity
    public static let balanced = ReferenceFrameConfig(
        keyframeInterval: 30,
        maxDeltaFrames: 120,
        similarityThreshold: 0.7,
        maxReferenceFrames: 4
    )
    
    /// Common preset: Conservative delta encoding (more keyframes, faster seeking)
    /// Keyframe every 15 frames, up to 60 consecutive deltas, 80% similarity
    public static let conservative = ReferenceFrameConfig(
        keyframeInterval: 15,
        maxDeltaFrames: 60,
        similarityThreshold: 0.8,
        maxReferenceFrames: 2
    )
}

/// Encoding options
public struct EncodingOptions: Sendable {
    /// Compression mode
    public var mode: CompressionMode
    
    /// Encoding effort
    public var effort: EncodingEffort
    
    /// Enable progressive encoding (frequency-based: DC, low-freq AC, high-freq AC)
    public var progressive: Bool
    
    /// Enable responsive encoding (quality-based layers)
    /// When enabled, encodes multiple quality layers for progressive quality refinement
    /// Note: Can be combined with progressive for both frequency and quality layering
    public var responsiveEncoding: Bool
    
    /// Responsive encoding configuration
    /// Only used when responsiveEncoding is enabled
    public var responsiveConfig: ResponsiveConfig?
    
    /// Use modular mode even for lossy (forces lossless for some operations)
    public var modularMode: Bool
    
    /// Number of threads to use (0 = auto-detect)
    public var numThreads: Int
    
    /// Use hardware acceleration when available
    public var useHardwareAcceleration: Bool
    
    /// Prefer Apple Accelerate framework
    public var useAccelerate: Bool
    
    /// Prefer Metal GPU acceleration
    public var useMetal: Bool
    
    /// Keep original JPEG if transcoding
    public var keepJPEG: Bool
    
    /// Enable adaptive quantisation per block in VarDCT mode.
    ///
    /// When enabled, each 8×8 block's quantisation step is scaled by
    /// the local spatial activity (variance).  High-detail blocks
    /// receive finer quantisation to preserve edges; flat blocks are
    /// quantised more coarsely because the human visual system is
    /// less sensitive to noise in smooth regions.
    public var adaptiveQuantization: Bool
    
    /// Use ANS (Asymmetric Numeral Systems) entropy coding.
    ///
    /// When enabled, the encoder uses rANS entropy coding instead of
    /// the simplified run-length + Golomb-Rice encoding.  ANS provides
    /// near-optimal compression at a modest increase in encoding time.
    /// This follows ISO/IEC 18181-1 Annex A.
    public var useANS: Bool
    
    /// Animation configuration for multi-frame encoding.
    ///
    /// When set, enables animation mode with the specified frame rate,
    /// loop count, and frame durations. Use with the multi-frame encoder
    /// API to create animated JPEG XL files.
    public var animationConfig: AnimationConfig?
    
    /// Region of interest configuration for selective quality encoding.
    ///
    /// When set, the specified region will be encoded at higher quality
    /// than the rest of the image, with optional feathering for smooth
    /// transitions. Useful for preserving detail in important areas
    /// while reducing file size by compressing less important regions.
    public var regionOfInterest: RegionOfInterest?
    
    /// Reference frame configuration for animation delta encoding.
    ///
    /// When set and used with animation encoding, frames will be encoded
    /// as deltas from previous reference frames when beneficial, significantly
    /// reducing file size for video-like content. Only applies to multi-frame
    /// animations (requires animationConfig to be set).
    public var referenceFrameConfig: ReferenceFrameConfig?
    
    public init(
        mode: CompressionMode = .lossy(quality: 90),
        effort: EncodingEffort = .squirrel,
        progressive: Bool = false,
        responsiveEncoding: Bool = false,
        responsiveConfig: ResponsiveConfig? = nil,
        modularMode: Bool = false,
        numThreads: Int = 0,
        useHardwareAcceleration: Bool = true,
        useAccelerate: Bool = true,
        useMetal: Bool = true,
        keepJPEG: Bool = false,
        adaptiveQuantization: Bool = true,
        useANS: Bool = false,
        animationConfig: AnimationConfig? = nil,
        regionOfInterest: RegionOfInterest? = nil,
        referenceFrameConfig: ReferenceFrameConfig? = nil
    ) {
        self.mode = mode
        self.effort = effort
        self.progressive = progressive
        self.responsiveEncoding = responsiveEncoding
        self.responsiveConfig = responsiveConfig
        self.modularMode = modularMode
        self.numThreads = numThreads
        self.useHardwareAcceleration = useHardwareAcceleration
        self.useAccelerate = useAccelerate
        self.useMetal = useMetal
        self.keepJPEG = keepJPEG
        self.adaptiveQuantization = adaptiveQuantization
        self.useANS = useANS
        self.animationConfig = animationConfig
        self.regionOfInterest = regionOfInterest
        self.referenceFrameConfig = referenceFrameConfig
    }
    
    /// Default high-quality encoding
    public static let highQuality = EncodingOptions(
        mode: .lossy(quality: 95),
        effort: .kitten
    )
    
    /// Default fast encoding
    public static let fast = EncodingOptions(
        mode: .lossy(quality: 85),
        effort: .falcon
    )
    
    /// Lossless encoding
    public static let lossless = EncodingOptions(
        mode: .lossless,
        effort: .squirrel,
        modularMode: true
    )
}

/// Encoder result
public struct EncodedImage: Sendable {
    /// Compressed image data
    public let data: Data
    
    /// Compression statistics
    public let stats: CompressionStats
}

/// Compression statistics
public struct CompressionStats: Sendable {
    /// Original size in bytes
    public let originalSize: Int
    
    /// Compressed size in bytes
    public let compressedSize: Int
    
    /// Compression ratio
    public var compressionRatio: Double {
        guard originalSize > 0 else { return 0 }
        return Double(originalSize) / Double(compressedSize)
    }
    
    /// Encoding time in seconds
    public let encodingTime: TimeInterval
    
    /// Peak memory usage in bytes
    public let peakMemory: Int
}
