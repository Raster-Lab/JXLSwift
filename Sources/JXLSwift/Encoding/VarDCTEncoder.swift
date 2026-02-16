/// VarDCT Mode Encoder
///
/// Implements lossy compression using the VarDCT mode of JPEG XL.
/// Uses DCT transforms, quantization, and entropy coding.

import Foundation

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
    
    init(hardware: HardwareCapabilities, options: EncodingOptions, distance: Float) {
        self.hardware = hardware
        self.options = options
        self.distance = distance
    }
    
    /// Encode frame using VarDCT mode
    func encode(frame: ImageFrame) throws -> Data {
        var writer = BitstreamWriter()
        
        // Write VarDCT mode indicator
        writer.writeBit(false) // Use VarDCT mode
        
        // Convert to YCbCr color space for better compression
        let ycbcr = convertToYCbCr(frame: frame)
        
        // Extract all channels as 2D float arrays
        let channelArrays = (0..<ycbcr.channels).map { channel in
            extractChannel(frame: ycbcr, channel: channel)
        }
        
        // Compute luma DCT blocks for CfL prediction (only if we have chroma)
        let lumaDCTBlocks: [[[[Float]]]]?
        if ycbcr.channels >= 3 {
            lumaDCTBlocks = computeDCTBlocks(
                data: channelArrays[0],
                width: ycbcr.width,
                height: ycbcr.height
            )
        } else {
            lumaDCTBlocks = nil
        }
        
        // Process each channel with DCT
        for channel in 0..<ycbcr.channels {
            let encoded = try encodeChannelDCT(
                data: channelArrays[channel],
                width: ycbcr.width,
                height: ycbcr.height,
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
                let value = frame.getPixel(x: x, y: y, channel: channel)
                channelData[y][x] = Float(value) / 65535.0
            }
        }
        
        return channelData
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
    
    /// Compute the CfL correlation coefficient for a single block.
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
        if hardware.hasAccelerate && options.useAccelerate {
            return applyDCTAccelerate(block: block)
        } else if hardware.hasNEON && options.useHardwareAcceleration {
            return applyDCTNEON(block: block)
        } else {
            return applyDCTScalar(block: block)
        }
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
        let qMatrix = generateQuantizationMatrix(channel: channel, activity: activity)
        
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
                quantized[y][x] = Int16(round(value / qValue))
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
    
    func generateQuantizationMatrix(channel: Int, activity: Float = 1.0) -> [[Float]] {
        var matrix = [[Float]](
            repeating: [Float](repeating: 1, count: blockSize),
            count: blockSize
        )
        
        // Base quantization on distance parameter
        let baseQuant = max(1.0, distance * 8.0)
        
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
    
    private func encodeBlock(writer: inout BitstreamWriter, block: [[Int16]], dcResidual: Int16? = nil) {
        // Zigzag scan order for better compression
        let coefficients = zigzagScan(block: block)
        
        // Encode DC coefficient (use prediction residual if available)
        let dcValue = dcResidual ?? coefficients[0]
        writer.writeVarint(encodeSignedValue(Int32(dcValue)))
        
        // Encode AC coefficients with run-length encoding
        var zeroRun = 0
        for i in 1..<coefficients.count {
            let coeff = coefficients[i]
            
            if coeff == 0 {
                zeroRun += 1
            } else {
                // Encode zero run
                if zeroRun > 0 {
                    writer.writeVarint(UInt64(zeroRun))
                    zeroRun = 0
                }
                
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
    ///   - allBlocks: All quantised 8×8 blocks in raster order.
    ///   - dcResiduals: DC prediction residuals for each block.
    /// - Returns: ANS-compressed coefficient data.
    func encodeBlocksANS(
        allBlocks: [[[Int16]]],
        dcResiduals: [Int16]
    ) throws -> Data {
        // Collect symbols by context: DC (ctx 0) and AC (ctx 1)
        var dcSymbols = [Int]()
        var acSymbols = [Int]()
        var pairs = [(symbol: Int, context: Int)]()
        
        for (blockIdx, block) in allBlocks.enumerated() {
            let coefficients = zigzagScan(block: block)
            
            // DC coefficient (use residual)
            let dcValue = dcResiduals[blockIdx]
            let dcSym = Int(encodeSignedValue(Int32(dcValue)))
            dcSymbols.append(dcSym)
            pairs.append((symbol: min(dcSym, ANSConstants.maxAlphabetSize - 1),
                          context: 0))
            
            // AC coefficients
            for i in 1..<coefficients.count {
                let acSym = Int(encodeSignedValue(Int32(coefficients[i])))
                acSymbols.append(acSym)
                pairs.append((symbol: min(acSym, ANSConstants.maxAlphabetSize - 1),
                              context: 1))
            }
        }
        
        // Clamp to alphabet size
        let maxAlpha = ANSConstants.maxAlphabetSize
        let clampedDC = dcSymbols.map { min($0, maxAlpha - 1) }
        let clampedAC = acSymbols.map { min($0, maxAlpha - 1) }
        
        // Build multi-context encoder (2 contexts: DC and AC)
        let ansEncoder = try MultiContextANSEncoder.build(
            contextSymbols: [clampedDC, clampedAC],
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
}
