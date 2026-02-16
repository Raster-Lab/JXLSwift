/// Modular Mode Encoder
///
/// Implements lossless compression using the Modular mode of JPEG XL.
/// This uses predictive coding and entropy encoding for efficient lossless compression.

import Foundation

/// Modular encoder for lossless compression
class ModularEncoder {
    private let hardware: HardwareCapabilities
    private let options: EncodingOptions
    
    init(hardware: HardwareCapabilities, options: EncodingOptions) {
        self.hardware = hardware
        self.options = options
    }
    
    /// Encode frame using modular mode
    func encode(frame: ImageFrame) throws -> Data {
        var writer = BitstreamWriter()
        
        // Write modular mode indicator
        writer.writeBit(true) // Use modular mode
        
        // Process each channel separately
        for channel in 0..<frame.channels {
            let channelData = extractChannel(frame: frame, channel: channel)
            let encoded = try encodeChannel(data: channelData, 
                                           width: frame.width,
                                           height: frame.height)
            writer.writeData(encoded)
        }
        
        writer.flushByte()
        return writer.data
    }
    
    // MARK: - Channel Extraction
    
    private func extractChannel(frame: ImageFrame, channel: Int) -> [UInt16] {
        var channelData = [UInt16](repeating: 0, count: frame.width * frame.height)
        
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let value = frame.getPixel(x: x, y: y, channel: channel)
                channelData[y * frame.width + x] = value
            }
        }
        
        return channelData
    }
    
    // MARK: - Channel Encoding
    
    private func encodeChannel(data: [UInt16], width: Int, height: Int) throws -> Data {
        // Apply predictive coding
        let predicted = applyPrediction(data: data, width: width, height: height)
        
        // Apply entropy encoding
        let encoded = try entropyEncode(data: predicted)
        
        return encoded
    }
    
    // MARK: - Predictive Coding
    
    private func applyPrediction(data: [UInt16], width: Int, height: Int) -> [Int32] {
        var residuals = [Int32](repeating: 0, count: data.count)
        
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let actual = Int32(data[index])
                
                // Predict based on neighbors
                let predicted = predictPixel(data: data, x: x, y: y, width: width, height: height)
                
                // Store residual
                residuals[index] = actual - predicted
            }
        }
        
        return residuals
    }
    
    /// Predict pixel value using Median Edge Detector (MED) predictor
    private func predictPixel(data: [UInt16], x: Int, y: Int, width: Int, height: Int) -> Int32 {
        // MED predictor: median(N, W, N+W-NW)
        // N = North, W = West, NW = North-West
        
        if x == 0 && y == 0 {
            return 0
        } else if y == 0 {
            // First row: predict from West
            let w = Int32(data[y * width + (x - 1)])
            return w
        } else if x == 0 {
            // First column: predict from North
            let n = Int32(data[(y - 1) * width + x])
            return n
        } else {
            // General case: MED predictor
            let n = Int32(data[(y - 1) * width + x])      // North
            let w = Int32(data[y * width + (x - 1)])      // West
            let nw = Int32(data[(y - 1) * width + (x - 1)]) // North-West
            
            // Gradient predictor
            let gradient = n + w - nw
            
            // Clamp to avoid overflow
            let maxVal = Int32(65535)
            return max(0, min(maxVal, gradient))
        }
    }
    
    // MARK: - Entropy Encoding
    
    private func entropyEncode(data: [Int32]) throws -> Data {
        // Simplified entropy encoding
        // Real JPEG XL uses ANS (Asymmetric Numeral Systems)
        
        var writer = BitstreamWriter()
        
        // Write length
        writer.writeU32(UInt32(data.count))
        
        // Simple run-length + Golomb-Rice encoding
        var i = 0
        while i < data.count {
            let value = data[i]
            
            // Count consecutive identical values
            var runLength = 1
            while i + runLength < data.count && data[i + runLength] == value {
                runLength += 1
            }
            
            // Encode value using signed representation
            let encoded = encodeSignedValue(value)
            writer.writeVarint(encoded)
            
            // Encode run length if > 1
            if runLength > 1 {
                writer.writeVarint(UInt64(runLength - 1))
            } else {
                writer.writeVarint(0)
            }
            
            i += runLength
        }
        
        writer.flushByte()
        return writer.data
    }
    
    /// Encode signed value to unsigned for variable-length encoding
    private func encodeSignedValue(_ value: Int32) -> UInt64 {
        // ZigZag encoding: map signed to unsigned
        // 0 -> 0, -1 -> 1, 1 -> 2, -2 -> 3, 2 -> 4, ...
        if value >= 0 {
            return UInt64(value * 2)
        } else {
            return UInt64(-value * 2 - 1)
        }
    }
}
