// Encoding configuration: mode, effort, and a few common knobs that map
// directly onto libjxl's `JxlEncoderFrameSettings`.

import Foundation

/// What kind of compression to apply.
public enum CompressionMode: Sendable, Equatable {
    /// Bit-exact lossless compression. Maps to libjxl distance = 0.0.
    case lossless
    /// Quality-driven lossy compression. `quality` is a 0…100 score where
    /// 90 is visually lossless on photographic content and 100 is near-
    /// transparent. Mapped to libjxl distance via the standard quality→
    /// distance curve from `cjxl --quality`.
    case lossy(quality: Float)
    /// Distance-driven lossy compression. Smaller is higher quality.
    /// `0.0` is lossless. The libjxl-recommended sweet spot is `1.0`.
    /// Maximum value is `25.0`.
    case distance(Float)
}

/// libjxl effort levels. Higher = slower + smaller output.
public enum EncodingEffort: Int, Sendable {
    case lightning = 1
    case thunder   = 2
    case falcon    = 3
    case cheetah   = 4
    case hare      = 5
    case wombat    = 6
    case squirrel  = 7
    case kitten    = 8
    case tortoise  = 9
}

/// Encoding configuration. Sensible defaults for the common case.
public struct EncodingOptions: Sendable {
    public var mode: CompressionMode
    public var effort: EncodingEffort
    /// Use libjxl's progressive DC encoding (multi-pass delivery).
    public var progressive: Bool
    /// Number of decoder threads to spawn during encoding. `0` means
    /// "let libjxl pick".
    public var numThreads: Int

    public init(
        mode: CompressionMode = .lossy(quality: 90),
        effort: EncodingEffort = .squirrel,
        progressive: Bool = false,
        numThreads: Int = 0
    ) {
        self.mode = mode
        self.effort = effort
        self.progressive = progressive
        self.numThreads = numThreads
    }

    /// The libjxl distance value that this configuration maps to. Used
    /// by the encoder when calling `JxlEncoderSetFrameDistance`.
    public var distance: Float {
        switch mode {
        case .lossless:
            return 0.0
        case .distance(let d):
            return max(0.0, min(d, 25.0))
        case .lossy(let q):
            // libjxl's quality→distance curve, mirroring `cjxl --quality`.
            // Source: lib/jxl/encoder/encoder.cc.
            let qq = max(0.0, min(q, 100.0))
            if qq >= 100 { return 0.0 }
            if qq >= 30  { return 0.1 + (100 - qq) * 0.09 }
            return 53.0 / 3000.0 * qq * qq - 23.0 / 20.0 * qq + 25.0
        }
    }
}

/// Statistics returned alongside an encoded image.
public struct CompressionStats: Sendable {
    public let originalSize: Int
    public let compressedSize: Int
    public let encodingTime: TimeInterval

    public var compressionRatio: Double {
        guard compressedSize > 0 else { return 0 }
        return Double(originalSize) / Double(compressedSize)
    }

    public init(originalSize: Int, compressedSize: Int, encodingTime: TimeInterval) {
        self.originalSize = originalSize
        self.compressedSize = compressedSize
        self.encodingTime = encodingTime
    }
}

/// The result of a successful encode.
public struct EncodedImage: Sendable {
    public let data: Data
    public let stats: CompressionStats

    public init(data: Data, stats: CompressionStats) {
        self.data = data
        self.stats = stats
    }
}
