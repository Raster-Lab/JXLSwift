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
        adaptiveQuantization: Bool = true
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
