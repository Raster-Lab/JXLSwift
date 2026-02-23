/// VarDCT Mode Encoder
///
/// Implements lossy compression using the VarDCT mode of JPEG XL.
/// Uses DCT transforms, quantization, and entropy coding.

import Foundation

// MARK: - DCT Block Sizes

/// Variable DCT block sizes supported by JPEG XL per ISO/IEC 18181-1 §6.
///
/// The encoder selects optimal block sizes based on local image content:
/// - Larger blocks (16×16, 32×32) for smooth regions — fewer coefficients relative to area
/// - Smaller blocks (8×8) for textured/detailed regions — better frequency localization
/// - Rectangular blocks (16×8, 8×16, 32×8, etc.) for directional content like edges
public enum DCTBlockSize: UInt8, Sendable, CaseIterable {
    /// Standard 8×8 DCT block (JPEG-compatible)
    case dct8x8 = 0
    /// 16×16 DCT block for smooth regions
    case dct16x16 = 1
    /// 32×32 DCT block for very smooth regions
    case dct32x32 = 2
    /// 16×8 horizontal rectangular block
    case dct16x8 = 3
    /// 8×16 vertical rectangular block
    case dct8x16 = 4
    /// 32×8 wide horizontal block
    case dct32x8 = 5
    /// 8×32 tall vertical block
    case dct8x32 = 6
    /// 32×16 wide block
    case dct32x16 = 7
    /// 16×32 tall block
    case dct16x32 = 8

    /// Width of this block type in pixels
    public var width: Int {
        switch self {
        case .dct8x8:   return 8
        case .dct16x16: return 16
        case .dct32x32: return 32
        case .dct16x8:  return 16
        case .dct8x16:  return 8
        case .dct32x8:  return 32
        case .dct8x32:  return 8
        case .dct32x16: return 32
        case .dct16x32: return 16
        }
    }

    /// Height of this block type in pixels
    public var height: Int {
        switch self {
        case .dct8x8:   return 8
        case .dct16x16: return 16
        case .dct32x32: return 32
        case .dct16x8:  return 8
        case .dct8x16:  return 16
        case .dct32x8:  return 8
        case .dct8x32:  return 32
        case .dct32x16: return 16
        case .dct16x32: return 32
        }
    }

    /// Total number of coefficients in this block
    public var coefficientCount: Int {
        return width * height
    }

    /// Number of 8×8 sub-blocks in this block (for grid alignment)
    public var subBlockCount: Int {
        return (width / 8) * (height / 8)
    }
}

/// VarDCT frame header per ISO/IEC 18181-1 §6
///
/// Contains all parameters needed to decode a VarDCT frame including
/// frame dimensions, color transform, quantization, and block size information.
struct VarDCTFrameHeader: Sendable {
    /// Frame encoding mode (false = VarDCT)
    let isModular: Bool
    /// Image width in pixels
    let width: UInt32
    /// Image height in pixels
    let height: UInt32
    /// Number of colour channels
    let channels: UInt8
    /// Distance parameter (IEEE 754 float) — quantization control
    let distance: Float
    /// Encoding flags (bit 0: adaptive quantization, bit 1: ANS entropy)
    let flags: UInt8
    /// Pixel type (0=uint8, 1=uint16, 2=float32)
    let pixelType: UInt8
    /// Color transform (0=YCbCr, 1=XYB, 2=none)
    let colorTransform: UInt8
    /// Variable block size mode (0=fixed 8×8, 1=variable)
    let variableBlockSize: UInt8
    /// Number of progressive passes (1=non-progressive, 3=progressive)
    let numPasses: UInt8
    /// Frame header version for forward compatibility
    static let headerVersion: UInt8 = 1

    /// Whether adaptive quantization is enabled
    var adaptiveQuantization: Bool { (flags & 0x01) != 0 }
    /// Whether ANS entropy coding is enabled
    var useANS: Bool { (flags & 0x02) != 0 }
    /// Whether variable block sizes are enabled
    var hasVariableBlocks: Bool { variableBlockSize != 0 }
}

/// Progressive pass definition for multi-pass encoding
struct ProgressivePass {
    /// Pass index (0 = DC-only, 1+ = AC passes)
    let passIndex: Int
    
    /// Range of coefficient indices to encode in this pass (in zigzag order)
    /// For DC-only pass: 0..<1
    /// For AC passes: 1..<16, 16..<64, etc.
    let coefficientRange: Range<Int>
    
    /// Human-readable description of the pass
    var description: String {
        if coefficientRange == 0..<1 {
            return "DC-only pass"
        } else if coefficientRange == 1..<16 {
            return "Low-frequency AC pass (1-15)"
        } else if coefficientRange == 16..<64 {
            return "High-frequency AC pass (16-63)"
        } else {
            return "AC pass \(coefficientRange)"
        }
    }
}

/// Quality layer definition for responsive encoding
struct QualityLayer {
    /// Layer index (0 = lowest quality/preview, higher = better quality)
    let layerIndex: Int
    
    /// Distance value for this layer (lower = higher quality)
    let distance: Float
    
    /// Human-readable description of the layer
    var description: String {
        if layerIndex == 0 {
            return "Preview layer (distance: \(String(format: "%.2f", distance)))"
        } else {
            return "Quality layer \(layerIndex) (distance: \(String(format: "%.2f", distance)))"
        }
    }
}

/// VarDCT encoder for lossy compression
class VarDCTEncoder {
    private let hardware: HardwareCapabilities
    private let options: EncodingOptions
    private let distance: Float
    
    /// DCT block size (8x8 is standard)
    private let blockSize = 8
    
    /// Fixed-point scale factor for encoding CfL coefficients to the bitstream.
    ///
    /// The floating-point CfL coefficient is multiplied by this value,
    /// rounded, and stored as an integer so the decoder can reconstruct it.
    static let cflScaleFactor: Float = 256
    
    /// Minimum adaptive quantisation scale (floor for high-activity blocks).
    static let minAdaptiveScale: Float = 0.5
    
    /// Maximum adaptive quantisation scale (ceiling for flat blocks).
    static let maxAdaptiveScale: Float = 2.0
    
    /// Fixed-point scale factor for encoding per-block quantisation fields.
    ///
    /// The floating-point activity scale is multiplied by this value,
    /// rounded, and stored as a varint so the decoder can reconstruct
    /// the adaptive quantisation matrix for each block.
    static let qfScaleFactor: Float = 256
    
    /// Minimum number of blocks required to use async Metal GPU pipeline.
    ///
    /// Below this threshold, the overhead of GPU transfer and async coordination
    /// outweighs the benefit. Empirically chosen based on Apple Silicon performance.
    private static let minBlocksForAsyncGPU = 32
    
    /// Batch size for Metal GPU processing.
    ///
    /// Processing blocks in batches of 64 provides good GPU utilization while
    /// keeping memory footprint reasonable. Larger batches increase throughput
    /// but require more memory for buffering.
    private static let metalBatchSize = 64
    
    init(hardware: HardwareCapabilities, options: EncodingOptions, distance: Float) {
        self.hardware = hardware
        self.options = options
        self.distance = distance
    }
    
    /// Generate progressive passes for multi-pass encoding
    ///
    /// Returns an array of ProgressivePass structures defining how to split
    /// DCT coefficients across multiple rendering passes.
    ///
    /// - Returns: Array of passes (1 pass for non-progressive, 3 passes for progressive)
    private func generateProgressivePasses() -> [ProgressivePass] {
        guard options.progressive else {
            // Non-progressive: encode all coefficients in a single pass
            return [ProgressivePass(passIndex: 0, coefficientRange: 0..<64)]
        }
        
        // Progressive encoding with 3 passes:
        // Pass 0: DC coefficients only (coefficient 0)
        // Pass 1: Low-frequency AC coefficients (coefficients 1-15)
        // Pass 2: High-frequency AC coefficients (coefficients 16-63)
        return [
            ProgressivePass(passIndex: 0, coefficientRange: 0..<1),   // DC-only
            ProgressivePass(passIndex: 1, coefficientRange: 1..<16),  // Low-freq AC
            ProgressivePass(passIndex: 2, coefficientRange: 16..<64)  // High-freq AC
        ]
    }
    
    /// Generate quality layers for responsive encoding
    ///
    /// Returns an array of QualityLayer structures defining progressive quality refinement.
    /// Each layer uses a different distance (quantization) value, allowing decoders to
    /// progressively improve image quality as more data arrives.
    ///
    /// - Parameter baseDistance: Base distance value (from quality setting)
    /// - Returns: Array of quality layers (1 layer for non-responsive, N layers for responsive)
    private func generateQualityLayers(baseDistance: Float) -> [QualityLayer] {
        guard options.responsiveEncoding else {
            // Non-responsive: single quality layer
            return [QualityLayer(layerIndex: 0, distance: baseDistance)]
        }
        
        // Get responsive configuration or use default
        let config = options.responsiveConfig ?? ResponsiveConfig()
        
        // Use custom distances if provided
        if !config.layerDistances.isEmpty {
            return config.layerDistances.enumerated().map { index, distance in
                QualityLayer(layerIndex: index, distance: distance)
            }
        }
        
        // Auto-generate quality layers based on layer count
        // Strategy: distribute distances logarithmically from high (preview) to low (final)
        // Layer 0: Preview with significantly higher distance (lower quality)
        // Middle layers: Progressively lower distances
        // Final layer: Base distance (target quality)
        
        var layers: [QualityLayer] = []
        let layerCount = config.layerCount
        
        // Calculate distance range
        // Preview layer should be 4-8x the base distance (much lower quality for fast preview)
        let previewMultiplier: Float = 6.0
        let maxDistance = min(baseDistance * previewMultiplier, 15.0) // Cap at distance 15
        let minDistance = baseDistance
        
        for i in 0..<layerCount {
            let progress = Float(layerCount - 1 - i) / Float(layerCount - 1)
            // Use exponential distribution for better perceptual quality steps
            let distance: Float
            if layerCount == 1 {
                distance = baseDistance
            } else {
                // Exponential interpolation: distance = max * (min/max)^(1-progress)
                distance = maxDistance * pow(minDistance / maxDistance, 1.0 - progress)
            }
            layers.append(QualityLayer(layerIndex: i, distance: distance))
        }
        
        return layers
    }
    
    /// Encode frame using VarDCT mode
    func encode(frame: ImageFrame) throws -> Data {
        var writer = BitstreamWriter()
        
        // Validate ROI if configured
        if let roi = options.regionOfInterest {
            try roi.validate(imageWidth: frame.width, imageHeight: frame.height)
        }
        
        // Write VarDCT mode indicator
        writer.writeBit(false) // Use VarDCT mode

        // Write VarDCT header: distance (IEEE 754) + encoding flags + pixel type
        writer.flushByte()
        writer.writeU32(distance.bitPattern)
        var flags: UInt8 = 0
        if options.adaptiveQuantization { flags |= 0x01 }
        if options.useANS { flags |= 0x02 }
        writer.writeByte(flags)
        // Pixel type byte so the decoder can derive the CbCr offset
        switch frame.pixelType {
        case .uint8:   writer.writeByte(0)
        case .uint16:  writer.writeByte(1)
        case .float32: writer.writeByte(2)
        }

        // Convert to YCbCr colour space as float channel arrays.
        // Using float arrays directly avoids uint8 clamping that would
        // destroy Cb/Cr precision for low-dynamic-range pixel types.
        let channelArrays = convertToYCbCrFloat(frame: frame)
        
        // Compute luma DCT blocks for CfL prediction (only if we have chroma)
        let lumaDCTBlocks: [[[[Float]]]]?
        if frame.channels >= 3 {
            // Use async Metal pipeline for better performance on large images
            lumaDCTBlocks = computeDCTBlocksAsync(
                data: channelArrays[0],
                width: frame.width,
                height: frame.height
            )
        } else {
            lumaDCTBlocks = nil
        }
        
        // Process each channel with DCT
        for channel in 0..<frame.channels {
            let encoded = try encodeChannelDCT(
                data: channelArrays[channel],
                width: frame.width,
                height: frame.height,
                channel: channel,
                lumaDCTBlocks: (channel > 0) ? lumaDCTBlocks : nil
            )
            writer.writeData(encoded)
        }
        
        writer.flushByte()
        return writer.data
    }
    
    // MARK: - Color Space Conversion
    
    /// Convert RGB frame to YCbCr colour space using BT.601 coefficients.
    ///
    /// - Note: The conversion computes output values in 16-bit range (0–65535)
    ///   regardless of the frame's pixel type. For `uint8` frames, `setPixel`
    ///   clamps the 16-bit result to 0–255, which saturates chroma channels.
    ///   This is acceptable because the VarDCT pipeline reads the written
    ///   values back through `getPixel`, maintaining internal consistency.
    func convertToYCbCr(frame: ImageFrame) -> ImageFrame {
        // Only convert RGB images
        guard frame.channels >= 3 else {
            return frame
        }
        
        #if canImport(Accelerate)
        if hardware.hasAccelerate && options.useAccelerate {
            return convertToYCbCrAccelerate(frame: frame)
        }
        #endif
        
        #if arch(arm64)
        if hardware.hasNEON && options.useHardwareAcceleration {
            return convertToYCbCrNEON(frame: frame)
        }
        #endif
        
        #if arch(x86_64)
        if options.useHardwareAcceleration {
            return convertToYCbCrSSE(frame: frame)
        }
        #endif
        
        // Scalar fallback
        return convertToYCbCrScalar(frame: frame)
    }
    
    // MARK: - XYB Colour Space Conversion
    
    /// Opsin absorbance bias used in the cube-root transfer function.
    ///
    /// Per ISO/IEC 18181-1, the transfer function is:
    ///   `f(x) = cbrt(x + bias) - cbrt(bias)`
    /// where `bias = 0.00379246`.
    static let opsinBias: Float = 0.00379246
    
    /// Cube-root of the opsin bias, precomputed for efficiency.
    static let cbrtBias: Float = cbrt(opsinBias)
    
    /// Opsin absorbance matrix mapping linear RGB to LMS-like cone responses.
    ///
    /// Per the JPEG XL reference implementation, this matrix converts
    /// linear sRGB to opsin absorbance (L, M, S) values.
    static let opsinAbsorbanceMatrix: [Float] = [
        // L row
        0.30078125, 0.63046875, 0.06875,
        // M row
        0.23046875, 0.69531250, 0.07421875,
        // S row
        0.24218750, 0.07812500, 0.67968750
    ]
    
    /// Inverse opsin absorbance matrix (LMS → linear RGB).
    ///
    /// Precomputed from the opsin absorbance matrix using matrix inversion.
    static let inverseOpsinAbsorbanceMatrix: [Float] = [
        // R row
         10.948393,  -9.924701,  -0.023692,
        // G row
         -3.252452,   4.404409,  -0.151958,
        // B row
         -3.527307,   3.030134,   1.497173
    ]
    
    /// Apply the opsin transfer function to a single value.
    ///
    /// Computes `cbrt(x + bias) - cbrt(bias)`, where `bias = 0.00379246`.
    ///
    /// - Parameter x: Linear intensity value (≥ 0)
    /// - Returns: Perceptually linearised value
    static func opsinTransfer(_ x: Float) -> Float {
        cbrt(max(0, x) + opsinBias) - cbrtBias
    }
    
    /// Apply the inverse opsin transfer function to a single value.
    ///
    /// Computes `(v + cbrt(bias))³ - bias`.
    ///
    /// - Parameter v: Opsin-transferred value
    /// - Returns: Linear intensity value
    static func inverseOpsinTransfer(_ v: Float) -> Float {
        let sum = v + cbrtBias
        return sum * sum * sum - opsinBias
    }
    
    /// Convert an RGB frame to the JPEG XL XYB colour space.
    ///
    /// The XYB transform is JPEG XL's native perceptual colour space
    /// (ISO/IEC 18181-1 §9). The pipeline is:
    ///
    /// 1. Linear RGB → LMS via the opsin absorbance matrix
    /// 2. LMS → L'M'S' via a cube-root transfer function
    /// 3. L'M'S' → XYB via `X = (L' - M') / 2`, `Y = (L' + M') / 2`, `B = S'`
    ///
    /// - Parameter frame: Input image frame with ≥ 3 channels (RGB)
    /// - Returns: A new frame with channels reinterpreted as X, Y, B
    func convertToXYB(frame: ImageFrame) -> ImageFrame {
        guard frame.channels >= 3 else {
            return frame
        }
        
        #if canImport(Accelerate)
        if hardware.hasAccelerate && options.useAccelerate {
            return convertToXYBAccelerate(frame: frame)
        }
        #endif
        
        #if arch(arm64)
        if hardware.hasNEON && options.useHardwareAcceleration {
            return convertToXYBNEON(frame: frame)
        }
        #endif
        
        #if arch(x86_64)
        if options.useHardwareAcceleration {
            return convertToXYBSSE(frame: frame)
        }
        #endif
        
        return convertToXYBScalar(frame: frame)
    }
    
    /// Scalar XYB conversion (reference implementation).
    func convertToXYBScalar(frame: ImageFrame) -> ImageFrame {
        var xybFrame = frame
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let r = Float(frame.getPixel(x: x, y: y, channel: 0)) / 65535.0
                let g = Float(frame.getPixel(x: x, y: y, channel: 1)) / 65535.0
                let b = Float(frame.getPixel(x: x, y: y, channel: 2)) / 65535.0
                
                // Step 1: Linear RGB → LMS via opsin absorbance matrix
                let m = VarDCTEncoder.opsinAbsorbanceMatrix
                let lVal = m[0] * r + m[1] * g + m[2] * b
                let mVal = m[3] * r + m[4] * g + m[5] * b
                let sVal = m[6] * r + m[7] * g + m[8] * b
                
                // Step 2: Apply cube-root transfer function
                let lPrime = VarDCTEncoder.opsinTransfer(lVal)
                let mPrime = VarDCTEncoder.opsinTransfer(mVal)
                let sPrime = VarDCTEncoder.opsinTransfer(sVal)
                
                // Step 3: LMS' → XYB
                let xVal = (lPrime - mPrime) * 0.5
                let yVal = (lPrime + mPrime) * 0.5
                let bVal = sPrime
                
                xybFrame.setPixel(x: x, y: y, channel: 0,
                                  value: UInt16(max(0, min(65535, xVal * 65535))))
                xybFrame.setPixel(x: x, y: y, channel: 1,
                                  value: UInt16(max(0, min(65535, yVal * 65535))))
                xybFrame.setPixel(x: x, y: y, channel: 2,
                                  value: UInt16(max(0, min(65535, bVal * 65535))))
            }
        }
        return xybFrame
    }
    
    /// Convert an XYB frame back to linear RGB.
    ///
    /// Applies the inverse of the XYB transform:
    /// 1. XYB → L'M'S': `L' = Y + X`, `M' = Y - X`, `S' = B`
    /// 2. Inverse opsin transfer: `LMS = inverse_transfer(L'M'S')`
    /// 3. LMS → linear RGB via the inverse opsin absorbance matrix
    ///
    /// - Parameter frame: Input frame with channels interpreted as X, Y, B
    /// - Returns: A new frame with channels as linear R, G, B
    func convertFromXYB(frame: ImageFrame) -> ImageFrame {
        guard frame.channels >= 3 else {
            return frame
        }
        
        #if canImport(Accelerate)
        if hardware.hasAccelerate && options.useAccelerate {
            return convertFromXYBAccelerate(frame: frame)
        }
        #endif
        
        #if arch(arm64)
        if hardware.hasNEON && options.useHardwareAcceleration {
            return convertFromXYBNEON(frame: frame)
        }
        #endif
        
        #if arch(x86_64)
        if options.useHardwareAcceleration {
            return convertFromXYBSSE(frame: frame)
        }
        #endif
        
        return convertFromXYBScalar(frame: frame)
    }
    
    /// Scalar inverse XYB conversion (reference implementation).
    func convertFromXYBScalar(frame: ImageFrame) -> ImageFrame {
        var rgbFrame = frame
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let xVal = Float(frame.getPixel(x: x, y: y, channel: 0)) / 65535.0
                let yVal = Float(frame.getPixel(x: x, y: y, channel: 1)) / 65535.0
                let bVal = Float(frame.getPixel(x: x, y: y, channel: 2)) / 65535.0
                
                // Step 1: XYB → L'M'S'
                let lPrime = yVal + xVal
                let mPrime = yVal - xVal
                let sPrime = bVal
                
                // Step 2: Inverse opsin transfer
                let lVal = VarDCTEncoder.inverseOpsinTransfer(lPrime)
                let mVal = VarDCTEncoder.inverseOpsinTransfer(mPrime)
                let sVal = VarDCTEncoder.inverseOpsinTransfer(sPrime)
                
                // Step 3: LMS → linear RGB via inverse matrix
                let im = VarDCTEncoder.inverseOpsinAbsorbanceMatrix
                let r = im[0] * lVal + im[1] * mVal + im[2] * sVal
                let g = im[3] * lVal + im[4] * mVal + im[5] * sVal
                let b = im[6] * lVal + im[7] * mVal + im[8] * sVal
                
                rgbFrame.setPixel(x: x, y: y, channel: 0,
                                  value: UInt16(max(0, min(65535, r * 65535))))
                rgbFrame.setPixel(x: x, y: y, channel: 1,
                                  value: UInt16(max(0, min(65535, g * 65535))))
                rgbFrame.setPixel(x: x, y: y, channel: 2,
                                  value: UInt16(max(0, min(65535, b * 65535))))
            }
        }
        return rgbFrame
    }
    
    #if canImport(Accelerate)
    /// Accelerate-based XYB conversion using vectorised operations.
    private func convertToXYBAccelerate(frame: ImageFrame) -> ImageFrame {
        var xybFrame = frame
        let pixelCount = frame.width * frame.height
        
        var rChannel = [Float](repeating: 0, count: pixelCount)
        var gChannel = [Float](repeating: 0, count: pixelCount)
        var bChannel = [Float](repeating: 0, count: pixelCount)
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                rChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 0)) / 65535.0
                gChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 1)) / 65535.0
                bChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 2)) / 65535.0
            }
        }
        
        let (xArr, yArr, bArr) = AccelerateOps.rgbToXYB(
            r: rChannel, g: gChannel, b: bChannel
        )
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                xybFrame.setPixel(x: x, y: y, channel: 0,
                                  value: UInt16(max(0, min(65535, xArr[idx] * 65535))))
                xybFrame.setPixel(x: x, y: y, channel: 1,
                                  value: UInt16(max(0, min(65535, yArr[idx] * 65535))))
                xybFrame.setPixel(x: x, y: y, channel: 2,
                                  value: UInt16(max(0, min(65535, bArr[idx] * 65535))))
            }
        }
        
        return xybFrame
    }
    
    /// Accelerate-based inverse XYB conversion.
    private func convertFromXYBAccelerate(frame: ImageFrame) -> ImageFrame {
        var rgbFrame = frame
        let pixelCount = frame.width * frame.height
        
        var xChannel = [Float](repeating: 0, count: pixelCount)
        var yChannel = [Float](repeating: 0, count: pixelCount)
        var bChannel = [Float](repeating: 0, count: pixelCount)
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                xChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 0)) / 65535.0
                yChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 1)) / 65535.0
                bChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 2)) / 65535.0
            }
        }
        
        let (rArr, gArr, bArr) = AccelerateOps.xybToRGB(
            x: xChannel, y: yChannel, b: bChannel
        )
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                rgbFrame.setPixel(x: x, y: y, channel: 0,
                                  value: UInt16(max(0, min(65535, rArr[idx] * 65535))))
                rgbFrame.setPixel(x: x, y: y, channel: 1,
                                  value: UInt16(max(0, min(65535, gArr[idx] * 65535))))
                rgbFrame.setPixel(x: x, y: y, channel: 2,
                                  value: UInt16(max(0, min(65535, bArr[idx] * 65535))))
            }
        }
        
        return rgbFrame
    }
    #endif
    
    /// Scalar YCbCr conversion (reference implementation).
    private func convertToYCbCrScalar(frame: ImageFrame) -> ImageFrame {
        var ycbcrFrame = frame
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let r = Float(frame.getPixel(x: x, y: y, channel: 0)) / 65535.0
                let g = Float(frame.getPixel(x: x, y: y, channel: 1)) / 65535.0
                let b = Float(frame.getPixel(x: x, y: y, channel: 2)) / 65535.0
                
                // ITU-R BT.601 conversion
                let yVal = 0.299 * r + 0.587 * g + 0.114 * b
                let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 0.5
                let cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 0.5
                
                ycbcrFrame.setPixel(x: x, y: y, channel: 0, value: UInt16(yVal * 65535))
                ycbcrFrame.setPixel(x: x, y: y, channel: 1, value: UInt16(cb * 65535))
                ycbcrFrame.setPixel(x: x, y: y, channel: 2, value: UInt16(cr * 65535))
            }
        }
        return ycbcrFrame
    }
    
    #if canImport(Accelerate)
    /// Accelerate-based YCbCr conversion using vectorised BT.601 operations.
    private func convertToYCbCrAccelerate(frame: ImageFrame) -> ImageFrame {
        var ycbcrFrame = frame
        let pixelCount = frame.width * frame.height
        
        // Extract channels as float arrays
        var rChannel = [Float](repeating: 0, count: pixelCount)
        var gChannel = [Float](repeating: 0, count: pixelCount)
        var bChannel = [Float](repeating: 0, count: pixelCount)
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                rChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 0)) / 65535.0
                gChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 1)) / 65535.0
                bChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 2)) / 65535.0
            }
        }
        
        let (yArr, cbArr, crArr) = AccelerateOps.rgbToYCbCr(
            r: rChannel, g: gChannel, b: bChannel
        )
        
        // Write back
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                ycbcrFrame.setPixel(x: x, y: y, channel: 0, value: UInt16(yArr[idx] * 65535))
                ycbcrFrame.setPixel(x: x, y: y, channel: 1, value: UInt16(cbArr[idx] * 65535))
                ycbcrFrame.setPixel(x: x, y: y, channel: 2, value: UInt16(crArr[idx] * 65535))
            }
        }
        
        return ycbcrFrame
    }
    #endif
    
    // MARK: - Channel Extraction
    
    private func extractChannel(frame: ImageFrame, channel: Int) -> [[Float]] {
        var channelData = [[Float]](
            repeating: [Float](repeating: 0, count: frame.width),
            count: frame.height
        )
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                channelData[y][x] = Float(frame.getPixel(x: x, y: y, channel: channel))
            }
        }
        
        return channelData
    }

    /// Convert an RGB frame to YCbCr as float channel arrays.
    ///
    /// Unlike ``convertToYCbCr(frame:)`` this method returns float arrays
    /// directly, avoiding uint8 clamping that would destroy Cb/Cr precision.
    /// The normalisation uses 65535 for consistency with
    /// ``extractChannel(frame:channel:)``.
    ///
    /// For single-channel images, returns the channel as-is.
    ///
    /// - Parameter frame: Input RGB frame.
    /// - Returns: Array of 2D float arrays, one per channel.
    func convertToYCbCrFloat(frame: ImageFrame) -> [[[Float]]] {
        guard frame.channels >= 3 else {
            return (0..<frame.channels).map { extractChannel(frame: frame, channel: $0) }
        }

        let w = frame.width
        let h = frame.height
        // Offset for Cb/Cr centring — half the maximum getPixel value
        let offset = VarDCTEncoder.cbcrOffset(for: frame.pixelType)

        var yArr = [[Float]](repeating: [Float](repeating: 0, count: w), count: h)
        var cbArr = [[Float]](repeating: [Float](repeating: 0, count: w), count: h)
        var crArr = [[Float]](repeating: [Float](repeating: 0, count: w), count: h)

        for y in 0..<h {
            for x in 0..<w {
                let r = Float(frame.getPixel(x: x, y: y, channel: 0))
                let g = Float(frame.getPixel(x: x, y: y, channel: 1))
                let b = Float(frame.getPixel(x: x, y: y, channel: 2))

                yArr[y][x]  =  0.299    * r + 0.587    * g + 0.114    * b
                cbArr[y][x] = -0.168736 * r - 0.331264 * g + 0.5      * b + offset
                crArr[y][x] =  0.5      * r - 0.418688 * g - 0.081312 * b + offset
            }
        }

        var result = [yArr, cbArr, crArr]
        // Preserve extra channels (alpha, etc.)
        for c in 3..<frame.channels {
            result.append(extractChannel(frame: frame, channel: c))
        }
        return result
    }

    /// Cb/Cr offset for centring chroma around zero.
    ///
    /// Returns half the maximum `getPixel` value for the given pixel type.
    static func cbcrOffset(for pixelType: PixelType) -> Float {
        switch pixelType {
        case .uint8:   return 128.0
        case .uint16:  return 32768.0
        case .float32: return 32768.0
        }
    }
    
    // MARK: - Chroma-from-Luma (CfL) Prediction
    
    /// Compute all DCT blocks for a channel without encoding them.
    ///
    /// Used to pre-compute luma DCT coefficients so they can drive
    /// Chroma-from-Luma (CfL) prediction on the chroma channels.
    ///
    /// - Parameters:
    ///   - data: 2D float pixel data (row-major, value range 0–1).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    /// - Returns: 2D grid of 8×8 DCT coefficient blocks indexed as
    ///   `[blockY][blockX][row][col]`.
    func computeDCTBlocks(
        data: [[Float]],
        width: Int,
        height: Int
    ) -> [[[[Float]]]] {
        let blocksX = (width + blockSize - 1) / blockSize
        let blocksY = (height + blockSize - 1) / blockSize
        
        var blocks = [[[[Float]]]](
            repeating: [[[Float]]](
                repeating: [[Float]](
                    repeating: [Float](repeating: 0, count: blockSize),
                    count: blockSize
                ),
                count: blocksX
            ),
            count: blocksY
        )
        
        for blockY in 0..<blocksY {
            for blockX in 0..<blocksX {
                let block = extractBlock(
                    data: data, blockX: blockX, blockY: blockY,
                    width: width, height: height
                )
                blocks[blockY][blockX] = applyDCT(block: block)
            }
        }
        
        return blocks
    }
    
    /// Compute all DCT blocks for a channel using async Metal GPU pipeline when beneficial.
    ///
    /// This version attempts to use the async Metal GPU pipeline for better performance
    /// on large images by overlapping CPU and GPU work. Falls back to synchronous processing
    /// if Metal is unavailable or batch size is too small.
    ///
    /// - Parameters:
    ///   - data: 2D float pixel data (row-major, value range 0–1).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    /// - Returns: 2D grid of 8×8 DCT coefficient blocks indexed as
    ///   `[blockY][blockX][row][col]`.
    func computeDCTBlocksAsync(
        data: [[Float]],
        width: Int,
        height: Int
    ) -> [[[[Float]]]] {
        let blocksX = (width + blockSize - 1) / blockSize
        let blocksY = (height + blockSize - 1) / blockSize
        let totalBlocks = blocksX * blocksY
        
        // Only use async Metal for larger images where benefit outweighs overhead
        #if canImport(Metal)
        if hardware.hasMetal && options.useMetal && totalBlocks >= Self.minBlocksForAsyncGPU {
            if let result = computeDCTBlocksMetalAsync(data: data, width: width, height: height, blocksX: blocksX, blocksY: blocksY) {
                return result
            }
            // Fall through to sync version if async Metal fails
        }
        #endif

        // Use Vulkan GPU for larger images on Linux/Windows
        // Note: reuses `options.useMetal` as a general "enable GPU acceleration" flag;
        // the option will be renamed to `useGPU` in a future API version.
        #if canImport(Vulkan)
        if hardware.hasVulkan && options.useMetal && totalBlocks >= Self.minBlocksForAsyncGPU {
            if let result = computeDCTBlocksVulkanAsync(data: data, width: width, height: height, blocksX: blocksX, blocksY: blocksY) {
                return result
            }
            // Fall through to sync version if Vulkan fails
        }
        #endif
        
        // Fallback to synchronous processing
        return computeDCTBlocks(data: data, width: width, height: height)
    }
    
    #if canImport(Metal)
    /// Internal helper to process DCT blocks using async Metal pipeline
    private func computeDCTBlocksMetalAsync(
        data: [[Float]],
        width: Int,
        height: Int,
        blocksX: Int,
        blocksY: Int
    ) -> [[[[Float]]]]? {
        guard MetalOps.isAvailable else { return nil }
        
        // Extract all blocks first (CPU preparation phase)
        var flatBlocks: [[Float]] = []
        flatBlocks.reserveCapacity(blocksX * blocksY)
        
        for blockY in 0..<blocksY {
            for blockX in 0..<blocksX {
                let block = extractBlock(
                    data: data, blockX: blockX, blockY: blockY,
                    width: width, height: height
                )
                // Flatten 2D block to 1D for Metal processing
                let flatBlock = block.flatMap { $0 }
                flatBlocks.append(flatBlock)
            }
        }
        
        // Process in batches using Metal async pipeline
        var allResults: [[Float]] = []
        allResults.reserveCapacity(flatBlocks.count)
        
        // Thread-safety synchronization:
        // - DispatchGroup: Coordinates completion of all async operations
        // - DCTBatchState (lock-protected): Protects shared mutable state (processedResults, hasError)
        let dispatchGroup = DispatchGroup()
        let batchState = DCTBatchState(count: flatBlocks.count)
        
        // Process batches with double-buffering via async pipeline
        for batchStart in stride(from: 0, to: flatBlocks.count, by: Self.metalBatchSize) {
            let batchEnd = min(batchStart + Self.metalBatchSize, flatBlocks.count)
            let batch = Array(flatBlocks[batchStart..<batchEnd])
            
            dispatchGroup.enter()
            
            // Flatten batch for Metal (each block is 64 floats)
            let flatData = batch.flatMap { $0 }
            let blockCount = batch.count
            
            // Arrange blocks horizontally for Metal
            let metalWidth = 8 * blockCount
            let metalHeight = 8
            
            MetalCompute.dct8x8Async(
                inputData: flatData,
                width: metalWidth,
                height: metalHeight
            ) { result in
                defer { dispatchGroup.leave() }
                
                guard let transformed = result else {
                    batchState.setError()
                    return
                }
                
                // Split back into blocks
                var batchResults: [[Float]] = []
                batchResults.reserveCapacity(blockCount)
                
                for blockIdx in 0..<blockCount {
                    let blockStart = blockIdx * 64
                    let blockEnd = blockStart + 64
                    let blockData = Array(transformed[blockStart..<blockEnd])
                    batchResults.append(blockData)
                }
                
                // Store results
                batchState.setResults(batchResults, startingAt: batchStart)
            }
        }
        
        // Wait for all batches to complete
        dispatchGroup.wait()
        
        // Check for errors
        if batchState.hadError {
            return nil
        }
        
        let processedResults = batchState.getResults()
        
        // Reconstruct 4D block structure from flat results
        var blocks = [[[[Float]]]](
            repeating: [[[Float]]](
                repeating: [[Float]](
                    repeating: [Float](repeating: 0, count: blockSize),
                    count: blockSize
                ),
                count: blocksX
            ),
            count: blocksY
        )
        
        var blockIdx = 0
        for blockY in 0..<blocksY {
            for blockX in 0..<blocksX {
                guard let flatBlock = processedResults[blockIdx] else {
                    return nil // Missing result
                }
                
                // Reshape flat 64-element array to 8×8 2D array
                var block = [[Float]](
                    repeating: [Float](repeating: 0, count: blockSize),
                    count: blockSize
                )
                for i in 0..<blockSize {
                    for j in 0..<blockSize {
                        block[i][j] = flatBlock[i * blockSize + j]
                    }
                }
                blocks[blockY][blockX] = block
                blockIdx += 1
            }
        }
        
        return blocks
    }
    
    /// Thread-safe state container for DCT batch processing results
    ///
    /// Thread Safety: Uses `@unchecked Sendable` with `NSLock` protection for
    /// mutable `results` and `hasError`. All mutations go through the lock.
    private final class DCTBatchState: @unchecked Sendable {
        private var results: [[Float]?]
        private var _hasError: Bool = false
        private let lock = NSLock()
        
        init(count: Int) {
            self.results = Array(repeating: nil, count: count)
        }
        
        /// Mark that an error occurred
        func setError() {
            lock.lock()
            defer { lock.unlock() }
            _hasError = true
        }
        
        /// Set batch results starting at the given index
        func setResults(_ batchResults: [[Float]], startingAt offset: Int) {
            lock.lock()
            defer { lock.unlock() }
            for (idx, blockResult) in batchResults.enumerated() {
                results[offset + idx] = blockResult
            }
        }
        
        /// Whether an error occurred during processing
        var hadError: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _hasError
        }
        
        /// Get the final results array
        func getResults() -> [[Float]?] {
            lock.lock()
            defer { lock.unlock() }
            return results
        }
    }
    #endif

    #if canImport(Vulkan)
    /// Internal helper to process DCT blocks using async Vulkan pipeline on Linux/Windows.
    private func computeDCTBlocksVulkanAsync(
        data: [[Float]],
        width: Int,
        height: Int,
        blocksX: Int,
        blocksY: Int
    ) -> [[[[Float]]]]? {
        guard VulkanOps.isAvailable else { return nil }

        let blockSize = 8
        var flatBlocks: [[Float]] = []
        flatBlocks.reserveCapacity(blocksX * blocksY)

        for blockY in 0..<blocksY {
            for blockX in 0..<blocksX {
                let block = extractBlock(
                    data: data, blockX: blockX, blockY: blockY,
                    width: width, height: height
                )
                flatBlocks.append(block.flatMap { $0 })
            }
        }

        let dispatchGroup = DispatchGroup()
        let batchState = DCTBatchState(count: flatBlocks.count)

        for batchStart in stride(from: 0, to: flatBlocks.count, by: Self.metalBatchSize) {
            let batchEnd = min(batchStart + Self.metalBatchSize, flatBlocks.count)
            let batch = Array(flatBlocks[batchStart..<batchEnd])
            let blockCount = batch.count
            let flatData = batch.flatMap { $0 }
            let vulkanWidth = 8 * blockCount
            let vulkanHeight = 8

            dispatchGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { dispatchGroup.leave() }
                guard let transformed = VulkanCompute.dct8x8(
                    inputData: flatData, width: vulkanWidth, height: vulkanHeight
                ) else {
                    batchState.setError()
                    return
                }
                var batchResults: [[Float]] = []
                batchResults.reserveCapacity(blockCount)
                for blockIdx in 0..<blockCount {
                    let start = blockIdx * 64
                    batchResults.append(Array(transformed[start..<start + 64]))
                }
                batchState.setResults(batchResults, startingAt: batchStart)
            }
        }

        dispatchGroup.wait()
        guard !batchState.hadError else { return nil }

        let processedResults = batchState.getResults()
        var blocks = [[[[Float]]]](
            repeating: [[[Float]]](
                repeating: [[Float]](
                    repeating: [Float](repeating: 0, count: blockSize),
                    count: blockSize
                ),
                count: blocksX
            ),
            count: blocksY
        )

        var blockIdx = 0
        for blockY in 0..<blocksY {
            for blockX in 0..<blocksX {
                guard let flatBlock = processedResults[blockIdx] else { return nil }
                var block = [[Float]](
                    repeating: [Float](repeating: 0, count: blockSize),
                    count: blockSize
                )
                for i in 0..<blockSize {
                    for j in 0..<blockSize {
                        block[i][j] = flatBlock[i * blockSize + j]
                    }
                }
                blocks[blockY][blockX] = block
                blockIdx += 1
            }
        }
        return blocks
    }
    #endif // canImport(Vulkan)

    ///
    /// Determines how well the chroma DCT coefficients can be predicted
    /// from the luma DCT coefficients using a linear model:
    ///
    ///     predicted_chroma[u][v] = cflCoefficient × luma[u][v]
    ///
    /// The optimal coefficient minimises the sum of squared residuals
    /// and is computed as:
    ///
    ///     cflCoefficient = Σ(luma × chroma) / Σ(luma × luma)
    ///
    /// The DC coefficient (position [0][0]) is excluded because it is
    /// encoded separately via DC prediction.
    ///
    /// - Parameters:
    ///   - lumaDCT: 8×8 luma DCT coefficients.
    ///   - chromaDCT: 8×8 chroma DCT coefficients.
    /// - Returns: The CfL correlation coefficient.  Returns 0 when the
    ///   luma energy is negligible (no useful prediction possible).
    func computeCfLCoefficient(lumaDCT: [[Float]], chromaDCT: [[Float]]) -> Float {
        var lumaChromaSum: Float = 0
        var lumaLumaSum: Float = 0
        
        for v in 0..<blockSize {
            for u in 0..<blockSize {
                // Skip DC coefficient (encoded separately)
                if u == 0 && v == 0 { continue }
                
                let l = lumaDCT[v][u]
                let c = chromaDCT[v][u]
                
                lumaChromaSum += l * c
                lumaLumaSum += l * l
            }
        }
        
        // Avoid division by zero; if luma has no AC energy, CfL is useless
        guard lumaLumaSum > 1e-10 else { return 0 }
        
        return lumaChromaSum / lumaLumaSum
    }
    
    /// Apply CfL prediction to a chroma DCT block.
    ///
    /// Subtracts the luma-based prediction from the chroma block,
    /// leaving only the residual to be quantized and encoded.
    ///
    /// - Parameters:
    ///   - chromaDCT: 8×8 chroma DCT coefficients (modified in place conceptually).
    ///   - lumaDCT: 8×8 luma DCT coefficients.
    ///   - coefficient: CfL correlation coefficient from ``computeCfLCoefficient``.
    /// - Returns: A new 8×8 block of chroma residuals after CfL prediction.
    func applyCfLPrediction(
        chromaDCT: [[Float]],
        lumaDCT: [[Float]],
        coefficient: Float
    ) -> [[Float]] {
        var residual = chromaDCT
        
        for v in 0..<blockSize {
            for u in 0..<blockSize {
                // Skip DC coefficient (encoded separately)
                if u == 0 && v == 0 { continue }
                
                residual[v][u] = chromaDCT[v][u] - coefficient * lumaDCT[v][u]
            }
        }
        
        return residual
    }
    
    /// Reconstruct chroma DCT coefficients from CfL residuals.
    ///
    /// This is the inverse of ``applyCfLPrediction`` and would be used
    /// by a decoder to recover the original chroma coefficients.
    ///
    /// - Parameters:
    ///   - residual: 8×8 chroma residual block.
    ///   - lumaDCT: 8×8 luma DCT coefficients.
    ///   - coefficient: CfL correlation coefficient.
    /// - Returns: Reconstructed 8×8 chroma DCT coefficients.
    func reconstructFromCfL(
        residual: [[Float]],
        lumaDCT: [[Float]],
        coefficient: Float
    ) -> [[Float]] {
        var chroma = residual
        
        for v in 0..<blockSize {
            for u in 0..<blockSize {
                if u == 0 && v == 0 { continue }
                
                chroma[v][u] = residual[v][u] + coefficient * lumaDCT[v][u]
            }
        }
        
        return chroma
    }
    
    // MARK: - DCT Encoding
    
    private func encodeChannelDCT(
        data: [[Float]],
        width: Int,
        height: Int,
        channel: Int,
        lumaDCTBlocks: [[[[Float]]]]? = nil
    ) throws -> Data {
        // Check if progressive encoding is enabled
        if options.progressive {
            return try encodeChannelDCTProgressive(
                data: data,
                width: width,
                height: height,
                channel: channel,
                lumaDCTBlocks: lumaDCTBlocks
            )
        }
        
        // Non-progressive encoding (existing code)
        var writer = BitstreamWriter()
        
        // Process image in 8x8 blocks
        let blocksX = (width + blockSize - 1) / blockSize
        let blocksY = (height + blockSize - 1) / blockSize
        
        // Track quantized DC values for inter-block prediction
        var dcValues = [[Int16]](
            repeating: [Int16](repeating: 0, count: blocksX),
            count: blocksY
        )
        
        let useAdaptive = options.adaptiveQuantization
        let useANS = options.useANS
        
        // Initialize noise synthesizer if configured
        var noiseSynthesizer: NoiseSynthesizer? = nil
        if let noiseConfig = options.noiseConfig, noiseConfig.enabled {
            noiseSynthesizer = NoiseSynthesizer(config: noiseConfig)
        }
        
        // ANS mode: collect all blocks and DC residuals for batch encoding
        var allBlocks = [[[Int16]]]()
        var allDCResiduals = [Int16]()
        
        for blockY in 0..<blocksY {
            for blockX in 0..<blocksX {
                // Extract block
                let block = extractBlock(
                    data: data,
                    blockX: blockX,
                    blockY: blockY,
                    width: width,
                    height: height
                )
                
                // Compute adaptive quantisation scale from spatial activity
                let activity: Float
                if useAdaptive {
                    let rawActivity = computeBlockActivity(block: block)
                    activity = adaptiveQuantizationScale(activity: rawActivity)
                } else {
                    activity = 1.0
                }
                
                // Apply DCT
                var dctBlock = applyDCT(block: block)
                
                // Apply CfL prediction for chroma channels
                if let lumaDCT = lumaDCTBlocks?[blockY][blockX] {
                    let cflCoeff = computeCfLCoefficient(
                        lumaDCT: lumaDCT, chromaDCT: dctBlock
                    )
                    dctBlock = applyCfLPrediction(
                        chromaDCT: dctBlock, lumaDCT: lumaDCT,
                        coefficient: cflCoeff
                    )
                    // Write CfL coefficient to bitstream for decoder
                    writer.writeVarint(encodeSignedValue(
                        Int32(round(cflCoeff * VarDCTEncoder.cflScaleFactor))
                    ))
                }
                
                // Apply noise synthesis if configured
                if noiseSynthesizer != nil {
                    dctBlock = applyNoiseIfConfigured(
                        dctBlock: dctBlock,
                        channel: channel,
                        noiseSynthesizer: &noiseSynthesizer!
                    )
                }
                
                // Quantize with per-block activity scaling
                let quantized = quantize(
                    block: dctBlock, channel: channel, activity: activity
                )
                
                // Write per-block quantisation field for decoder
                if useAdaptive {
                    writer.writeVarint(
                        UInt64(round(activity * VarDCTEncoder.qfScaleFactor))
                    )
                }
                
                // Compute DC prediction residual, then store DC value
                let dc = quantized[0][0]
                let predicted = predictDC(
                    dcValues: dcValues,
                    blockX: blockX,
                    blockY: blockY
                )
                let dcResidual = dc - predicted
                dcValues[blockY][blockX] = dc
                
                if useANS {
                    // Collect for batch ANS encoding
                    allBlocks.append(quantized)
                    allDCResiduals.append(dcResidual)
                } else {
                    // Encode coefficients with DC prediction residual
                    encodeBlock(writer: &writer, block: quantized, dcResidual: dcResidual)
                }
            }
        }
        
        if useANS && !allBlocks.isEmpty {
            // Batch-encode all coefficients with ANS
            let ansData = try encodeBlocksANS(
                allBlocks: allBlocks, dcResiduals: allDCResiduals
            )
            writer.writeData(ansData)
        }
        
        writer.flushByte()
        return writer.data
    }
    
    /// Progressive DCT encoding with multiple frequency passes
    private func encodeChannelDCTProgressive(
        data: [[Float]],
        width: Int,
        height: Int,
        channel: Int,
        lumaDCTBlocks: [[[[Float]]]]? = nil
    ) throws -> Data {
        var writer = BitstreamWriter()
        
        // Process image in 8x8 blocks
        let blocksX = (width + blockSize - 1) / blockSize
        let blocksY = (height + blockSize - 1) / blockSize
        
        // Track quantized DC values for inter-block prediction
        var dcValues = [[Int16]](
            repeating: [Int16](repeating: 0, count: blocksX),
            count: blocksY
        )
        
        let useAdaptive = options.adaptiveQuantization
        let useANS = options.useANS
        
        // Initialize noise synthesizer if configured
        var noiseSynthesizer: NoiseSynthesizer? = nil
        if let noiseConfig = options.noiseConfig, noiseConfig.enabled {
            noiseSynthesizer = NoiseSynthesizer(config: noiseConfig)
        }
        
        // Store all quantized blocks for multi-pass encoding
        var allQuantizedBlocks = [[[Int16]]]()
        var allDCResiduals = [Int16]()
        var allActivities = [Float]()
        var allCfLCoeffs = [Float?]()
        
        // First pass: compute all DCT blocks and quantize them
        for blockY in 0..<blocksY {
            for blockX in 0..<blocksX {
                // Extract block
                let block = extractBlock(
                    data: data,
                    blockX: blockX,
                    blockY: blockY,
                    width: width,
                    height: height
                )
                
                // Compute adaptive quantization scale
                let activity: Float
                if useAdaptive {
                    let rawActivity = computeBlockActivity(block: block)
                    activity = adaptiveQuantizationScale(activity: rawActivity)
                } else {
                    activity = 1.0
                }
                allActivities.append(activity)
                
                // Apply DCT
                var dctBlock = applyDCT(block: block)
                
                // Apply CfL prediction for chroma channels
                var cflCoeff: Float? = nil
                if let lumaDCT = lumaDCTBlocks?[blockY][blockX] {
                    cflCoeff = computeCfLCoefficient(
                        lumaDCT: lumaDCT, chromaDCT: dctBlock
                    )
                    dctBlock = applyCfLPrediction(
                        chromaDCT: dctBlock, lumaDCT: lumaDCT,
                        coefficient: cflCoeff!
                    )
                }
                allCfLCoeffs.append(cflCoeff)
                
                // Apply noise synthesis if configured
                if noiseSynthesizer != nil {
                    dctBlock = applyNoiseIfConfigured(
                        dctBlock: dctBlock,
                        channel: channel,
                        noiseSynthesizer: &noiseSynthesizer!
                    )
                }
                
                // Calculate block-specific distance (for ROI support)
                let blockDistance = calculateBlockDistance(blockX: blockX, blockY: blockY)
                
                // Quantize
                let quantized = quantize(
                    block: dctBlock, channel: channel, activity: activity, distance: blockDistance
                )
                
                // Store DC residual
                let dc = quantized[0][0]
                let predicted = predictDC(
                    dcValues: dcValues,
                    blockX: blockX,
                    blockY: blockY
                )
                let dcResidual = dc - predicted
                dcValues[blockY][blockX] = dc
                
                allQuantizedBlocks.append(quantized)
                allDCResiduals.append(dcResidual)
            }
        }
        
        // Generate progressive passes
        let passes = generateProgressivePasses()
        
        // Encode each pass
        for pass in passes {
            // Write pass marker to help identify boundaries (simplified)
            writer.writeBits(UInt32(pass.passIndex), count: 8)
            
            // Write metadata for this pass (simplified - proper implementation
            // would use section headers per JPEG XL spec)
            var blockIdx = 0
            for _ in 0..<blocksY {
                for _ in 0..<blocksX {
                    // Write CfL coefficient (only in first pass for chroma)
                    if pass.passIndex == 0, let cflCoeff = allCfLCoeffs[blockIdx] {
                        writer.writeVarint(encodeSignedValue(
                            Int32(round(cflCoeff * VarDCTEncoder.cflScaleFactor))
                        ))
                    }
                    
                    // Write per-block quantization field (only in first pass)
                    if pass.passIndex == 0 && useAdaptive {
                        writer.writeVarint(
                            UInt64(round(allActivities[blockIdx] * VarDCTEncoder.qfScaleFactor))
                        )
                    }
                    
                    blockIdx += 1
                }
            }
            
            // Encode coefficients for this pass
            if useANS {
                // Batch ANS encoding for this pass
                let ansData = try encodeBlocksANS(
                    allBlocks: allQuantizedBlocks,
                    dcResiduals: allDCResiduals,
                    coefficientRange: pass.coefficientRange
                )
                writer.writeData(ansData)
            } else {
                // Run-length encoding for each block
                for blockIdx in 0..<allQuantizedBlocks.count {
                    let block = allQuantizedBlocks[blockIdx]
                    let dcResidual = pass.coefficientRange.lowerBound == 0 ?
                        allDCResiduals[blockIdx] : nil
                    encodeBlock(
                        writer: &writer,
                        block: block,
                        dcResidual: dcResidual,
                        coefficientRange: pass.coefficientRange
                    )
                }
            }
        }
        
        writer.flushByte()
        return writer.data
    }
    
    // MARK: - DC Prediction
    
    /// Predict the DC coefficient of the current block from its left and above neighbors.
    ///
    /// Uses a simple predictor inspired by the MED (Median Edge Detector) approach:
    /// - First block (0, 0): prediction is 0 (no neighbors available)
    /// - First row: prediction is the left neighbor's DC
    /// - First column: prediction is the above neighbor's DC
    /// - General case: prediction is the average of left and above neighbors' DC values
    ///
    /// - Parameters:
    ///   - dcValues: 2D grid of quantized DC values for already-processed blocks
    ///   - blockX: Horizontal block index of the current block
    ///   - blockY: Vertical block index of the current block
    /// - Returns: The predicted DC value for the current block
    func predictDC(dcValues: [[Int16]], blockX: Int, blockY: Int) -> Int16 {
        let hasLeft = blockX > 0
        let hasAbove = blockY > 0
        
        if hasLeft && hasAbove {
            // General case: average of left and above
            let left = Int(dcValues[blockY][blockX - 1])
            let above = Int(dcValues[blockY - 1][blockX])
            return Int16((left + above) / 2)
        } else if hasLeft {
            // First row: use left neighbor
            return dcValues[blockY][blockX - 1]
        } else if hasAbove {
            // First column: use above neighbor
            return dcValues[blockY - 1][blockX]
        } else {
            // First block: no prediction available
            return 0
        }
    }
    
    // MARK: - Region of Interest
    
    /// Calculate the effective distance for a block based on ROI configuration.
    ///
    /// If a region of interest is configured, blocks within the ROI will have
    /// lower distance (higher quality), with smooth feathering at the edges.
    ///
    /// - Parameters:
    ///   - blockX: Horizontal block index
    ///   - blockY: Vertical block index
    /// - Returns: Effective distance for this block
    func calculateBlockDistance(blockX: Int, blockY: Int) -> Float {
        guard let roi = options.regionOfInterest else {
            return self.distance
        }
        
        // Calculate the center pixel position of this block
        let centerX = blockX * blockSize + blockSize / 2
        let centerY = blockY * blockSize + blockSize / 2
        
        // Get the distance multiplier for this block's center
        let multiplier = roi.distanceMultiplier(px: centerX, py: centerY)
        
        // Apply multiplier to base distance
        return self.distance * multiplier
    }
    
    func extractBlock(data: [[Float]], blockX: Int, blockY: Int, 
                      width: Int, height: Int) -> [[Float]] {
        var block = [[Float]](
            repeating: [Float](repeating: 0, count: blockSize),
            count: blockSize
        )
        
        let startX = blockX * blockSize
        let startY = blockY * blockSize
        
        for y in 0..<blockSize {
            for x in 0..<blockSize {
                let srcX = min(startX + x, width - 1)
                let srcY = min(startY + y, height - 1)
                block[y][x] = data[srcY][srcX]
            }
        }
        
        return block
    }
    
    // MARK: - DCT Transform
    
    private func applyDCT(block: [[Float]]) -> [[Float]] {
        // Use hardware-accelerated DCT if available
        // Note: Metal is most efficient for batch processing, not single blocks
        if hardware.hasAccelerate && options.useAccelerate {
            return applyDCTAccelerate(block: block)
        } else if hardware.hasNEON && options.useHardwareAcceleration {
            return applyDCTNEON(block: block)
        }
        #if arch(x86_64)
        if options.useHardwareAcceleration {
            if hardware.hasAVX2 {
                return applyDCTAVX(block: block)
            }
            return applyDCTSSE(block: block)
        }
        #endif
        return applyDCTScalar(block: block)
    }
    
    /// SSE-accelerated DCT for x86-64 processors.
    private func applyDCTSSE(block: [[Float]]) -> [[Float]] {
        #if arch(x86_64)
        return SSEOps.dct2D(block)
        #else
        return applyDCTScalar(block: block)
        #endif
    }
    
    /// AVX2-accelerated DCT for x86-64 processors with AVX2 support.
    private func applyDCTAVX(block: [[Float]]) -> [[Float]] {
        #if arch(x86_64)
        return AVXOps.dct2D(block)
        #else
        return applyDCTScalar(block: block)
        #endif
    }
    
    /// Apply DCT to multiple 8×8 blocks in parallel using Metal GPU
    ///
    /// This method is more efficient than processing blocks one at a time.
    /// Falls back to CPU if Metal is unavailable or if batch size is too small.
    ///
    /// - Parameters:
    ///   - blocks: Array of 8×8 blocks (each block is 64 floats in row-major order)
    /// - Returns: Array of DCT-transformed blocks, or `nil` if Metal processing fails
    private func applyDCTBatchMetal(blocks: [[Float]]) -> [[Float]]? {
        #if canImport(Metal)
        guard hardware.hasMetal && options.useMetal else { return nil }
        guard MetalOps.isAvailable else { return nil }
        
        // Only use GPU for larger batches to amortize transfer cost
        let minBlocksForGPU = 16
        guard blocks.count >= minBlocksForGPU else { return nil }
        
        // Flatten all blocks into a single array
        let flatData = blocks.flatMap { $0 }
        let blockCount = blocks.count
        
        // Ensure each block is exactly 64 elements
        guard flatData.count == blockCount * 64 else { return nil }
        
        // Calculate dimensions for Metal processing
        let width = 8 * blockCount // Arrange blocks horizontally
        let height = 8
        
        // Apply DCT using Metal
        guard let transformed = MetalCompute.dct8x8(
            inputData: flatData,
            width: width,
            height: height
        ) else {
            return nil
        }
        
        // Split back into blocks
        var result: [[Float]] = []
        result.reserveCapacity(blockCount)
        
        for blockIdx in 0..<blockCount {
            var block = [Float](repeating: 0, count: 64)
            let baseOffset = blockIdx * 64
            for i in 0..<64 {
                block[i] = transformed[baseOffset + i]
            }
            result.append(block)
        }
        
        return result
        #else
        return nil
        #endif
    }
    
    func applyDCTScalar(block: [[Float]]) -> [[Float]] {
        var dct = [[Float]](
            repeating: [Float](repeating: 0, count: blockSize),
            count: blockSize
        )
        
        let n = Float(blockSize)
        let normFactor = sqrt(2.0 / n)
        
        for u in 0..<blockSize {
            for v in 0..<blockSize {
                var sum: Float = 0
                
                for x in 0..<blockSize {
                    for y in 0..<blockSize {
                        let cu = u == 0 ? Float(1.0 / sqrt(2.0)) : Float(1.0)
                        let cv = v == 0 ? Float(1.0 / sqrt(2.0)) : Float(1.0)
                        
                        let cosU = cos((2.0 * Float(x) + 1.0) * Float(u) * .pi / (2.0 * n))
                        let cosV = cos((2.0 * Float(y) + 1.0) * Float(v) * .pi / (2.0 * n))
                        
                        let pixelValue = block[y][x]
                        let coefficient = pixelValue * cosU * cosV * cu * cv
                        sum += coefficient
                    }
                }
                
                dct[v][u] = sum * normFactor * normFactor
            }
        }
        
        return dct
    }
    
    /// Apply inverse DCT (IDCT) to an 8×8 block using the scalar reference implementation
    func applyIDCTScalar(block: [[Float]]) -> [[Float]] {
        var spatial = [[Float]](
            repeating: [Float](repeating: 0, count: blockSize),
            count: blockSize
        )
        
        let n = Float(blockSize)
        let normFactor = sqrt(2.0 / n)
        
        for x in 0..<blockSize {
            for y in 0..<blockSize {
                var sum: Float = 0
                
                for u in 0..<blockSize {
                    for v in 0..<blockSize {
                        let cu = u == 0 ? Float(1.0 / sqrt(2.0)) : Float(1.0)
                        let cv = v == 0 ? Float(1.0 / sqrt(2.0)) : Float(1.0)
                        
                        let cosU = cos((2.0 * Float(x) + 1.0) * Float(u) * .pi / (2.0 * n))
                        let cosV = cos((2.0 * Float(y) + 1.0) * Float(v) * .pi / (2.0 * n))
                        
                        let coefficient = block[v][u]
                        sum += coefficient * cosU * cosV * cu * cv
                    }
                }
                
                spatial[y][x] = sum * normFactor * normFactor
            }
        }
        
        return spatial
    }
    
    private func applyDCTAccelerate(block: [[Float]]) -> [[Float]] {
        #if canImport(Accelerate)
        // Flatten block for Accelerate processing
        let flat = block.flatMap { $0 }
        let result = AccelerateOps.dct2D(flat, size: blockSize)
        
        // Convert back to 2D array
        guard result.count == blockSize * blockSize else {
            return applyDCTScalar(block: block)
        }
        var output = [[Float]](
            repeating: [Float](repeating: 0, count: blockSize),
            count: blockSize
        )
        for y in 0..<blockSize {
            for x in 0..<blockSize {
                output[y][x] = result[y * blockSize + x]
            }
        }
        return output
        #else
        return applyDCTScalar(block: block)
        #endif
    }
    
    // Placeholder for NEON-based DCT
    private func applyDCTNEON(block: [[Float]]) -> [[Float]] {
        #if arch(arm64)
        return NEONOps.dct2D(block)
        #else
        return applyDCTScalar(block: block)
        #endif
    }
    
    // MARK: - Adaptive Quantisation
    
    /// Compute the spatial activity of an 8×8 pixel block.
    ///
    /// Activity is defined as the variance of pixel values inside the
    /// block.  A perfectly flat block has activity 0; a block with
    /// complex texture or edges has high activity.
    ///
    /// - Parameter block: 8×8 spatial-domain pixel values (range 0–1).
    /// - Returns: Variance of the pixel values (≥ 0).
    func computeBlockActivity(block: [[Float]]) -> Float {
        var sum: Float = 0
        var sumSq: Float = 0
        let n = Float(blockSize * blockSize)
        
        for y in 0..<blockSize {
            for x in 0..<blockSize {
                let v = block[y][x]
                sum += v
                sumSq += v * v
            }
        }
        
        let mean = sum / n
        let variance = sumSq / n - mean * mean
        return max(0, variance)
    }
    
    /// Convert raw block activity (variance) into a normalised scale
    /// factor suitable for adaptive quantisation.
    ///
    /// The mapping uses a simple formula inspired by the JPEG XL
    /// reference encoder:
    ///
    ///     scale = 1 + strength × (activity / (activity + kappa) - 0.5)
    ///
    /// where `kappa` controls the midpoint (blocks with activity =
    /// kappa get scale = 1) and `strength` controls the dynamic range.
    ///
    /// - Parameters:
    ///   - activity: Raw variance from ``computeBlockActivity(block:)``.
    ///   - strength: Dynamic range of the adjustment (default 1.0).
    ///     Higher values produce larger differences between flat and
    ///     detailed blocks.
    ///   - kappa: Midpoint activity level (default 0.01).
    /// - Returns: A scale factor typically in [0.5, 1.5].  Values > 1
    ///   indicate a detailed block (finer quantisation); values < 1
    ///   indicate a flat block (coarser quantisation).
    func adaptiveQuantizationScale(
        activity: Float,
        strength: Float = 1.0,
        kappa: Float = 0.01
    ) -> Float {
        let normalised = activity / (activity + kappa)
        return 1.0 + strength * (normalised - 0.5)
    }
    
    // MARK: - Quantization
    
    /// Apply noise synthesis to DCT coefficients if configured.
    ///
    /// Adds controlled noise to the DCT coefficients to improve perceptual quality
    /// by masking quantization artifacts and maintaining natural texture.
    ///
    /// - Parameters:
    ///   - dctBlock: 8×8 DCT coefficient block to modify
    ///   - channel: Channel index (0 = luma, >0 = chroma)
    ///   - noiseSynthesizer: Noise synthesizer instance
    /// - Returns: Modified DCT block with noise applied
    private func applyNoiseIfConfigured(
        dctBlock: [[Float]],
        channel: Int,
        noiseSynthesizer: inout NoiseSynthesizer
    ) -> [[Float]] {
        guard let _ = options.noiseConfig, options.noiseConfig?.enabled == true else {
            return dctBlock
        }
        
        // Flatten to 1D for noise application
        var coefficients = dctBlock.flatMap { $0 }
        
        // Apply noise to coefficients
        let isLuma = (channel == 0)
        noiseSynthesizer.applyNoiseToCoefficients(coefficients: &coefficients, isLuma: isLuma)
        
        // Reshape back to 2D
        var noisyBlock = [[Float]](
            repeating: [Float](repeating: 0, count: blockSize),
            count: blockSize
        )
        for y in 0..<blockSize {
            for x in 0..<blockSize {
                noisyBlock[y][x] = coefficients[y * blockSize + x]
            }
        }
        
        return noisyBlock
    }
    
    /// Quantise an 8×8 DCT block using the base quantisation matrix.
    ///
    /// When adaptive quantisation is disabled (or for API compatibility),
    /// this method delegates to ``quantize(block:channel:activity:)``
    /// with an activity of 1.0 (neutral scaling).
    func quantize(block: [[Float]], channel: Int) -> [[Int16]] {
        return quantize(block: block, channel: channel, activity: 1.0)
    }
    
    /// Quantise an 8×8 DCT block using the base quantisation matrix
    /// scaled by the given activity factor.
    ///
    /// - Parameters:
    ///   - block: 8×8 DCT coefficient block.
    ///   - channel: Channel index (0 = luma, >0 = chroma).
    ///   - activity: Local spatial activity.  Values > 1 indicate a
    ///     detailed block and produce finer quantisation; values < 1
    ///     indicate a flat block and produce coarser quantisation.
    func quantize(block: [[Float]], channel: Int, activity: Float) -> [[Int16]] {
        return quantize(block: block, channel: channel, activity: activity, distance: self.distance)
    }
    
    /// Quantise an 8×8 DCT block using the base quantisation matrix
    /// scaled by the given activity factor and custom distance.
    ///
    /// - Parameters:
    ///   - block: 8×8 DCT coefficient block.
    ///   - channel: Channel index (0 = luma, >0 = chroma).
    ///   - activity: Local spatial activity.
    ///   - distance: Custom distance for this block (supports ROI).
    func quantize(block: [[Float]], channel: Int, activity: Float, distance: Float) -> [[Int16]] {
        let qMatrix = generateQuantizationMatrix(channel: channel, activity: activity, distance: distance)
        
        #if canImport(Accelerate)
        if hardware.hasAccelerate && options.useAccelerate {
            return quantizeAccelerate(block: block, qMatrix: qMatrix)
        }
        #endif
        
        #if arch(arm64)
        if hardware.hasNEON && options.useHardwareAcceleration {
            return NEONOps.quantize(block: block, qMatrix: qMatrix)
        }
        #endif
        
        #if arch(x86_64)
        if options.useHardwareAcceleration {
            return SSEOps.quantize(block: block, qMatrix: qMatrix)
        }
        #endif
        
        return quantizeScalar(block: block, qMatrix: qMatrix)
    }
    
    /// Scalar quantization (reference implementation).
    private func quantizeScalar(block: [[Float]], qMatrix: [[Float]]) -> [[Int16]] {
        var quantized = [[Int16]](
            repeating: [Int16](repeating: 0, count: blockSize),
            count: blockSize
        )
        
        for y in 0..<blockSize {
            for x in 0..<blockSize {
                let value = block[y][x]
                let qValue = qMatrix[y][x]
                let rounded = round(value / qValue)
                quantized[y][x] = Int16(clamping: Int32(rounded))
            }
        }
        
        return quantized
    }
    
    #if canImport(Accelerate)
    /// Accelerate-based vectorised quantization.
    private func quantizeAccelerate(block: [[Float]], qMatrix: [[Float]]) -> [[Int16]] {
        let flat = block.flatMap { $0 }
        let flatQ = qMatrix.flatMap { $0 }
        
        let result = AccelerateOps.quantize(flat, qMatrix: flatQ)
        
        // Convert back to 2D array
        var quantized = [[Int16]](
            repeating: [Int16](repeating: 0, count: blockSize),
            count: blockSize
        )
        for y in 0..<blockSize {
            for x in 0..<blockSize {
                quantized[y][x] = result[y * blockSize + x]
            }
        }
        return quantized
    }
    #endif
    
    func generateQuantizationMatrix(channel: Int, activity: Float = 1.0, distance: Float? = nil) -> [[Float]] {
        var matrix = [[Float]](
            repeating: [Float](repeating: 1, count: blockSize),
            count: blockSize
        )
        
        // Base quantization on distance parameter (use custom or default)
        let effectiveDistance = distance ?? self.distance
        let baseQuant = max(1.0, effectiveDistance * 8.0)
        
        // Adaptive scale: invert activity so that high-detail blocks
        // (activity > 1) get smaller (finer) quantisation steps and
        // flat blocks (activity < 1) get larger (coarser) steps.
        // Clamped to [minAdaptiveScale, maxAdaptiveScale] to prevent
        // extreme adjustments.
        let adaptiveScale: Float = max(
            VarDCTEncoder.minAdaptiveScale,
            min(VarDCTEncoder.maxAdaptiveScale, 1.0 / activity)
        )
        
        // Use frequency-dependent quantization
        // Lower frequencies (top-left) get finer quantization
        for y in 0..<blockSize {
            for x in 0..<blockSize {
                let freq = Float(x + y)
                matrix[y][x] = baseQuant * (1.0 + freq * 0.5) * adaptiveScale
                
                // Chroma channels can be quantized more aggressively
                if channel > 0 {
                    matrix[y][x] *= 1.5
                }
            }
        }
        
        return matrix
    }
    
    // MARK: - Coefficient Encoding
    
    private func encodeBlock(
        writer: inout BitstreamWriter,
        block: [[Int16]],
        dcResidual: Int16? = nil,
        coefficientRange: Range<Int> = 0..<64
    ) {
        // Zigzag scan order for better compression
        let coefficients = zigzagScan(block: block)
        
        // Determine which coefficients to encode based on the range
        let startIdx = coefficientRange.lowerBound
        let endIdx = min(coefficientRange.upperBound, coefficients.count)
        
        // Encode DC coefficient if in range (use prediction residual if available)
        if startIdx == 0 && endIdx > 0 {
            let dcValue = dcResidual ?? coefficients[0]
            writer.writeVarint(encodeSignedValue(Int32(dcValue)))
        }
        
        // Encode AC coefficients with run-length encoding
        // Format: alternating (zeroRun, coefficient) pairs
        // zeroRun is always written (even when 0) so the decoder can
        // unambiguously distinguish runs from coefficients.
        var zeroRun = 0
        let acStart = max(1, startIdx)
        for i in acStart..<endIdx {
            let coeff = coefficients[i]
            
            if coeff == 0 {
                zeroRun += 1
            } else {
                // Write zero run (always, even when 0)
                writer.writeVarint(UInt64(zeroRun))
                zeroRun = 0
                
                // Encode coefficient
                writer.writeVarint(encodeSignedValue(Int32(coeff)))
            }
        }
        
        // End of block marker if there are trailing zeros
        if zeroRun > 0 {
            writer.writeVarint(0xFFFF) // EOB marker
        }
    }
    
    /// Encode all coefficients of a channel using ANS entropy coding.
    ///
    /// Collects all DC and AC coefficients from the block grid, maps them
    /// to unsigned symbols via ZigZag encoding, and compresses using a
    /// two-context rANS encoder (context 0 = DC, context 1 = AC).
    ///
    /// - Parameters:
    ///   - allBlocks: All quantized 8×8 blocks in raster order.
    ///   - dcResiduals: DC prediction residuals for each block.
    ///   - coefficientRange: Range of coefficient indices to encode (in zigzag order)
    /// - Returns: ANS-compressed coefficient data.
    func encodeBlocksANS(
        allBlocks: [[[Int16]]],
        dcResiduals: [Int16],
        coefficientRange: Range<Int> = 0..<64
    ) throws -> Data {
        let maxAlpha = ANSConstants.maxAlphabetSize
        
        // Collect symbols by context: DC (ctx 0) and AC (ctx 1).
        // Symbols exceeding the ANS alphabet are clamped to the maximum
        // index.  This can happen with large quantised coefficients but
        // is rare in practice; the decoder must apply the same clamping.
        var dcSymbols = [Int]()
        var acSymbols = [Int]()
        var pairs = [(symbol: Int, context: Int)]()
        
        let startIdx = coefficientRange.lowerBound
        let endIdx = min(coefficientRange.upperBound, 64)
        
        for (blockIdx, block) in allBlocks.enumerated() {
            let coefficients = zigzagScan(block: block)
            
            // DC coefficient (use residual) - only if in range
            if startIdx == 0 && endIdx > 0 {
                let dcValue = dcResiduals[blockIdx]
                let dcSym = min(Int(encodeSignedValue(Int32(dcValue))),
                                maxAlpha - 1)
                dcSymbols.append(dcSym)
                pairs.append((symbol: dcSym, context: 0))
            }
            
            // AC coefficients - only encode those in range
            let acStart = max(1, startIdx)
            for i in acStart..<endIdx {
                let acSym = min(Int(encodeSignedValue(Int32(coefficients[i]))),
                                maxAlpha - 1)
                acSymbols.append(acSym)
                pairs.append((symbol: acSym, context: 1))
            }
        }
        
        // Build multi-context encoder (2 contexts: DC and AC)
        let ansEncoder = try MultiContextANSEncoder.build(
            contextSymbols: [dcSymbols, acSymbols],
            alphabetSize: maxAlpha
        )
        
        let encoded = try ansEncoder.encode(pairs)
        
        // Build output with header
        var writer = BitstreamWriter()
        
        // ANS marker
        writer.writeByte(0x02)  // VarDCT ANS mode
        
        // Block count
        writer.writeU32(UInt32(allBlocks.count))
        
        // Serialise distributions
        for dist in ansEncoder.distributions {
            let table = dist.serialise()
            writer.writeVarint(UInt64(table.count))
            writer.writeData(table)
        }
        
        // Write encoded data
        writer.writeU32(UInt32(encoded.count))
        writer.writeData(encoded)
        
        writer.flushByte()
        return writer.data
    }
    
    func zigzagScan(block: [[Int16]]) -> [Int16] {
        // Zigzag order for 8x8 block
        let order: [(Int, Int)] = [
            (0,0), (0,1), (1,0), (2,0), (1,1), (0,2), (0,3), (1,2),
            (2,1), (3,0), (4,0), (3,1), (2,2), (1,3), (0,4), (0,5),
            (1,4), (2,3), (3,2), (4,1), (5,0), (6,0), (5,1), (4,2),
            (3,3), (2,4), (1,5), (0,6), (0,7), (1,6), (2,5), (3,4),
            (4,3), (5,2), (6,1), (7,0), (7,1), (6,2), (5,3), (4,4),
            (3,5), (2,6), (1,7), (2,7), (3,6), (4,5), (5,4), (6,3),
            (7,2), (7,3), (6,4), (5,5), (4,6), (3,7), (4,7), (5,6),
            (6,5), (7,4), (7,5), (6,6), (5,7), (6,7), (7,6), (7,7)
        ]
        
        return order.map { block[$0.0][$0.1] }
    }
    
    /// Natural order coefficient scan for an 8×8 block per JPEG XL spec.
    ///
    /// Natural order arranges coefficients by increasing frequency magnitude
    /// (u² + v²), with ties broken by row-major order. This produces better
    /// compression for JPEG XL's VarDCT mode compared to the diagonal zigzag
    /// pattern used by legacy JPEG, because it groups coefficients of similar
    /// perceptual importance together.
    ///
    /// - Parameter block: 8×8 quantized coefficient block.
    /// - Returns: 64 coefficients in natural frequency order.
    func naturalOrderScan(block: [[Int16]]) -> [Int16] {
        return Self.naturalOrder8x8.map { block[$0.0][$0.1] }
    }

    /// Precomputed natural order permutation for 8×8 blocks.
    ///
    /// Coefficients are sorted by increasing frequency magnitude (u² + v²),
    /// with ties broken by row index then column index.
    static let naturalOrder8x8: [(Int, Int)] = {
        var positions: [(row: Int, col: Int, freq: Int)] = []
        for r in 0..<8 {
            for c in 0..<8 {
                positions.append((r, c, r * r + c * c))
            }
        }
        positions.sort { a, b in
            if a.freq != b.freq { return a.freq < b.freq }
            if a.row != b.row { return a.row < b.row }
            return a.col < b.col
        }
        return positions.map { ($0.row, $0.col) }
    }()

    /// Generate natural order permutation for an arbitrary N×M block.
    ///
    /// - Parameters:
    ///   - width: Block width
    ///   - height: Block height
    /// - Returns: Array of (row, col) tuples in natural frequency order.
    static func naturalOrder(width: Int, height: Int) -> [(Int, Int)] {
        var positions: [(row: Int, col: Int, freq: Int)] = []
        for r in 0..<height {
            for c in 0..<width {
                positions.append((r, c, r * r + c * c))
            }
        }
        positions.sort { a, b in
            if a.freq != b.freq { return a.freq < b.freq }
            if a.row != b.row { return a.row < b.row }
            return a.col < b.col
        }
        return positions.map { ($0.row, $0.col) }
    }

    // MARK: - Block Size Selection

    /// Select optimal block size for a region based on local content analysis.
    ///
    /// Analyses the spatial activity (variance) of the region at multiple
    /// scales to decide which block size best fits the content:
    /// - Smooth regions → larger blocks (16×16, 32×32) for efficiency
    /// - Textured regions → 8×8 blocks for better frequency localization
    /// - Directional content → rectangular blocks (16×8 / 8×16)
    ///
    /// - Parameters:
    ///   - data: Full channel data as 2D float array.
    ///   - blockX: Horizontal position in 8×8 grid units.
    ///   - blockY: Vertical position in 8×8 grid units.
    ///   - width: Image width.
    ///   - height: Image height.
    /// - Returns: The recommended ``DCTBlockSize`` for this region.
    func selectBlockSize(
        data: [[Float]],
        blockX: Int,
        blockY: Int,
        width: Int,
        height: Int
    ) -> DCTBlockSize {
        // Calculate available pixels for larger block sizes
        let startX = blockX * 8
        let startY = blockY * 8
        let availableW = width - startX
        let availableH = height - startY

        // If there's not enough room for larger blocks, use 8×8
        guard availableW >= 16 && availableH >= 16 else {
            return .dct8x8
        }

        // Compute variance at 8×8 scale (four sub-blocks)
        let topLeft = computeRegionVariance(data: data, x: startX, y: startY, w: 8, h: 8, imgW: width, imgH: height)
        let topRight = computeRegionVariance(data: data, x: startX + 8, y: startY, w: 8, h: 8, imgW: width, imgH: height)
        let bottomLeft = computeRegionVariance(data: data, x: startX, y: startY + 8, w: 8, h: 8, imgW: width, imgH: height)
        let bottomRight = computeRegionVariance(data: data, x: startX + 8, y: startY + 8, w: 8, h: 8, imgW: width, imgH: height)

        let maxSubVariance = max(topLeft, topRight, bottomLeft, bottomRight)
        let avgVariance = (topLeft + topRight + bottomLeft + bottomRight) / 4.0

        // Smooth region threshold (low variance across all sub-blocks)
        let smoothThreshold: Float = 0.005

        if maxSubVariance < smoothThreshold {
            // Very smooth region — check if 32×32 is feasible
            if availableW >= 32 && availableH >= 32 {
                return .dct32x32
            }
            return .dct16x16
        }

        // Check for directional content (horizontal vs vertical variance)
        let hVariance = (topLeft + topRight) / 2.0
        let vVariance = (topLeft + bottomLeft) / 2.0
        let directionRatio = max(hVariance, vVariance) / max(Float.leastNormalMagnitude, min(hVariance, vVariance))

        if directionRatio > 2.0 && avgVariance < 0.05 {
            // Directional content — use rectangular block
            if hVariance > vVariance {
                // Horizontal edges → wide block
                return .dct16x8
            } else {
                // Vertical edges → tall block
                return .dct8x16
            }
        }

        // Default: standard 8×8 for textured regions
        return .dct8x8
    }

    /// Compute pixel variance in a sub-region (clamped to image bounds).
    private func computeRegionVariance(
        data: [[Float]], x: Int, y: Int, w: Int, h: Int,
        imgW: Int, imgH: Int
    ) -> Float {
        var sum: Float = 0
        var sumSq: Float = 0
        var count: Float = 0
        for dy in 0..<h {
            let sy = min(y + dy, imgH - 1)
            for dx in 0..<w {
                let sx = min(x + dx, imgW - 1)
                let v = data[sy][sx]
                sum += v
                sumSq += v * v
                count += 1
            }
        }
        let mean = sum / count
        return max(0, sumSq / count - mean * mean)
    }

    // MARK: - Variable-Size DCT

    /// Apply a 2D DCT of arbitrary size using the scalar reference algorithm.
    ///
    /// Generalizes the fixed 8×8 ``applyDCTScalar(block:)`` to N×M blocks
    /// for variable block size support. Used for block sizes other than 8×8.
    ///
    /// - Parameters:
    ///   - block: 2D array of spatial-domain pixel values (height × width).
    ///   - blockWidth: Block width.
    ///   - blockHeight: Block height.
    /// - Returns: 2D array of DCT coefficients.
    func applyDCTVariable(block: [[Float]], blockWidth: Int, blockHeight: Int) -> [[Float]] {
        // For 8×8 blocks, delegate to the optimized path
        if blockWidth == 8 && blockHeight == 8 {
            return applyDCTScalar(block: block)
        }

        var dct = [[Float]](
            repeating: [Float](repeating: 0, count: blockWidth),
            count: blockHeight
        )

        let nW = Float(blockWidth)
        let nH = Float(blockHeight)
        let normW = sqrt(2.0 / nW)
        let normH = sqrt(2.0 / nH)

        for v in 0..<blockHeight {
            for u in 0..<blockWidth {
                var sum: Float = 0
                let cu: Float = u == 0 ? Float(1.0 / sqrt(2.0)) : 1.0
                let cv: Float = v == 0 ? Float(1.0 / sqrt(2.0)) : 1.0

                for y in 0..<blockHeight {
                    let cosV = cos((2.0 * Float(y) + 1.0) * Float(v) * .pi / (2.0 * nH))
                    for x in 0..<blockWidth {
                        let cosU = cos((2.0 * Float(x) + 1.0) * Float(u) * .pi / (2.0 * nW))
                        sum += block[y][x] * cosU * cosV
                    }
                }

                dct[v][u] = sum * cu * cv * normW * normH
            }
        }

        return dct
    }

    /// Apply a 2D inverse DCT of arbitrary size.
    ///
    /// - Parameters:
    ///   - block: 2D array of DCT coefficients (height × width).
    ///   - blockWidth: Block width.
    ///   - blockHeight: Block height.
    /// - Returns: 2D array of reconstructed spatial-domain values.
    func applyIDCTVariable(block: [[Float]], blockWidth: Int, blockHeight: Int) -> [[Float]] {
        if blockWidth == 8 && blockHeight == 8 {
            return applyIDCTScalar(block: block)
        }

        var spatial = [[Float]](
            repeating: [Float](repeating: 0, count: blockWidth),
            count: blockHeight
        )

        let nW = Float(blockWidth)
        let nH = Float(blockHeight)
        let normW = sqrt(2.0 / nW)
        let normH = sqrt(2.0 / nH)

        for y in 0..<blockHeight {
            for x in 0..<blockWidth {
                var sum: Float = 0
                for v in 0..<blockHeight {
                    let cv: Float = v == 0 ? Float(1.0 / sqrt(2.0)) : 1.0
                    let cosV = cos((2.0 * Float(y) + 1.0) * Float(v) * .pi / (2.0 * nH))
                    for u in 0..<blockWidth {
                        let cu: Float = u == 0 ? Float(1.0 / sqrt(2.0)) : 1.0
                        let cosU = cos((2.0 * Float(x) + 1.0) * Float(u) * .pi / (2.0 * nW))
                        sum += block[v][u] * cu * cv * cosU * cosV
                    }
                }
                spatial[y][x] = sum * normW * normH
            }
        }

        return spatial
    }

    /// Extract a variable-sized block from channel data with edge clamping.
    ///
    /// - Parameters:
    ///   - data: Full channel data as 2D float array.
    ///   - startX: Left pixel coordinate.
    ///   - startY: Top pixel coordinate.
    ///   - blockWidth: Block width in pixels.
    ///   - blockHeight: Block height in pixels.
    ///   - width: Image width.
    ///   - height: Image height.
    /// - Returns: 2D block of pixel values.
    func extractVariableBlock(
        data: [[Float]],
        startX: Int, startY: Int,
        blockWidth: Int, blockHeight: Int,
        width: Int, height: Int
    ) -> [[Float]] {
        var block = [[Float]](
            repeating: [Float](repeating: 0, count: blockWidth),
            count: blockHeight
        )
        for y in 0..<blockHeight {
            let srcY = min(startY + y, height - 1)
            for x in 0..<blockWidth {
                let srcX = min(startX + x, width - 1)
                block[y][x] = data[srcY][srcX]
            }
        }
        return block
    }

    /// Generate a quantization matrix for a variable-sized block.
    ///
    /// Extends the fixed 8×8 ``generateQuantizationMatrix(channel:activity:distance:)``
    /// to arbitrary dimensions.
    ///
    /// - Parameters:
    ///   - blockWidth: Block width.
    ///   - blockHeight: Block height.
    ///   - channel: Channel index (0 = luma, >0 = chroma).
    ///   - activity: Local spatial activity scale.
    ///   - distance: Quantization distance.
    /// - Returns: 2D quantization matrix.
    func generateVariableQuantizationMatrix(
        blockWidth: Int, blockHeight: Int,
        channel: Int, activity: Float = 1.0, distance: Float? = nil
    ) -> [[Float]] {
        let effectiveDistance = distance ?? self.distance
        let baseQuant = max(1.0, effectiveDistance * 8.0)
        let adaptiveScale: Float = max(
            VarDCTEncoder.minAdaptiveScale,
            min(VarDCTEncoder.maxAdaptiveScale, 1.0 / activity)
        )

        var matrix = [[Float]](
            repeating: [Float](repeating: 1, count: blockWidth),
            count: blockHeight
        )
        for y in 0..<blockHeight {
            for x in 0..<blockWidth {
                let freq = Float(x + y)
                matrix[y][x] = baseQuant * (1.0 + freq * 0.5) * adaptiveScale
                if channel > 0 {
                    matrix[y][x] *= 1.5
                }
            }
        }
        return matrix
    }

    // MARK: - Frame Header I/O

    /// Write the full VarDCT frame header per ISO/IEC 18181-1 §6.
    ///
    /// The extended header includes frame dimensions, color transform,
    /// block size mode, and progressive pass count in addition to the
    /// existing distance, flags, and pixel type fields.
    ///
    /// - Parameters:
    ///   - writer: Bitstream writer to write to.
    ///   - frame: Image frame being encoded.
    func writeVarDCTFrameHeader(writer: inout BitstreamWriter, frame: ImageFrame) {
        // Mode bit: false = VarDCT
        writer.writeBit(false)
        writer.flushByte()

        // Header version byte for forward compatibility
        writer.writeByte(VarDCTFrameHeader.headerVersion)

        // Frame dimensions
        writer.writeU32(UInt32(frame.width))
        writer.writeU32(UInt32(frame.height))
        writer.writeByte(UInt8(frame.channels))

        // Distance (IEEE 754 float)
        writer.writeU32(distance.bitPattern)

        // Encoding flags
        var flags: UInt8 = 0
        if options.adaptiveQuantization { flags |= 0x01 }
        if options.useANS { flags |= 0x02 }
        writer.writeByte(flags)

        // Pixel type
        switch frame.pixelType {
        case .uint8:   writer.writeByte(0)
        case .uint16:  writer.writeByte(1)
        case .float32: writer.writeByte(2)
        }

        // Color transform (0=YCbCr, 1=XYB, 2=none)
        let colorTransform: UInt8 = options.useXYBColorSpace ? 1 : 0
        writer.writeByte(colorTransform)

        // Variable block size mode (0=fixed 8×8, 1=variable)
        let variableBlocks: UInt8 = options.variableBlockSize ? 1 : 0
        writer.writeByte(variableBlocks)

        // Number of progressive passes
        let numPasses: UInt8 = options.progressive ? 3 : 1
        writer.writeByte(numPasses)
    }

    /// Read a VarDCT frame header from a bitstream reader.
    ///
    /// - Parameter reader: Bitstream reader positioned at the start of VarDCT data.
    /// - Returns: Parsed ``VarDCTFrameHeader``.
    /// - Throws: ``VarDCTDecoderError`` if the header is malformed.
    static func readVarDCTFrameHeader(reader: inout BitstreamReader) throws -> VarDCTFrameHeader {
        // Mode bit
        guard let modeBit = reader.readBit() else {
            throw VarDCTDecoderError.unexpectedEndOfData
        }
        guard !modeBit else {
            throw VarDCTDecoderError.invalidVarDCTMode
        }
        reader.skipToByteAlignment()

        // Check header version
        guard let version = reader.readByte() else {
            throw VarDCTDecoderError.unexpectedEndOfData
        }

        if version == VarDCTFrameHeader.headerVersion {
            // Extended header (version 1)
            guard let widthBytes = readU32Static(&reader),
                  let heightBytes = readU32Static(&reader) else {
                throw VarDCTDecoderError.unexpectedEndOfData
            }
            guard let channels = reader.readByte() else {
                throw VarDCTDecoderError.unexpectedEndOfData
            }
            guard let distBits = readU32Static(&reader) else {
                throw VarDCTDecoderError.unexpectedEndOfData
            }
            guard let flags = reader.readByte(),
                  let pixelType = reader.readByte(),
                  let colorTransform = reader.readByte(),
                  let variableBlockSize = reader.readByte(),
                  let numPasses = reader.readByte() else {
                throw VarDCTDecoderError.unexpectedEndOfData
            }

            return VarDCTFrameHeader(
                isModular: false,
                width: widthBytes,
                height: heightBytes,
                channels: channels,
                distance: Float(bitPattern: distBits),
                flags: flags,
                pixelType: pixelType,
                colorTransform: colorTransform,
                variableBlockSize: variableBlockSize,
                numPasses: numPasses
            )
        } else {
            // Legacy header (version 0): the byte we read is the first byte of the distance U32
            // Re-read: version byte was actually part of distance in the old format
            // For backward compatibility we fall back to legacy parsing
            throw VarDCTDecoderError.malformedBlockData("Unsupported VarDCT header version \(version)")
        }
    }

    /// Read a UInt32 from a BitstreamReader (static helper, big-endian).
    private static func readU32Static(_ reader: inout BitstreamReader) -> UInt32? {
        guard let b0 = reader.readByte(),
              let b1 = reader.readByte(),
              let b2 = reader.readByte(),
              let b3 = reader.readByte() else {
            return nil
        }
        return (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
    }

    func encodeSignedValue(_ value: Int32) -> UInt64 {
        if value >= 0 {
            return UInt64(value * 2)
        } else {
            return UInt64(-value * 2 - 1)
        }
    }
    
    // MARK: - NEON Dispatch Helpers
    
    #if arch(arm64)
    /// NEON-accelerated YCbCr conversion using SIMD4 processing.
    private func convertToYCbCrNEON(frame: ImageFrame) -> ImageFrame {
        var ycbcrFrame = frame
        let pixelCount = frame.width * frame.height
        
        var rChannel = [Float](repeating: 0, count: pixelCount)
        var gChannel = [Float](repeating: 0, count: pixelCount)
        var bChannel = [Float](repeating: 0, count: pixelCount)
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                rChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 0)) / 65535.0
                gChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 1)) / 65535.0
                bChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 2)) / 65535.0
            }
        }
        
        let (yArr, cbArr, crArr) = NEONOps.rgbToYCbCr(
            r: rChannel, g: gChannel, b: bChannel
        )
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                ycbcrFrame.setPixel(x: x, y: y, channel: 0,
                                    value: UInt16(max(0, min(65535, yArr[idx] * 65535))))
                ycbcrFrame.setPixel(x: x, y: y, channel: 1,
                                    value: UInt16(max(0, min(65535, cbArr[idx] * 65535))))
                ycbcrFrame.setPixel(x: x, y: y, channel: 2,
                                    value: UInt16(max(0, min(65535, crArr[idx] * 65535))))
            }
        }
        
        return ycbcrFrame
    }
    
    /// NEON-accelerated XYB conversion.
    private func convertToXYBNEON(frame: ImageFrame) -> ImageFrame {
        var xybFrame = frame
        let pixelCount = frame.width * frame.height
        
        var rChannel = [Float](repeating: 0, count: pixelCount)
        var gChannel = [Float](repeating: 0, count: pixelCount)
        var bChannel = [Float](repeating: 0, count: pixelCount)
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                rChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 0)) / 65535.0
                gChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 1)) / 65535.0
                bChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 2)) / 65535.0
            }
        }
        
        let (xArr, yArr, bArr) = NEONOps.rgbToXYB(
            r: rChannel, g: gChannel, b: bChannel
        )
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                xybFrame.setPixel(x: x, y: y, channel: 0,
                                  value: UInt16(max(0, min(65535, xArr[idx] * 65535))))
                xybFrame.setPixel(x: x, y: y, channel: 1,
                                  value: UInt16(max(0, min(65535, yArr[idx] * 65535))))
                xybFrame.setPixel(x: x, y: y, channel: 2,
                                  value: UInt16(max(0, min(65535, bArr[idx] * 65535))))
            }
        }
        
        return xybFrame
    }
    
    /// NEON-accelerated inverse XYB conversion.
    private func convertFromXYBNEON(frame: ImageFrame) -> ImageFrame {
        var rgbFrame = frame
        let pixelCount = frame.width * frame.height
        
        var xChannel = [Float](repeating: 0, count: pixelCount)
        var yChannel = [Float](repeating: 0, count: pixelCount)
        var bChannel = [Float](repeating: 0, count: pixelCount)
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                xChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 0)) / 65535.0
                yChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 1)) / 65535.0
                bChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 2)) / 65535.0
            }
        }
        
        let (rArr, gArr, bArr) = NEONOps.xybToRGB(
            x: xChannel, y: yChannel, b: bChannel
        )
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                rgbFrame.setPixel(x: x, y: y, channel: 0,
                                  value: UInt16(max(0, min(65535, rArr[idx] * 65535))))
                rgbFrame.setPixel(x: x, y: y, channel: 1,
                                  value: UInt16(max(0, min(65535, gArr[idx] * 65535))))
                rgbFrame.setPixel(x: x, y: y, channel: 2,
                                  value: UInt16(max(0, min(65535, bArr[idx] * 65535))))
            }
        }
        
        return rgbFrame
    }
    #endif
    
    // MARK: - SSE Colour Conversion (x86-64)
    
    /// SSE-accelerated YCbCr conversion.
    private func convertToYCbCrSSE(frame: ImageFrame) -> ImageFrame {
        var ycbcrFrame = frame
        let pixelCount = frame.width * frame.height
        
        var rChannel = [Float](repeating: 0, count: pixelCount)
        var gChannel = [Float](repeating: 0, count: pixelCount)
        var bChannel = [Float](repeating: 0, count: pixelCount)
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                rChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 0)) / 65535.0
                gChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 1)) / 65535.0
                bChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 2)) / 65535.0
            }
        }
        
        let (yArr, cbArr, crArr) = SSEOps.rgbToYCbCr(
            r: rChannel, g: gChannel, b: bChannel
        )
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                ycbcrFrame.setPixel(x: x, y: y, channel: 0,
                                    value: UInt16(max(0, min(65535, yArr[idx]  * 65535))))
                ycbcrFrame.setPixel(x: x, y: y, channel: 1,
                                    value: UInt16(max(0, min(65535, cbArr[idx] * 65535))))
                ycbcrFrame.setPixel(x: x, y: y, channel: 2,
                                    value: UInt16(max(0, min(65535, crArr[idx] * 65535))))
            }
        }
        
        return ycbcrFrame
    }
    
    /// SSE-accelerated XYB conversion.
    private func convertToXYBSSE(frame: ImageFrame) -> ImageFrame {
        var xybFrame = frame
        let pixelCount = frame.width * frame.height
        
        var rChannel = [Float](repeating: 0, count: pixelCount)
        var gChannel = [Float](repeating: 0, count: pixelCount)
        var bChannel = [Float](repeating: 0, count: pixelCount)
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                rChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 0)) / 65535.0
                gChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 1)) / 65535.0
                bChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 2)) / 65535.0
            }
        }
        
        let (xArr, yArr, bArr) = SSEOps.rgbToXYB(
            r: rChannel, g: gChannel, b: bChannel
        )
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                xybFrame.setPixel(x: x, y: y, channel: 0,
                                  value: UInt16(max(0, min(65535, xArr[idx] * 65535))))
                xybFrame.setPixel(x: x, y: y, channel: 1,
                                  value: UInt16(max(0, min(65535, yArr[idx] * 65535))))
                xybFrame.setPixel(x: x, y: y, channel: 2,
                                  value: UInt16(max(0, min(65535, bArr[idx] * 65535))))
            }
        }
        
        return xybFrame
    }
    
    /// SSE-accelerated inverse XYB conversion.
    private func convertFromXYBSSE(frame: ImageFrame) -> ImageFrame {
        var rgbFrame = frame
        let pixelCount = frame.width * frame.height
        
        var xChannel = [Float](repeating: 0, count: pixelCount)
        var yChannel = [Float](repeating: 0, count: pixelCount)
        var bChannel = [Float](repeating: 0, count: pixelCount)
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                xChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 0)) / 65535.0
                yChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 1)) / 65535.0
                bChannel[idx] = Float(frame.getPixel(x: x, y: y, channel: 2)) / 65535.0
            }
        }
        
        let (rArr, gArr, bArr) = SSEOps.xybToRGB(
            x: xChannel, y: yChannel, b: bChannel
        )
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let idx = y * frame.width + x
                rgbFrame.setPixel(x: x, y: y, channel: 0,
                                  value: UInt16(max(0, min(65535, rArr[idx] * 65535))))
                rgbFrame.setPixel(x: x, y: y, channel: 1,
                                  value: UInt16(max(0, min(65535, gArr[idx] * 65535))))
                rgbFrame.setPixel(x: x, y: y, channel: 2,
                                  value: UInt16(max(0, min(65535, bArr[idx] * 65535))))
            }
        }
        
        return rgbFrame
    }
}
