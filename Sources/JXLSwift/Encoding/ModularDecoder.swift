/// Modular Mode Decoder
///
/// Implements decoding of modular-encoded data produced by ``ModularEncoder``.
/// Reconstructs pixel data by reversing the encoding pipeline:
/// entropy decoding → inverse squeeze → inverse prediction → inverse RCT.

import Foundation

// MARK: - Decoder Errors

/// Errors that can occur during modular decoding.
enum ModularDecoderError: Error, LocalizedError {
    /// The bitstream ended unexpectedly before all data was read.
    case unexpectedEndOfData
    /// The modular mode flag was not set in the bitstream.
    case invalidModularMode
    /// The decoded element count does not match the expected channel size.
    case elementCountMismatch(expected: Int, got: Int)
    /// A varint in the bitstream could not be read.
    case invalidVarint

    var errorDescription: String? {
        switch self {
        case .unexpectedEndOfData:
            return "Unexpected end of modular bitstream data"
        case .invalidModularMode:
            return "Bitstream does not indicate modular mode"
        case .elementCountMismatch(let expected, let got):
            return "Element count mismatch: expected \(expected), got \(got)"
        case .invalidVarint:
            return "Failed to read varint from bitstream"
        }
    }
}

// MARK: - ModularDecoder

/// Decodes modular-encoded data produced by ``ModularEncoder``.
///
/// The decoder reverses the encoding pipeline:
/// 1. Read modular mode and RCT flags.
/// 2. For each channel, entropy-decode the run-length + ZigZag data.
/// 3. Apply the inverse squeeze transform.
/// 4. Apply inverse prediction to reconstruct pixel values from residuals.
/// 5. If RCT was used, apply the inverse colour transform.
///
/// The caller is responsible for stripping the JXL codestream header
/// (signature + image header) before passing data to this decoder.
/// Only the modular payload produced by ``ModularEncoder/encode(frame:)``
/// should be provided.
class ModularDecoder {
    private let hardware: HardwareCapabilities
    private let options: EncodingOptions

    /// The MA tree, built to match the encoder's tree for the same effort level.
    let maTree: MATree

    /// Creates a modular decoder.
    ///
    /// - Parameters:
    ///   - hardware: Hardware capabilities (used for NEON acceleration selection).
    ///   - options: Encoding options; the ``EncodingOptions/effort`` level
    ///     determines which MA tree is used for prediction.
    init(hardware: HardwareCapabilities, options: EncodingOptions) {
        self.hardware = hardware
        self.options = options
        if options.effort.rawValue >= EncodingEffort.squirrel.rawValue {
            self.maTree = MATree.buildExtended()
        } else {
            self.maTree = MATree.buildDefault()
        }
    }

    // MARK: - Public API

    /// Decode modular-encoded data into an ``ImageFrame``.
    ///
    /// - Parameters:
    ///   - data: The modular payload (without JXL codestream header).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - channels: Number of colour channels.
    ///   - bitsPerSample: Bits per sample (e.g. 8, 16).
    ///   - pixelType: The pixel storage type.
    /// - Returns: A reconstructed ``ImageFrame``.
    /// - Throws: ``ModularDecoderError`` if the bitstream is malformed.
    func decode(
        data: Data,
        width: Int,
        height: Int,
        channels: Int,
        bitsPerSample: Int = 8,
        pixelType: PixelType = .uint8
    ) throws -> ImageFrame {
        var reader = BitstreamReader(data: data)

        // 1. Read modular mode flag
        guard let isModular = reader.readBit(), isModular else {
            throw ModularDecoderError.invalidModularMode
        }

        // 2. Read RCT flag
        guard let useRCT = reader.readBit() else {
            throw ModularDecoderError.unexpectedEndOfData
        }

        // 3. Decode each channel
        // After reading the two flag bits the reader is mid-byte.
        // The encoder calls writer.writeData(encoded) for each channel,
        // which flushes the current byte first. That means each channel's
        // entropy data starts at a byte boundary *in the overall stream*.
        // However the first channel's data also starts after the two bits
        // written so far.  BitstreamWriter.writeData calls flushByte()
        // which pads the remaining 6 bits with zeros and advances to the
        // next full byte.  We must skip those padding bits on the reader
        // side.
        alignReaderToByte(&reader)

        let pixelCount = width * height
        var decodedChannels = [[UInt16]]()

        for c in 0..<channels {
            let squeezedResiduals = try entropyDecode(
                reader: &reader,
                expectedCount: pixelCount
            )

            // Compute the same squeeze steps that forwardSqueeze would record
            let steps = computeSqueezeSteps(width: width, height: height)

            // Apply inverse squeeze
            let residuals = inverseSqueeze(data: squeezedResiduals, steps: steps)

            // Apply inverse prediction to reconstruct pixel values
            let channelData = inversePrediction(
                residuals: residuals,
                width: width,
                height: height,
                channel: c
            )

            decodedChannels.append(channelData)
        }

        // 4. If RCT was used, apply inverse RCT
        if useRCT {
            inverseRCT(channels: &decodedChannels)
        }

        // 5. Build the output ImageFrame
        var frame = ImageFrame(
            width: width,
            height: height,
            channels: channels,
            pixelType: pixelType,
            bitsPerSample: bitsPerSample
        )

        for c in 0..<channels {
            let channelData = decodedChannels[c]
            for y in 0..<height {
                for x in 0..<width {
                    frame.setPixel(
                        x: x, y: y, channel: c,
                        value: channelData[y * width + x]
                    )
                }
            }
        }

        return frame
    }

    /// Decode a framed modular subbitstream produced by
    /// ``ModularEncoder/encodeWithFraming(frame:)``.
    ///
    /// The framed format has section 0 as global info (modular flag, RCT flag,
    /// channel count, MA tree type, squeeze levels) and sections 1…N as
    /// per-channel entropy-coded data.
    ///
    /// - Parameters:
    ///   - sections: The section payloads extracted from the ``FrameData``.
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - bitsPerSample: Bits per sample (e.g. 8, 16).
    ///   - pixelType: The pixel storage type.
    /// - Returns: A reconstructed ``ImageFrame``.
    /// - Throws: ``ModularDecoderError`` if the data is malformed.
    func decodeFramed(
        sections: [Data],
        width: Int,
        height: Int,
        bitsPerSample: Int = 8,
        pixelType: PixelType = .uint8
    ) throws -> ImageFrame {
        guard !sections.isEmpty else {
            throw ModularDecoderError.unexpectedEndOfData
        }

        // --- Parse global section (section 0) ---
        var globalReader = BitstreamReader(data: sections[0])

        guard let isModular = globalReader.readBit(), isModular else {
            throw ModularDecoderError.invalidModularMode
        }
        guard let useRCT = globalReader.readBit() else {
            throw ModularDecoderError.unexpectedEndOfData
        }
        // Channel count, MA tree type, squeeze levels
        alignReaderToByte(&globalReader)
        guard let channelCount = globalReader.readByte() else {
            throw ModularDecoderError.unexpectedEndOfData
        }
        // MA tree type and squeeze levels are read but currently
        // derived from options; reserved for future use.
        _ = globalReader.readByte() // treeType
        _ = globalReader.readByte() // squeezeLevels

        let channels = Int(channelCount)
        let expectedSections = channels + 1 // global + one per channel
        guard sections.count >= expectedSections else {
            throw ModularDecoderError.elementCountMismatch(
                expected: expectedSections, got: sections.count
            )
        }

        // --- Decode per-channel sections ---
        let pixelCount = width * height
        var decodedChannels = [[UInt16]]()

        for c in 0..<channels {
            var channelReader = BitstreamReader(data: sections[c + 1])
            let squeezedResiduals = try entropyDecode(
                reader: &channelReader,
                expectedCount: pixelCount
            )

            let steps = computeSqueezeSteps(width: width, height: height)
            let residuals = inverseSqueeze(data: squeezedResiduals, steps: steps)
            let channelData = inversePrediction(
                residuals: residuals,
                width: width,
                height: height,
                channel: c
            )

            decodedChannels.append(channelData)
        }

        if useRCT {
            inverseRCT(channels: &decodedChannels)
        }

        var frame = ImageFrame(
            width: width,
            height: height,
            channels: channels,
            pixelType: pixelType,
            bitsPerSample: bitsPerSample
        )

        for c in 0..<channels {
            let channelData = decodedChannels[c]
            for y in 0..<height {
                for x in 0..<width {
                    frame.setPixel(
                        x: x, y: y, channel: c,
                        value: channelData[y * width + x]
                    )
                }
            }
        }

        return frame
    }

    // MARK: - Bitstream Helpers

    /// Advance the reader to the next byte boundary.
    ///
    /// The encoder calls `flushByte()` / `writeData()` which pads
    /// the current byte with zeros. The reader must skip those padding
    /// bits. After the two flag bits (modular mode + RCT), 6 padding
    /// bits remain in the first byte.
    private func alignReaderToByte(_ reader: inout BitstreamReader) {
        for _ in 0..<6 {
            _ = reader.readBit()
        }
    }

    /// Read a big-endian `UInt32` from the reader.
    ///
    /// Mirrors ``BitstreamWriter/writeU32(_:)``.
    private func readU32(_ reader: inout BitstreamReader) throws -> UInt32 {
        guard let b0 = reader.readByte(),
              let b1 = reader.readByte(),
              let b2 = reader.readByte(),
              let b3 = reader.readByte() else {
            throw ModularDecoderError.unexpectedEndOfData
        }
        return (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
    }

    /// Read a variable-length integer from the reader.
    ///
    /// Mirrors ``BitstreamWriter/writeVarint(_:)``.
    /// Each byte contributes 7 data bits; the high bit signals continuation.
    private func readVarint(_ reader: inout BitstreamReader) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard let byte = reader.readByte() else {
                throw ModularDecoderError.invalidVarint
            }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                throw ModularDecoderError.invalidVarint
            }
        }
    }

    // MARK: - ZigZag Decoding

    /// Decode a ZigZag-encoded unsigned value back to a signed value.
    ///
    /// Inverse of ``ModularEncoder/encodeSignedValue(_:)``.
    /// Mapping: 0→0, 1→-1, 2→1, 3→-2, 4→2, …
    private func decodeSignedValue(_ encoded: UInt64) -> Int32 {
        if encoded % 2 == 0 {
            return Int32(encoded / 2)
        } else {
            return -Int32((encoded + 1) / 2)
        }
    }

    // MARK: - Entropy Decoding

    /// Entropy-decode a channel's data from the bitstream.
    ///
    /// Reads the format produced by
    /// ``ModularEncoder/entropyEncodeWithContext(data:width:height:)``:
    /// 1. `UInt32`: element count (big-endian).
    /// 2. Runs of (varint zigzag-value, varint run-length-minus-1).
    ///
    /// - Parameters:
    ///   - reader: The bitstream reader positioned at the channel data.
    ///   - expectedCount: The number of elements expected (`width * height`).
    /// - Returns: Array of signed residual values.
    /// - Throws: ``ModularDecoderError`` on malformed data.
    private func entropyDecode(
        reader: inout BitstreamReader,
        expectedCount: Int
    ) throws -> [Int32] {
        let elementCount = Int(try readU32(&reader))

        if elementCount != expectedCount {
            throw ModularDecoderError.elementCountMismatch(
                expected: expectedCount, got: elementCount
            )
        }

        var result = [Int32]()
        result.reserveCapacity(elementCount)

        while result.count < elementCount {
            let encodedValue = try readVarint(&reader)
            let value = decodeSignedValue(encodedValue)

            let runMinus1 = try readVarint(&reader)
            let runLength = Int(runMinus1) + 1

            let remaining = elementCount - result.count
            let actualRun = min(runLength, remaining)
            for _ in 0..<actualRun {
                result.append(value)
            }
        }

        return result
    }

    // MARK: - Squeeze Transform (Inverse)

    /// Compute the squeeze steps that ``ModularEncoder/forwardSqueeze``
    /// would record for the given dimensions.
    ///
    /// The forward squeeze loop is deterministic: it alternates horizontal
    /// and vertical squeezes, halving the active region each time.
    /// By replaying the same loop structure we obtain the step descriptors
    /// needed by ``inverseSqueeze(data:steps:)``.
    ///
    /// - Parameters:
    ///   - width: Channel width.
    ///   - height: Channel height.
    ///   - levels: Number of decomposition levels (must match encoder, default 3).
    /// - Returns: Array of squeeze step descriptors in forward (application) order.
    func computeSqueezeSteps(
        width: Int,
        height: Int,
        levels: Int = 3
    ) -> [ModularEncoder.SqueezeStep] {
        let bufStride = width
        var w = width
        var h = height
        var steps: [ModularEncoder.SqueezeStep] = []

        for _ in 0..<levels {
            if w > 1 {
                steps.append(ModularEncoder.SqueezeStep(
                    horizontal: true, width: w, height: h, stride: bufStride
                ))
                w = (w + 1) / 2
            }
            if h > 1 {
                steps.append(ModularEncoder.SqueezeStep(
                    horizontal: false, width: w, height: h, stride: bufStride
                ))
                h = (h + 1) / 2
            }
            if w <= 1 && h <= 1 { break }
        }

        return steps
    }

    /// Apply the inverse squeeze transform.
    ///
    /// Delegates to ``ModularEncoder`` helper methods (which are
    /// stateless and only depend on the step geometry).
    ///
    /// - Parameters:
    ///   - data: Squeeze-transformed residual data.
    ///   - steps: Squeeze steps in forward order (reversed internally).
    /// - Returns: Residuals with the squeeze undone.
    private func inverseSqueeze(
        data: [Int32],
        steps: [ModularEncoder.SqueezeStep]
    ) -> [Int32] {
        // Create a temporary ModularEncoder to access squeeze inversion.
        let encoder = ModularEncoder(hardware: hardware, options: options)
        return encoder.inverseSqueeze(data: data, steps: steps)
    }

    // MARK: - Inverse Prediction

    /// Reconstruct pixel values from residuals using the same prediction
    /// scheme as the encoder.
    ///
    /// At each position the predictor is evaluated on the
    /// *already-reconstructed* pixels (causally preceding the current one).
    /// The original value is recovered as:
    /// ```
    /// pixel[i] = residual[i] + predicted[i]
    /// ```
    ///
    /// When the effort level is below ``EncodingEffort/squirrel`` the
    /// encoder uses MED prediction (possibly NEON-accelerated).  At
    /// squirrel and above it uses the MA tree.  The decoder mirrors this
    /// selection so the predicted values match.
    ///
    /// - Parameters:
    ///   - residuals: Signed residuals (`actual − predicted`).
    ///   - width: Image width.
    ///   - height: Image height.
    ///   - channel: Channel index (for MA property evaluation).
    /// - Returns: Reconstructed unsigned pixel values.
    private func inversePrediction(
        residuals: [Int32],
        width: Int,
        height: Int,
        channel: Int
    ) -> [UInt16] {
        let count = width * height
        var reconstructed = [UInt16](repeating: 0, count: count)
        // Keep a running residual buffer for MA property evaluation.
        var reconResiduals = [Int32](repeating: 0, count: count)

        let useMATree = options.effort.rawValue >= EncodingEffort.squirrel.rawValue

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x

                let predicted: Int32
                if useMATree {
                    let (predictor, _) = maTree.traverse { property in
                        MATree.evaluateProperty(
                            property,
                            data: reconstructed,
                            residuals: reconResiduals,
                            x: x, y: y,
                            width: width, height: height,
                            channel: channel
                        )
                    }
                    predicted = MATree.applyPredictor(
                        predictor, data: reconstructed,
                        x: x, y: y,
                        width: width, height: height
                    )
                } else {
                    predicted = predictPixelMED(
                        data: reconstructed,
                        x: x, y: y,
                        width: width
                    )
                }

                let actual = residuals[index] + predicted
                reconstructed[index] = UInt16(clamping: max(0, actual))
                reconResiduals[index] = residuals[index]
            }
        }

        return reconstructed
    }

    /// MED predictor matching ``ModularEncoder/predictPixel(data:x:y:width:height:)``.
    private func predictPixelMED(
        data: [UInt16],
        x: Int,
        y: Int,
        width: Int
    ) -> Int32 {
        if x == 0 && y == 0 {
            return 0
        } else if y == 0 {
            return Int32(data[y * width + (x - 1)])
        } else if x == 0 {
            return Int32(data[(y - 1) * width + x])
        } else {
            let n = Int32(data[(y - 1) * width + x])
            let w = Int32(data[y * width + (x - 1)])
            let nw = Int32(data[(y - 1) * width + (x - 1)])
            let gradient = n + w - nw
            return max(0, min(65535, gradient))
        }
    }

    // MARK: - Inverse Reversible Colour Transform (RCT)

    /// Apply inverse RCT (YCoCg-R → RGB).
    ///
    /// Delegates to ``ModularEncoder/inverseRCT(channels:)`` which
    /// handles the +32768 offset on Co/Cg.
    private func inverseRCT(channels: inout [[UInt16]]) {
        let encoder = ModularEncoder(hardware: hardware, options: options)
        encoder.inverseRCT(channels: &channels)
    }
}
