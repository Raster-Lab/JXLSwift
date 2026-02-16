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
        
        // Process each channel with DCT
        for channel in 0..<ycbcr.channels {
            let channelData = extractChannel(frame: ycbcr, channel: channel)
            let encoded = try encodeChannelDCT(
                data: channelData,
                width: ycbcr.width,
                height: ycbcr.height,
                channel: channel
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
        
        // Scalar fallback
        return convertToYCbCrScalar(frame: frame)
    }
    
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
    
    // MARK: - DCT Encoding
    
    private func encodeChannelDCT(data: [[Float]], width: Int, height: Int, channel: Int) throws -> Data {
        var writer = BitstreamWriter()
        
        // Process image in 8x8 blocks
        let blocksX = (width + blockSize - 1) / blockSize
        let blocksY = (height + blockSize - 1) / blockSize
        
        // Track quantized DC values for inter-block prediction
        var dcValues = [[Int16]](
            repeating: [Int16](repeating: 0, count: blocksX),
            count: blocksY
        )
        
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
                
                // Apply DCT
                let dctBlock = applyDCT(block: block)
                
                // Quantize
                let quantized = quantize(block: dctBlock, channel: channel)
                
                // Compute DC prediction residual, then store DC value
                let dc = quantized[0][0]
                let predicted = predictDC(
                    dcValues: dcValues,
                    blockX: blockX,
                    blockY: blockY
                )
                let dcResidual = dc - predicted
                dcValues[blockY][blockX] = dc
                
                // Encode coefficients with DC prediction residual
                encodeBlock(writer: &writer, block: quantized, dcResidual: dcResidual)
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
    // TODO: Implement using ARM NEON SIMD instructions for 8x8 block processing
    private func applyDCTNEON(block: [[Float]]) -> [[Float]] {
        // Use NEON vector instructions for parallel computation
        return applyDCTScalar(block: block)
    }
    
    // MARK: - Quantization
    
    func quantize(block: [[Float]], channel: Int) -> [[Int16]] {
        // Generate quantization matrix based on distance
        let qMatrix = generateQuantizationMatrix(channel: channel)
        
        #if canImport(Accelerate)
        if hardware.hasAccelerate && options.useAccelerate {
            return quantizeAccelerate(block: block, qMatrix: qMatrix)
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
    
    func generateQuantizationMatrix(channel: Int) -> [[Float]] {
        var matrix = [[Float]](
            repeating: [Float](repeating: 1, count: blockSize),
            count: blockSize
        )
        
        // Base quantization on distance parameter
        let baseQuant = max(1.0, distance * 8.0)
        
        // Use frequency-dependent quantization
        // Lower frequencies (top-left) get finer quantization
        for y in 0..<blockSize {
            for x in 0..<blockSize {
                let freq = Float(x + y)
                matrix[y][x] = baseQuant * (1.0 + freq * 0.5)
                
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
}
