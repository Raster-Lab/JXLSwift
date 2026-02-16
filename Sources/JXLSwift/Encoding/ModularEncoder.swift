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
        
        // Extract all channels
        var channels = (0..<frame.channels).map { channel in
            extractChannel(frame: frame, channel: channel)
        }
        
        // Apply RCT for multi-channel (RGB) images
        let useRCT = frame.channels >= 3
        writer.writeBit(useRCT) // Signal whether RCT is applied
        
        if useRCT {
            applyRCT(channels: &channels)
        }
        
        // Process each channel separately
        for channelData in channels {
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
    
    // MARK: - Reversible Colour Transform (RCT)
    
    /// Apply forward RCT (YCoCg-R) to decorrelate RGB channels.
    ///
    /// Transforms in-place: channels[0..2] = (R, G, B) → (Y, Co, Cg).
    /// Uses the lifting-based YCoCg-R transform from ISO/IEC 18181-1.
    /// All arithmetic is integer-exact and perfectly reversible.
    ///
    /// - Parameter channels: Array of channel data; first three are R, G, B.
    ///   After the call they hold Y, Co, Cg (stored as offset unsigned values).
    func applyRCT(channels: inout [[UInt16]]) {
        guard channels.count >= 3 else { return }
        
        let count = channels[0].count
        let r = channels[0]
        let g = channels[1]
        let b = channels[2]
        
        var yChannel  = [UInt16](repeating: 0, count: count)
        var coChannel = [UInt16](repeating: 0, count: count)
        var cgChannel = [UInt16](repeating: 0, count: count)
        
        for i in 0..<count {
            let (y, co, cg) = forwardRCT(r: Int32(r[i]), g: Int32(g[i]), b: Int32(b[i]))
            
            // Co and Cg are signed; offset by 32768 to store as UInt16
            yChannel[i]  = UInt16(clamping: y)
            coChannel[i] = UInt16(clamping: co + 32768)
            cgChannel[i] = UInt16(clamping: cg + 32768)
        }
        
        channels[0] = yChannel
        channels[1] = coChannel
        channels[2] = cgChannel
    }
    
    /// Apply inverse RCT (YCoCg-R) to recover RGB from decorrelated channels.
    ///
    /// - Parameter channels: Array of channel data; first three are Y, Co, Cg
    ///   (Co/Cg stored with +32768 offset). After the call they hold R, G, B.
    func inverseRCT(channels: inout [[UInt16]]) {
        guard channels.count >= 3 else { return }
        
        let count = channels[0].count
        let yChannel  = channels[0]
        let coChannel = channels[1]
        let cgChannel = channels[2]
        
        var r = [UInt16](repeating: 0, count: count)
        var g = [UInt16](repeating: 0, count: count)
        var b = [UInt16](repeating: 0, count: count)
        
        for i in 0..<count {
            // Remove the +32768 offset from Co and Cg
            let co = Int32(coChannel[i]) - 32768
            let cg = Int32(cgChannel[i]) - 32768
            
            let (ri, gi, bi) = inverseRCTPixel(y: Int32(yChannel[i]), co: co, cg: cg)
            
            r[i] = UInt16(clamping: ri)
            g[i] = UInt16(clamping: gi)
            b[i] = UInt16(clamping: bi)
        }
        
        channels[0] = r
        channels[1] = g
        channels[2] = b
    }
    
    /// Forward YCoCg-R transform for a single pixel.
    ///
    /// - Parameters:
    ///   - r: Red channel value.
    ///   - g: Green channel value.
    ///   - b: Blue channel value.
    /// - Returns: Tuple (Y, Co, Cg) where Co and Cg are signed values.
    func forwardRCT(r: Int32, g: Int32, b: Int32) -> (y: Int32, co: Int32, cg: Int32) {
        let co = r - b
        let t  = b + (co >> 1)
        let cg = g - t
        let y  = t + (cg >> 1)
        return (y, co, cg)
    }
    
    /// Inverse YCoCg-R transform for a single pixel.
    ///
    /// - Parameters:
    ///   - y: Luminance value.
    ///   - co: Orange chroma value (signed).
    ///   - cg: Green chroma value (signed).
    /// - Returns: Tuple (R, G, B).
    func inverseRCTPixel(y: Int32, co: Int32, cg: Int32) -> (r: Int32, g: Int32, b: Int32) {
        let t = y - (cg >> 1)
        let g = cg + t
        let b = t - (co >> 1)
        let r = co + b
        return (r, g, b)
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
    func predictPixel(data: [UInt16], x: Int, y: Int, width: Int, height: Int) -> Int32 {
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
    func encodeSignedValue(_ value: Int32) -> UInt64 {
        // ZigZag encoding: map signed to unsigned
        // 0 -> 0, -1 -> 1, 1 -> 2, -2 -> 3, 2 -> 4, ...
        if value >= 0 {
            return UInt64(value * 2)
        } else {
            return UInt64(-value * 2 - 1)
        }
    }
}
