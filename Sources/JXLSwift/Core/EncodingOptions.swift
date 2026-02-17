/// Encoding configuration and parameters
///
/// Defines configuration options for JPEG XL encoding

import Foundation

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

/// Encoding options
public struct EncodingOptions: Sendable {
    /// Compression mode
    public var mode: CompressionMode
    
    /// Encoding effort
    public var effort: EncodingEffort
    
    /// Enable progressive encoding
    public var progressive: Bool
    
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
    
    public init(
        mode: CompressionMode = .lossy(quality: 90),
        effort: EncodingEffort = .squirrel,
        progressive: Bool = false,
        modularMode: Bool = false,
        numThreads: Int = 0,
        useHardwareAcceleration: Bool = true,
        useAccelerate: Bool = true,
        useMetal: Bool = true,
        keepJPEG: Bool = false,
        adaptiveQuantization: Bool = true,
        useANS: Bool = false,
        animationConfig: AnimationConfig? = nil
    ) {
        self.mode = mode
        self.effort = effort
        self.progressive = progressive
        self.modularMode = modularMode
        self.numThreads = numThreads
        self.useHardwareAcceleration = useHardwareAcceleration
        self.useAccelerate = useAccelerate
        self.useMetal = useMetal
        self.keepJPEG = keepJPEG
        self.adaptiveQuantization = adaptiveQuantization
        self.useANS = useANS
        self.animationConfig = animationConfig
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
