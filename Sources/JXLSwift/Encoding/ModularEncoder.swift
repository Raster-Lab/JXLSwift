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
    
    // MARK: - Squeeze Transform (Multi-Resolution Decomposition)
    
    /// A single squeeze step descriptor.
    ///
    /// Each step records whether it operates horizontally or vertically,
    /// along with the region dimensions and the buffer stride, so the
    /// inverse can reconstruct the original layout.
    struct SqueezeStep {
        /// `true` for a horizontal squeeze (columns), `false` for vertical (rows).
        let horizontal: Bool
        /// Width of the active region before this squeeze step.
        let width: Int
        /// Height of the active region before this squeeze step.
        let height: Int
        /// Row stride of the buffer (may be larger than `width` at deeper levels).
        let stride: Int
    }
    
    /// Apply the forward squeeze transform to a single channel.
    ///
    /// The transform alternates horizontal and vertical squeezes,
    /// halving the active region in each dimension per iteration.
    /// The result is a multi-resolution decomposition where the
    /// low-resolution approximation occupies the top-left corner and
    /// detail (residual) coefficients fill the remainder.
    ///
    /// This is the Haar-like integer wavelet transform used by JPEG XL
    /// Modular mode (ISO/IEC 18181-1 §7).  All arithmetic is integer-exact
    /// and perfectly reversible via ``inverseSqueeze``.
    ///
    /// - Parameters:
    ///   - data: Channel pixel values laid out row-major.
    ///   - width: Channel width in pixels.
    ///   - height: Channel height in pixels.
    ///   - levels: Number of decomposition levels (default 3).
    /// - Returns: Tuple of the transformed data and the squeeze steps
    ///   recorded in application order.
    func forwardSqueeze(
        data: [Int32],
        width: Int,
        height: Int,
        levels: Int = 3
    ) -> (data: [Int32], steps: [SqueezeStep]) {
        var current = data
        let bufStride = width          // row stride never changes
        var w = width
        var h = height
        var steps: [SqueezeStep] = []
        
        for _ in 0..<levels {
            // Horizontal squeeze (if width > 1)
            if w > 1 {
                steps.append(SqueezeStep(horizontal: true, width: w, height: h, stride: bufStride))
                squeezeHorizontal(data: &current, regionW: w, regionH: h, stride: bufStride)
                w = (w + 1) / 2
            }
            
            // Vertical squeeze (if height > 1)
            if h > 1 {
                steps.append(SqueezeStep(horizontal: false, width: w, height: h, stride: bufStride))
                squeezeVertical(data: &current, regionW: w, regionH: h, stride: bufStride)
                h = (h + 1) / 2
            }
            
            // Stop if both dimensions are 1
            if w <= 1 && h <= 1 { break }
        }
        
        return (current, steps)
    }
    
    /// Apply the inverse squeeze transform to reconstruct the original channel.
    ///
    /// The steps recorded during ``forwardSqueeze`` are replayed in reverse
    /// order so that every split is undone in the correct sequence.
    ///
    /// - Parameters:
    ///   - data: Transformed channel data (low-res + details).
    ///   - steps: The squeeze steps returned by ``forwardSqueeze``, in
    ///     the same (forward) order — they are reversed internally.
    /// - Returns: Reconstructed channel data matching the original.
    func inverseSqueeze(
        data: [Int32],
        steps: [SqueezeStep]
    ) -> [Int32] {
        var current = data
        
        for step in steps.reversed() {
            if step.horizontal {
                inverseSqueezeHorizontal(
                    data: &current, regionW: step.width, regionH: step.height, stride: step.stride
                )
            } else {
                inverseSqueezeVertical(
                    data: &current, regionW: step.width, regionH: step.height, stride: step.stride
                )
            }
        }
        
        return current
    }
    
    // MARK: Horizontal Squeeze
    
    /// Forward horizontal squeeze on a sub-region of the buffer.
    ///
    /// For each row in `0..<regionH`, even-indexed columns within
    /// `0..<regionW` form the low-res signal and odd columns store the
    /// detail (residual).  The row stride of the underlying buffer is
    /// given by `stride` (which may be larger than `regionW` at deeper
    /// decomposition levels).
    ///
    ///     avg  = floor((even + odd) / 2)   (towards -∞)
    ///     diff = even - odd
    func squeezeHorizontal(data: inout [Int32], regionW: Int, regionH: Int, stride bufStride: Int) {
        let lowW = (regionW + 1) / 2
        // Temporary row buffer to avoid in-place aliasing
        var row = [Int32](repeating: 0, count: regionW)
        
        for y in 0..<regionH {
            let rowBase = y * bufStride
            
            // Process pairs
            for x in Swift.stride(from: 0, to: regionW - 1, by: 2) {
                let even = data[rowBase + x]
                let odd  = data[rowBase + x + 1]
                
                let avg: Int32
                if (even + odd) >= 0 {
                    avg = (even + odd) / 2
                } else {
                    avg = (even + odd - 1) / 2
                }
                let diff = even - odd
                
                row[x / 2]        = avg
                row[lowW + x / 2] = diff
            }
            // Trailing column when regionW is odd
            if regionW % 2 == 1 {
                row[lowW - 1] = data[rowBase + regionW - 1]
            }
            
            // Write back
            for x in 0..<regionW {
                data[rowBase + x] = row[x]
            }
        }
    }
    
    /// Inverse horizontal squeeze on a sub-region of the buffer.
    func inverseSqueezeHorizontal(data: inout [Int32], regionW: Int, regionH: Int, stride bufStride: Int) {
        let lowW = (regionW + 1) / 2
        var row = [Int32](repeating: 0, count: regionW)
        
        for y in 0..<regionH {
            let rowBase = y * bufStride
            
            // Read current row into temporary
            for x in 0..<regionW {
                row[x] = data[rowBase + x]
            }
            
            for x in Swift.stride(from: 0, to: regionW - 1, by: 2) {
                let avg  = row[x / 2]
                let diff = row[lowW + x / 2]
                
                let even = avg + (diff + (diff >= 0 ? 1 : 0)) / 2
                let odd  = even - diff
                
                data[rowBase + x]     = even
                data[rowBase + x + 1] = odd
            }
            if regionW % 2 == 1 {
                data[rowBase + regionW - 1] = row[lowW - 1]
            }
        }
    }
    
    // MARK: Vertical Squeeze
    
    /// Forward vertical squeeze on a sub-region of the buffer.
    ///
    /// For each column in `0..<regionW`, even-indexed rows within
    /// `0..<regionH` form the low-res signal and odd rows store the
    /// detail.  Low-res rows are packed into rows `0..<(regionH+1)/2`
    /// and details into rows `(regionH+1)/2..<regionH`.
    func squeezeVertical(data: inout [Int32], regionW: Int, regionH: Int, stride bufStride: Int) {
        let lowH = (regionH + 1) / 2
        var col = [Int32](repeating: 0, count: regionH)
        
        for x in 0..<regionW {
            // Read column into temporary
            for y in 0..<regionH {
                col[y] = data[y * bufStride + x]
            }
            
            var out = [Int32](repeating: 0, count: regionH)
            
            for y in Swift.stride(from: 0, to: regionH - 1, by: 2) {
                let even = col[y]
                let odd  = col[y + 1]
                
                let avg: Int32
                if (even + odd) >= 0 {
                    avg = (even + odd) / 2
                } else {
                    avg = (even + odd - 1) / 2
                }
                let diff = even - odd
                
                out[y / 2]        = avg
                out[lowH + y / 2] = diff
            }
            if regionH % 2 == 1 {
                out[lowH - 1] = col[regionH - 1]
            }
            
            // Write back
            for y in 0..<regionH {
                data[y * bufStride + x] = out[y]
            }
        }
    }
    
    /// Inverse vertical squeeze on a sub-region of the buffer.
    func inverseSqueezeVertical(data: inout [Int32], regionW: Int, regionH: Int, stride bufStride: Int) {
        let lowH = (regionH + 1) / 2
        var col = [Int32](repeating: 0, count: regionH)
        
        for x in 0..<regionW {
            // Read column into temporary
            for y in 0..<regionH {
                col[y] = data[y * bufStride + x]
            }
            
            for y in Swift.stride(from: 0, to: regionH - 1, by: 2) {
                let avg  = col[y / 2]
                let diff = col[lowH + y / 2]
                
                let even = avg + (diff + (diff >= 0 ? 1 : 0)) / 2
                let odd  = even - diff
                
                data[y * bufStride + x]       = even
                data[(y + 1) * bufStride + x] = odd
            }
            if regionH % 2 == 1 {
                data[(regionH - 1) * bufStride + x] = col[lowH - 1]
            }
        }
    }
    
    // MARK: - Channel Encoding
    
    private func encodeChannel(data: [UInt16], width: Int, height: Int) throws -> Data {
        // Apply predictive coding
        let predicted = applyPrediction(data: data, width: width, height: height)
        
        // Apply squeeze transform for multi-resolution decomposition
        let (squeezed, _) = forwardSqueeze(data: predicted, width: width, height: height)
        
        // Apply context-modelled entropy encoding
        let encoded = try entropyEncodeWithContext(
            data: squeezed, width: width, height: height
        )
        
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
    
    // MARK: - Context Modelling
    
    /// Number of distinct contexts for entropy coding.
    ///
    /// Contexts are selected based on local gradient properties:
    /// - Contexts 0–4: classified by gradient magnitude bucket
    /// - Within each bucket the context is further split by gradient
    ///   orientation (horizontal vs. vertical dominance).
    ///
    /// This follows the general idea of ISO/IEC 18181-1 §7 where the
    /// encoder selects a context from the causal neighborhood so that
    /// symbols with similar statistical distributions share a context.
    static let contextCount = 8
    
    /// Per-context statistics tracker.
    ///
    /// Maintains a running count and sum-of-magnitudes so the encoder
    /// can adapt the Golomb-Rice parameter per context.
    struct ContextModel {
        /// Number of symbols encoded in each context.
        private(set) var counts: [Int]
        /// Sum of unsigned (ZigZag-mapped) symbol magnitudes per context.
        private(set) var sumOfValues: [UInt64]
        
        /// Create a context model with the given number of contexts.
        init(contextCount: Int) {
            self.counts = [Int](repeating: 0, count: contextCount)
            self.sumOfValues = [UInt64](repeating: 0, count: contextCount)
        }
        
        /// Record that `unsignedValue` was encoded under `context`.
        mutating func record(context: Int, unsignedValue: UInt64) {
            counts[context] += 1
            sumOfValues[context] += unsignedValue
        }
        
        /// Adaptive Golomb-Rice parameter for `context`.
        ///
        /// Returns a small non-negative integer *k* such that the
        /// expected codeword length for the observed distribution is
        /// roughly minimised.  When no symbols have been seen the
        /// parameter defaults to 0 (unary coding).
        func riceParameter(for context: Int) -> Int {
            let n = counts[context]
            guard n > 0 else { return 0 }
            
            let mean = sumOfValues[context] / UInt64(n)
            // k ≈ floor(log2(mean + 1))
            if mean == 0 { return 0 }
            var k = 0
            var v = mean
            while v > 0 {
                v >>= 1
                k += 1
            }
            return max(0, k - 1)
        }
    }
    
    /// Select the entropy coding context for a residual at position (`x`, `y`).
    ///
    /// The context is derived from the magnitudes and orientation of the
    /// horizontal and vertical gradients in the already-processed causal
    /// neighbourhood (North, West, North-West pixels).
    ///
    /// - Parameters:
    ///   - residuals: The residual buffer (same layout as the channel data).
    ///   - x: Column index of the current pixel.
    ///   - y: Row index of the current pixel.
    ///   - width: Row stride of the residual buffer.
    /// - Returns: Context index in `0 ..< contextCount`.
    func selectContext(
        residuals: [Int32],
        x: Int,
        y: Int,
        width: Int
    ) -> Int {
        // Collect causal neighbors (already-encoded residuals)
        let n:  Int32 = y > 0 ? abs(residuals[(y - 1) * width + x]) : 0
        let w:  Int32 = x > 0 ? abs(residuals[y * width + (x - 1)]) : 0
        let nw: Int32 = (x > 0 && y > 0) ? abs(residuals[(y - 1) * width + (x - 1)]) : 0
        
        // Gradient magnitude: average of absolute neighbor residuals
        let gradMagnitude = (n + w + nw) / 3
        
        // Bucket by gradient magnitude (4 buckets)
        let bucket: Int
        if gradMagnitude == 0 {
            bucket = 0        // Flat / DC area
        } else if gradMagnitude < 16 {
            bucket = 1        // Low gradient
        } else if gradMagnitude < 256 {
            bucket = 2        // Medium gradient
        } else {
            bucket = 3        // High gradient
        }
        
        // Sub-classify by gradient orientation
        let horizontal = n > w   // stronger vertical edge → horizontal sub-context
        let contextIndex = bucket * 2 + (horizontal ? 1 : 0)
        
        return min(contextIndex, ModularEncoder.contextCount - 1)
    }
    
    // MARK: - Entropy Encoding
    
    /// Entropy-encode residuals using context-modelled run-length + Golomb-Rice coding.
    ///
    /// Each residual is first mapped to an unsigned value via ZigZag encoding,
    /// then encoded under a context selected from the local gradient properties
    /// of its causal neighbourhood.  The Golomb-Rice parameter adapts per
    /// context based on the running symbol statistics.
    private func entropyEncode(data: [Int32]) throws -> Data {
        var writer = BitstreamWriter()
        
        // Write length
        writer.writeU32(UInt32(data.count))
        
        var contextModel = ContextModel(contextCount: ModularEncoder.contextCount)
        
        // Context-modelled run-length + adaptive Golomb-Rice encoding
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
            
            // Update context model for all positions in this run
            // (the context is uniform within a run because the
            //  residual values are identical)
            let ctx = selectContext(residuals: data, x: i % max(1, Int(sqrt(Double(data.count)))),
                                    y: i / max(1, Int(sqrt(Double(data.count)))),
                                    width: max(1, Int(sqrt(Double(data.count)))))
            for _ in 0..<runLength {
                contextModel.record(context: ctx, unsignedValue: encoded)
            }
            
            i += runLength
        }
        
        writer.flushByte()
        return writer.data
    }
    
    /// Entropy-encode residuals with full 2D context modelling.
    ///
    /// Unlike `entropyEncode(data:)`, this method receives the image
    /// dimensions so that it can compute the correct 2D position of
    /// each residual for context selection.
    ///
    /// The context index is not written to the bitstream — the decoder
    /// derives the identical context from the same causal neighbourhood.
    /// Instead the context drives run-length grouping: consecutive
    /// pixels that share both the same residual value *and* the same
    /// context are grouped into a single run, which improves compression
    /// when flat regions produce long uniform-context runs.
    func entropyEncodeWithContext(
        data: [Int32],
        width: Int,
        height: Int
    ) throws -> Data {
        var writer = BitstreamWriter()
        
        // Write element count
        writer.writeU32(UInt32(data.count))
        
        var contextModel = ContextModel(contextCount: ModularEncoder.contextCount)
        
        var i = 0
        while i < data.count {
            let value = data[i]
            let x0 = i % width
            let y0 = i / width
            let ctx0 = selectContext(residuals: data, x: x0, y: y0, width: width)
            
            // Count consecutive identical values in the same context
            var runLength = 1
            while i + runLength < data.count && data[i + runLength] == value {
                let xr = (i + runLength) % width
                let yr = (i + runLength) / width
                let ctxR = selectContext(residuals: data, x: xr, y: yr, width: width)
                guard ctxR == ctx0 else { break }
                runLength += 1
            }
            
            // Encode value using signed-to-unsigned mapping
            let encoded = encodeSignedValue(value)
            writer.writeVarint(encoded)
            
            // Encode run length
            if runLength > 1 {
                writer.writeVarint(UInt64(runLength - 1))
            } else {
                writer.writeVarint(0)
            }
            
            // Update context model
            for _ in 0..<runLength {
                contextModel.record(context: ctx0, unsignedValue: encoded)
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
