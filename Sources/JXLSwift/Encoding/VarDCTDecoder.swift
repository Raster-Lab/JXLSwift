/// VarDCT Mode Decoder
///
/// Implements decoding of VarDCT-encoded data produced by ``VarDCTEncoder``.
/// Reconstructs pixel data by reversing the encoding pipeline:
/// entropy decoding → dequantisation → inverse DCT → inverse CfL → YCbCr→RGB.

import Foundation

// MARK: - VarDCT Decoder Errors

/// Errors that can occur during VarDCT decoding.
enum VarDCTDecoderError: Error, LocalizedError {
    /// The bitstream ended unexpectedly before all data was read.
    case unexpectedEndOfData
    /// The VarDCT mode flag was not set in the bitstream.
    case invalidVarDCTMode
    /// A varint in the bitstream could not be read.
    case invalidVarint
    /// The ANS entropy data could not be decoded.
    case ansDecodingFailed(String)
    /// The block data is malformed.
    case malformedBlockData(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedEndOfData:
            return "Unexpected end of VarDCT bitstream data"
        case .invalidVarDCTMode:
            return "Bitstream does not indicate VarDCT mode"
        case .invalidVarint:
            return "Failed to read varint from VarDCT bitstream"
        case .ansDecodingFailed(let reason):
            return "ANS decoding failed: \(reason)"
        case .malformedBlockData(let reason):
            return "Malformed block data: \(reason)"
        }
    }
}

// MARK: - VarDCTDecoder

/// Decodes VarDCT-encoded data produced by ``VarDCTEncoder``.
///
/// The decoder reverses the encoding pipeline:
/// 1. Read VarDCT mode flag and header (distance, encoding flags).
/// 2. For each channel, decode quantised DCT coefficients from the bitstream.
/// 3. Dequantise using the stored distance and per-block activity.
/// 4. Apply inverse DCT to recover spatial-domain pixel values.
/// 5. Reconstruct chroma via inverse CfL prediction (if applicable).
/// 6. Convert YCbCr back to RGB.
///
/// The caller is responsible for stripping the JXL codestream header
/// (signature + image header) before passing data to this decoder.
class VarDCTDecoder {
    private let hardware: HardwareCapabilities

    /// DCT block size (8×8 is standard).
    private let blockSize = 8

    /// Creates a VarDCT decoder.
    ///
    /// - Parameter hardware: Hardware capabilities for acceleration.
    init(hardware: HardwareCapabilities) {
        self.hardware = hardware
    }

    // MARK: - Public API

    /// Decode VarDCT-encoded data into an ``ImageFrame``.
    ///
    /// - Parameters:
    ///   - data: The VarDCT payload (without JXL codestream header).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - channels: Number of colour channels.
    ///   - bitsPerSample: Bits per sample (e.g. 8, 16).
    ///   - pixelType: The pixel storage type.
    /// - Returns: A reconstructed ``ImageFrame``.
    /// - Throws: ``VarDCTDecoderError`` if the bitstream is malformed.
    func decode(
        data: Data,
        width: Int,
        height: Int,
        channels: Int,
        bitsPerSample: Int = 8,
        pixelType: PixelType = .uint8
    ) throws -> ImageFrame {
        var reader = BitstreamReader(data: data)

        // 1. Read VarDCT mode flag
        guard let isVarDCT = reader.readBit(), !isVarDCT else {
            // The bit is false for VarDCT, true for Modular
            throw VarDCTDecoderError.invalidVarDCTMode
        }

        // 2. Read VarDCT header: distance (4 bytes IEEE 754) + flags (1 byte)
        // The mode bit doesn't fill a byte; flush to alignment before U32
        reader.skipToByteAlignment()

        let distanceBits = try readU32(&reader)
        let distance = Float(bitPattern: distanceBits)

        guard let flags = reader.readByte() else {
            throw VarDCTDecoderError.unexpectedEndOfData
        }
        let useAdaptive = (flags & 0x01) != 0
        let useANS = (flags & 0x02) != 0
        let hasCfL = channels >= 3

        // Read pixel type for CbCr offset derivation
        guard let pixelTypeByte = reader.readByte() else {
            throw VarDCTDecoderError.unexpectedEndOfData
        }
        let sourcePixelType: PixelType
        switch pixelTypeByte {
        case 0:  sourcePixelType = .uint8
        case 1:  sourcePixelType = .uint16
        default: sourcePixelType = .float32
        }
        let cbcrOffset = VarDCTEncoder.cbcrOffset(for: sourcePixelType)
        let maxPixelVal: Float
        switch sourcePixelType {
        case .uint8:  maxPixelVal = 255.0
        case .uint16: maxPixelVal = 65535.0
        case .float32: maxPixelVal = 65535.0
        }

        // 3. Decode each channel's DCT data
        let blocksX = (width + blockSize - 1) / blockSize
        let blocksY = (height + blockSize - 1) / blockSize

        var channelPixels = [[[Float]]](
            repeating: [[Float]](
                repeating: [Float](repeating: 0, count: width),
                count: height
            ),
            count: channels
        )

        // We need luma DCT blocks if CfL is used (to reconstruct chroma)
        var lumaDCTBlocks: [[[[Float]]]]? = nil

        for channel in 0..<channels {
            let (pixels, dctBlocks) = try decodeChannelDCT(
                reader: &reader,
                width: width,
                height: height,
                channel: channel,
                distance: distance,
                useAdaptive: useAdaptive,
                useANS: useANS,
                hasCfL: hasCfL && channel > 0,
                lumaDCTBlocks: (hasCfL && channel > 0) ? lumaDCTBlocks : nil
            )

            channelPixels[channel] = pixels

            // Store luma DCT blocks for CfL reconstruction on chroma channels
            if channel == 0 && hasCfL {
                lumaDCTBlocks = dctBlocks
            }
        }

        // 4. Convert YCbCr → RGB directly on float arrays to avoid
        //    uint8 clamping that would corrupt Cb/Cr values.
        if channels >= 3 {
            convertFromYCbCrFloat(
                channels: &channelPixels,
                width: width,
                height: height,
                offset: cbcrOffset
            )
        }

        // 5. Build the output frame
        var frame = ImageFrame(
            width: width,
            height: height,
            channels: channels,
            pixelType: pixelType,
            bitsPerSample: bitsPerSample
        )

        // Float values are in [0, maxPixelVal]; write back as UInt16
        for c in 0..<channels {
            for y in 0..<height {
                for x in 0..<width {
                    let value = max(0, min(maxPixelVal, channelPixels[c][y][x]))
                    frame.setPixel(
                        x: x, y: y, channel: c,
                        value: UInt16(value)
                    )
                }
            }
        }

        return frame
    }

    // MARK: - Channel Decoding

    /// Decode a single channel's DCT data from the bitstream.
    ///
    /// - Parameters:
    ///   - reader: The bitstream reader.
    ///   - width: Image width.
    ///   - height: Image height.
    ///   - channel: Channel index.
    ///   - distance: Quantisation distance.
    ///   - useAdaptive: Whether adaptive quantisation is enabled.
    ///   - useANS: Whether ANS entropy coding is used.
    ///   - hasCfL: Whether CfL prediction is used for this channel.
    ///   - lumaDCTBlocks: Luma DCT blocks for CfL reconstruction.
    /// - Returns: Tuple of (2D pixel array, DCT blocks if channel 0).
    private func decodeChannelDCT(
        reader: inout BitstreamReader,
        width: Int,
        height: Int,
        channel: Int,
        distance: Float,
        useAdaptive: Bool,
        useANS: Bool,
        hasCfL: Bool,
        lumaDCTBlocks: [[[[Float]]]]?
    ) throws -> ([[Float]], [[[[Float]]]]?) {
        let blocksX = (width + blockSize - 1) / blockSize
        let blocksY = (height + blockSize - 1) / blockSize

        // Track DC values for inter-block prediction
        var dcValues = [[Int16]](
            repeating: [Int16](repeating: 0, count: blocksX),
            count: blocksY
        )

        // Storage for decoded DCT blocks (needed for CfL on subsequent channels)
        var dctBlocks: [[[[Float]]]]? = nil
        if channel == 0 {
            dctBlocks = [[[[Float]]]](
                repeating: [[[Float]]](
                    repeating: [[Float]](
                        repeating: [Float](repeating: 0, count: blockSize),
                        count: blockSize
                    ),
                    count: blocksX
                ),
                count: blocksY
            )
        }

        // Output pixel array
        var pixels = [[Float]](
            repeating: [Float](repeating: 0, count: width),
            count: height
        )

        if useANS {
            // ANS mode: decode all blocks at once from ANS-encoded data
            try decodeChannelANS(
                reader: &reader,
                width: width,
                height: height,
                channel: channel,
                distance: distance,
                useAdaptive: useAdaptive,
                hasCfL: hasCfL,
                lumaDCTBlocks: lumaDCTBlocks,
                dcValues: &dcValues,
                dctBlocks: &dctBlocks,
                pixels: &pixels
            )
        } else {
            // Non-ANS mode: decode block by block
            for blockY in 0..<blocksY {
                for blockX in 0..<blocksX {
                    // Read CfL coefficient if applicable
                    var cflCoeff: Float = 0
                    if hasCfL {
                        let encoded = try readVarint(&reader)
                        cflCoeff = Float(decodeSignedValue(encoded)) /
                            VarDCTEncoder.cflScaleFactor
                    }

                    // Read activity scale if adaptive quantisation
                    let activity: Float
                    if useAdaptive {
                        let activityEncoded = try readVarint(&reader)
                        activity = Float(activityEncoded) /
                            VarDCTEncoder.qfScaleFactor
                    } else {
                        activity = 1.0
                    }

                    // Decode block coefficients
                    let quantized = try decodeBlock(reader: &reader)

                    // Reconstruct DC from residual + prediction
                    let predicted = predictDC(
                        dcValues: dcValues,
                        blockX: blockX,
                        blockY: blockY
                    )
                    var block = quantized
                    block[0][0] += predicted
                    dcValues[blockY][blockX] = block[0][0]

                    // Dequantise
                    let qMatrix = generateQuantizationMatrix(
                        channel: channel,
                        activity: activity,
                        distance: distance
                    )
                    var dctBlock = dequantize(block: block, qMatrix: qMatrix)

                    // Inverse CfL prediction: reconstruct chroma from residual
                    if hasCfL, let lumaDCT = lumaDCTBlocks?[blockY][blockX] {
                        dctBlock = reconstructFromCfL(
                            residual: dctBlock,
                            lumaDCT: lumaDCT,
                            coefficient: cflCoeff
                        )
                    }

                    // Store DCT block for future CfL (channel 0 only)
                    if channel == 0 {
                        dctBlocks?[blockY][blockX] = dctBlock
                    }

                    // Inverse DCT → spatial pixels
                    let spatial = applyIDCTScalar(block: dctBlock)

                    // Place block pixels into output
                    placeBlock(
                        spatial: spatial,
                        pixels: &pixels,
                        blockX: blockX,
                        blockY: blockY,
                        width: width,
                        height: height
                    )
                }
            }
        }

        return (pixels, dctBlocks)
    }

    // MARK: - ANS Channel Decoding

    /// Decode a channel's blocks using ANS entropy coding.
    private func decodeChannelANS(
        reader: inout BitstreamReader,
        width: Int,
        height: Int,
        channel: Int,
        distance: Float,
        useAdaptive: Bool,
        hasCfL: Bool,
        lumaDCTBlocks: [[[[Float]]]]?,
        dcValues: inout [[Int16]],
        dctBlocks: inout [[[[Float]]]]?,
        pixels: inout [[Float]]
    ) throws {
        let blocksX = (width + blockSize - 1) / blockSize
        let blocksY = (height + blockSize - 1) / blockSize

        // Read per-block metadata (CfL + activity) written before ANS data
        var cflCoeffs = [Float]()
        var activities = [Float]()

        for blockY in 0..<blocksY {
            for blockX in 0..<blocksX {
                _ = blockX; _ = blockY

                if hasCfL {
                    let encoded = try readVarint(&reader)
                    cflCoeffs.append(
                        Float(decodeSignedValue(encoded)) /
                        VarDCTEncoder.cflScaleFactor
                    )
                }

                if useAdaptive {
                    let activityEncoded = try readVarint(&reader)
                    activities.append(
                        Float(activityEncoded) /
                        VarDCTEncoder.qfScaleFactor
                    )
                }
            }
        }

        // Read ANS marker
        guard let marker = reader.readByte(), marker == 0x02 else {
            throw VarDCTDecoderError.ansDecodingFailed("missing ANS marker")
        }

        // Read block count
        let blockCount = Int(try readU32(&reader))
        let expectedBlocks = blocksX * blocksY
        guard blockCount == expectedBlocks else {
            throw VarDCTDecoderError.ansDecodingFailed(
                "block count mismatch: expected \(expectedBlocks), got \(blockCount)"
            )
        }

        // Read distribution tables (2 contexts: DC and AC)
        var distributions = [ANSDistribution]()
        for _ in 0..<2 {
            let tableLength = Int(try readVarint(&reader))
            var tableData = Data()
            for _ in 0..<tableLength {
                guard let b = reader.readByte() else {
                    throw VarDCTDecoderError.unexpectedEndOfData
                }
                tableData.append(b)
            }
            let dist = try ANSDistribution.deserialise(from: tableData)
            distributions.append(dist)
        }

        // Read encoded data length and data
        let encodedLength = Int(try readU32(&reader))
        var encodedData = Data()
        for _ in 0..<encodedLength {
            guard let b = reader.readByte() else {
                throw VarDCTDecoderError.unexpectedEndOfData
            }
            encodedData.append(b)
        }

        // Build context sequence: DC(ctx 0) then AC(ctx 1) × 63 per block
        var contexts = [Int]()
        for _ in 0..<blockCount {
            contexts.append(0) // DC
            for _ in 1..<64 {
                contexts.append(1) // AC
            }
        }

        // Decode symbols
        let multiDecoder = MultiContextANSEncoder(distributions: distributions)
        let symbols = try multiDecoder.decode(encodedData, contexts: contexts)

        // Reconstruct blocks from symbols
        var symbolIdx = 0
        var blockIdx = 0

        for blockY in 0..<blocksY {
            for blockX in 0..<blocksX {
                // Read DC symbol
                let dcSym = symbols[symbolIdx]
                symbolIdx += 1
                let dcResidual = Int16(decodeSignedValue(UInt64(dcSym)))

                // Read AC symbols
                var coefficients = [Int16](repeating: 0, count: 64)
                coefficients[0] = dcResidual
                for i in 1..<64 {
                    let acSym = symbols[symbolIdx]
                    symbolIdx += 1
                    coefficients[i] = Int16(decodeSignedValue(UInt64(acSym)))
                }

                // Convert zigzag back to 2D block
                var block = inverseZigzag(coefficients: coefficients)

                // Reconstruct DC from residual + prediction
                let predicted = predictDC(
                    dcValues: dcValues,
                    blockX: blockX,
                    blockY: blockY
                )
                block[0][0] += predicted
                dcValues[blockY][blockX] = block[0][0]

                // Dequantise
                let activity = useAdaptive ? activities[blockIdx] : Float(1.0)
                let qMatrix = generateQuantizationMatrix(
                    channel: channel,
                    activity: activity,
                    distance: distance
                )
                var dctBlock = dequantize(block: block, qMatrix: qMatrix)

                // Inverse CfL prediction
                if hasCfL, let lumaDCT = lumaDCTBlocks?[blockY][blockX] {
                    let cflCoeff = cflCoeffs[blockIdx]
                    dctBlock = reconstructFromCfL(
                        residual: dctBlock,
                        lumaDCT: lumaDCT,
                        coefficient: cflCoeff
                    )
                }

                // Store DCT block for future CfL (channel 0 only)
                if channel == 0 {
                    dctBlocks?[blockY][blockX] = dctBlock
                }

                // Inverse DCT → spatial pixels
                let spatial = applyIDCTScalar(block: dctBlock)

                // Place block pixels into output
                placeBlock(
                    spatial: spatial,
                    pixels: &pixels,
                    blockX: blockX,
                    blockY: blockY,
                    width: width,
                    height: height
                )

                blockIdx += 1
            }
        }
    }

    // MARK: - Block Decoding

    /// Decode a single 8×8 block of quantised DCT coefficients.
    ///
    /// Reads the block format produced by ``VarDCTEncoder/encodeBlock``:
    /// - DC coefficient as zigzag-encoded varint (this is the DC residual)
    /// - AC coefficients as alternating (zeroRun, coefficient) pairs:
    ///   - Zero run length (varint, always present including 0)
    ///   - Non-zero coefficient (zigzag-encoded varint)
    ///   - EOB marker (0xFFFF) for trailing zeros
    ///
    /// - Parameter reader: The bitstream reader positioned at the block data.
    /// - Returns: 8×8 block with DC residual at [0][0] and AC coefficients.
    private func decodeBlock(
        reader: inout BitstreamReader
    ) throws -> [[Int16]] {
        var coefficients = [Int16](repeating: 0, count: 64)

        // Read DC coefficient (residual)
        let dcEncoded = try readVarint(&reader)
        coefficients[0] = Int16(decodeSignedValue(dcEncoded))

        // Read AC coefficients: alternating (zeroRun, coefficient) pairs
        var pos = 1
        while pos < 64 {
            // Read zero run
            let runValue = try readVarint(&reader)

            if runValue == 0xFFFF {
                // End-of-block marker: remaining coefficients are zero
                break
            }

            // Skip zero positions
            pos += Int(runValue)

            guard pos < 64 else { break }

            // Read the coefficient
            let coeffEncoded = try readVarint(&reader)
            coefficients[pos] = Int16(decodeSignedValue(coeffEncoded))
            pos += 1
        }

        // Convert zigzag order back to 2D block
        return inverseZigzag(coefficients: coefficients)
    }

    // MARK: - Dequantisation

    /// Dequantise an 8×8 block by multiplying by the quantisation matrix.
    ///
    /// This is the inverse of ``VarDCTEncoder/quantizeScalar``:
    /// `dct[y][x] = quantized[y][x] × qMatrix[y][x]`
    ///
    /// - Parameters:
    ///   - block: 8×8 quantised coefficient block.
    ///   - qMatrix: 8×8 quantisation matrix.
    /// - Returns: 8×8 dequantised DCT coefficient block.
    func dequantize(block: [[Int16]], qMatrix: [[Float]]) -> [[Float]] {
        var dct = [[Float]](
            repeating: [Float](repeating: 0, count: blockSize),
            count: blockSize
        )
        for y in 0..<blockSize {
            for x in 0..<blockSize {
                dct[y][x] = Float(block[y][x]) * qMatrix[y][x]
            }
        }
        return dct
    }

    /// Generate the quantisation matrix matching the encoder's formula.
    ///
    /// - Parameters:
    ///   - channel: Channel index (0 = luma, >0 = chroma).
    ///   - activity: Local spatial activity scale.
    ///   - distance: Quantisation distance parameter.
    /// - Returns: 8×8 quantisation matrix.
    func generateQuantizationMatrix(
        channel: Int,
        activity: Float = 1.0,
        distance: Float
    ) -> [[Float]] {
        var matrix = [[Float]](
            repeating: [Float](repeating: 1, count: blockSize),
            count: blockSize
        )

        let baseQuant = max(1.0, distance * 8.0)

        let adaptiveScale: Float = max(
            VarDCTEncoder.minAdaptiveScale,
            min(VarDCTEncoder.maxAdaptiveScale, 1.0 / activity)
        )

        for y in 0..<blockSize {
            for x in 0..<blockSize {
                let freq = Float(x + y)
                matrix[y][x] = baseQuant * (1.0 + freq * 0.5) * adaptiveScale

                if channel > 0 {
                    matrix[y][x] *= 1.5
                }
            }
        }

        return matrix
    }

    // MARK: - Inverse DCT

    /// Apply inverse DCT (IDCT) to an 8×8 block.
    ///
    /// Uses the same formula as ``VarDCTEncoder/applyIDCTScalar``.
    ///
    /// - Parameter block: 8×8 DCT coefficient block.
    /// - Returns: 8×8 spatial-domain pixel values.
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

                        let cosU = cos(
                            (2.0 * Float(x) + 1.0) * Float(u) * .pi /
                            (2.0 * n)
                        )
                        let cosV = cos(
                            (2.0 * Float(y) + 1.0) * Float(v) * .pi /
                            (2.0 * n)
                        )

                        sum += block[v][u] * cosU * cosV * cu * cv
                    }
                }

                spatial[y][x] = sum * normFactor * normFactor
            }
        }

        return spatial
    }

    // MARK: - Inverse CfL Prediction

    /// Reconstruct chroma DCT coefficients from CfL residuals.
    ///
    /// Inverse of ``VarDCTEncoder/applyCfLPrediction``.
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

    // MARK: - Colour Space Conversion

    /// Convert YCbCr float channel arrays to RGB in-place.
    ///
    /// Operates directly on float arrays, avoiding uint8 clamping.
    ///
    /// - Parameters:
    ///   - channels: Mutable array of 2D float channel arrays (Y, Cb, Cr, …).
    ///   - width: Image width.
    ///   - height: Image height.
    ///   - offset: Cb/Cr centring offset (128 for uint8, 32768 for uint16).
    private func convertFromYCbCrFloat(
        channels: inout [[[Float]]],
        width: Int,
        height: Int,
        offset: Float
    ) {
        guard channels.count >= 3 else { return }

        for y in 0..<height {
            for x in 0..<width {
                let yVal = channels[0][y][x]
                let cb = channels[1][y][x] - offset
                let cr = channels[2][y][x] - offset

                // Inverse ITU-R BT.601
                channels[0][y][x] = yVal + 1.402 * cr
                channels[1][y][x] = yVal - 0.344136 * cb - 0.714136 * cr
                channels[2][y][x] = yVal + 1.772 * cb
            }
        }
    }

    /// Convert a YCbCr frame back to RGB using inverse BT.601.
    ///
    /// Uses the unnormalized convention matching ``VarDCTEncoder/convertToYCbCrFloat``.
    ///
    /// - Parameter frame: Input frame with channels as Y, Cb, Cr.
    /// - Returns: A new frame with channels as R, G, B.
    func convertFromYCbCr(frame: ImageFrame) -> ImageFrame {
        guard frame.channels >= 3 else { return frame }

        let offset = VarDCTEncoder.cbcrOffset(for: frame.pixelType)
        let maxVal: Float
        switch frame.pixelType {
        case .uint8:  maxVal = 255.0
        case .uint16: maxVal = 65535.0
        case .float32: maxVal = 65535.0
        }

        var rgbFrame = frame
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let yVal = Float(frame.getPixel(x: x, y: y, channel: 0))
                let cb = Float(frame.getPixel(x: x, y: y, channel: 1)) - offset
                let cr = Float(frame.getPixel(x: x, y: y, channel: 2)) - offset

                // Inverse ITU-R BT.601
                let r = yVal + 1.402 * cr
                let g = yVal - 0.344136 * cb - 0.714136 * cr
                let b = yVal + 1.772 * cb

                rgbFrame.setPixel(
                    x: x, y: y, channel: 0,
                    value: UInt16(max(0, min(maxVal, r)))
                )
                rgbFrame.setPixel(
                    x: x, y: y, channel: 1,
                    value: UInt16(max(0, min(maxVal, g)))
                )
                rgbFrame.setPixel(
                    x: x, y: y, channel: 2,
                    value: UInt16(max(0, min(maxVal, b)))
                )
            }
        }
        return rgbFrame
    }

    // MARK: - DC Prediction

    /// Predict DC coefficient from neighbouring blocks.
    ///
    /// Matches ``VarDCTEncoder/predictDC``.
    func predictDC(dcValues: [[Int16]], blockX: Int, blockY: Int) -> Int16 {
        let hasLeft = blockX > 0
        let hasAbove = blockY > 0

        if hasLeft && hasAbove {
            let left = Int(dcValues[blockY][blockX - 1])
            let above = Int(dcValues[blockY - 1][blockX])
            return Int16((left + above) / 2)
        } else if hasLeft {
            return dcValues[blockY][blockX - 1]
        } else if hasAbove {
            return dcValues[blockY - 1][blockX]
        } else {
            return 0
        }
    }

    // MARK: - Zigzag Helpers

    /// The zigzag scan order for an 8×8 block, matching the encoder.
    private let zigzagOrder: [(Int, Int)] = [
        (0,0), (0,1), (1,0), (2,0), (1,1), (0,2), (0,3), (1,2),
        (2,1), (3,0), (4,0), (3,1), (2,2), (1,3), (0,4), (0,5),
        (1,4), (2,3), (3,2), (4,1), (5,0), (6,0), (5,1), (4,2),
        (3,3), (2,4), (1,5), (0,6), (0,7), (1,6), (2,5), (3,4),
        (4,3), (5,2), (6,1), (7,0), (7,1), (6,2), (5,3), (4,4),
        (3,5), (2,6), (1,7), (2,7), (3,6), (4,5), (5,4), (6,3),
        (7,2), (7,3), (6,4), (5,5), (4,6), (3,7), (4,7), (5,6),
        (6,5), (7,4), (7,5), (6,6), (5,7), (6,7), (7,6), (7,7)
    ]

    /// Convert zigzag-ordered coefficients back to a 2D 8×8 block.
    ///
    /// - Parameter coefficients: 64 coefficients in zigzag scan order.
    /// - Returns: 8×8 block with coefficients at their natural positions.
    func inverseZigzag(coefficients: [Int16]) -> [[Int16]] {
        var block = [[Int16]](
            repeating: [Int16](repeating: 0, count: blockSize),
            count: blockSize
        )
        for (i, pos) in zigzagOrder.enumerated() where i < coefficients.count {
            block[pos.0][pos.1] = coefficients[i]
        }
        return block
    }

    // MARK: - Block Placement

    /// Place spatial-domain block pixels into the output image.
    private func placeBlock(
        spatial: [[Float]],
        pixels: inout [[Float]],
        blockX: Int,
        blockY: Int,
        width: Int,
        height: Int
    ) {
        let startX = blockX * blockSize
        let startY = blockY * blockSize

        for y in 0..<blockSize {
            let dstY = startY + y
            guard dstY < height else { break }
            for x in 0..<blockSize {
                let dstX = startX + x
                guard dstX < width else { break }
                pixels[dstY][dstX] = spatial[y][x]
            }
        }
    }

    // MARK: - Bitstream Helpers

    /// Read a big-endian UInt32 from the reader.
    private func readU32(_ reader: inout BitstreamReader) throws -> UInt32 {
        guard let b0 = reader.readByte(),
              let b1 = reader.readByte(),
              let b2 = reader.readByte(),
              let b3 = reader.readByte() else {
            throw VarDCTDecoderError.unexpectedEndOfData
        }
        return (UInt32(b0) << 24) | (UInt32(b1) << 16) |
               (UInt32(b2) << 8) | UInt32(b3)
    }

    /// Read a variable-length integer from the reader.
    private func readVarint(
        _ reader: inout BitstreamReader
    ) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard let byte = reader.readByte() else {
                throw VarDCTDecoderError.invalidVarint
            }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                throw VarDCTDecoderError.invalidVarint
            }
        }
    }

    // MARK: - ZigZag Value Decoding

    /// Decode a ZigZag-encoded unsigned value back to a signed value.
    ///
    /// Inverse of ``VarDCTEncoder/encodeSignedValue``.
    /// Mapping: 0→0, 1→-1, 2→1, 3→-2, 4→2, …
    func decodeSignedValue(_ encoded: UInt64) -> Int32 {
        if encoded % 2 == 0 {
            return Int32(encoded / 2)
        } else {
            return -Int32((encoded + 1) / 2)
        }
    }
}
