// MinimalLosslessCodec — Phase M0 vertical slice.
//
// **Status: project-internal.** This file exists to prove that the
// entropy-primitive layer can encode real pixel data end-to-end and
// round-trip it back losslessly. It is **not** a JPEG-XL-spec-
// compliant file format. The actual JXL frame header (§C.8.1) and
// Modular sub-codec (§C.7) are still ahead — implementing those is
// the next milestone after this.
//
// What this proves:
//   • The bitstream + integer-coding layer can pack a real header.
//   • `SimpleEntropyStream` correctly encodes an arbitrary `[UInt32]`
//     stream of pixel values into bytes.
//   • The decoder recovers the exact same pixel values.
//
// Buffer layout:
//
//     signature           u(16)        // "FF 0A" (spec — also used by the real codestream)
//     SizeHeader                       // §C.3.2 (spec)
//     ImageMetadata                    // §C.3.3 (spec)
//     'M0' marker         u(16)        // 0x4D30, makes the placeholder explicit
//     align to byte
//     if channels == 3:
//         rct_variant     u(2)         // RCTVariant.identity or .ycocgR
//     align to byte
//     per-channel predictor IDs        // u(3) per channel; see PredictorID
//     align to byte
//     SimpleEntropyStream              // residual-value stream
//
// The 'M0' marker exists so the future spec-compliant decoder can
// distinguish a placeholder buffer from a real codestream and refuse
// to silently treat one as the other. When the real frame header
// lands, this file should either be deleted or kept as a
// regression-test fixture.
//
// Pixel encoding strategy (lossless):
//   • For 3-channel frames we optionally apply RCT (`RCTVariant.ycocgR`)
//     before prediction. The encoder tries both `.identity` and
//     `.ycocgR`, scores them by total predictor-best distinct tokens
//     across all three channels, and writes the winning u(2) variant
//     ID into the bitstream. For correlated colour input (RGB photos
//     or RGB-stored grayscale), YCoCg-R reduces two of the three
//     channels to constant residuals.
//   • Each channel is then processed separately in row-major order.
//     For every channel the encoder evaluates each available
//     predictor against the channel's pixels, picks the one whose
//     residuals produce the fewest distinct HybridUint tokens (ties
//     broken by the smaller `Σ|residual|`), and writes that
//     predictor's u(3) ID into the bitstream. Then for every pixel we
//     compute `predicted = chosenPredictor(W, N, NW, NE)` using
//     already-encoded neighbours and emit
//     `ZigZag.pack(actual - predicted)` to the entropy stream. The
//     decoder reverses: read the RCT variant + predictor IDs, decode
//     each residual, predict from already-decoded neighbours, recover
//     `actual = predicted + residual`, then apply RCT inverse.
//   • Residuals cluster near zero on natural-looking images, so the
//     `HybridUint` token alphabet sees mostly small values (which
//     pack into the literal-token range and consume no extra bits)
//     instead of the full pixel-value range. This is the standard JXL
//     lossless-Modular pattern: prediction + zigzag-encoded residuals
//     into a small-alphabet entropy coder.
//   • Uint8 and uint16 are supported. Float32 is not.
//
// Compared with the pre-prediction version of M0 (which encoded raw
// pixel values), the gradient-predicted output is meaningfully
// smaller on smooth-gradient images — the test
// `testM0_GradientPredictionReducesOutputSize_*` exercises this.
//
// **Predictor selection is per-channel, fixed within a channel.** A
// real Modular sub-codec drives per-pixel adaptive selection via the
// MA-tree (§C.7.4); per-channel selection is a much weaker
// approximation but lets us pick `north` for vertical-stripe images,
// `west` for horizontal-stripe ones, and so on. When the MA-tree
// lands, this file should either be deleted or kept as a regression-
// test fixture for the predictor primitive.

import Foundation

public enum MinimalLosslessError: Error, Sendable {
    case unsupportedPixelType
    case missingSignature
    case missingMarker
    case truncated
    case bitstream(BitstreamError)
    case container(ContainerError)
    case entropyStream(SimpleEntropyStreamError)
    case anscode(ANSError)
    case ansdist(ANSDistributionFormatError)
}

public struct MinimalLosslessCodec {

    /// Marker constant: 'M' '0' = 0x4D, 0x30 — placed in the header so
    /// a future spec-compliant decoder can recognise this is *not* a
    /// real JXL codestream.
    public static let placeholderMarker: UInt32 = 0x4D30

    /// Encode a frame to the M0 placeholder buffer format. Throws
    /// `unsupportedPixelType` for `.float32` (not yet supported by M0).
    public static func encode(_ frame: ImageFrame) throws -> Data {
        guard frame.pixelType == .uint8 || frame.pixelType == .uint16 else {
            throw MinimalLosslessError.unsupportedPixelType
        }

        // 1. JXL signature (spec — `FF 0A`).
        var w = BitWriter()
        w.write(bits: 8, value: 0xFF)
        w.write(bits: 8, value: 0x0A)

        // 2. SizeHeader.
        let size = SizeHeader(xsize: UInt32(frame.width),
                              ysize: UInt32(frame.height))
        do { try size.write(to: &w) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }

        // 3. ImageMetadata. Pick the colour encoding to match the
        // frame's channel count — grayscale for 1-channel frames,
        // sRGB for 3-channel ones. The decoder uses the recovered
        // colour-space tag to reconstruct the channel count, so this
        // must match what the encoder saw.
        let bd = BitDepth(
            floatingPoint: false,
            bitsPerSample: UInt32(frame.pixelType.bitsPerSample)
        )
        let colorEnc: ColorEncoding =
            (frame.channels == 1) ? .grayscaleD65 : .srgb
        let meta = ImageMetadata(
            allDefault: false,
            orientation: 1,
            intrinsicSize: nil,
            preview: nil,
            animation: nil,
            bitDepth: bd,
            modular16BitBufferSufficient: frame.pixelType == .uint8 || frame.pixelType == .uint16,
            extraChannels: [],
            xybEncoded: false,
            colorEncoding: colorEnc,
            intensityTarget: 255.0,
            minNits: 0.0,
            relativeToMaxDisplay: false,
            linearBelow: 0.0
        )
        do { try meta.write(to: &w) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }

        // 4. Placeholder marker. Align before writing so the marker
        // sits on a byte boundary — this lets external tools (and our
        // tests) find it by scanning the buffer for the literal bytes.
        w.alignToByte()
        w.write(bits: 16, value: placeholderMarker)

        // 5a. Optional RCT (3-channel frames only). We score
        // .identity against .ycocgR by summing the per-channel
        // best-predictor distinct-token counts after each transform,
        // and pick the one with the smaller sum.
        w.alignToByte()
        var channelBuffers = (0..<frame.channels).map {
            buildChannelBuffer(frame, channel: $0)
        }
        let rctVariant: RCTVariant
        if frame.channels == 3 {
            rctVariant = bestRCTVariant(
                channelBuffers: channelBuffers, width: frame.width,
                hybridConfig: HybridUintConfig.defaultConfig
            )
            if rctVariant != .identity {
                var c0 = channelBuffers[0]
                var c1 = channelBuffers[1]
                var c2 = channelBuffers[2]
                RCT.forward(rctVariant, channel0: &c0, channel1: &c1, channel2: &c2)
                channelBuffers[0] = c0
                channelBuffers[1] = c1
                channelBuffers[2] = c2
            }
            w.write(bits: 2, value: rctVariant.rawValue)
        } else {
            rctVariant = .identity   // not emitted for 1-channel frames
        }

        // 5b. Per-channel predictor selection. For each channel we
        // build an Int32 buffer of pixel values, score every
        // available predictor against it, and emit the winner's u(3)
        // ID. The decoder reads the IDs in the same channel order.
        w.alignToByte()
        let channelPredictors: [PredictorID] = channelBuffers.map {
            bestPredictorForChannel(
                $0, width: frame.width,
                hybridConfig: HybridUintConfig.defaultConfig
            )
        }
        for id in channelPredictors {
            w.write(bits: 3, value: id.rawValue)
        }
        w.alignToByte()

        // 6. Residual stream. Use the chosen per-channel predictor to
        // produce ZigZag-packed residuals, in channel-major then
        // row-major order, and feed them through SimpleEntropyStream.
        let values = pixelStream(
            channelBuffers: channelBuffers,
            width: frame.width, height: frame.height,
            predictors: channelPredictors
        )
        let alphabetSize = HybridUintConfig.defaultConfig.maxToken + 1

        // Pick the best-fit distribution shape from the existing
        // shortcut palette. When the actual token histogram has 1–4
        // distinct symbols, the simple-distribution path encodes each
        // token in 1–2 bits instead of the ~7 bits flat costs. For
        // wider histograms we fall back to flat. (The full per-symbol-
        // frequency mode that would handle arbitrary skewed
        // histograms is Phase E4b-full, deferred.)
        let shape = autoSelectShape(
            values: values,
            hybridConfig: HybridUintConfig.defaultConfig
        )

        // Build the matching `ANSDistribution`. We round-trip the
        // header bits through the format so the encoder's distribution
        // exactly matches what the decoder will reconstruct from the
        // serialised bytes.
        var distBits = BitWriter()
        do {
            switch shape {
            case .flat:
                try ANSDistributionFormat.encodeFlat(
                    alphabetSize: alphabetSize, to: &distBits
                )
            case .simple(let syms):
                try ANSDistributionFormat.encodeSimple(
                    symbols: syms, alphabetSize: alphabetSize, to: &distBits
                )
            }
        } catch let e as ANSDistributionFormatError {
            throw MinimalLosslessError.ansdist(e)
        }
        var distReader = BitReader(distBits.finishToData())
        let dist: ANSDistribution
        do { dist = try ANSDistributionFormat.decode(
            alphabetSize: alphabetSize, from: &distReader
        ) }
        catch let e as ANSDistributionFormatError {
            throw MinimalLosslessError.ansdist(e)
        }
        let ctx = SimpleEntropyContext(
            alphabetSize: alphabetSize,
            hybridConfig: HybridUintConfig.defaultConfig,
            distribution: dist
        )
        let streamData: Data
        do {
            streamData = try SimpleEntropyStream.encode(
                values: values, context: ctx, shape: shape
            )
        } catch let e as SimpleEntropyStreamError {
            throw MinimalLosslessError.entropyStream(e)
        }

        var out = w.finishToData()
        out.append(streamData)
        return out
    }

    /// Decode an M0 placeholder buffer produced by `encode(_:)`.
    public static func decode(_ data: Data) throws -> ImageFrame {
        var r = BitReader(data)
        // 1. Signature.
        let sig0: UInt32
        let sig1: UInt32
        do {
            sig0 = try r.read(bits: 8)
            sig1 = try r.read(bits: 8)
        } catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        guard sig0 == 0xFF && sig1 == 0x0A else {
            throw MinimalLosslessError.missingSignature
        }
        // 2. SizeHeader.
        let size: SizeHeader
        do { size = try SizeHeader.read(from: &r) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        // 3. ImageMetadata.
        let meta: ImageMetadata
        do { meta = try ImageMetadata.read(from: &r) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        // 4. Marker — encoder aligned-then-wrote, so we align-then-read.
        do { try r.alignToByte() }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        let marker: UInt32
        do { marker = try r.read(bits: 16) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        guard marker == placeholderMarker else {
            throw MinimalLosslessError.missingMarker
        }

        // Determine the channel count (must match what the encoder
        // wrote — see step 5 below) before reading predictor IDs.
        let pixelType: PixelType =
            meta.bitDepth.bitsPerSample == 8 ? .uint8 :
            (meta.bitDepth.floatingPoint ? .float32 : .uint16)
        guard pixelType != .float32 else {
            throw MinimalLosslessError.unsupportedPixelType
        }
        let channels = (meta.colorEncoding.colorSpace == .grayscale) ? 1 : 3

        // 5a. Optional RCT variant — only present in the 3-channel
        // case. In all other cases the decoder treats the variant as
        // identity.
        do { try r.alignToByte() }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        let rctVariant: RCTVariant
        if channels == 3 {
            let raw: UInt32
            do { raw = try r.read(bits: 2) }
            catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
            guard let v = RCTVariant(rawValue: raw) else {
                throw MinimalLosslessError.unsupportedPixelType
            }
            rctVariant = v
        } else {
            rctVariant = .identity
        }

        // 5b. Per-channel predictor IDs.
        do { try r.alignToByte() }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        var channelPredictors = [PredictorID](); channelPredictors.reserveCapacity(channels)
        for _ in 0..<channels {
            let raw: UInt32
            do { raw = try r.read(bits: 3) }
            catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
            guard let id = PredictorID(rawValue: raw) else {
                throw MinimalLosslessError.unsupportedPixelType
            }
            channelPredictors.append(id)
        }
        do { try r.alignToByte() }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }

        // 6. Residual stream.
        let bytePosition = r.position / 8
        let streamSlice = data.subdata(
            in: (data.startIndex + bytePosition)..<data.endIndex
        )
        let values: [UInt32]
        do {
            values = try SimpleEntropyStream.decode(streamSlice)
        } catch let e as SimpleEntropyStreamError {
            throw MinimalLosslessError.entropyStream(e)
        }

        // Reconstruct ImageFrame.
        var frame = ImageFrame(
            width: Int(size.xsize),
            height: Int(size.ysize),
            channels: channels,
            pixelType: pixelType,
            colorSpace: pixelType == .uint8 ? .sRGB : .grayscale,
            alphaChannels: 0,
            iccProfile: nil
        )
        // 7. Recover per-channel Int32 buffers from the residual
        //    stream + per-channel predictors.
        var channelBuffers = recoverChannelBuffers(
            values: values, predictors: channelPredictors,
            channels: channels, width: frame.width, height: frame.height
        )
        // 8. Inverse RCT if the encoder applied it.
        if rctVariant != .identity, channels == 3 {
            var c0 = channelBuffers[0]
            var c1 = channelBuffers[1]
            var c2 = channelBuffers[2]
            RCT.inverse(rctVariant, channel0: &c0, channel1: &c1, channel2: &c2)
            channelBuffers[0] = c0
            channelBuffers[1] = c1
            channelBuffers[2] = c2
        }
        // 9. Write channel buffers back into the frame.
        for c in 0..<channels {
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    let v = channelBuffers[c][y * frame.width + x]
                    writeChannelPixel(&frame, x: x, y: y, channel: c, value: v)
                }
            }
        }
        return frame
    }

    // MARK: - Distribution-shape selection

    /// Inspect the actual token histogram produced by running `values`
    /// through `hybridConfig`, and return the entropy-coder shape that
    /// will compress them best within the existing simple+flat
    /// shortcut palette:
    ///
    ///   • 1–4 distinct tokens → `.simple(symbols)`. The simple
    ///     distribution gives each listed symbol a predefined slice of
    ///     the rANS table (`[tab]`, `[tab/2]×2`, `[tab/4, tab/4,
    ///     tab/2]`, `[tab/4]×4`), so each token costs 1–2 bits instead
    ///     of the ~7 bits flat costs.
    ///   • Anything wider → `.flat` (uniform across the alphabet).
    ///
    /// For the 3-symbol case the predefined split is asymmetric — the
    /// last position gets `tab/2`. We reorder so the most-frequent
    /// token lands there.
    static func autoSelectShape(
        values: [UInt32], hybridConfig: HybridUintConfig
    ) -> SimpleEntropyDistributionShape {
        if values.isEmpty { return .flat }
        var counts: [Int: Int] = [:]
        for v in values {
            let tok = Int(hybridConfig.encode(v).token)
            counts[tok, default: 0] += 1
        }
        if counts.count > 4 { return .flat }
        // Sort tokens by frequency descending, ties broken by token
        // index for determinism.
        let sortedDesc = counts.sorted {
            $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key)
        }.map { $0.key }
        switch sortedDesc.count {
        case 1, 2, 4:
            return .simple(symbols: sortedDesc)
        case 3:
            // Reorder so the most-frequent token is at position 2 and
            // gets the `tab/2` slice.
            return .simple(symbols: [sortedDesc[1], sortedDesc[2], sortedDesc[0]])
        default:
            return .flat
        }
    }

    // MARK: - Per-channel best-predictor selection

    /// Build a flat row-major Int32 buffer of one channel's pixels.
    static func buildChannelBuffer(_ frame: ImageFrame, channel c: Int) -> [Int32] {
        var buf = [Int32](repeating: 0, count: frame.width * frame.height)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                buf[y * frame.width + x] = readChannelPixel(frame, x: x, y: y, channel: c)
            }
        }
        return buf
    }

    /// Try every `PredictorID` against the channel's pixels and pick
    /// the one whose residuals produce the fewest distinct
    /// HybridUint tokens (which is what `autoSelectShape` needs to
    /// hit the simple-distribution shortcut). Ties broken by
    /// smaller `Σ|residual|`.
    static func bestPredictorForChannel(
        _ buf: [Int32], width: Int, hybridConfig: HybridUintConfig
    ) -> PredictorID {
        let height = buf.count / width
        var bestID: PredictorID = .gradient
        var bestDistinct = Int.max
        var bestSumAbs: Int64 = .max

        for id in PredictorID.allCases {
            let predictor = id.predictor
            var seen = Set<UInt32>()
            var sumAbs: Int64 = 0
            // Shadow buffer of already-"emitted" pixels (= the
            // channel's actuals) so each prediction sees the same
            // neighbourhood the real encoder/decoder will see.
            var shadow = [Int32](repeating: 0, count: buf.count)
            for y in 0..<height {
                for x in 0..<width {
                    let actual = buf[y * width + x]
                    let nbh = Neighbourhood(at: x, y, in: shadow, width: width)
                    let pred = predictor.apply(to: nbh)
                    let residual = actual &- pred
                    let token = hybridConfig.encode(ZigZag.pack(residual)).token
                    seen.insert(token)
                    sumAbs &+= Int64(residual < 0 ? -residual : residual)
                    shadow[y * width + x] = actual
                }
            }
            if seen.count < bestDistinct ||
               (seen.count == bestDistinct && sumAbs < bestSumAbs) {
                bestID = id
                bestDistinct = seen.count
                bestSumAbs = sumAbs
            }
        }
        return bestID
    }

    // MARK: - Pixel ↔ residual-stream conversion (per-channel predictor)
    //
    // Channels are processed independently in `predictors[c]` order.
    // For each channel we walk pixels in row-major order, predict
    // from already-encoded neighbours, and emit
    // `ZigZag.pack(actual - predicted)`. The decoder reverses the
    // transformation pixel-by-pixel.

    private static func pixelStream(
        channelBuffers: [[Int32]],
        width: Int, height: Int,
        predictors: [PredictorID]
    ) -> [UInt32] {
        let total = width * height * channelBuffers.count
        var out = [UInt32](); out.reserveCapacity(total)
        for (c, channelBuf) in channelBuffers.enumerated() {
            let predictor = predictors[c].predictor
            var shadow = [Int32](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let actual = channelBuf[y * width + x]
                    let nbh = Neighbourhood(at: x, y, in: shadow, width: width)
                    let pred = predictor.apply(to: nbh)
                    let residual = actual &- pred
                    out.append(ZigZag.pack(residual))
                    shadow[y * width + x] = actual
                }
            }
        }
        return out
    }

    /// Recover per-channel Int32 buffers from the entropy-coded
    /// residual stream and the per-channel predictor IDs. The
    /// returned buffers are in the channel order they were encoded
    /// (i.e. *before* any RCT inverse — the caller applies that).
    private static func recoverChannelBuffers(
        values: [UInt32], predictors: [PredictorID],
        channels: Int, width: Int, height: Int
    ) -> [[Int32]] {
        let pixelsPerChannel = width * height
        var bufs = [[Int32]](repeating: [], count: channels)
        for c in 0..<channels {
            let predictor = predictors[c].predictor
            var buf = [Int32](repeating: 0, count: pixelsPerChannel)
            for y in 0..<height {
                for x in 0..<width {
                    let i = c * pixelsPerChannel + y * width + x
                    let residual = ZigZag.unpack(values[i])
                    let nbh = Neighbourhood(at: x, y, in: buf, width: width)
                    let pred = predictor.apply(to: nbh)
                    buf[y * width + x] = pred &+ residual
                }
            }
            bufs[c] = buf
        }
        return bufs
    }

    /// Pick whichever RCT variant produces fewer total distinct
    /// HybridUint tokens across all three channels (i.e. the best
    /// match for the auto-shape selector that will run downstream).
    /// Operates on copies — does not mutate `channelBuffers`.
    static func bestRCTVariant(
        channelBuffers: [[Int32]], width: Int, hybridConfig: HybridUintConfig
    ) -> RCTVariant {
        precondition(channelBuffers.count == 3, "RCT scoring requires 3 channels")
        var bestVariant = RCTVariant.identity
        var bestScore = Int.max
        for variant in RCTVariant.allCases {
            var bufs = channelBuffers
            if variant != .identity {
                var c0 = bufs[0]
                var c1 = bufs[1]
                var c2 = bufs[2]
                RCT.forward(variant, channel0: &c0, channel1: &c1, channel2: &c2)
                bufs[0] = c0
                bufs[1] = c1
                bufs[2] = c2
            }
            // Sum the per-channel best-predictor distinct-token
            // counts to score the variant.
            var totalDistinct = 0
            for buf in bufs {
                let id = bestPredictorForChannel(
                    buf, width: width, hybridConfig: hybridConfig
                )
                let predictor = id.predictor
                var seen = Set<UInt32>()
                var shadow = [Int32](repeating: 0, count: buf.count)
                let height = buf.count / width
                for y in 0..<height {
                    for x in 0..<width {
                        let actual = buf[y * width + x]
                        let nbh = Neighbourhood(at: x, y, in: shadow, width: width)
                        let pred = predictor.apply(to: nbh)
                        let residual = actual &- pred
                        let token = hybridConfig.encode(ZigZag.pack(residual)).token
                        seen.insert(token)
                        shadow[y * width + x] = actual
                    }
                }
                totalDistinct &+= seen.count
            }
            if totalDistinct < bestScore {
                bestScore = totalDistinct
                bestVariant = variant
            }
        }
        return bestVariant
    }

    /// Read one channel's pixel as `Int32` (wide enough for any
    /// supported bit depth, signed for residual arithmetic).
    private static func readChannelPixel(
        _ frame: ImageFrame, x: Int, y: Int, channel c: Int
    ) -> Int32 {
        let bps = frame.pixelType.bytesPerSample
        let i = (y * frame.width + x) * frame.channels + c
        switch bps {
        case 1:
            return Int32(frame.data[i])
        case 2:
            let lo = Int32(frame.data[i * 2])
            let hi = Int32(frame.data[i * 2 + 1])
            return (hi << 8) | lo
        default:
            return 0
        }
    }

    /// Write one channel's pixel from an `Int32`. The decoder is
    /// responsible for ensuring `value` lies in the channel's
    /// representable range — for the test images we use it does.
    private static func writeChannelPixel(
        _ frame: inout ImageFrame, x: Int, y: Int, channel c: Int, value: Int32
    ) {
        let bps = frame.pixelType.bytesPerSample
        let i = (y * frame.width + x) * frame.channels + c
        switch bps {
        case 1:
            frame.data[i] = UInt8(truncatingIfNeeded: value)
        case 2:
            let v = UInt32(bitPattern: value)
            frame.data[i * 2]     = UInt8(v & 0xFF)
            frame.data[i * 2 + 1] = UInt8((v >> 8) & 0xFF)
        default:
            break
        }
    }

}

