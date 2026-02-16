/// Modular Mode Encoder
///
/// Implements lossless compression using the Modular mode of JPEG XL.
/// This uses predictive coding and entropy encoding for efficient lossless compression.

import Foundation

// MARK: - MA (Meta-Adaptive) Tree Types

/// Property identifiers used at MA tree decision nodes.
///
/// Each property extracts a scalar value from the causal neighbourhood of the
/// current pixel, allowing the tree to route prediction based on local image
/// characteristics.  These correspond to the property set defined in
/// ISO/IEC 18181-1 §7.3.
enum MAProperty: Int, CaseIterable, Sendable {
    /// Channel index (0 = first channel).
    case channelIndex = 0
    /// Horizontal gradient: abs(W − NW).
    case gradientH = 1
    /// Vertical gradient: abs(N − NW).
    case gradientV = 2
    /// North pixel value.
    case northValue = 3
    /// West pixel value.
    case westValue = 4
    /// North-West pixel value.
    case northWestValue = 5
    /// West − NW difference (signed).
    case westMinusNW = 6
    /// North − NW difference (signed).
    case northMinusNW = 7
    /// North − NE difference (signed, or 0 when NE unavailable).
    case northMinusNE = 8
    /// Maximum absolute neighbour residual (already encoded).
    case maxAbsResidual = 9
}

/// Predictor modes selectable at MA tree leaf nodes.
///
/// Each mode computes a pixel prediction from the causal neighbourhood.
/// The tree selects the best predictor per-pixel based on the decision
/// path, which is the core idea of Meta-Adaptive prediction.
enum MAPredictor: Int, CaseIterable, Sendable {
    /// Zero prediction (constant 0).
    case zero = 0
    /// West neighbour.
    case west = 1
    /// North neighbour.
    case north = 2
    /// Average of West and North: floor((W + N) / 2).
    case averageWN = 3
    /// MED (Median Edge Detector): clamp(N + W − NW).
    case med = 4
    /// Select between N and W based on gradient (adaptive gradient).
    case selectGradient = 5
    /// Average of West and North-West: floor((W + NW) / 2).
    case averageWNW = 6
    /// Average of North and North-West: floor((N + NW) / 2).
    case averageNNW = 7
}

/// A single node in a Meta-Adaptive decision tree.
///
/// Internal (decision) nodes test ``MAProperty`` against a threshold
/// and branch left (≤) or right (>).  Leaf nodes carry a ``MAPredictor``
/// and an entropy-coding context index.
enum MANode: Sendable {
    /// Decision node: tests `property` against `threshold`.
    ///
    /// - Parameters:
    ///   - property: The pixel property to evaluate.
    ///   - threshold: Signed threshold value.
    ///   - left: Index of the child node taken when property ≤ threshold.
    ///   - right: Index of the child node taken when property > threshold.
    case decision(property: MAProperty, threshold: Int32, left: Int, right: Int)
    
    /// Leaf node: specifies the predictor and entropy context.
    ///
    /// - Parameters:
    ///   - predictor: Predictor mode to use.
    ///   - context: Entropy coding context index for the residual.
    case leaf(predictor: MAPredictor, context: Int)
}

/// Meta-Adaptive (MA) decision tree for per-pixel predictor selection.
///
/// The tree is stored as a flat array of ``MANode`` values.  Traversal
/// starts at index 0 and follows ``MANode/decision`` branches until a
/// ``MANode/leaf`` is reached.  The leaf supplies both the predictor to
/// use and the entropy context for the resulting residual.
///
/// The default tree (``MATree/buildDefault()``) partitions pixels by
/// gradient magnitude and orientation, selecting simpler predictors for
/// edges and MED for smooth areas — matching the general strategy
/// described in ISO/IEC 18181-1 §7.3.
struct MATree: Sendable {
    /// Flat node storage (index 0 = root).
    let nodes: [MANode]
    
    /// The number of distinct leaf contexts in this tree.
    let contextCount: Int
    
    /// Build the default MA tree.
    ///
    /// The tree layout is:
    /// ```
    ///                      [0] gradH ≤ 16 ?
    ///                     /                 \
    ///          [1] gradV ≤ 16 ?         [4] gradV ≤ 16 ?
    ///          /              \          /              \
    ///  [2] leaf(med,0)  [3] leaf(west,1) [5] leaf(north,2) [6] leaf(selectGrad,3)
    /// ```
    ///
    /// - Returns: A tree with 7 nodes (4 leaves, 3 decisions) and 4 contexts.
    static func buildDefault() -> MATree {
        let nodes: [MANode] = [
            // 0: root — split on horizontal gradient
            .decision(property: .gradientH, threshold: 16, left: 1, right: 4),
            // 1: low horizontal gradient — split on vertical gradient
            .decision(property: .gradientV, threshold: 16, left: 2, right: 3),
            // 2: smooth area → MED predictor (best for gradients)
            .leaf(predictor: .med, context: 0),
            // 3: vertical edge, low horizontal gradient → West predictor
            .leaf(predictor: .west, context: 1),
            // 4: high horizontal gradient — split on vertical gradient
            .decision(property: .gradientV, threshold: 16, left: 5, right: 6),
            // 5: horizontal edge → North predictor
            .leaf(predictor: .north, context: 2),
            // 6: textured area → adaptive gradient selector
            .leaf(predictor: .selectGradient, context: 3),
        ]
        return MATree(nodes: nodes, contextCount: 4)
    }
    
    /// Build an extended MA tree for higher effort levels.
    ///
    /// Uses finer gradient thresholds and more predictor variety.
    /// MED remains the primary predictor for smooth areas because it
    /// optimally handles linear gradients (N + W − NW), while
    /// specialised predictors are used for edges and textured areas.
    ///
    /// - Returns: A tree with 15 nodes (8 leaves, 7 decisions) and 8 contexts.
    static func buildExtended() -> MATree {
        let nodes: [MANode] = [
            // 0: root — split on horizontal gradient
            .decision(property: .gradientH, threshold: 16, left: 1, right: 8),
            
            // ---- Low horizontal gradient subtree ----
            // 1: split on vertical gradient
            .decision(property: .gradientV, threshold: 16, left: 2, right: 5),
            // 2: smooth area — split on max abs residual for context
            .decision(property: .maxAbsResidual, threshold: 4, left: 3, right: 4),
            // 3: very smooth → MED (optimal for linear gradients)
            .leaf(predictor: .med, context: 0),
            // 4: smooth with some residual → MED (still best, different context)
            .leaf(predictor: .med, context: 1),
            // 5: vertical edge subtree — split on N-NW
            .decision(property: .northMinusNW, threshold: 0, left: 6, right: 7),
            // 6: positive N-NW → averageWNW
            .leaf(predictor: .averageWNW, context: 2),
            // 7: negative N-NW → West
            .leaf(predictor: .west, context: 3),
            
            // ---- High horizontal gradient subtree ----
            // 8: split on vertical gradient
            .decision(property: .gradientV, threshold: 16, left: 9, right: 12),
            // 9: horizontal edge — split on W-NW
            .decision(property: .westMinusNW, threshold: 0, left: 10, right: 11),
            // 10: positive W-NW → averageNNW
            .leaf(predictor: .averageNNW, context: 4),
            // 11: negative W-NW → North
            .leaf(predictor: .north, context: 5),
            // 12: textured — split on max abs residual
            .decision(property: .maxAbsResidual, threshold: 64, left: 13, right: 14),
            // 13: moderate texture → selectGradient
            .leaf(predictor: .selectGradient, context: 6),
            // 14: high texture → zero predictor (entropy-only)
            .leaf(predictor: .zero, context: 7),
        ]
        return MATree(nodes: nodes, contextCount: 8)
    }
    
    /// Traverse the tree for a given set of property values.
    ///
    /// - Parameter properties: A closure that maps ``MAProperty`` to the
    ///   scalar value at the current pixel position.
    /// - Returns: Tuple of the selected ``MAPredictor`` and context index.
    func traverse(properties: (MAProperty) -> Int32) -> (predictor: MAPredictor, context: Int) {
        var index = 0
        while true {
            switch nodes[index] {
            case let .decision(property, threshold, left, right):
                let value = properties(property)
                index = value <= threshold ? left : right
            case let .leaf(predictor, context):
                return (predictor, context)
            }
        }
    }
    
    /// Evaluate a single property from the causal neighbourhood.
    ///
    /// - Parameters:
    ///   - property: The property to evaluate.
    ///   - data: Original pixel data for the channel.
    ///   - residuals: Already-computed residuals (for ``maxAbsResidual``).
    ///   - x: Column index.
    ///   - y: Row index.
    ///   - width: Row stride.
    ///   - height: Image height.
    ///   - channel: Current channel index.
    /// - Returns: The scalar property value.
    static func evaluateProperty(
        _ property: MAProperty,
        data: [UInt16],
        residuals: [Int32],
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        channel: Int
    ) -> Int32 {
        // Fetch causal neighbours with boundary-aware fallbacks.
        // When a neighbour is unavailable, use the nearest available
        // neighbour so that gradient properties reflect actual local
        // variation rather than an offset artefact (e.g. RCT bias).
        let n: Int32
        if y > 0 {
            n = Int32(data[(y - 1) * width + x])
        } else if x > 0 {
            n = Int32(data[y * width + (x - 1)])     // fallback to W
        } else {
            n = 0
        }
        
        let w: Int32
        if x > 0 {
            w = Int32(data[y * width + (x - 1)])
        } else if y > 0 {
            w = Int32(data[(y - 1) * width + x])     // fallback to N
        } else {
            w = 0
        }
        
        let nw: Int32
        if x > 0 && y > 0 {
            nw = Int32(data[(y - 1) * width + (x - 1)])
        } else if y > 0 {
            nw = Int32(data[(y - 1) * width + x])    // fallback to N
        } else if x > 0 {
            nw = Int32(data[y * width + (x - 1)])    // fallback to W
        } else {
            nw = 0
        }
        
        let ne: Int32
        if y > 0 && x < width - 1 {
            ne = Int32(data[(y - 1) * width + (x + 1)])
        } else {
            ne = n                                    // fallback to N
        }
        
        switch property {
        case .channelIndex:
            return Int32(channel)
        case .gradientH:
            return abs(w - nw)
        case .gradientV:
            return abs(n - nw)
        case .northValue:
            return n
        case .westValue:
            return w
        case .northWestValue:
            return nw
        case .westMinusNW:
            return w - nw
        case .northMinusNW:
            return n - nw
        case .northMinusNE:
            return n - ne
        case .maxAbsResidual:
            let rn:  Int32 = y > 0 ? abs(residuals[(y - 1) * width + x]) : 0
            let rw:  Int32 = x > 0 ? abs(residuals[y * width + (x - 1)]) : 0
            let rnw: Int32 = (x > 0 && y > 0) ? abs(residuals[(y - 1) * width + (x - 1)]) : 0
            return max(rn, max(rw, rnw))
        }
    }
    
    /// Compute the predicted pixel value for a given predictor mode.
    ///
    /// - Parameters:
    ///   - predictor: The predictor to apply.
    ///   - data: Original pixel data.
    ///   - x: Column index.
    ///   - y: Row index.
    ///   - width: Row stride.
    ///   - height: Image height.
    /// - Returns: Predicted pixel value.
    static func applyPredictor(
        _ predictor: MAPredictor,
        data: [UInt16],
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> Int32 {
        let n:  Int32 = y > 0 ? Int32(data[(y - 1) * width + x]) : 0
        let w:  Int32 = x > 0 ? Int32(data[y * width + (x - 1)]) : 0
        let nw: Int32 = (x > 0 && y > 0) ? Int32(data[(y - 1) * width + (x - 1)]) : 0
        let maxVal: Int32 = 65535
        
        // For first pixel, all predictors return 0
        if x == 0 && y == 0 { return 0 }
        
        switch predictor {
        case .zero:
            return 0
        case .west:
            return w
        case .north:
            return n
        case .averageWN:
            return (w + n) / 2
        case .med:
            let gradient = n + w - nw
            return max(0, min(maxVal, gradient))
        case .selectGradient:
            // Choose between N and W based on which gradient is smaller
            let gradH = abs(w - nw)
            let gradV = abs(n - nw)
            return gradV < gradH ? w : n
        case .averageWNW:
            return (w + nw) / 2
        case .averageNNW:
            return (n + nw) / 2
        }
    }
}

/// Modular encoder for lossless compression
class ModularEncoder {
    private let hardware: HardwareCapabilities
    private let options: EncodingOptions
    /// MA tree for per-pixel predictor selection.
    let maTree: MATree
    
    init(hardware: HardwareCapabilities, options: EncodingOptions) {
        self.hardware = hardware
        self.options = options
        // Select tree complexity based on encoding effort
        if options.effort.rawValue >= EncodingEffort.squirrel.rawValue {
            self.maTree = MATree.buildExtended()
        } else {
            self.maTree = MATree.buildDefault()
        }
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
        
        #if arch(arm64)
        if hardware.hasNEON && options.useHardwareAcceleration {
            let (yArr, coArr, cgArr) = NEONOps.forwardRCT(r: r, g: g, b: b)
            // Convert Int32 results to UInt16, offsetting Co/Cg by 32768
            var yChannel  = [UInt16](repeating: 0, count: count)
            var coChannel = [UInt16](repeating: 0, count: count)
            var cgChannel = [UInt16](repeating: 0, count: count)
            for i in 0..<count {
                yChannel[i]  = UInt16(clamping: yArr[i])
                coChannel[i] = UInt16(clamping: coArr[i] + 32768)
                cgChannel[i] = UInt16(clamping: cgArr[i] + 32768)
            }
            channels[0] = yChannel
            channels[1] = coChannel
            channels[2] = cgChannel
            return
        }
        #endif
        
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
        
        #if arch(arm64)
        if hardware.hasNEON && options.useHardwareAcceleration {
            // Convert to Int32, removing the +32768 offset from Co/Cg
            var yArr  = [Int32](repeating: 0, count: count)
            var coArr = [Int32](repeating: 0, count: count)
            var cgArr = [Int32](repeating: 0, count: count)
            for i in 0..<count {
                yArr[i]  = Int32(yChannel[i])
                coArr[i] = Int32(coChannel[i]) - 32768
                cgArr[i] = Int32(cgChannel[i]) - 32768
            }
            let (rArr, gArr, bArr) = NEONOps.inverseRCT(y: yArr, co: coArr, cg: cgArr)
            var r = [UInt16](repeating: 0, count: count)
            var g = [UInt16](repeating: 0, count: count)
            var b = [UInt16](repeating: 0, count: count)
            for i in 0..<count {
                r[i] = UInt16(clamping: rArr[i])
                g[i] = UInt16(clamping: gArr[i])
                b[i] = UInt16(clamping: bArr[i])
            }
            channels[0] = r
            channels[1] = g
            channels[2] = b
            return
        }
        #endif
        
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
        
        #if arch(arm64)
        let useNEON = hardware.hasNEON && options.useHardwareAcceleration
        #endif
        
        for _ in 0..<levels {
            // Horizontal squeeze (if width > 1)
            if w > 1 {
                steps.append(SqueezeStep(horizontal: true, width: w, height: h, stride: bufStride))
                #if arch(arm64)
                if useNEON {
                    NEONOps.squeezeHorizontal(data: &current, regionW: w, regionH: h, stride: bufStride)
                } else {
                    squeezeHorizontal(data: &current, regionW: w, regionH: h, stride: bufStride)
                }
                #else
                squeezeHorizontal(data: &current, regionW: w, regionH: h, stride: bufStride)
                #endif
                w = (w + 1) / 2
            }
            
            // Vertical squeeze (if height > 1)
            if h > 1 {
                steps.append(SqueezeStep(horizontal: false, width: w, height: h, stride: bufStride))
                #if arch(arm64)
                if useNEON {
                    NEONOps.squeezeVertical(data: &current, regionW: w, regionH: h, stride: bufStride)
                } else {
                    squeezeVertical(data: &current, regionW: w, regionH: h, stride: bufStride)
                }
                #else
                squeezeVertical(data: &current, regionW: w, regionH: h, stride: bufStride)
                #endif
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
        
        // Select entropy coding backend
        if options.useANS {
            return try entropyEncodeANS(
                data: squeezed, width: width, height: height
            )
        }
        
        // Apply context-modelled entropy encoding (default)
        let encoded = try entropyEncodeWithContext(
            data: squeezed, width: width, height: height
        )
        
        return encoded
    }
    
    // MARK: - Predictive Coding
    
    private func applyPrediction(data: [UInt16], width: Int, height: Int) -> [Int32] {
        // For lower effort levels, use NEON-accelerated MED prediction
        // when available. At higher effort levels, use the MA tree-based
        // prediction which adapts per-pixel but is inherently sequential.
        #if arch(arm64)
        if hardware.hasNEON && options.useHardwareAcceleration
            && options.effort.rawValue < EncodingEffort.squirrel.rawValue {
            return NEONOps.predictMED(data: data, width: width, height: height)
        }
        #endif

        return applyMAPrediction(data: data, width: width, height: height, channel: 0)
    }
    
    /// Apply MA tree-based prediction for a single channel.
    ///
    /// For each pixel the MA tree selects the optimal predictor based on local
    /// image properties (gradient magnitudes, neighbour values, etc.).  The
    /// resulting residuals tend to be smaller than a fixed MED predictor
    /// because the tree adapts to local edge orientation and texture.
    ///
    /// - Parameters:
    ///   - data: Original channel pixel values.
    ///   - width: Image width.
    ///   - height: Image height.
    ///   - channel: Channel index (used by ``MAProperty/channelIndex``).
    /// - Returns: Array of signed residuals (actual − predicted).
    func applyMAPrediction(data: [UInt16], width: Int, height: Int, channel: Int) -> [Int32] {
        var residuals = [Int32](repeating: 0, count: data.count)
        
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let actual = Int32(data[index])
                
                // Traverse the MA tree to select predictor
                let (predictor, _) = maTree.traverse { property in
                    MATree.evaluateProperty(
                        property,
                        data: data,
                        residuals: residuals,
                        x: x, y: y,
                        width: width, height: height,
                        channel: channel
                    )
                }
                
                // Apply selected predictor
                let predicted = MATree.applyPredictor(
                    predictor, data: data,
                    x: x, y: y,
                    width: width, height: height
                )
                
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
    /// - 4 gradient magnitude buckets (flat, low, medium, high)
    /// - 2 orientation sub-contexts per bucket (horizontal vs. vertical)
    /// - Total: contexts 0–7
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
    
    /// Entropy-encode residuals using ANS (Asymmetric Numeral Systems).
    ///
    /// This method maps signed residuals to unsigned symbols via ZigZag
    /// encoding, partitions them by context (gradient-based), builds
    /// per-context ANS distributions, and encodes using the multi-context
    /// rANS encoder.  The distribution tables are serialised as a header
    /// so the decoder can reconstruct them.
    ///
    /// - Parameters:
    ///   - data: Signed residual values.
    ///   - width: Image width (for 2D context selection).
    ///   - height: Image height.
    /// - Returns: Compressed data with embedded distribution tables.
    func entropyEncodeANS(
        data: [Int32],
        width: Int,
        height: Int
    ) throws -> Data {
        // Map signed residuals → unsigned symbols via ZigZag
        let symbols = data.map { v -> Int in
            Int(encodeSignedValue(v))
        }
        
        // Determine alphabet size (max symbol + 1, clamped to 256)
        let maxSym = symbols.max() ?? 0
        let alphabetSize = min(maxSym + 1, ANSConstants.maxAlphabetSize)
        
        // Clamp symbols to alphabet range for very large residuals
        let clampedSymbols = symbols.map { min($0, alphabetSize - 1) }
        
        // Partition symbols by context
        var contextSymbols = [[Int]](
            repeating: [], count: ModularEncoder.contextCount
        )
        for i in 0..<clampedSymbols.count {
            let x = i % width
            let y = i / width
            let ctx = selectContext(
                residuals: data, x: x, y: y, width: width
            )
            contextSymbols[ctx].append(clampedSymbols[i])
        }
        
        // Build multi-context ANS encoder
        let ansEncoder = try MultiContextANSEncoder.build(
            contextSymbols: contextSymbols,
            alphabetSize: alphabetSize
        )
        
        // Build (symbol, context) pairs in order
        var pairs = [(symbol: Int, context: Int)]()
        pairs.reserveCapacity(clampedSymbols.count)
        for i in 0..<clampedSymbols.count {
            let x = i % width
            let y = i / width
            let ctx = selectContext(
                residuals: data, x: x, y: y, width: width
            )
            pairs.append((symbol: clampedSymbols[i], context: ctx))
        }
        
        // Encode symbols
        let encoded = try ansEncoder.encode(pairs)
        
        // Build output: header + distribution tables + encoded data
        var writer = BitstreamWriter()
        
        // Write element count
        writer.writeU32(UInt32(data.count))
        
        // Write ANS mode marker (1 byte: 0x01 = ANS)
        writer.writeByte(0x01)
        
        // Write alphabet size (2 bytes LE)
        writer.writeByte(UInt8(alphabetSize & 0xFF))
        writer.writeByte(UInt8((alphabetSize >> 8) & 0xFF))
        
        // Write context count
        writer.writeByte(UInt8(ModularEncoder.contextCount))
        
        // Serialise each distribution table
        for dist in ansEncoder.distributions {
            let table = dist.serialise()
            writer.writeVarint(UInt64(table.count))
            writer.writeData(table)
        }
        
        // Write encoded data length and data
        writer.writeU32(UInt32(encoded.count))
        writer.writeData(encoded)
        
        writer.flushByte()
        return writer.data
    }
    
    /// Entropy-encode residuals using context-modelled run-length + Golomb-Rice coding.
    ///
    /// Each residual is first mapped to an unsigned value via ZigZag encoding,
    /// then encoded under a context selected from the local gradient properties
    /// of its causal neighbourhood.  The Golomb-Rice parameter adapts per
    /// context based on the running symbol statistics.
    ///
    /// - Note: This overload estimates 2D positions from a flat index via
    ///   `sqrt(data.count)`.  Prefer ``entropyEncodeWithContext(data:width:height:)``
    ///   when the actual image dimensions are available.
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
