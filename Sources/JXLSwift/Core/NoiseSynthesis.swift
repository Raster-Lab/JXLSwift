// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import Foundation

/// Configuration for noise synthesis during encoding.
///
/// Noise synthesis adds film grain or synthetic noise to encoded images,
/// which can improve perceptual quality by masking quantization artifacts
/// and maintaining natural texture appearance in smooth areas.
///
/// This feature is particularly useful for:
/// - Preserving film grain in scanned photographs
/// - Adding natural texture to synthetic/rendered images
/// - Masking compression artifacts in smooth gradients
/// - Matching noise characteristics of original content
public struct NoiseConfig: Sendable {
    /// Whether noise synthesis is enabled
    public let enabled: Bool
    
    /// Noise amplitude (strength) in range [0.0, 1.0]
    /// - 0.0: No noise
    /// - 0.1-0.3: Subtle grain (typical for high-quality photos)
    /// - 0.4-0.6: Moderate grain (film-like)
    /// - 0.7-1.0: Heavy grain (artistic effect)
    public let amplitude: Float
    
    /// Luma channel noise strength multiplier [0.0, 2.0]
    /// Default 1.0 means same as amplitude
    public let lumaStrength: Float
    
    /// Chroma channel noise strength multiplier [0.0, 2.0]
    /// Default 0.5 means half of luma noise (natural for photos)
    public let chromaStrength: Float
    
    /// Random seed for reproducible noise generation
    /// Use 0 for non-deterministic (time-based) seeding
    public let seed: UInt64
    
    /// Creates a noise synthesis configuration
    ///
    /// - Parameters:
    ///   - enabled: Whether to enable noise synthesis
    ///   - amplitude: Noise strength in [0.0, 1.0]
    ///   - lumaStrength: Luma multiplier in [0.0, 2.0]
    ///   - chromaStrength: Chroma multiplier in [0.0, 2.0]
    ///   - seed: Random seed (0 for time-based)
    public init(
        enabled: Bool = false,
        amplitude: Float = 0.1,
        lumaStrength: Float = 1.0,
        chromaStrength: Float = 0.5,
        seed: UInt64 = 0
    ) {
        self.enabled = enabled
        self.amplitude = max(0.0, min(1.0, amplitude))
        self.lumaStrength = max(0.0, min(2.0, lumaStrength))
        self.chromaStrength = max(0.0, min(2.0, chromaStrength))
        self.seed = seed
    }
    
    /// Validates the configuration
    ///
    /// - Throws: `EncoderError.encodingFailed` if validation fails
    public func validate() throws {
        if amplitude < 0.0 || amplitude > 1.0 {
            throw EncoderError.encodingFailed("Noise amplitude must be in range [0.0, 1.0]")
        }
        if lumaStrength < 0.0 || lumaStrength > 2.0 {
            throw EncoderError.encodingFailed("Luma strength must be in range [0.0, 2.0]")
        }
        if chromaStrength < 0.0 || chromaStrength > 2.0 {
            throw EncoderError.encodingFailed("Chroma strength must be in range [0.0, 2.0]")
        }
    }
    
    // MARK: - Presets
    
    /// Subtle noise preset - minimal grain for high-quality images
    public static let subtle = NoiseConfig(
        enabled: true,
        amplitude: 0.15,
        lumaStrength: 1.0,
        chromaStrength: 0.4
    )
    
    /// Moderate noise preset - balanced film-like grain
    public static let moderate = NoiseConfig(
        enabled: true,
        amplitude: 0.35,
        lumaStrength: 1.0,
        chromaStrength: 0.5
    )
    
    /// Heavy noise preset - strong artistic grain effect
    public static let heavy = NoiseConfig(
        enabled: true,
        amplitude: 0.65,
        lumaStrength: 1.2,
        chromaStrength: 0.6
    )
    
    /// Film grain preset - mimics analog film characteristics
    public static let filmGrain = NoiseConfig(
        enabled: true,
        amplitude: 0.45,
        lumaStrength: 1.1,
        chromaStrength: 0.7
    )
}

/// Deterministic pseudo-random number generator for noise synthesis
struct NoiseGenerator {
    private var state: UInt64
    
    /// Initialize with a seed value
    /// - Parameter seed: Random seed (use 0 for time-based)
    init(seed: UInt64) {
        if seed == 0 {
            // Use time-based seed if not specified
            self.state = UInt64(Date().timeIntervalSince1970 * 1000000)
        } else {
            self.state = seed
        }
    }
    
    /// Generate next random UInt64 using xorshift64*
    /// This is a fast, high-quality PRNG suitable for noise generation
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545F4914F6CDD1D
    }
    
    /// Generate random Float in range [0.0, 1.0]
    mutating func nextFloat() -> Float {
        let random = next()
        // Convert to [0, 1] using upper 24 bits for mantissa
        return Float(random >> 40) / Float(1 << 24)
    }
    
    /// Generate random Float in range [-1.0, 1.0]
    mutating func nextFloatSymmetric() -> Float {
        return nextFloat() * 2.0 - 1.0
    }
    
    /// Generate Gaussian-distributed noise using Box-Muller transform
    /// - Parameter sigma: Standard deviation
    /// - Returns: Normally distributed value with mean 0 and std dev sigma
    mutating func nextGaussian(sigma: Float = 1.0) -> Float {
        let u1 = nextFloat()
        let u2 = nextFloat()
        
        // Box-Muller transform
        let magnitude = sigma * sqrt(-2.0 * log(max(u1, 1e-10)))
        let angle = 2.0 * Float.pi * u2
        
        return magnitude * cos(angle)
    }
}

/// Applies noise synthesis to image data
struct NoiseSynthesizer {
    private let config: NoiseConfig
    private var generator: NoiseGenerator
    
    /// Initialize noise synthesizer with configuration
    init(config: NoiseConfig) {
        self.config = config
        self.generator = NoiseGenerator(seed: config.seed)
    }
    
    /// Apply noise to a single pixel value
    /// - Parameters:
    ///   - value: Original pixel value (typically in range [0, 255] or [0, 65535])
    ///   - maxValue: Maximum value for the pixel type
    ///   - isLuma: Whether this is a luma (Y) channel vs chroma (Cb/Cr)
    /// - Returns: Noisy pixel value, clamped to valid range
    mutating func applyNoise(value: Float, maxValue: Float, isLuma: Bool) -> Float {
        guard config.enabled && config.amplitude > 0 else {
            return value
        }
        
        // Get strength multiplier based on channel type
        let strength = isLuma ? config.lumaStrength : config.chromaStrength
        
        // Generate Gaussian noise scaled by amplitude and channel strength
        let noise = generator.nextGaussian(sigma: config.amplitude * strength * maxValue * 0.05)
        
        // Apply noise and clamp to valid range
        let noisyValue = value + noise
        return max(0.0, min(maxValue, noisyValue))
    }
    
    /// Apply noise to an array of pixel values
    /// - Parameters:
    ///   - values: Array of pixel values to modify in-place
    ///   - maxValue: Maximum value for the pixel type
    ///   - isLuma: Whether this is a luma channel
    mutating func applyNoise(values: inout [Float], maxValue: Float, isLuma: Bool) {
        guard config.enabled && config.amplitude > 0 else {
            return
        }
        
        for i in 0..<values.count {
            values[i] = applyNoise(value: values[i], maxValue: maxValue, isLuma: isLuma)
        }
    }
    
    /// Apply noise to frequency-domain coefficients (for VarDCT)
    /// This applies noise in the DCT domain, which can be more perceptually uniform
    /// - Parameters:
    ///   - coefficients: DCT coefficients (8x8 block flattened)
    ///   - isLuma: Whether this is a luma channel
    mutating func applyNoiseToCoefficients(coefficients: inout [Float], isLuma: Bool) {
        guard config.enabled && config.amplitude > 0 else {
            return
        }
        
        let strength = isLuma ? config.lumaStrength : config.chromaStrength
        
        // Apply noise primarily to higher frequencies (AC coefficients)
        // Skip DC coefficient (index 0) or apply minimal noise
        for i in 0..<coefficients.count {
            // Frequency-dependent scaling: more noise in mid-high frequencies
            let freqWeight: Float
            if i == 0 {
                // DC: minimal noise
                freqWeight = 0.1
            } else if i < 8 {
                // Low frequencies: moderate noise
                freqWeight = 0.5
            } else {
                // High frequencies: full noise
                freqWeight = 1.0
            }
            
            let noise = generator.nextGaussian(sigma: config.amplitude * strength * freqWeight * 2.0)
            coefficients[i] += noise
        }
    }
}
