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
//     channels            u(3)         // 1..4 (grayscale / gray+alpha / RGB / RGBA)
//     if channels >= 3:
//         rct_variant     u(2)         // RCTVariant.identity or .ycocgR (R/G/B only)
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
    case unsupportedChannelCount(Int)
    case missingSignature
    case missingMarker
    case truncated
    case bitstream(BitstreamError)
    case container(ContainerError)
    case entropyStream(SimpleEntropyStreamError)
    case anscode(ANSError)
    case ansdist(ANSDistributionFormatError)
}

/// Encode-time speed/ratio trade-off for `MinimalLosslessCodec`. The
/// decoder doesn't need to know which mode was used — it reads the
/// stored predictor IDs and RCT variant either way.
public enum M0Effort: Sendable, Equatable {
    /// Skip predictor + RCT search. Pick `Predictor.gradient` for
    /// every channel and `RCTVariant.identity` for the colour
    /// transform. Encode is roughly 6× faster than `.balanced` but
    /// compression ratio is worse on stripe-like and constant-fill
    /// images (where `.balanced` would have picked `.north` /
    /// `.west` / `.zero`).
    case fast
    /// Score every predictor against the channel's pixels and (for
    /// 3+ channel frames) every RCT variant against the channel
    /// triple. Pick the combination whose residuals produce the
    /// fewest distinct HybridUint tokens.
    case balanced
}

public struct MinimalLosslessCodec {

    /// Marker constant: 'M' '0' = 0x4D, 0x30 — placed in the header so
    /// a future spec-compliant decoder can recognise this is *not* a
    /// real JXL codestream.
    public static let placeholderMarker: UInt32 = 0x4D30

    /// Encode a frame to the M0 placeholder buffer format. The
    /// `effort` parameter trades encode speed against compression
    /// ratio — see `M0Effort`. Throws `.unsupportedPixelType` for
    /// `.float32` (not yet supported by M0).
    public static func encode(
        _ frame: ImageFrame, effort: M0Effort = .balanced
    ) throws -> Data {
        guard frame.pixelType == .uint8 || frame.pixelType == .uint16 else {
            throw MinimalLosslessError.unsupportedPixelType
        }
        guard (1...4).contains(frame.channels) else {
            throw MinimalLosslessError.unsupportedChannelCount(frame.channels)
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

        // 3. ImageMetadata. ColorEncoding picks grayscale for
        // grayscale-shaped frames (1 or 2 channels — the second is
        // alpha), sRGB for RGB-shaped (3 or 4 channels — the fourth
        // is alpha). The actual channel count is then carried
        // explicitly in the M0 header (step 5a) so we don't have to
        // infer it from colour-space at decode time.
        let bd = BitDepth(
            floatingPoint: false,
            bitsPerSample: UInt32(frame.pixelType.bitsPerSample)
        )
        let colorEnc: ColorEncoding =
            (frame.channels <= 2) ? .grayscaleD65 : .srgb
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

        // 5a. Single combined predictor + RCT preparation pass. This
        // tries every RCT variant (3-channel frames only) × every
        // predictor per channel, and keeps the residuals from the
        // best combination so the encoder doesn't re-run prediction
        // afterwards.
        w.alignToByte()
        w.write(bits: 3, value: UInt32(frame.channels))
        let channelBuffers = (0..<frame.channels).map {
            buildChannelBuffer(frame, channel: $0)
        }
        let prep: EncodePreparation
        switch effort {
        case .balanced:
            prep = bestEncodePreparation(
                channelBuffers: channelBuffers, width: frame.width,
                hybridConfig: HybridUintConfig.defaultConfig
            )
        case .fast:
            prep = fastEncodePreparation(
                channelBuffers: channelBuffers, width: frame.width,
                hybridConfig: HybridUintConfig.defaultConfig
            )
        }
        if frame.channels >= 3 {
            w.write(bits: 2, value: prep.rctVariant.rawValue)
        }

        // 5b. Per-channel predictor IDs (in channel order).
        w.alignToByte()
        for id in prep.channelPredictors {
            w.write(bits: 3, value: id.rawValue)
        }
        w.alignToByte()

        // 6. Residual stream — already computed by bestEncodePreparation.
        let values = prep.residuals
        let alphabetSize = HybridUintConfig.defaultConfig.maxToken + 1

        // Pick the best-fit distribution shape: simple for ≤4
        // distinct tokens, otherwise estimate full vs flat by bit
        // cost (Shannon entropy + alphabet × 13 overhead vs
        // log2(alphabet) per token).
        let shape = autoSelectShape(
            values: values,
            hybridConfig: HybridUintConfig.defaultConfig,
            alphabetSize: alphabetSize
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
            case .full(let freqs):
                try ANSDistributionFormat.encodeFull(
                    frequencies: freqs, alphabetSize: alphabetSize, to: &distBits
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

        let pixelType: PixelType =
            meta.bitDepth.bitsPerSample == 8 ? .uint8 :
            (meta.bitDepth.floatingPoint ? .float32 : .uint16)
        guard pixelType != .float32 else {
            throw MinimalLosslessError.unsupportedPixelType
        }

        // 5a. Channel count + optional RCT variant. The encoder
        // writes the channel count explicitly; decoder reads it
        // before any per-channel field. RCT variant is only emitted
        // when channels >= 3.
        do { try r.alignToByte() }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        let channels: Int
        do { channels = Int(try r.read(bits: 3)) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        guard (1...4).contains(channels) else {
            throw MinimalLosslessError.unsupportedChannelCount(channels)
        }
        let rctVariant: RCTVariant
        if channels >= 3 {
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

        // Reconstruct ImageFrame. Channel counts:
        //   1 → grayscale,  2 → grayscale + alpha,
        //   3 → RGB,        4 → RGBA.
        // alphaChannels is always 0 or 1 (per ImageFrame's contract).
        let isGrayShaped = channels <= 2
        let alphaChannels = (channels == 2 || channels == 4) ? 1 : 0
        let frameColorSpace: ColorSpace = isGrayShaped ? .grayscale : .sRGB
        var frame = ImageFrame(
            width: Int(size.xsize),
            height: Int(size.ysize),
            channels: channels,
            pixelType: pixelType,
            colorSpace: frameColorSpace,
            alphaChannels: alphaChannels,
            iccProfile: nil
        )
        // 7. Recover per-channel Int32 buffers from the residual
        //    stream + per-channel predictors.
        var channelBuffers = recoverChannelBuffers(
            values: values, predictors: channelPredictors,
            channels: channels, width: frame.width, height: frame.height
        )
        // 8. Inverse RCT — only the first three channels (R, G, B) when
        //    channels >= 3. Alpha (channel 3 of RGBA) is left alone.
        if rctVariant != .identity, channels >= 3 {
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

    // MARK: - Inspection (M0-specific diagnostic fields)

    /// Lightweight summary of an M0 buffer: image geometry + the
    /// encoder's compression choices. Cheaper than `decode(_:)`
    /// because it stops before the entropy stream — useful for
    /// `jxl-tool info`-style diagnostics.
    public struct M0Inspection: Sendable {
        public let xsize: UInt32
        public let ysize: UInt32
        public let bitsPerSample: UInt32
        public let channels: Int
        public let rctVariant: RCTVariant
        public let channelPredictors: [PredictorID]
    }

    /// Inspect an M0 buffer without decoding pixels. Reads the
    /// signature + SizeHeader + ImageMetadata + 'M0' marker + channel
    /// count + (if applicable) RCT variant + per-channel predictor
    /// IDs, and returns them. Throws if the buffer doesn't have the
    /// 'M0' marker (i.e. isn't an M0 buffer).
    public static func inspectM0(_ data: Data) throws -> M0Inspection {
        var r = BitReader(data)
        let sig0: UInt32
        let sig1: UInt32
        do {
            sig0 = try r.read(bits: 8)
            sig1 = try r.read(bits: 8)
        } catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        guard sig0 == 0xFF && sig1 == 0x0A else {
            throw MinimalLosslessError.missingSignature
        }
        let size: SizeHeader
        do { size = try SizeHeader.read(from: &r) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        let meta: ImageMetadata
        do { meta = try ImageMetadata.read(from: &r) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        do { try r.alignToByte() }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        let marker: UInt32
        do { marker = try r.read(bits: 16) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        guard marker == placeholderMarker else {
            throw MinimalLosslessError.missingMarker
        }
        do { try r.alignToByte() }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        let channels: Int
        do { channels = Int(try r.read(bits: 3)) }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        guard (1...4).contains(channels) else {
            throw MinimalLosslessError.unsupportedChannelCount(channels)
        }
        let rctVariant: RCTVariant
        if channels >= 3 {
            let raw: UInt32
            do { raw = try r.read(bits: 2) }
            catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
            rctVariant = RCTVariant(rawValue: raw) ?? .identity
        } else {
            rctVariant = .identity
        }
        do { try r.alignToByte() }
        catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
        var predictors = [PredictorID](); predictors.reserveCapacity(channels)
        for _ in 0..<channels {
            let raw: UInt32
            do { raw = try r.read(bits: 3) }
            catch let e as BitstreamError { throw MinimalLosslessError.bitstream(e) }
            predictors.append(PredictorID(rawValue: raw) ?? .gradient)
        }
        return M0Inspection(
            xsize: size.xsize,
            ysize: size.ysize,
            bitsPerSample: meta.bitDepth.bitsPerSample,
            channels: channels,
            rctVariant: rctVariant,
            channelPredictors: predictors
        )
    }

    /// True iff the buffer carries the M0 placeholder marker. Useful
    /// to gate display of M0-specific fields in tools that handle
    /// both M0 and (eventually) real JXL codestreams.
    public static func isM0(_ data: Data) -> Bool {
        do { _ = try inspectM0(data); return true }
        catch { return false }
    }

    // MARK: - Distribution-shape selection

    /// Inspect the actual token histogram produced by running `values`
    /// through `hybridConfig`, and return the best-fitting entropy-
    /// coder shape:
    ///
    ///   • 1–4 distinct tokens → `.simple(symbols)`. The simple
    ///     distribution gives each listed symbol a predefined slice of
    ///     the rANS table (`[tab]`, `[tab/2]×2`, `[tab/4, tab/4,
    ///     tab/2]`, `[tab/4]×4`), so each token costs 1–2 bits instead
    ///     of the ~7 bits flat costs.
    ///   • > 4 distinct tokens → estimate the bit cost of `.full`
    ///     (per-symbol frequencies) versus `.flat` and pick the
    ///     smaller. Full has a fixed `alphabet × 13`-bit overhead but
    ///     pays the actual entropy per token; flat pays
    ///     `log2(alphabet)` bits per token regardless of skew. For
    ///     skewed real-image residual histograms the per-token saving
    ///     amortises the overhead very quickly.
    ///
    /// For the 3-symbol case the predefined split is asymmetric — the
    /// last position gets `tab/2`. We reorder so the most-frequent
    /// token lands there.
    static func autoSelectShape(
        values: [UInt32], hybridConfig: HybridUintConfig,
        alphabetSize: Int
    ) -> SimpleEntropyDistributionShape {
        if values.isEmpty { return .flat }
        var counts: [Int: Int] = [:]
        for v in values {
            let tok = Int(hybridConfig.encode(v).token)
            counts[tok, default: 0] += 1
        }
        if counts.count <= 4 {
            // Sort tokens by frequency descending, ties broken by
            // token index for determinism.
            let sortedDesc = counts.sorted {
                $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key)
            }.map { $0.key }
            switch sortedDesc.count {
            case 1, 2, 4:
                return .simple(symbols: sortedDesc)
            case 3:
                // Reorder so the most-frequent token is at position 2
                // and gets the `tab/2` slice.
                return .simple(symbols: [sortedDesc[1], sortedDesc[2], sortedDesc[0]])
            default:
                return .flat
            }
        }
        // Wider histogram — choose between flat and full by
        // estimated bit cost.
        return chooseFullOrFlat(counts: counts, alphabetSize: alphabetSize)
    }

    /// Decide between `.full` and `.flat` for a histogram with > 4
    /// distinct tokens. Computes the approximate bit cost of each
    /// (Shannon entropy for full, `log2(alphabet)` per token for
    /// flat) and picks the smaller. When `.full` wins, builds the
    /// normalised frequencies array.
    private static func chooseFullOrFlat(
        counts: [Int: Int], alphabetSize: Int
    ) -> SimpleEntropyDistributionShape {
        let total = counts.values.reduce(0, +)
        if total == 0 { return .flat }

        // Flat: each token costs ceil(log2(alphabet)) bits.
        let flatBitsPerToken = Int(ceilLog2(UInt32(alphabetSize)))
        let flatBits = total &* flatBitsPerToken

        // Full: token cost ≈ Shannon entropy; overhead = alphabet × 13.
        var fullEntropyBits = 0.0
        for (_, c) in counts where c > 0 {
            let p = Double(c) / Double(total)
            fullEntropyBits -= Double(c) * Foundation.log2(p)
        }
        let fullOverheadBits = alphabetSize * 13
        let fullBits = Int(fullEntropyBits.rounded(.up)) + fullOverheadBits

        if fullBits < flatBits {
            // Build the frequency array from the histogram.
            var raw = [UInt32](repeating: 0, count: alphabetSize)
            for (sym, c) in counts { raw[sym] = UInt32(c) }
            let freqs: [UInt32]
            do { freqs = try ANSDistributionFormat.normaliseToTabSize(raw) }
            catch { return .flat }   // fall back if normalisation fails
            return .full(frequencies: freqs)
        }
        return .flat
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

    /// Result of `bestPredictorForChannel(_:width:hybridConfig:)`.
    /// Carries the chosen predictor, the ZigZag-packed residuals
    /// produced by it (in row-major order — ready to feed straight
    /// into `SimpleEntropyStream`), and the number of distinct
    /// HybridUint tokens the residuals produced (used as the
    /// scoring metric — fewer is better).
    struct ChannelPredictorChoice {
        let id: PredictorID
        let residuals: [UInt32]
        let distinctCount: Int
    }

    /// One predictor's trial result against a channel — produced
    /// in parallel inside `bestPredictorForChannel`.
    private struct PredictorTrial: Sendable {
        let id: PredictorID
        let distinctCount: Int
        let sumAbs: Int64
        let residuals: [UInt32]
    }

    /// Evaluate a single predictor against `buf` and return its
    /// trial result. Self-contained (allocates its own scratch) so
    /// it's safe to call concurrently for different predictors.
    private static func evaluatePredictor(
        id: PredictorID, buf: [Int32], width: Int,
        hybridConfig: HybridUintConfig, alphabetSize: Int
    ) -> PredictorTrial {
        let height = buf.count / width
        let predictor = id.predictor
        var residuals = [UInt32](repeating: 0, count: buf.count)
        var shadow = [Int32](repeating: 0, count: buf.count)
        var seen = [Bool](repeating: false, count: alphabetSize)
        var distinctCount = 0
        var sumAbs: Int64 = 0
        for y in 0..<height {
            for x in 0..<width {
                let actual = buf[y * width + x]
                let nbh = Neighbourhood(at: x, y, in: shadow, width: width)
                let pred = predictor.apply(to: nbh)
                let residual = actual &- pred
                let zig = ZigZag.pack(residual)
                residuals[y * width + x] = zig
                let token = Int(hybridConfig.tokenOnly(zig))
                if !seen[token] {
                    seen[token] = true
                    distinctCount &+= 1
                }
                sumAbs &+= Int64(residual < 0 ? -residual : residual)
                shadow[y * width + x] = actual
            }
        }
        return PredictorTrial(
            id: id, distinctCount: distinctCount,
            sumAbs: sumAbs, residuals: residuals
        )
    }

    /// Try every `PredictorID` against the channel's pixels and pick
    /// the one whose residuals produce the fewest distinct
    /// HybridUint tokens (which is what `autoSelectShape` needs to
    /// hit the simple-distribution shortcut). Ties broken by
    /// smaller `Σ|residual|`. Returns both the chosen predictor and
    /// its residuals so callers don't need to re-run prediction.
    ///
    /// Runs the 6 predictor evaluations in parallel via
    /// `parallelMap` — gives a 4-6× speedup on multi-core for a
    /// single channel. Combined with per-channel parallelism in
    /// `bestEncodePreparation`, multi-channel encodes parallelise
    /// at two nested levels.
    static func bestPredictorForChannel(
        _ buf: [Int32], width: Int, hybridConfig: HybridUintConfig
    ) -> ChannelPredictorChoice {
        let alphabetSize = hybridConfig.maxToken + 1
        let allIDs = PredictorID.allCases
        let trials: [PredictorTrial] = parallelMap(allIDs.count) { i in
            evaluatePredictor(
                id: allIDs[i], buf: buf, width: width,
                hybridConfig: hybridConfig, alphabetSize: alphabetSize
            )
        }

        // Pick winner: smallest distinctCount; ties broken by sumAbs.
        var bestIdx = 0
        for i in 1..<trials.count {
            let t = trials[i]
            let b = trials[bestIdx]
            if t.distinctCount < b.distinctCount ||
               (t.distinctCount == b.distinctCount && t.sumAbs < b.sumAbs) {
                bestIdx = i
            }
        }
        let winner = trials[bestIdx]
        return ChannelPredictorChoice(
            id: winner.id, residuals: winner.residuals,
            distinctCount: winner.distinctCount
        )
    }

    // MARK: - Decoder-side pixel reconstruction
    //
    // Channels are processed independently in `predictors[c]` order.
    // For each channel we walk pixels in row-major order, predict
    // from already-decoded neighbours, and recover
    // `actual = predicted + ZigZag.unpack(residual)`.

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
    ///
    /// This now reuses `bestPredictorForChannel`'s returned distinct
    /// count rather than re-running prediction for the score.
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
            var totalDistinct = 0
            for buf in bufs {
                let choice = bestPredictorForChannel(
                    buf, width: width, hybridConfig: hybridConfig
                )
                totalDistinct &+= choice.distinctCount
            }
            if totalDistinct < bestScore {
                bestScore = totalDistinct
                bestVariant = variant
            }
        }
        return bestVariant
    }

    /// Combined "what should the encoder emit" preparation. Picks
    /// the best RCT variant and the best per-channel predictor, AND
    /// returns the ZigZag-packed residuals so the encoder doesn't
    /// re-run prediction. This is the single hot path through the
    /// encoder; the predictor passes here dominate encode time.
    struct EncodePreparation {
        let rctVariant: RCTVariant
        let channelPredictors: [PredictorID]
        /// Channel-major, row-major ZigZag-packed residuals — fed
        /// straight into the `SimpleEntropyStream`.
        let residuals: [UInt32]
    }

    static func bestEncodePreparation(
        channelBuffers: [[Int32]], width: Int,
        hybridConfig: HybridUintConfig
    ) -> EncodePreparation {
        let channels = channelBuffers.count
        let candidates: [RCTVariant] = (channels >= 3)
            ? Array(RCTVariant.allCases) : [.identity]

        var bestVariant: RCTVariant = .identity
        var bestPredictors: [PredictorID] = []
        var bestResiduals: [UInt32] = []
        var bestScore = Int.max

        for variant in candidates {
            var trial = channelBuffers
            if variant != .identity && channels >= 3 {
                var c0 = trial[0]
                var c1 = trial[1]
                var c2 = trial[2]
                RCT.forward(variant, channel0: &c0, channel1: &c1, channel2: &c2)
                trial[0] = c0
                trial[1] = c1
                trial[2] = c2
            }
            // Per-channel predictor selection. Parallelise across
            // channels when there are 2+: each channel's
            // bestPredictorForChannel is independent and dominated by
            // 6 sequential predictor passes per channel, so 4-channel
            // RGBA gets a 4× theoretical speedup on multi-core.
            let trialFrozen = trial   // capture immutable copy for @Sendable closure
            let choices: [ChannelPredictorChoice] = parallelMap(trialFrozen.count) { i in
                bestPredictorForChannel(
                    trialFrozen[i], width: width, hybridConfig: hybridConfig
                )
            }
            var predictors: [PredictorID] = []
            predictors.reserveCapacity(choices.count)
            var residuals: [UInt32] = []
            residuals.reserveCapacity(width * (channelBuffers[0].count / width) * channels)
            var score = 0
            for choice in choices {
                predictors.append(choice.id)
                residuals.append(contentsOf: choice.residuals)
                score &+= choice.distinctCount
            }
            if score < bestScore {
                bestVariant = variant
                bestPredictors = predictors
                bestResiduals = residuals
                bestScore = score
            }
        }
        return EncodePreparation(
            rctVariant: bestVariant,
            channelPredictors: bestPredictors,
            residuals: bestResiduals
        )
    }

    /// Fast-path encode preparation: skip predictor + RCT search,
    /// pick `.gradient` for every channel and `.identity` for RCT.
    /// One prediction pass per channel total — `.balanced` does
    /// (RCT-variants × predictors) passes per channel, so this is
    /// roughly 6× faster on grayscale and 12× faster on RGB.
    static func fastEncodePreparation(
        channelBuffers: [[Int32]], width: Int,
        hybridConfig: HybridUintConfig
    ) -> EncodePreparation {
        let channels = channelBuffers.count
        let predictor = Predictor.gradient
        var residuals = [UInt32]()
        residuals.reserveCapacity(width * (channelBuffers[0].count / width) * channels)
        for buf in channelBuffers {
            let height = buf.count / width
            var shadow = [Int32](repeating: 0, count: buf.count)
            for y in 0..<height {
                for x in 0..<width {
                    let actual = buf[y * width + x]
                    let nbh = Neighbourhood(at: x, y, in: shadow, width: width)
                    let pred = predictor.apply(to: nbh)
                    let residual = actual &- pred
                    residuals.append(ZigZag.pack(residual))
                    shadow[y * width + x] = actual
                }
            }
        }
        return EncodePreparation(
            rctVariant: .identity,
            channelPredictors: [PredictorID](repeating: .gradient, count: channels),
            residuals: residuals
        )
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

/// Run `work(i)` for each `i` in `0..<count` in parallel where
/// possible, collecting the results into an ordered array. Falls
/// through to a sequential loop for `count <= 1` (no dispatch
/// overhead).
///
/// Uses GCD `concurrentPerform` under the hood; the closure is
/// `@Sendable` and we coordinate writes to disjoint indices via
/// `withUnsafeMutableBufferPointer` (a scoped, Swift-stdlib-
/// blessed escape hatch — not the prohibited
/// `nonisolated(unsafe)` long-lived state pattern).
@inline(__always)
private func parallelMap<T: Sendable>(
    _ count: Int,
    _ work: @Sendable (Int) -> T
) -> [T] {
    if count <= 1 {
        return (0..<count).map(work)
    }
    var results: [T?] = Array(repeating: nil, count: count)
    results.withUnsafeMutableBufferPointer { buffer in
        // Capture the buffer's base pointer as a Sendable
        // raw-pointer integer — disjoint-index writes are safe.
        let base = UInt(bitPattern: Int(bitPattern: OpaquePointer(buffer.baseAddress!)))
        DispatchQueue.concurrentPerform(iterations: count) { i in
            let p = UnsafeMutablePointer<T?>(
                bitPattern: Int(bitPattern: base)
            )!
            p.advanced(by: i).pointee = work(i)
        }
    }
    return results.map { $0! }
}

