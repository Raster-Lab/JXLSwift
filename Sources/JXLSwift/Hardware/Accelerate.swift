/// Apple Silicon Hardware Acceleration
///
/// Provides optimized implementations using ARM NEON SIMD and Apple Accelerate framework

import Foundation

#if canImport(Accelerate)
import Accelerate

/// Accelerate framework utilities for hardware acceleration
public enum AccelerateOps {
    
    // MARK: - DCT Operations
    
    /// Perform 2D DCT using vDSP
    public static func dct2D(_ input: [Float], size: Int) -> [Float] {
        guard size > 0 else { return [] }
        
        var output = [Float](repeating: 0, count: size * size)
        
        // Setup DCT using modern Swift Accelerate API
        guard let dct = vDSP.DCT(count: size, transformType: .II) else {
            return input
        }
        
        // Process rows
        var temp = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            let offset = row * size
            let rowData = Array(input[offset..<offset+size])
            let transformed = dct.transform(rowData)
            temp.replaceSubrange(offset..<offset+size, with: transformed)
        }
        
        // Transpose
        var transposed = [Float](repeating: 0, count: size * size)
        vDSP_mtrans(temp, 1, &transposed, 1, vDSP_Length(size), vDSP_Length(size))
        
        // Process columns (which are now rows after transpose)
        for row in 0..<size {
            let offset = row * size
            let rowData = Array(transposed[offset..<offset+size])
            let transformed = dct.transform(rowData)
            temp.replaceSubrange(offset..<offset+size, with: transformed)
        }
        
        // Transpose back
        vDSP_mtrans(temp, 1, &output, 1, vDSP_Length(size), vDSP_Length(size))
        
        return output
    }
    
    /// Perform 2D inverse DCT (IDCT) using vDSP
    /// - Parameters:
    ///   - input: Flattened frequency-domain coefficients (size × size)
    ///   - size: Block dimension (e.g. 8 for 8×8 blocks)
    /// - Returns: Flattened spatial-domain values
    public static func idct2D(_ input: [Float], size: Int) -> [Float] {
        guard size > 0 else { return [] }
        
        var output = [Float](repeating: 0, count: size * size)
        
        guard let idct = vDSP.DCT(count: size, transformType: .III) else {
            return input
        }
        
        // Process rows
        var temp = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            let offset = row * size
            let rowData = Array(input[offset..<offset+size])
            let transformed = idct.transform(rowData)
            temp.replaceSubrange(offset..<offset+size, with: transformed)
        }
        
        // Transpose
        var transposed = [Float](repeating: 0, count: size * size)
        vDSP_mtrans(temp, 1, &transposed, 1, vDSP_Length(size), vDSP_Length(size))
        
        // Process columns (which are now rows after transpose)
        for row in 0..<size {
            let offset = row * size
            let rowData = Array(transposed[offset..<offset+size])
            let transformed = idct.transform(rowData)
            temp.replaceSubrange(offset..<offset+size, with: transformed)
        }
        
        // Transpose back
        vDSP_mtrans(temp, 1, &output, 1, vDSP_Length(size), vDSP_Length(size))
        
        return output
    }
    
    // MARK: - Colour Space Conversion
    
    /// Convert interleaved RGB float arrays to YCbCr using BT.601 coefficients.
    ///
    /// - Parameters:
    ///   - r: Red channel values in [0, 1]
    ///   - g: Green channel values in [0, 1]
    ///   - b: Blue channel values in [0, 1]
    /// - Returns: Tuple of (Y, Cb, Cr) arrays in [0, 1]
    public static func rgbToYCbCr(
        r: [Float], g: [Float], b: [Float]
    ) -> (y: [Float], cb: [Float], cr: [Float]) {
        let count = r.count
        precondition(g.count == count && b.count == count)
        
        // Y  =  0.299·R + 0.587·G + 0.114·B
        // Cb = -0.168736·R - 0.331264·G + 0.5·B + 0.5
        // Cr =  0.5·R - 0.418688·G - 0.081312·B + 0.5
        
        // Y channel
        var yChannel = [Float](repeating: 0, count: count)
        var rScaled = [Float](repeating: 0, count: count)
        var gScaled = [Float](repeating: 0, count: count)
        var bScaled = [Float](repeating: 0, count: count)
        
        var kr: Float = 0.299
        var kg: Float = 0.587
        var kb: Float = 0.114
        vDSP_vsmul(r, 1, &kr, &rScaled, 1, vDSP_Length(count))
        vDSP_vsmul(g, 1, &kg, &gScaled, 1, vDSP_Length(count))
        vDSP_vsmul(b, 1, &kb, &bScaled, 1, vDSP_Length(count))
        vDSP_vadd(rScaled, 1, gScaled, 1, &yChannel, 1, vDSP_Length(count))
        vDSP_vadd(yChannel, 1, bScaled, 1, &yChannel, 1, vDSP_Length(count))
        
        // Cb channel
        var cbChannel = [Float](repeating: 0, count: count)
        var kcbr: Float = -0.168736
        var kcbg: Float = -0.331264
        var kcbb: Float = 0.5
        vDSP_vsmul(r, 1, &kcbr, &rScaled, 1, vDSP_Length(count))
        vDSP_vsmul(g, 1, &kcbg, &gScaled, 1, vDSP_Length(count))
        vDSP_vsmul(b, 1, &kcbb, &bScaled, 1, vDSP_Length(count))
        vDSP_vadd(rScaled, 1, gScaled, 1, &cbChannel, 1, vDSP_Length(count))
        vDSP_vadd(cbChannel, 1, bScaled, 1, &cbChannel, 1, vDSP_Length(count))
        var offset: Float = 0.5
        vDSP_vsadd(cbChannel, 1, &offset, &cbChannel, 1, vDSP_Length(count))
        
        // Cr channel
        var crChannel = [Float](repeating: 0, count: count)
        var kcrr: Float = 0.5
        var kcrg: Float = -0.418688
        var kcrb: Float = -0.081312
        vDSP_vsmul(r, 1, &kcrr, &rScaled, 1, vDSP_Length(count))
        vDSP_vsmul(g, 1, &kcrg, &gScaled, 1, vDSP_Length(count))
        vDSP_vsmul(b, 1, &kcrb, &bScaled, 1, vDSP_Length(count))
        vDSP_vadd(rScaled, 1, gScaled, 1, &crChannel, 1, vDSP_Length(count))
        vDSP_vadd(crChannel, 1, bScaled, 1, &crChannel, 1, vDSP_Length(count))
        vDSP_vsadd(crChannel, 1, &offset, &crChannel, 1, vDSP_Length(count))
        
        return (yChannel, cbChannel, crChannel)
    }
    
    // MARK: - XYB Colour Space Conversion
    
    /// Convert linear RGB to the JPEG XL XYB colour space using vectorised operations.
    ///
    /// The pipeline mirrors `VarDCTEncoder.convertToXYBScalar`:
    /// 1. Linear RGB → LMS via opsin absorbance matrix (vectorised multiply + add)
    /// 2. LMS → L'M'S' via cube-root transfer (element-wise)
    /// 3. L'M'S' → XYB: X = (L' - M') / 2, Y = (L' + M') / 2, B = S'
    ///
    /// - Parameters:
    ///   - r: Red channel values in [0, 1]
    ///   - g: Green channel values in [0, 1]
    ///   - b: Blue channel values in [0, 1]
    /// - Returns: Tuple of (X, Y, B) arrays
    public static func rgbToXYB(
        r: [Float], g: [Float], b: [Float]
    ) -> (x: [Float], y: [Float], b: [Float]) {
        let count = r.count
        precondition(g.count == count && b.count == count)
        
        let m = VarDCTEncoder.opsinAbsorbanceMatrix
        var rScaled = [Float](repeating: 0, count: count)
        var gScaled = [Float](repeating: 0, count: count)
        var bScaled = [Float](repeating: 0, count: count)
        
        // L = m[0]*R + m[1]*G + m[2]*B
        var lChannel = [Float](repeating: 0, count: count)
        var k0 = m[0]; var k1 = m[1]; var k2 = m[2]
        vDSP_vsmul(r, 1, &k0, &rScaled, 1, vDSP_Length(count))
        vDSP_vsmul(g, 1, &k1, &gScaled, 1, vDSP_Length(count))
        vDSP_vsmul(b, 1, &k2, &bScaled, 1, vDSP_Length(count))
        vDSP_vadd(rScaled, 1, gScaled, 1, &lChannel, 1, vDSP_Length(count))
        vDSP_vadd(lChannel, 1, bScaled, 1, &lChannel, 1, vDSP_Length(count))
        
        // M = m[3]*R + m[4]*G + m[5]*B
        var mChannel = [Float](repeating: 0, count: count)
        var k3 = m[3]; var k4 = m[4]; var k5 = m[5]
        vDSP_vsmul(r, 1, &k3, &rScaled, 1, vDSP_Length(count))
        vDSP_vsmul(g, 1, &k4, &gScaled, 1, vDSP_Length(count))
        vDSP_vsmul(b, 1, &k5, &bScaled, 1, vDSP_Length(count))
        vDSP_vadd(rScaled, 1, gScaled, 1, &mChannel, 1, vDSP_Length(count))
        vDSP_vadd(mChannel, 1, bScaled, 1, &mChannel, 1, vDSP_Length(count))
        
        // S = m[6]*R + m[7]*G + m[8]*B
        var sChannel = [Float](repeating: 0, count: count)
        var k6 = m[6]; var k7 = m[7]; var k8 = m[8]
        vDSP_vsmul(r, 1, &k6, &rScaled, 1, vDSP_Length(count))
        vDSP_vsmul(g, 1, &k7, &gScaled, 1, vDSP_Length(count))
        vDSP_vsmul(b, 1, &k8, &bScaled, 1, vDSP_Length(count))
        vDSP_vadd(rScaled, 1, gScaled, 1, &sChannel, 1, vDSP_Length(count))
        vDSP_vadd(sChannel, 1, bScaled, 1, &sChannel, 1, vDSP_Length(count))
        
        // Apply opsin transfer element-wise (cube root is not vectorisable via vDSP)
        for i in 0..<count {
            lChannel[i] = VarDCTEncoder.opsinTransfer(lChannel[i])
            mChannel[i] = VarDCTEncoder.opsinTransfer(mChannel[i])
            sChannel[i] = VarDCTEncoder.opsinTransfer(sChannel[i])
        }
        
        // X = (L' - M') / 2, Y = (L' + M') / 2, B = S'
        var xChannel = [Float](repeating: 0, count: count)
        var yChannel = [Float](repeating: 0, count: count)
        vDSP_vsub(mChannel, 1, lChannel, 1, &xChannel, 1, vDSP_Length(count))
        var half: Float = 0.5
        vDSP_vsmul(xChannel, 1, &half, &xChannel, 1, vDSP_Length(count))
        vDSP_vadd(lChannel, 1, mChannel, 1, &yChannel, 1, vDSP_Length(count))
        vDSP_vsmul(yChannel, 1, &half, &yChannel, 1, vDSP_Length(count))
        
        return (xChannel, yChannel, sChannel)
    }
    
    /// Convert XYB colour space back to linear RGB using vectorised operations.
    ///
    /// - Parameters:
    ///   - x: X channel values
    ///   - y: Y channel values
    ///   - b: B channel values
    /// - Returns: Tuple of (R, G, B) linear channel arrays
    public static func xybToRGB(
        x: [Float], y: [Float], b: [Float]
    ) -> (r: [Float], g: [Float], b: [Float]) {
        let count = x.count
        precondition(y.count == count && b.count == count)
        
        // L' = Y + X, M' = Y - X, S' = B
        var lPrime = [Float](repeating: 0, count: count)
        var mPrime = [Float](repeating: 0, count: count)
        vDSP_vadd(y, 1, x, 1, &lPrime, 1, vDSP_Length(count))
        vDSP_vsub(x, 1, y, 1, &mPrime, 1, vDSP_Length(count))
        
        // Inverse opsin transfer
        var lChannel = [Float](repeating: 0, count: count)
        var mChannel = [Float](repeating: 0, count: count)
        var sChannel = [Float](repeating: 0, count: count)
        for i in 0..<count {
            lChannel[i] = VarDCTEncoder.inverseOpsinTransfer(lPrime[i])
            mChannel[i] = VarDCTEncoder.inverseOpsinTransfer(mPrime[i])
            sChannel[i] = VarDCTEncoder.inverseOpsinTransfer(b[i])
        }
        
        // LMS → RGB via inverse matrix
        let im = VarDCTEncoder.inverseOpsinAbsorbanceMatrix
        var rScaled = [Float](repeating: 0, count: count)
        var gScaled = [Float](repeating: 0, count: count)
        var bScaled = [Float](repeating: 0, count: count)
        
        var rChannel = [Float](repeating: 0, count: count)
        var k0 = im[0]; var k1 = im[1]; var k2 = im[2]
        vDSP_vsmul(lChannel, 1, &k0, &rScaled, 1, vDSP_Length(count))
        vDSP_vsmul(mChannel, 1, &k1, &gScaled, 1, vDSP_Length(count))
        vDSP_vsmul(sChannel, 1, &k2, &bScaled, 1, vDSP_Length(count))
        vDSP_vadd(rScaled, 1, gScaled, 1, &rChannel, 1, vDSP_Length(count))
        vDSP_vadd(rChannel, 1, bScaled, 1, &rChannel, 1, vDSP_Length(count))
        
        var gOut = [Float](repeating: 0, count: count)
        var k3 = im[3]; var k4 = im[4]; var k5 = im[5]
        vDSP_vsmul(lChannel, 1, &k3, &rScaled, 1, vDSP_Length(count))
        vDSP_vsmul(mChannel, 1, &k4, &gScaled, 1, vDSP_Length(count))
        vDSP_vsmul(sChannel, 1, &k5, &bScaled, 1, vDSP_Length(count))
        vDSP_vadd(rScaled, 1, gScaled, 1, &gOut, 1, vDSP_Length(count))
        vDSP_vadd(gOut, 1, bScaled, 1, &gOut, 1, vDSP_Length(count))
        
        var bOut = [Float](repeating: 0, count: count)
        var k6 = im[6]; var k7 = im[7]; var k8 = im[8]
        vDSP_vsmul(lChannel, 1, &k6, &rScaled, 1, vDSP_Length(count))
        vDSP_vsmul(mChannel, 1, &k7, &gScaled, 1, vDSP_Length(count))
        vDSP_vsmul(sChannel, 1, &k8, &bScaled, 1, vDSP_Length(count))
        vDSP_vadd(rScaled, 1, gScaled, 1, &bOut, 1, vDSP_Length(count))
        vDSP_vadd(bOut, 1, bScaled, 1, &bOut, 1, vDSP_Length(count))
        
        return (rChannel, gOut, bOut)
    }
    
    // MARK: - Quantization
    
    /// Vectorised quantization: divide each element by the corresponding
    /// quantization step and round to the nearest integer.
    ///
    /// - Parameters:
    ///   - values: Flattened DCT coefficients
    ///   - qMatrix: Flattened quantization matrix (same length as `values`)
    /// - Returns: Quantized values as `[Int16]`
    public static func quantize(_ values: [Float], qMatrix: [Float]) -> [Int16] {
        let count = values.count
        precondition(qMatrix.count == count)
        
        var divided = [Float](repeating: 0, count: count)
        vDSP_vdiv(qMatrix, 1, values, 1, &divided, 1, vDSP_Length(count))
        
        // Round to nearest integer (vvnintf provides vectorised round-to-nearest)
        var rounded = [Float](repeating: 0, count: count)
        vvnintf(&rounded, divided, [Int32(count)])
        
        return rounded.map { Int16($0) }
    }
    
    // MARK: - Vector Operations
    
    /// Vector addition
    public static func vectorAdd(_ a: [Float], _ b: [Float]) -> [Float] {
        precondition(a.count == b.count)
        var result = [Float](repeating: 0, count: a.count)
        vDSP_vadd(a, 1, b, 1, &result, 1, vDSP_Length(a.count))
        return result
    }
    
    /// Vector subtraction
    public static func vectorSubtract(_ a: [Float], _ b: [Float]) -> [Float] {
        precondition(a.count == b.count)
        var result = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &result, 1, vDSP_Length(a.count))
        return result
    }
    
    /// Vector multiplication
    public static func vectorMultiply(_ a: [Float], _ b: [Float]) -> [Float] {
        precondition(a.count == b.count)
        var result = [Float](repeating: 0, count: a.count)
        vDSP_vmul(a, 1, b, 1, &result, 1, vDSP_Length(a.count))
        return result
    }
    
    /// Dot product
    public static func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }
    
    // MARK: - Matrix Operations
    
    /// Matrix multiplication
    public static func matrixMultiply(_ a: [Float], rowsA: Int, colsA: Int,
                                     _ b: [Float], colsB: Int) -> [Float] {
        precondition(a.count == rowsA * colsA)
        precondition(b.count == colsA * colsB)
        
        var result = [Float](repeating: 0, count: rowsA * colsB)
        
        vDSP_mmul(
            a, 1,
            b, 1,
            &result, 1,
            vDSP_Length(rowsA),
            vDSP_Length(colsB),
            vDSP_Length(colsA)
        )
        
        return result
    }
    
    // MARK: - Statistical Operations
    
    /// Calculate mean
    public static func mean(_ values: [Float]) -> Float {
        var result: Float = 0
        vDSP_meanv(values, 1, &result, vDSP_Length(values.count))
        return result
    }
    
    /// Calculate standard deviation
    public static func standardDeviation(_ values: [Float]) -> Float {
        let meanVal = mean(values)
        var variance: Float = 0
        
        var centered = [Float](repeating: 0, count: values.count)
        var negMean = -meanVal
        vDSP_vsadd(values, 1, &negMean, &centered, 1, vDSP_Length(values.count))
        
        var squared = [Float](repeating: 0, count: values.count)
        vDSP_vsq(centered, 1, &squared, 1, vDSP_Length(values.count))
        
        vDSP_meanv(squared, 1, &variance, vDSP_Length(values.count))
        
        return sqrt(variance)
    }
    
    // MARK: - Conversion Operations
    
    /// Convert UInt8 to Float with scaling
    public static func convertU8ToFloat(_ input: [UInt8], scale: Float = 1.0/255.0) -> [Float] {
        var floatValues = [Float](repeating: 0, count: input.count)
        vDSP_vfltu8(input, 1, &floatValues, 1, vDSP_Length(input.count))
        
        if scale != 1.0 {
            var mutableScale = scale
            vDSP_vsmul(floatValues, 1, &mutableScale, &floatValues, 1, vDSP_Length(input.count))
        }
        
        return floatValues
    }
    
    /// Convert Float to UInt8 with scaling
    public static func convertFloatToU8(_ input: [Float], scale: Float = 255.0) -> [UInt8] {
        var scaled = [Float](repeating: 0, count: input.count)
        var mutableScale = scale
        vDSP_vsmul(input, 1, &mutableScale, &scaled, 1, vDSP_Length(input.count))
        
        var output = [UInt8](repeating: 0, count: input.count)
        vDSP_vfixu8(scaled, 1, &output, 1, vDSP_Length(input.count))
        
        return output
    }
}

#endif

// MARK: - SIMD Operations

/// SIMD-accelerated operations for image processing
public enum SIMDOps {
    
    #if arch(arm64)
    
    // MARK: - ARM NEON Operations
    
    /// SIMD-accelerated pixel prediction for ARM NEON
    /// Note: Currently uses scalar implementation. Full NEON optimization pending.
    public static func predictPixelsNEON(
        data: UnsafePointer<UInt16>,
        predictions: UnsafeMutablePointer<Int32>,
        width: Int,
        height: Int
    ) {
        // TODO: Implement using ARM NEON intrinsics for vectorized operations
        // This placeholder uses scalar operations for now
        
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let actual = Int32(data[index])
                
                // Simple gradient predictor
                if x > 0 && y > 0 {
                    let n = Int32(data[(y - 1) * width + x])
                    let w = Int32(data[y * width + (x - 1)])
                    let nw = Int32(data[(y - 1) * width + (x - 1)])
                    predictions[index] = actual - (n + w - nw)
                } else if y > 0 {
                    let n = Int32(data[(y - 1) * width + x])
                    predictions[index] = actual - n
                } else if x > 0 {
                    let w = Int32(data[y * width + (x - 1)])
                    predictions[index] = actual - w
                } else {
                    predictions[index] = actual
                }
            }
        }
    }
    
    /// SIMD-accelerated DCT for ARM NEON
    public static func dctBlockNEON(_ block: [[Float]]) -> [[Float]] {
        // Placeholder for NEON-optimized DCT
        // Would use ARM NEON vector instructions
        return block
    }
    
    #elseif arch(x86_64)
    
    // MARK: - x86-64 SIMD Operations (AVX2)
    
    /// AVX2-accelerated operations
    /// Note: These would be implemented using C intrinsics or assembly
    public static func dctBlockAVX(_ block: [[Float]]) -> [[Float]] {
        // Placeholder for AVX2-optimized DCT
        return block
    }
    
    #endif
}
