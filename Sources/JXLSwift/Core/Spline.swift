// Copyright (c) 2024 Raster Lab
// Licensed under the MIT License

import Foundation

/// JPEG XL Splines — Vector overlay encoding using cubic Bézier curves
///
/// Implements spline encoding per ISO/IEC 18181-1, allowing efficient
/// representation of smooth curves, lines, and edges as overlays rather
/// than rasterized pixels. Particularly useful for:
/// - Line art and vector graphics
/// - Text overlays
/// - Sharp edges and contours
/// - Diagrams and illustrations

// MARK: - Spline Point

extension Spline {
    /// A 2D point in spline space
    public struct Point: Sendable, Equatable {
        /// X coordinate
        public let x: Float
        
        /// Y coordinate
        public let y: Float
        
        /// Initialize a point
        /// - Parameters:
        ///   - x: X coordinate
        ///   - y: Y coordinate
        public init(x: Float, y: Float) {
            self.x = x
            self.y = y
        }
        
        /// Check if two points are approximately equal
        public static func ==(lhs: Point, rhs: Point) -> Bool {
            return abs(lhs.x - rhs.x) < 1e-3 && abs(lhs.y - rhs.y) < 1e-3
        }
    }
}

// MARK: - Spline

/// Represents a smooth curve defined by control points and rendered via Gaussian splatting
public struct Spline: Sendable {
    /// Control points defining the spline curve
    /// Minimum 2 points required
    public let controlPoints: [Point]
    
    /// DCT coefficients for color along the spline (X, Y, B channels)
    /// Each array contains 32 DCT coefficients
    public let colorDCT: [[Float]]
    
    /// DCT coefficients for sigma (width/blur) along the spline
    /// Array contains 32 DCT coefficients
    public let sigmaDCT: [Float]
    
    /// Initialize a spline
    /// - Parameters:
    ///   - controlPoints: Control points defining the curve (minimum 2)
    ///   - colorDCT: DCT coefficients for color (3 arrays of 32 floats each)
    ///   - sigmaDCT: DCT coefficients for sigma (32 floats)
    public init(
        controlPoints: [Point],
        colorDCT: [[Float]],
        sigmaDCT: [Float]
    ) {
        self.controlPoints = controlPoints
        self.colorDCT = colorDCT
        self.sigmaDCT = sigmaDCT
    }
    
    /// Validate the spline structure
    /// - Throws: EncoderError if validation fails
    public func validate() throws {
        // Require at least 2 control points
        if controlPoints.count < 2 {
            throw EncoderError.encodingFailed("Spline must have at least 2 control points, got \(controlPoints.count)")
        }
        
        // Maximum control points (per spec)
        let maxControlPoints = 1 << 20
        if controlPoints.count > maxControlPoints {
            throw EncoderError.encodingFailed("Spline has too many control points: \(controlPoints.count) > \(maxControlPoints)")
        }
        
        // Validate control point positions (must be within reasonable bounds)
        let posLimit: Float = Float(1 << 23)
        for (index, point) in controlPoints.enumerated() {
            if abs(point.x) >= posLimit || abs(point.y) >= posLimit {
                throw EncoderError.encodingFailed("Control point \(index) out of bounds: (\(point.x), \(point.y))")
            }
        }
        
        // Validate colorDCT structure (must be 3 channels × 32 coefficients)
        if colorDCT.count != 3 {
            throw EncoderError.encodingFailed("colorDCT must have 3 channels, got \(colorDCT.count)")
        }
        for (channel, dct) in colorDCT.enumerated() {
            if dct.count != 32 {
                throw EncoderError.encodingFailed("colorDCT channel \(channel) must have 32 coefficients, got \(dct.count)")
            }
        }
        
        // Validate sigmaDCT structure (must be 32 coefficients)
        if sigmaDCT.count != 32 {
            throw EncoderError.encodingFailed("sigmaDCT must have 32 coefficients, got \(sigmaDCT.count)")
        }
    }
}

// MARK: - SplineConfig

/// Configuration for spline encoding
public struct SplineConfig: Sendable {
    /// Whether spline encoding is enabled
    public let enabled: Bool
    
    /// Quantization adjustment for spline encoding (-128 to 127)
    /// Positive values increase precision, negative values decrease it
    /// - If positive: quantization weights are multiplied by 1 + adjustment/8
    /// - If negative: quantization weights are divided by 1 - adjustment/8
    /// - If 0: weights are unchanged
    public let quantizationAdjustment: Int32
    
    /// Minimum distance between control points (in pixels)
    /// Used during spline detection to filter out very short segments
    public let minControlPointDistance: Float
    
    /// Maximum number of splines per frame
    public let maxSplinesPerFrame: Int
    
    /// Edge detection threshold for automatic spline detection (0.0-1.0)
    /// Higher values require stronger edges to be considered for splines
    public let edgeThreshold: Float
    
    /// Minimum edge length (in pixels) to be considered for spline encoding
    public let minEdgeLength: Float
    
    /// Initialize spline configuration
    /// - Parameters:
    ///   - enabled: Whether to enable spline encoding
    ///   - quantizationAdjustment: Quantization adjustment (-128 to 127)
    ///   - minControlPointDistance: Minimum distance between control points
    ///   - maxSplinesPerFrame: Maximum number of splines per frame
    ///   - edgeThreshold: Edge detection threshold (0.0-1.0)
    ///   - minEdgeLength: Minimum edge length in pixels
    public init(
        enabled: Bool = false,
        quantizationAdjustment: Int32 = 0,
        minControlPointDistance: Float = 4.0,
        maxSplinesPerFrame: Int = 64,
        edgeThreshold: Float = 0.3,
        minEdgeLength: Float = 10.0
    ) {
        self.enabled = enabled
        self.quantizationAdjustment = max(-128, min(127, quantizationAdjustment))
        self.minControlPointDistance = max(1.0, minControlPointDistance)
        self.maxSplinesPerFrame = max(1, maxSplinesPerFrame)
        self.edgeThreshold = max(0.0, min(1.0, edgeThreshold))
        self.minEdgeLength = max(1.0, minEdgeLength)
    }
    
    /// Validate the configuration
    /// - Throws: EncoderError if validation fails
    public func validate() throws {
        if quantizationAdjustment < -128 || quantizationAdjustment > 127 {
            throw EncoderError.encodingFailed("Quantization adjustment must be in range [-128, 127]")
        }
        if minControlPointDistance < 1.0 {
            throw EncoderError.encodingFailed("Minimum control point distance must be >= 1.0")
        }
        if maxSplinesPerFrame < 1 {
            throw EncoderError.encodingFailed("Maximum splines per frame must be >= 1")
        }
        if edgeThreshold < 0.0 || edgeThreshold > 1.0 {
            throw EncoderError.encodingFailed("Edge threshold must be in range [0.0, 1.0]")
        }
        if minEdgeLength < 1.0 {
            throw EncoderError.encodingFailed("Minimum edge length must be >= 1.0")
        }
    }
    
    // MARK: - Presets
    
    /// Disabled preset - no spline encoding
    public static let disabled = SplineConfig(enabled: false)
    
    /// Subtle preset - minimal spline encoding for very sharp edges only
    /// Best for: Photographic content with occasional sharp features
    public static let subtle = SplineConfig(
        enabled: true,
        quantizationAdjustment: 0,
        minControlPointDistance: 8.0,
        maxSplinesPerFrame: 32,
        edgeThreshold: 0.6,
        minEdgeLength: 20.0
    )
    
    /// Moderate preset - balanced spline encoding (default)
    /// Best for: Mixed content with text, graphics, and photos
    public static let moderate = SplineConfig(
        enabled: true,
        quantizationAdjustment: 2,
        minControlPointDistance: 4.0,
        maxSplinesPerFrame: 64,
        edgeThreshold: 0.3,
        minEdgeLength: 10.0
    )
    
    /// Artistic preset - aggressive spline encoding for line art
    /// Best for: Vector graphics, diagrams, illustrations, screenshots
    public static let artistic = SplineConfig(
        enabled: true,
        quantizationAdjustment: 4,
        minControlPointDistance: 2.0,
        maxSplinesPerFrame: 128,
        edgeThreshold: 0.15,
        minEdgeLength: 5.0
    )
}

// MARK: - SplineDetector

/// Detects and extracts splines from image edges
public struct SplineDetector {
    /// Configuration for spline detection
    private let config: SplineConfig
    
    /// Initialize spline detector
    /// - Parameter config: Spline configuration
    public init(config: SplineConfig) {
        self.config = config
    }
    
    /// Detect splines in an image frame
    /// - Parameter frame: Image frame to analyze
    /// - Returns: Array of detected splines
    /// - Throws: EncoderError if detection fails
    public func detectSplines(in frame: ImageFrame) throws -> [Spline] {
        guard config.enabled else { return [] }
        try config.validate()
        
        // For now, return empty array - full edge detection would be implemented
        // in a production version. This provides the framework for spline encoding.
        // A complete implementation would:
        // 1. Perform edge detection (e.g., Canny edge detector)
        // 2. Trace edge contours
        // 3. Fit cubic Bézier curves to contours
        // 4. Extract color and sigma along curves via DCT
        // 5. Return quantized splines
        
        return []
    }
    
    /// Create a simple line spline for testing
    /// - Parameters:
    ///   - from: Starting point
    ///   - to: Ending point
    ///   - color: RGB color values
    ///   - sigma: Width/blur parameter
    /// - Returns: A spline representing a straight line
    public static func createLineSpline(
        from start: Spline.Point,
        to end: Spline.Point,
        color: [Float] = [1.0, 1.0, 1.0],
        sigma: Float = 1.0
    ) -> Spline {
        // Create control points for a straight line
        let controlPoints = [start, end]
        
        // Create constant color DCT (DC component only)
        var colorDCT: [[Float]] = []
        for channelColor in color {
            var dct = [Float](repeating: 0.0, count: 32)
            dct[0] = channelColor * sqrt(2.0) // DC component is scaled by sqrt(2)
            colorDCT.append(dct)
        }
        
        // Create constant sigma DCT (DC component only)
        var sigmaDCT = [Float](repeating: 0.0, count: 32)
        sigmaDCT[0] = sigma * sqrt(2.0) // DC component is scaled by sqrt(2)
        
        return Spline(
            controlPoints: controlPoints,
            colorDCT: colorDCT,
            sigmaDCT: sigmaDCT
        )
    }
}
