// SpecModularEncoder — pure-Swift, spec-compliant Modular encoder.
//
// **Status**: lossless Modular path is feature-complete for the
// integer pixel layouts the project's primary use cases need:
// 8-bit grayscale, 8-bit RGB, 8-bit RGBA, 9..16-bit grayscale,
// 9..16-bit RGB, 9..16-bit RGBA. All round-trip through both OUR
// decoder AND libjxl `djxl` 0.11.2 at any size up to 16384×16384
// (arbitrary dimensions). Multi-group encoding lights up automatically
// for >512² inputs; >4096-px dimensions add multiple DC groups. Wired
// through `JXLEncoder.encode(_:)` and
// `jxl-tool encode`; the only remaining work is lossy VarDCT
// (a separate multi-person-year project tracked in ROADMAP.md).
//
// Three non-obvious wire-format details that closed the libjxl
// compatibility gap (vs. an "obvious" reading of the spec):
//   • A `CustomTransformData` block (`image_metadata.cc`) sits
//     between `ImageMetadata` and the JumpToByteBoundary that
//     precedes `FrameHeader`. For a non-XYB image with all
//     defaults, that's a single `all_default = 1` bit — but you
//     have to write it.
//   • Modular frames carry a non-default `LoopFilter` with
//     `gab=false / epf_iters=0` (see `enc_frame.cc::
//     LoopFilterFromParams`), not the spec-default `gab=true /
//     epf_iters=2`. Those defaults are VarDCT-shaped.
//   • The Huffman alphabet declared in the prefix-codebook header
//     should be `max_used_token + 1`, NOT
//     `HybridUintConfig.maxToken + 1`. libjxl's decoder rejects
//     codebooks padded with trailing zero-length symbols past the
//     last actually-used token even though the resulting Kraft sum
//     still balances — observed: `djxl` returns "Failed to decode
//     image" silently on the larger alphabet form.
//   • The libjxl raw predictor IDs (`enum Predictor` in
//     `lib/jxl/modular/encoding/context_predict.h`) differ from our
//     internal `PredictorID` enum: ClampedGradient is **5** in
//     libjxl, but **4** in our enum. Use the libjxl numbers on the
//     wire — `applyLibjxlPredictor` is the decoder dispatcher.
//
// **Encoder pipeline** (libjxl `enc_modular.cc` + `enc_frame.cc`):
//
//     0xFF 0x0A                                       // signature
//     SizeHeader.write                                // §C.3.1
//     ImageMetadata.write                             // §C.3
//     // byte-align
//     FrameHeader.write                               // §C.8.1
//     TOC.write (one entry per logical section)       // §C.8.1.5
//     // Section 0 (DC global) for Modular frames:
//       1 bit  matrices_dc_default
//       1 bit  has_tree
//       if has_tree:
//         tree section: EntropySectionHeader (numContexts=6) +
//                       MultiClusterCodebook + tree tokens
//         post-tree section: EntropySectionHeader (numContexts=numLeaves) +
//                            MultiClusterCodebook
//       GroupHeader (useGlobalTree, wpHeader, transforms)
//       // For numGroups == 1 single-pass, all pixel data is here.
//
// **What works today**:
//
//   ✅ `encodeConstantGrayscale` — encodes a uniform-pixel-value
//     grayscale image (all pixels = `pixelValue`). The leaf carries
//     `predictor_offset = pixelValue`, `multiplier = 1`,
//     `predictor = Zero`, so every residual is 0 and the post-tree
//     codebook collapses to a 1-symbol prefix code (zero bits per
//     pixel). This trivially produces a valid spec-compliant
//     bitstream the decoder can round-trip.
//
//   ✅ `encodeGrayscale8` — encodes an 8-bit grayscale image of any
//     pixel content. Uses a 1-leaf tree with predictor=Gradient,
//     offset=0, multiplier=1; computes residuals from the gradient
//     prediction; builds a length-limited canonical Huffman from
//     the residual-token histogram and serialises it via the complex
//     prefix-code format.
//
//   ✅ `encodeRGB8` / `encodeRGBA8` — same pattern as the grayscale
//     path but with 3 (RGB) or 4 (RGB + alpha-as-extra) modular
//     channels. The histogram is pooled across all channels into
//     one shared codebook; libjxl's decoder iterates the channels
//     in order using a single shared `TokenStreamReader`.
//
//   ✅ `encodeGrayscale16` / `encodeRGB16` / `encodeRGBA16` — high-
//     bit-depth (9..16-bit) encoders for the medical-imaging-
//     primary use case. The bit depth is a parameter, so the same
//     entry point covers 10-bit, 12-bit, 14-bit and 16-bit content
//     by adjusting `BitDepth.bitsPerSample` + the predictor's
//     `sampleHi` clamp; pixels live in `[0, 2^bps - 1]`.
//
//   ✅ Multi-group encoding (>512²). `buildSections` automatically
//     splits each "too-big" channel into per-group rects and emits
//     the libjxl-shaped TOC: DC global + empty DC group sections
//     + empty AC global + one AC section per group. Per-group
//     residuals use rect-local edge fall-backs (matching the
//     decoder's per-rect decode loop), but the post-tree Huffman
//     codebook is a single global one built from the pooled
//     histogram across all groups + channels.
//
//   ✅ Wired through `JXLEncoder.encode(_:)` and `jxl-tool encode`
//     — the public entry points dispatch by `(pixelType, channels,
//     alphaChannels)` into the right `encode*` variant.
//
// **What's left**: lossy VarDCT (`Sources/JXLSwift/VarDCT/...`),
// tracked separately in ROADMAP.md. Lossless Modular is done.
//
//   ⏳ rANS path for `TokenStreamWriter` — ANSStreamEncoder is
//     buffered, but extras need to interleave with renorm words
//     in the bit stream.
//
// **Validation strategy**: encoder output is round-tripped through
// our decoder (byte-exact against `djxl` already), so a passing
// round-trip implies a spec-compliant bitstream.

import Foundation

package enum SpecModularEncoderError: Error, Sendable {
    case notImplemented(String)
    case unsupportedFrame(String)
}

package enum SpecModularEncoder {

    /// Encode a constant-pixel grayscale image (all pixels equal
    /// `pixelValue`) into a naked JXL codestream that round-trips
    /// through `JXLDecoder.decodeModular`. The simplest spec-compliant
    /// target — a useful first end-to-end validation that all the
    /// header / TOC / tree / codebook / GroupHeader writers wire up
    /// correctly.
    ///
    /// - Parameters:
    ///   - width: Image width in pixels. Must be ≥ 1 and ≤ 256 for
    ///     the small-mode SizeHeader fast path the encoder takes.
    ///   - height: Image height (same constraints).
    ///   - pixelValue: The constant 8-bit grayscale value every pixel
    ///     carries (0 ≤ value ≤ 255).
    package static func encodeConstantGrayscale(
        width: Int, height: Int, pixelValue: UInt8
    ) throws -> Data {
        precondition(width > 0 && height > 0)
        guard width <= 256 && height <= 256
              && width % 8 == 0 && height % 8 == 0 else {
            throw SpecModularEncoderError.unsupportedFrame(
                "encodeConstantGrayscale currently requires "
                + "8 ≤ width,height ≤ 256 and both multiples of 8 "
                + "(matches SizeHeader small-mode path)"
            )
        }
        // 1. Build the section-0 body in a separate BitWriter so we
        //    can measure its byte size before emitting the TOC.
        var sec = BitWriter()
        // 1a. matrices_dc_default = 1 (no custom DC matrices).
        sec.writeBit(true)
        // 1b. has_tree = 1 (we emit a global tree). With a default
        //     1-leaf tree everything else flows through the global
        //     tree + global codebook reused by the per-group section.
        //     But for single-group, "section 0" IS the only section,
        //     so the GroupHeader and pixel data follow inline.
        sec.writeBit(true)
        // 1c. Tree section: header + codebook + tree tokens.
        //     Tree has 1 leaf (predictor=Zero, offset=pixelValue,
        //     multiplier=1). The tree token stream contains 5 tokens
        //     across contexts 1..5; ctx 3 emits `pack(pixelValue)`
        //     which can be up to 510 (for pixel=255). All 6 contexts
        //     route to a single cluster; the HybridUintConfig below
        //     keeps the token alphabet small.
        // HybridUintConfig(splitExponent=0): only value 0 is a direct
        // token; non-zero values split as `token = 1 + n` (where n =
        // floor(log2(value))) plus `n` extra raw bits. This keeps
        // the tree's token alphabet tiny — for any 8-bit pixelValue
        // the worst case `pack(255) = 510` has `n = 8` ⇒ token = 9.
        // Without this the alphabet grows to 512 symbols, blowing
        // up the prefix-code-table size with all-9-bit codes.
        let treeUintCfg = HybridUintConfig(
            splitExponent: 0, msbInToken: 0, lsbInToken: 0
        )
        // Tree-token alphabet padded to 16 with a flat 4-bit Huffman
        // (Kraft = 16 × 1/16 = 1). Fits any token ≤ 9 from the
        // encoded tree above.
        let treeAlphabet = 16
        let treeLengths: [UInt8] = Array(repeating: 4, count: treeAlphabet)
        let treeTable = try PrefixCodeTable(lengths: treeLengths)
        let treeCodebook = MultiClusterCodebook(
            huffmanTables: [treeTable], ansCounts: [],
            alphabetSizes: [treeAlphabet]
        )
        let treeHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: 6),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [treeUintCfg]
        )
        try treeHeader.write(to: &sec, numContexts: 6)
        try treeCodebook.write(to: &sec, header: treeHeader)
        // Emit the tree tokens.
        let tree = ModularTree(nodes: [
            ModularTreeNode(
                property: -1, splitVal: 0,
                leftChildOrLeafId: 0, rightChild: 0,
                predictor: .zero,
                predictorOffset: Int64(pixelValue),
                multiplier: 1,
                rawPredictor: 0
            )
        ])
        let treeWriter = TokenStreamWriter(
            header: treeHeader, codebook: treeCodebook
        )
        try tree.encode { ctx, val in
            try treeWriter.writeToken(context: ctx, value: val, to: &sec)
        }
        // 1d. Post-tree section: 1-cluster codebook for the leaf.
        //     The leaf emits residual=0 → token=0 → single-symbol
        //     prefix code (zero bits).
        let postHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: 1),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [HybridUintConfig.defaultConfig]
        )
        let postLeafTable = try PrefixCodeTable(lengths: [0])
        let postCodebook = MultiClusterCodebook(
            huffmanTables: [postLeafTable], ansCounts: [],
            alphabetSizes: [1]
        )
        try postHeader.write(to: &sec, numContexts: 1)
        try postCodebook.write(to: &sec, header: postHeader)
        // 1e. GroupHeader (default: useGlobalTree=true, wp default,
        //     no transforms).
        try GroupHeader.default.write(to: &sec)
        // 1f. Pixel data: width*height tokens, all value 0, all 0
        //     bits per token (single-symbol Huffman).
        // ⇒ NO BITS to emit for the pixel data body.
        // Section 0 must end on a byte boundary (TOC entry sizes
        // are bytes). Pad with zeros.
        sec.alignToByte()
        let sec0Data = sec.finishToData()
        let sec0Bytes = sec0Data.count

        // 2. Build the outer codestream. Reserve ~the section size + a small
        // header margin so the byte buffer doesn't repeatedly geometric-grow
        // (semantically identical — reservation never changes emitted bytes).
        var w = BitWriter(reservingBytes: sec0Bytes + 4096)
        // Signature 0xFF 0x0A.
        w.write(bits: 8, value: 0xFF)
        w.write(bits: 8, value: 0x0A)
        // SizeHeader.
        try SizeHeader(
            xsize: UInt32(width), ysize: UInt32(height)
        ).write(to: &w)
        // ImageMetadata: 8-bit grayscale.
        let meta = ImageMetadata(
            allDefault: false, orientation: 1,
            intrinsicSize: nil, preview: nil, animation: nil,
            bitDepth: BitDepth(floatingPoint: false, bitsPerSample: 8),
            modular16BitBufferSufficient: true,
            extraChannels: [],
            xybEncoded: false,
            colorEncoding: .grayscaleD65,
            intensityTarget: 255.0, minNits: 0.0,
            relativeToMaxDisplay: false, linearBelow: 0.0
        )
        try meta.write(to: &w)
        // CustomTransformData: a 1-bit all_default=1 marker (xyb_encoded
        // is false, so the opsin matrix branch is skipped and the
        // single bit is the entire payload). libjxl `image_metadata.cc::
        // CustomTransformData::VisitFields` reads this between
        // ImageMetadata and the JumpToByteBoundary that precedes the
        // FrameHeader (see libjxl `decode.cc:1014-1017`).
        w.writeBit(true)
        // Byte-align before FrameHeader (libjxl calls JumpToByteBoundary
        // after CustomTransformData).
        w.alignToByte()
        // FrameHeader: regular Modular frame, all defaults except
        // encoding.
        let fh = FrameHeader(
            allDefault: false,
            frameType: .regular, encoding: .modular,
            flags: 0, colorTransform: .none,
            chromaSubsampling: .default,
            upsampling: 1, extraChannelUpsampling: [],
            // libjxl's effort-7 cjxl pipeline chooses groupSizeShift=2
            // (group dim 512). Both 1 and 2 are valid for our 8x8..256²
            // single-group frames; matching cjxl's choice keeps bit-level
            // diffs against the reference smaller.
            groupSizeShift: 2,
            xQmScale: 2, bQmScale: 2,
            passes: .default, dcLevel: 0,
            customSizeOrOrigin: false,
            frameOrigin: (0, 0), frameSize: nil,
            blendingInfo: .default,
            extraChannelBlendingInfo: [],
            animationFrame: .default,
            isLast: true,
            saveAsReference: 0,
            saveBeforeColorTransform: true,
            name: "",
            // libjxl `enc_frame.cc::LoopFilterFromParams` forces
            // gab=false / epfIters=0 for Modular frames — neither match
            // the spec defaults, so we have to emit a non-default
            // LoopFilter explicitly.
            loopFilter: LoopFilter(
                allDefault: false, gab: false, epfIters: 0
            )
        )
        let ctx = FrameHeaderContext(
            xybEncoded: false, numExtraChannels: 0,
            haveAnimation: false, haveTimecodes: false
        )
        try fh.write(to: &w, context: ctx)
        // TOC: one entry sized to sec0Bytes.
        let toc = TOC(
            hasPermutation: false,
            entrySizes: [UInt32(sec0Bytes)],
            offsets: [0, UInt64(sec0Bytes)]
        )
        try toc.write(to: &w)
        // Append section 0 bytes (TOC.write byte-aligned at end).
        var out = w.finishToData()
        out.append(sec0Data)
        return out
    }

    /// Encode an 8-bit grayscale image of arbitrary content into a
    /// naked JXL codestream that round-trips through `djxl`.
    ///
    /// The encoded frame uses a 1-leaf MA-tree with `predictor =
    /// Gradient`, `offset = 0`, `multiplier = 1`. Per pixel, the
    /// encoder computes `residual = pixel - gradient_predict(W, N,
    /// NW)` from the *original* pixels (lossless prediction is
    /// idempotent over the full buffer), zig-zag packs that signed
    /// residual into a HybridUint token + extras, and emits the token
    /// via a length-limited canonical Huffman built from the
    /// residual-token histogram. Single-leaf alphabet cluster only —
    /// no per-context bucketing yet.
    ///
    /// - Parameters:
    ///   - width: Image width in pixels (8..256, multiple of 8).
    ///   - height: Image height (8..256, multiple of 8).
    ///   - pixels: Row-major pixel buffer of length `width * height`.
    package static func encodeGrayscale8(
        width: Int, height: Int, pixels: [UInt8],
        effort: Int = 9
    ) throws -> Data {
        try validateSize(width: width, height: height)
        guard pixels.count == width * height else {
            throw SpecModularEncoderError.unsupportedFrame(
                "pixels.count (\(pixels.count)) "
                + "≠ width*height (\(width * height))"
            )
        }
        let built = try buildSections(
            width: width, height: height,
            channels: [pixels.map { Int32($0) }],
            sampleHi: 255, effort: effort
        )
        return try writeOuterCodestream(
            width: width, height: height,
            bitsPerSample: 8,
            colorSpace: .grayscale, extraChannels: [], built: built
        )
    }

    /// Encode a high-bit-depth grayscale image (9..16-bit) of
    /// arbitrary content. Uses the same single-leaf Gradient tree as
    /// the 8-bit path. Targets medical-imaging callers where the
    /// extra dynamic range matters: 12-bit X-ray, 14-bit some MRI,
    /// 16-bit CT — all flow through this entry point.
    ///
    /// - Parameters:
    ///   - width: Image width in pixels (≤ 16384, any dimension).
    ///   - height: Image height (≤ 16384, any dimension).
    ///   - bitsPerSample: 9..16. Pixels must lie in
    ///     `[0, 2^bitsPerSample - 1]`. The codestream's
    ///     `BitDepth.bitsPerSample` records this exactly so a
    ///     downstream `djxl` decode emits samples in the matching
    ///     range.
    ///   - pixels: Row-major `UInt16` buffer of length
    ///     `width * height`.
    package static func encodeGrayscale16(
        width: Int, height: Int,
        bitsPerSample: UInt32 = 16,
        pixels: [UInt16],
        effort: Int = 9
    ) throws -> Data {
        try validateSize(width: width, height: height)
        try validateHighBitDepth(bitsPerSample)
        guard pixels.count == width * height else {
            throw SpecModularEncoderError.unsupportedFrame(
                "pixels.count (\(pixels.count)) "
                + "≠ width*height (\(width * height))"
            )
        }
        let sampleHi = Int32((Int64(1) << bitsPerSample) - 1)
        let built = try buildSections(
            width: width, height: height,
            channels: [pixels.map { Int32($0) }],
            sampleHi: sampleHi, effort: effort
        )
        return try writeOuterCodestream(
            width: width, height: height,
            bitsPerSample: bitsPerSample,
            colorSpace: .grayscale, extraChannels: [], built: built
        )
    }

    /// Encode an 8-bit grayscale-with-alpha image (2 channels: luma + a
    /// single alpha extra channel) into a naked JXL codestream that
    /// round-trips through `djxl`. Fills the 2-channel gap between the
    /// 1-channel grayscale and 3/4-channel RGB(A) encoders; the alpha
    /// extra channel is coded as an ordinary modular channel alongside
    /// luma, sharing the same per-image cost-gated tree + codebook.
    ///
    /// - Parameters:
    ///   - width: Image width (≤ 16384, any dimension).
    ///   - height: Image height (≤ 16384, any dimension).
    ///   - gray/alpha: Row-major `UInt8` buffers of length `width*height`.
    package static func encodeGrayscaleAlpha8(
        width: Int, height: Int,
        gray: [UInt8], alpha: [UInt8],
        effort: Int = 9
    ) throws -> Data {
        try validateSize(width: width, height: height)
        let n = width * height
        guard gray.count == n, alpha.count == n else {
            throw SpecModularEncoderError.unsupportedFrame(
                "grayscale+alpha pixel counts must each equal "
                + "width*height (\(n))"
            )
        }
        let alphaInfo = ExtraChannelInfo(
            type: .alpha,
            bitDepth: BitDepth(floatingPoint: false, bitsPerSample: 8),
            dimShift: 0, name: "", alphaAssociated: false
        )
        let built = try buildSections(
            width: width, height: height,
            channels: [gray, alpha].map { $0.map { Int32($0) } },
            sampleHi: 255, effort: effort
        )
        return try writeOuterCodestream(
            width: width, height: height,
            bitsPerSample: 8,
            colorSpace: .grayscale, extraChannels: [alphaInfo], built: built
        )
    }

    /// Encode a high-bit-depth grayscale-with-alpha image (9..16-bit luma
    /// + a single alpha extra channel inheriting `bitsPerSample`). The
    /// 16-bit analogue of `encodeGrayscaleAlpha8`; round-trips through
    /// `djxl`.
    ///
    /// - Parameters:
    ///   - width: Image width (≤ 16384, any dimension).
    ///   - height: Image height (≤ 16384, any dimension).
    ///   - bitsPerSample: 9..16. Sample range bound for both channels.
    ///   - gray/alpha: Row-major `UInt16` buffers of length `width*height`.
    package static func encodeGrayscaleAlpha16(
        width: Int, height: Int,
        bitsPerSample: UInt32 = 16,
        gray: [UInt16], alpha: [UInt16],
        effort: Int = 9
    ) throws -> Data {
        try validateSize(width: width, height: height)
        try validateHighBitDepth(bitsPerSample)
        let n = width * height
        guard gray.count == n, alpha.count == n else {
            throw SpecModularEncoderError.unsupportedFrame(
                "grayscale+alpha pixel counts must each equal "
                + "width*height (\(n))"
            )
        }
        let alphaInfo = ExtraChannelInfo(
            type: .alpha,
            bitDepth: BitDepth(
                floatingPoint: false, bitsPerSample: bitsPerSample
            ),
            dimShift: 0, name: "", alphaAssociated: false
        )
        let sampleHi = Int32((Int64(1) << bitsPerSample) - 1)
        let built = try buildSections(
            width: width, height: height,
            channels: [gray, alpha].map { $0.map { Int32($0) } },
            sampleHi: sampleHi, effort: effort
        )
        return try writeOuterCodestream(
            width: width, height: height,
            bitsPerSample: bitsPerSample,
            colorSpace: .grayscale, extraChannels: [alphaInfo], built: built
        )
    }

    /// Encode a high-bit-depth RGB image (9..16-bit per channel).
    /// Same pipeline as `encodeGrayscale16`, just three channels
    /// sharing one pooled-histogram Huffman codebook.
    ///
    /// - Parameters:
    ///   - width: Image width (≤ 16384, any dimension).
    ///   - height: Image height (≤ 16384, any dimension).
    ///   - bitsPerSample: 9..16. Per-channel sample range bound.
    ///   - r/g/b: Row-major `UInt16` buffers of length
    ///     `width * height`.
    package static func encodeRGB16(
        width: Int, height: Int,
        bitsPerSample: UInt32 = 16,
        r: [UInt16], g: [UInt16], b: [UInt16],
        effort: Int = 9
    ) throws -> Data {
        try validateSize(width: width, height: height)
        try validateHighBitDepth(bitsPerSample)
        let n = width * height
        guard r.count == n, g.count == n, b.count == n else {
            throw SpecModularEncoderError.unsupportedFrame(
                "RGB16 pixel counts must each equal width*height (\(n))"
            )
        }
        let sampleHi = Int32((Int64(1) << bitsPerSample) - 1)
        let built = try buildSections(
            width: width, height: height,
            channels: [r, g, b].map { $0.map { Int32($0) } },
            sampleHi: sampleHi, effort: effort
        )
        return try writeOuterCodestream(
            width: width, height: height,
            bitsPerSample: bitsPerSample,
            colorSpace: .rgb, extraChannels: [], built: built
        )
    }

    /// Encode a high-bit-depth RGBA image (9..16-bit per channel)
    /// with a 16-bit alpha extra channel.
    package static func encodeRGBA16(
        width: Int, height: Int,
        bitsPerSample: UInt32 = 16,
        r: [UInt16], g: [UInt16], b: [UInt16], a: [UInt16],
        effort: Int = 9
    ) throws -> Data {
        try validateSize(width: width, height: height)
        try validateHighBitDepth(bitsPerSample)
        let n = width * height
        guard r.count == n, g.count == n, b.count == n, a.count == n else {
            throw SpecModularEncoderError.unsupportedFrame(
                "RGBA16 pixel counts must each equal width*height (\(n))"
            )
        }
        // libjxl reads each extra channel's bit depth from its
        // `ExtraChannelInfo`. To stay consistent with the colour
        // channels (and avoid the surprising case of 16-bit colour
        // with 8-bit alpha), the alpha extra channel inherits
        // `bitsPerSample`.
        let alpha = ExtraChannelInfo(
            type: .alpha,
            bitDepth: BitDepth(
                floatingPoint: false, bitsPerSample: bitsPerSample
            ),
            dimShift: 0, name: "", alphaAssociated: false
        )
        let sampleHi = Int32((Int64(1) << bitsPerSample) - 1)
        let built = try buildSections(
            width: width, height: height,
            channels: [r, g, b, a].map { $0.map { Int32($0) } },
            sampleHi: sampleHi, effort: effort
        )
        return try writeOuterCodestream(
            width: width, height: height,
            bitsPerSample: bitsPerSample,
            colorSpace: .rgb, extraChannels: [alpha], built: built
        )
    }

    /// Reject bit depths outside the high-bit-depth integer range
    /// our encoders accept (anything ≤ 8 should use the `*8`
    /// entries). The libjxl decoder accepts 1..32 for integer
    /// samples but our pipeline only buffers up to 16-bit (UInt16).
    private static func validateHighBitDepth(
        _ bitsPerSample: UInt32
    ) throws {
        guard (9...16).contains(bitsPerSample) else {
            throw SpecModularEncoderError.unsupportedFrame(
                "high-bit-depth encoder accepts bitsPerSample 9..16; "
                + "got \(bitsPerSample). Use encode*8 for ≤ 8-bit."
            )
        }
    }

    /// Encode an 8-bit RGB image into a naked JXL codestream that
    /// round-trips through `djxl`. Layout: three independent
    /// gradient-predicted modular channels (R, G, B) sharing one
    /// length-limited canonical Huffman codebook built from their
    /// combined residual-token histogram.
    ///
    /// - Parameters:
    ///   - width: Image width in pixels (8..256, multiple of 8).
    ///   - height: Image height (8..256, multiple of 8).
    ///   - r/g/b: Per-channel row-major pixel buffers, each of length
    ///     `width * height`.
    package static func encodeRGB8(
        width: Int, height: Int,
        r: [UInt8], g: [UInt8], b: [UInt8],
        effort: Int = 9
    ) throws -> Data {
        try validateSize(width: width, height: height)
        let n = width * height
        guard r.count == n, g.count == n, b.count == n else {
            throw SpecModularEncoderError.unsupportedFrame(
                "RGB pixel counts must each equal width*height (\(n))"
            )
        }
        let built = try buildSections(
            width: width, height: height,
            channels: [r, g, b].map { $0.map { Int32($0) } },
            sampleHi: 255, effort: effort
        )
        return try writeOuterCodestream(
            width: width, height: height,
            bitsPerSample: 8,
            colorSpace: .rgb, extraChannels: [], built: built
        )
    }

    /// Encode an 8-bit RGBA image. Layout: same as `encodeRGB8`,
    /// plus a 4th modular channel carrying alpha. The alpha extra
    /// channel is declared as the spec-default `.alpha` /
    /// 8-bit-int / dim_shift=0 / non-premultiplied / no name.
    ///
    /// - Parameters:
    ///   - width: Image width (8..256, multiple of 8).
    ///   - height: Image height (8..256, multiple of 8).
    ///   - r/g/b/a: Per-channel row-major buffers of length `width *
    ///     height`. `a == 255` is fully opaque.
    package static func encodeRGBA8(
        width: Int, height: Int,
        r: [UInt8], g: [UInt8], b: [UInt8], a: [UInt8],
        effort: Int = 9
    ) throws -> Data {
        try validateSize(width: width, height: height)
        let n = width * height
        guard r.count == n, g.count == n, b.count == n, a.count == n else {
            throw SpecModularEncoderError.unsupportedFrame(
                "RGBA pixel counts must each equal width*height (\(n))"
            )
        }
        let alpha = ExtraChannelInfo(
            type: .alpha, bitDepth: .standard,
            dimShift: 0, name: "", alphaAssociated: false
        )
        let built = try buildSections(
            width: width, height: height,
            channels: [r, g, b, a].map { $0.map { Int32($0) } },
            sampleHi: 255, effort: effort
        )
        return try writeOuterCodestream(
            width: width, height: height,
            bitsPerSample: 8,
            colorSpace: .rgb, extraChannels: [alpha], built: built
        )
    }

    /// Multi-section TOC payload: one Data per logical TOC entry.
    /// Layout follows libjxl `NumTocEntries`:
    ///   - `[DC global, DC groups…, AC global, AC groups…]` (length
    ///     `2 + numDcGroups + numGroups` for multi-group frames)
    ///   - or just `[whole frame]` (length 1) for the
    ///     `numGroups == 1 && numPasses == 1` fast path.
    struct EncodedSections {
        let groupSizeShift: UInt32
        let sections: [Data]
    }

    /// Build the codestream sections for an N-channel single-pass
    /// modular frame. Picks `groupSizeShift = 2` (group_dim=512). If
    /// the image fits inside one group, returns the single-section
    /// fast path; otherwise splits each "too-big" channel into per-
    /// group rects and emits one AC section per group.
    /// `sampleHi` is the inclusive upper bound on the sample range —
    /// 255 for 8-bit, 65535 for 16-bit.
    private static func buildSections(
        width: Int, height: Int,
        channels: [[Int32]], sampleHi: Int32,
        effort: Int = 9
    ) throws -> EncodedSections {
        let groupSizeShift: UInt32 = 2
        let groupDim = 128 << Int(groupSizeShift)   // 512
        let numGroupsX = (width + groupDim - 1) / groupDim
        let numGroupsY = (height + groupDim - 1) / groupDim
        let numGroups = numGroupsX * numGroupsY
        // libjxl `frame_dimensions.h`: dc_group_dim = group_dim *
        // kBlockDim (=8). For our currently-modest 8K cap that's
        // dcGroupDim ≥ 4096 > image size, so always 1 DC group.
        let dcGroupDim = groupDim << 3
        let numDcGroupsX = (width + dcGroupDim - 1) / dcGroupDim
        let numDcGroupsY = (height + dcGroupDim - 1) / dcGroupDim
        let numDcGroups = numDcGroupsX * numDcGroupsY

        if numGroups == 1 {
            let sec0 = try buildSingleSection(
                width: width, height: height,
                channels: channels, sampleHi: sampleHi, effort: effort
            )
            return EncodedSections(
                groupSizeShift: groupSizeShift, sections: [sec0]
            )
        }

        // Multi-group path. Compute residuals + pool histogram across
        // every (channel, group) rect, build the global Huffman, then
        // emit (1) DC global with the global tree + codebook, (2) one
        // empty section per DC group, (3) an empty AC global, (4) one
        // AC section per group with that group's per-channel rect
        // pixel data.
        let postCfg = HybridUintConfig.raw4
        // Per-(group,channel) residuals for one predictor, pooled into a
        // histogram. WP runs **per rect** (fresh state per group), matching
        // the decoder's independent per-group decode; gradient resolves
        // edge fall-backs against the rect. `flat` lists every group-channel
        // token run for the codebook cost-gate.
        func residuals(useWP: Bool)
            -> (perGroup: [[[UInt32]]], flatSymbols: [[UInt16]],
                histo: [Int], alphabetSize: Int, totalExtraNBits: Int) {
            // Every (channel, group) rect is an independent prediction
            // stream (WP state is per rect, matching the decoder) — run
            // them concurrently and merge in the channel-major slot
            // order the sequential loop produced. Histogram summing and
            // extra-bit totals are order-independent.
            struct RectOut: Sendable {
                let packed: [UInt32]
                let symbols: [UInt16]
                let histo: [Int]
                let maxTok: Int
                let extraNBits: Int
            }
            let chCount = channels.count
            let slots = parallelMap(chCount * numGroups) {
                (slot: Int) -> RectOut in
                let ci = slot / numGroups
                let gi = slot % numGroups
                let gy = gi / numGroupsX, gx = gi % numGroupsX
                let pix = channels[ci]
                let rectX0 = gx * groupDim, rectY0 = gy * groupDim
                let rectW = min(groupDim, width - rectX0)
                let rectH = min(groupDim, height - rectY0)
                var rect = [Int32](repeating: 0, count: rectW * rectH)
                for ry in 0..<rectH {
                    let s = (rectY0 + ry) * width + rectX0
                    for rx in 0..<rectW { rect[ry * rectW + rx] = pix[s + rx] }
                }
                var packed = [UInt32]()
                packed.reserveCapacity(rectW * rectH)
                var symbols = [UInt16]()
                symbols.reserveCapacity(rectW * rectH)
                var histo = [Int](repeating: 0, count: postCfg.maxToken + 1)
                var maxTok = 0
                var extraNBits = 0
                if useWP {
                    var wp = WeightedPredictor(
                        header: .default, xsize: max(1, rectW))
                    for ry in 0..<rectH {
                        for rx in 0..<rectW {
                            let nbh = Neighbourhood(at: rx, ry, in: rect, width: rectW)
                            let pred = wp.predict(
                                x: rx, y: ry, xsize: rectW,
                                n: nbh.n, w: nbh.w, ne: nbh.ne, nw: nbh.nw, nn: nbh.nn)
                            let actual = rect[ry * rectW + rx]
                            let p = ZigZag.pack(actual &- pred)
                            let exp = postCfg.encode(p)
                            let t = Int(exp.token)
                            histo[t] += 1; if t > maxTok { maxTok = t }
                            packed.append(p)
                            symbols.append(UInt16(truncatingIfNeeded: exp.token))
                            extraNBits += exp.extraNBits
                            wp.update(actual: actual, x: rx, y: ry, xsize: rectW)
                        }
                    }
                } else {
                    for ry in 0..<rectH {
                        for rx in 0..<rectW {
                            let nbh = Neighbourhood(at: rx, ry, in: rect, width: rectW)
                            let pred = Predictor.gradient.apply(to: nbh, lo: 0, hi: sampleHi)
                            let p = ZigZag.pack(rect[ry * rectW + rx] &- pred)
                            let exp = postCfg.encode(p)
                            let t = Int(exp.token)
                            histo[t] += 1; if t > maxTok { maxTok = t }
                            packed.append(p)
                            symbols.append(UInt16(truncatingIfNeeded: exp.token))
                            extraNBits += exp.extraNBits
                        }
                    }
                }
                return RectOut(packed: packed, symbols: symbols,
                               histo: histo, maxTok: maxTok,
                               extraNBits: extraNBits)
            }
            var perGroup: [[[UInt32]]] = Array(
                repeating: Array(repeating: [], count: chCount),
                count: numGroups)
            var flatSymbols: [[UInt16]] = []
            flatSymbols.reserveCapacity(slots.count)
            var fullHisto = [Int](repeating: 0, count: postCfg.maxToken + 1)
            var maxTok = 0
            var totalExtraNBits = 0
            for slot in 0..<slots.count {
                let out = slots[slot]
                let ci = slot / numGroups
                let gi = slot % numGroups
                perGroup[gi][ci] = out.packed
                flatSymbols.append(out.symbols)
                for t in 0...out.maxTok where out.histo[t] > 0 {
                    fullHisto[t] += out.histo[t]
                }
                if out.maxTok > maxTok { maxTok = out.maxTok }
                totalExtraNBits += out.extraNBits
            }
            return (perGroup, flatSymbols, Array(fullHisto[0..<(maxTok + 1)]),
                    maxTok + 1, totalExtraNBits)
        }
        // Cost-gate predictor × entropy (same lever as single-section).
        let grad = residuals(useWP: false)
        let gradBest = try bestModularPostCodebook(
            histo: grad.histo, alphabetSize: grad.alphabetSize,
            postCfg: postCfg, symbolsPerChannel: grad.flatSymbols,
            totalExtraNBits: grad.totalExtraNBits)
        let wp = residuals(useWP: true)
        let wpBest = try bestModularPostCodebook(
            histo: wp.histo, alphabetSize: wp.alphabetSize,
            postCfg: postCfg, symbolsPerChannel: wp.flatSymbols,
            totalExtraNBits: wp.totalExtraNBits)
        let useWP = wpBest.bits < gradBest.bits
        let chosen = useWP ? wpBest : gradBest
        let postHeader = chosen.header
        let postCodebook = chosen.codebook
        let postUsePrefix = chosen.usePrefix
        let perGroupPerChannelPacked = useWP ? wp.perGroup : grad.perGroup
        let rawPredictor: UInt32 = useWP ? 6 : 5

        // DC global section: matrices_dc, has_tree, tree+codebook,
        // GroupHeader. No inline pixel data because all channels are
        // larger than groupDim in at least one axis (true whenever
        // the frame itself is multi-group).
        var dcGlobal = BitWriter()
        dcGlobal.writeBit(true)            // matrices_dc_default
        dcGlobal.writeBit(true)            // has_tree
        try writeGlobalTreeAndPostCodebook(
            to: &dcGlobal,
            postHeader: postHeader, postCodebook: postCodebook,
            rawPredictor: rawPredictor
        )
        try GroupHeader.default.write(to: &dcGlobal)
        dcGlobal.alignToByte()
        let dcGlobalData = dcGlobal.finishToData()

        // One empty section per DC group + one empty AC global. They
        // carry no Modular data; libjxl reports 0-byte TOC sizes here.
        let dcGroupEmpty = Data()
        let acGlobalEmpty = Data()

        // Per-group AC sections. Each group is an independent section
        // sharing the global post codebook (Huffman writes inline; rANS
        // emits one fresh interleaved stream per group, matching the
        // decoder's per-group TokenStreamReader) — emit concurrently,
        // collect in group (TOC) order.
        let chCount = channels.count
        let acResults = parallelMap(numGroups) {
            (groupIdx: Int) -> Result<Data, any Error> in
            Result {
                var sec = BitWriter()
                try GroupHeader.default.write(to: &sec)
                if postUsePrefix {
                    let postWriter = TokenStreamWriter(
                        header: postHeader, codebook: postCodebook)
                    for ci in 0..<chCount {
                        for v in perGroupPerChannelPacked[groupIdx][ci] {
                            try postWriter.writeToken(context: 0, value: v, to: &sec)
                        }
                    }
                } else {
                    var aw = try ANSTokenStreamWriter(
                        header: postHeader, codebook: postCodebook)
                    for ci in 0..<chCount {
                        for v in perGroupPerChannelPacked[groupIdx][ci] {
                            try aw.writeToken(context: 0, value: v)
                        }
                    }
                    try aw.finish(to: &sec)
                }
                sec.alignToByte()
                return sec.finishToData()
            }
        }
        var acSections = [Data]()
        acSections.reserveCapacity(numGroups)
        for r in acResults { acSections.append(try r.get()) }

        var singleSections = [Data]()
        singleSections.reserveCapacity(2 + numDcGroups + numGroups)
        singleSections.append(dcGlobalData)
        for _ in 0..<numDcGroups { singleSections.append(dcGroupEmpty) }
        singleSections.append(acGlobalEmpty)
        singleSections.append(contentsOf: acSections)

        // Candidates, smallest total wins (section count — hence TOC shape
        // — is identical, so summed payload bytes is the faithful gate):
        //  • single-context (above),
        //  • activity split — a global property-15 WP-activity tree in DC
        //    global, every AC group routed through a shared codebook,
        //  • greedy multi-property MA-tree — branches on whichever of the
        //    djxl-verified properties best separates residuals.
        func total(_ s: [Data]) -> Int { s.reduce(0) { $0 + $1.count } }
        var best = singleSections
        // Effort gates the extra cost-gated candidates (each is a full
        // encode): activity split at effort ≥ 4, greedy multi-property at
        // effort ≥ 8 (the costly learner rung — the default effort 7
        // keeps the activity split, whose ratio is within a fraction of
        // a percent on most natural content; efforts 8/9 buy
        // progressively larger learned trees). effort ≤ 3 ships the
        // single-context baseline only.
        if effort >= 4, let multi = try? buildSectionsMultiContext(
            width: width, height: height,
            channels: channels, sampleHi: sampleHi,
            numGroupsX: numGroupsX, numGroupsY: numGroupsY,
            numGroups: numGroups, numDcGroups: numDcGroups,
            groupDim: groupDim),
           total(multi) < total(best) {
            best = multi
        }
        if effort >= 8, let greedy = buildSectionsGreedyTree(
            width: width, height: height,
            channels: channels, sampleHi: sampleHi, effort: effort,
            numGroupsX: numGroupsX, numGroupsY: numGroupsY,
            numGroups: numGroups, numDcGroups: numDcGroups,
            groupDim: groupDim),
           total(greedy) < total(best) {
            best = greedy
        }
        return EncodedSections(
            groupSizeShift: groupSizeShift, sections: best
        )
    }

    /// Build a balanced property-15 (WP-error / local-activity) decision
    /// tree for an N-bin activity split from sorted, strictly-increasing
    /// thresholds: `thr.count` 1 → 2 bins, 3 → 4 bins, 7 → 8 bins.
    /// Returns the leaf count, a per-pixel context map mirroring the tree
    /// walk (property > split → leftChild), and the tree in the decoder's
    /// level-order fill layout (standard binary-heap indices: node `i`'s
    /// children at `2i+1`, `2i+2`). Leaf `k` = number of thresholds the
    /// value is ≤ (0 = highest activity). All leaves use WP (rawPredictor
    /// 6) since the property-15 split requires WP to be run. Returns `nil`
    /// for an unsupported `thr.count`. Shared by the single-section and
    /// multi-group multi-context paths so the layout lives in one place.
    private static func activitySplitTree(thresholds thr: [Int32])
        -> (n: Int, ctxOf: (Int32) -> Int, tree: ModularTree)? {
        func leaf(_ id: Int) -> ModularTreeNode {
            ModularTreeNode(property: -1, splitVal: 0,
                leftChildOrLeafId: id, rightChild: 0,
                predictor: .gradient, predictorOffset: 0,
                multiplier: 1, rawPredictor: 6)
        }
        func dec(_ s: Int32, _ l: Int, _ r: Int) -> ModularTreeNode {
            ModularTreeNode(property: 15, splitVal: s,
                leftChildOrLeafId: l, rightChild: r,
                predictor: .gradient, predictorOffset: 0,
                multiplier: 1, rawPredictor: 6)
        }
        switch thr.count {
        case 1:
            let t = thr[0]
            return (2, { $0 > t ? 0 : 1 },
                    ModularTree(nodes: [dec(t, 1, 2), leaf(0), leaf(1)]))
        case 3:
            let q1 = thr[0], q2 = thr[1], q3 = thr[2]
            return (4, { p in p > q2 ? (p > q3 ? 0 : 1) : (p > q1 ? 2 : 3) },
                    ModularTree(nodes: [
                        dec(q2, 1, 2), dec(q3, 3, 4), dec(q1, 5, 6),
                        leaf(0), leaf(1), leaf(2), leaf(3)]))
        case 7:
            let t1 = thr[0], t2 = thr[1], t3 = thr[2], t4 = thr[3]
            let t5 = thr[4], t6 = thr[5], t7 = thr[6]
            // Depth-3 balanced BST over t1<…<t7. Root splits on the
            // median t4; each subtree's decision threshold is its own
            // sub-range median, so the heap-ordered walk lands on the
            // right leaf for any value.
            let nodes = [
                dec(t4, 1, 2), dec(t6, 3, 4), dec(t2, 5, 6),
                dec(t7, 7, 8), dec(t5, 9, 10), dec(t3, 11, 12), dec(t1, 13, 14),
                leaf(0), leaf(1), leaf(2), leaf(3),
                leaf(4), leaf(5), leaf(6), leaf(7)]
            let ctxOf: (Int32) -> Int = { p in
                if p > t4 {
                    return p > t6 ? (p > t7 ? 0 : 1) : (p > t5 ? 2 : 3)
                } else {
                    return p > t2 ? (p > t3 ? 4 : 5) : (p > t1 ? 6 : 7)
                }
            }
            return (8, ctxOf, ModularTree(nodes: nodes))
        default:
            return nil
        }
    }

    /// Learned (entropy-minimising) WP-activity threshold sets for 2 / 4 /
    /// 8-bin splits, via **level-order recursive greedy splitting**. Each
    /// split picks the boundary that minimises the summed residual-token
    /// entropy of its two sides — a cheap, exact proxy for coded size that
    /// needs no trial encode. The fixed percentile sets (median / quartile
    /// / octile) are a poor fit when the smooth/active mix is skewed (a
    /// mostly flat scan with a small dense region); learned splits land on
    /// the distribution's real boundaries instead.
    ///
    /// Sorts the activity pairs once, then for each level splits every
    /// current range, tracking each side's running Σ count·log₂count so a
    /// boundary scores in O(1). Level *d* yields `2^d − 1` thresholds —
    /// 1 / 3 / 7 for 2 / 4 / 8 bins — which, sorted, feed `activitySplitTree`
    /// directly (greedy recursion produces a valid ordered partition).
    /// Returns one sorted set per depth that fully split with strictly
    /// increasing thresholds; stops early if a range can't be split.
    private static func learnedThresholdSets(
        pairs: [(wpProp: Int32, token: UInt32)],
        postCfg: HybridUintConfig, maxDepth: Int
    ) -> [[Int32]] {
        let n = pairs.count
        guard n >= 2, maxDepth >= 1 else { return [] }
        let sorted = pairs.sorted { $0.wpProp < $1.wpProp }
        let maxTok = postCfg.maxToken
        let toks = sorted.map { Int(postCfg.encode($0.token).token) }
        // Memoise `c·log₂c` (0…n): the recursive sweep updates running
        // Σ count·log₂count per pixel, so computing `log2` inline was hot.
        // Identical values, so the chosen thresholds are unchanged.
        var clogc = [Double](repeating: 0, count: n + 1)
        for c in 2...max(2, n) where c <= n {
            clogc[c] = Double(c) * log2(Double(c))
        }
        func term(_ c: Int) -> Double { clogc[c] }
        // Best entropy split of `sorted[lo..<hi]`: returns the first index
        // of the high side and the threshold (props ≤ it route low), or
        // `nil` if no interior split exists (singleton / all-equal range).
        func bestSplit(_ lo: Int, _ hi: Int) -> (cut: Int, thr: Int32)? {
            guard hi - lo >= 2 else { return nil }
            var hiCount = [Int](repeating: 0, count: maxTok + 1)
            var hiTotal = 0, hiS = 0.0
            for i in lo..<hi { hiCount[toks[i]] += 1; hiTotal += 1 }
            for c in hiCount where c > 1 { hiS += term(c) }
            var loCount = [Int](repeating: 0, count: maxTok + 1)
            var loTotal = 0, loS = 0.0
            var best: (cost: Double, cut: Int, thr: Int32)? = nil
            var i = lo
            while i < hi {
                let v = sorted[i].wpProp
                while i < hi && sorted[i].wpProp == v {
                    let tk = toks[i]
                    hiS -= term(hiCount[tk]); hiCount[tk] -= 1; hiS += term(hiCount[tk])
                    hiTotal -= 1
                    loS -= term(loCount[tk]); loCount[tk] += 1; loS += term(loCount[tk])
                    loTotal += 1
                    i += 1
                }
                if hiTotal > 0 {
                    let loCost = loTotal <= 1 ? 0 : clogc[loTotal] - loS
                    let hiCost = clogc[hiTotal] - hiS
                    let c = loCost + hiCost
                    if best == nil || c < best!.cost { best = (c, i, v) }
                }
            }
            guard let b = best else { return nil }
            return (b.cut, b.thr)
        }

        var sets: [[Int32]] = []
        var ranges = [(0, n)]
        var thresholds: [Int32] = []
        for _ in 0..<maxDepth {
            var next: [(Int, Int)] = []
            var ok = true
            for (lo, hi) in ranges {
                guard let (cut, thr) = bestSplit(lo, hi) else { ok = false; break }
                thresholds.append(thr)
                next.append((lo, cut)); next.append((cut, hi))
            }
            if !ok { break }
            ranges = next
            let s = thresholds.sorted()
            var strict = true
            for k in 1..<s.count where s[k] <= s[k - 1] { strict = false; break }
            if !strict { break }
            sets.append(s)
        }
        return sets
    }

    /// Analytically cost the multi-group section array for a given MA-tree
    /// + per-group `(context, packed-residual)` routing: the EXACT summed
    /// section bytes (DC global with tree + shared codebook, empty DC
    /// groups / AC global, and one byte-aligned AC section per group),
    /// with the Huffman-vs-rANS codebook gate decided analytically —
    /// Huffman streams are `Σ codeLen + extras`, rANS streams are
    /// `32 + 16·refills + extras` per fresh group stream. Returns the
    /// winning header/codebook and the total, or `nil` for a degenerate /
    /// unencodable routing. The caller emits only the winner
    /// (`emitMultiGroupSections`); totals equal assembled byte sums
    /// exactly, so candidate comparisons are unchanged.
    private static func costMultiGroupSections(
        tree: ModularTree, numContexts n: Int,
        perGroupOrdered: [[(ctx: Int, val: UInt32)]],
        numDcGroups: Int, postCfg: HybridUintConfig
    ) -> (bytes: Int, header: EntropySectionHeader,
          codebook: MultiClusterCodebook)? {
        let numGroups = perGroupOrdered.count
        guard n >= 1, numGroups >= 1 else { return nil }
        var histo = [[Int]](
            repeating: [Int](repeating: 0, count: postCfg.maxToken + 1), count: n)
        var maxTok = 0
        // One tokenisation pass: global histograms for codebook building,
        // plus per-group (cluster, symbol) sequences + extra-bit totals so
        // both candidates below are costed analytically and only the
        // winner is actually assembled.
        var groupSymbols = [[UInt16]](repeating: [], count: numGroups)
        var groupClusters = [[UInt8]](repeating: [], count: numGroups)
        var groupExtraNBits = [Int](repeating: 0, count: numGroups)
        for g in 0..<numGroups {
            let run = perGroupOrdered[g]
            var syms = [UInt16](repeating: 0, count: run.count)
            var cls = [UInt8](repeating: 0, count: run.count)
            var extra = 0
            for (i, t) in run.enumerated() {
                let exp = postCfg.encode(t.val)
                let tk = Int(exp.token)
                histo[t.ctx][tk] += 1
                if tk > maxTok { maxTok = tk }
                syms[i] = UInt16(truncatingIfNeeded: exp.token)
                cls[i] = UInt8(truncatingIfNeeded: t.ctx)
                extra += exp.extraNBits
            }
            groupSymbols[g] = syms
            groupClusters[g] = cls
            groupExtraNBits[g] = extra
        }
        for c in 0..<n where histo[c].reduce(0, +) == 0 { return nil }
        let alpha = maxTok + 1
        guard let ctxMap = try? ContextMap(
            numClusters: n, map: (0..<n).map { UInt8($0) }) else { return nil }
        let cfgs = Array(repeating: postCfg, count: n)

        // Per-AC-section constant: the GroupHeader bits that precede each
        // group's token stream (every section is byte-aligned after it).
        let groupHeaderBits: Int = {
            var w = BitWriter()
            try? GroupHeader.default.write(to: &w)
            return w.bitCount
        }()
        // Analytic total bytes for one candidate: the DC-global section
        // (tree + header + codebook — built for real, it has no per-pixel
        // content) + one byte-aligned AC section per group whose stream
        // bits are computed without emission (Huffman: Σ len + extras;
        // rANS: 32 + 16·refills + extras per fresh group stream).
        func analyticTotal(
            _ h: EntropySectionHeader, _ c: MultiClusterCodebook
        ) -> Int {
            var dcGlobal = BitWriter()
            dcGlobal.writeBit(true)
            dcGlobal.writeBit(true)
            do {
                try writeModularTreeSectionOnly(to: &dcGlobal, tree: tree)
                try h.write(to: &dcGlobal, numContexts: n)
                try c.write(to: &dcGlobal, header: h)
                try GroupHeader.default.write(to: &dcGlobal)
            } catch { return Int.max }
            dcGlobal.alignToByte()
            var total = dcGlobal.bitCount / 8
            if h.usePrefixCode {
                for g in 0..<numGroups {
                    var bits = groupHeaderBits + groupExtraNBits[g]
                    let syms = groupSymbols[g]
                    let cls = groupClusters[g]
                    for i in 0..<syms.count {
                        let len = Int(c.huffmanTables[Int(cls[i])]
                            .lengths[Int(syms[i])])
                        if len == 0 { return Int.max }
                        bits += len
                    }
                    total += (bits + 7) / 8
                }
            } else {
                guard let aw = try? ANSTokenStreamWriter(header: h, codebook: c)
                else { return Int.max }
                for g in 0..<numGroups {
                    guard let r = try? aw.refillWordCount(
                        symbols: groupSymbols[g], clusters: groupClusters[g])
                    else { return Int.max }
                    let bits = groupHeaderBits + 32 + 16 * r + groupExtraNBits[g]
                    total += (bits + 7) / 8
                }
            }
            return total
        }

        var candidates: [(EntropySectionHeader, MultiClusterCodebook)] = []
        do {
            let huffTables = try (0..<n).map { c in
                try PrefixCodeTable(lengths: lengthLimitedCanonicalHuffman(
                    counts: Array(histo[c][0..<alpha]), maxLength: 15,
                    alphabetSize: alpha))
            }
            let huffCodebook = MultiClusterCodebook(
                huffmanTables: huffTables, ansCounts: [],
                alphabetSizes: Array(repeating: alpha, count: n))
            let huffHeader = EntropySectionHeader(
                lz77: .disabled, contextMap: ctxMap,
                usePrefixCode: true, logAlphaSize: 15, uintConfigs: cfgs)
            candidates.append((huffHeader, huffCodebook))
        } catch { /* fall through to rANS */ }
        var wires: [[Int32]] = []
        var maxWire = 0
        var ansOK = true
        for c in 0..<n {
            guard let dist = try? ANSDistribution(
                rawFrequencies: histo[c][0..<alpha].map { UInt32(max(0, $0)) })
            else { ansOK = false; break }
            var scratch = BitWriter()
            guard let wire = try? SpecANSDistribution.writeHistogram(
                dist.frequencies.map { Int32($0) }, to: &scratch)
            else { ansOK = false; break }
            wires.append(wire); maxWire = max(maxWire, wire.count)
        }
        if ansOK {
            var logAlpha = 5
            while (1 << logAlpha) < maxWire && logAlpha < 8 { logAlpha += 1 }
            if maxWire <= (1 << logAlpha) {
                let ansHeader = EntropySectionHeader(
                    lz77: .disabled, contextMap: ctxMap,
                    usePrefixCode: false, logAlphaSize: logAlpha, uintConfigs: cfgs)
                let ansCodebook = MultiClusterCodebook(
                    huffmanTables: [], ansCounts: wires,
                    alphabetSizes: wires.map { $0.count })
                candidates.append((ansHeader, ansCodebook))
            }
        }
        // Cost both analytically (exact section-byte totals).
        // `min(by: <)` keeps the earlier candidate on a tie — Huffman
        // first, matching the previous assemble-both order.
        let costed = candidates
            .map { (cand: $0, total: analyticTotal($0.0, $0.1)) }
            .filter { $0.total != Int.max }
        guard let winner = costed.min(by: { $0.total < $1.total })
        else { return nil }
        return (winner.total, winner.cand.0, winner.cand.1)
    }

    /// Emit the multi-group section array a `costMultiGroupSections`
    /// result describes (DC global + empty DC groups + empty AC global +
    /// one AC section per group). Summed bytes equal the cost exactly.
    private static func emitMultiGroupSections(
        tree: ModularTree, numContexts n: Int,
        perGroupOrdered: [[(ctx: Int, val: UInt32)]],
        numDcGroups: Int,
        header h: EntropySectionHeader, codebook c: MultiClusterCodebook
    ) -> [Data]? {
        let numGroups = perGroupOrdered.count
        var dcGlobal = BitWriter()
        dcGlobal.writeBit(true)            // matrices_dc_default
        dcGlobal.writeBit(true)            // has_tree
        do {
            try writeModularTreeSectionOnly(to: &dcGlobal, tree: tree)
            try h.write(to: &dcGlobal, numContexts: n)
            try c.write(to: &dcGlobal, header: h)
            try GroupHeader.default.write(to: &dcGlobal)
        } catch { return nil }
        dcGlobal.alignToByte()
        var sections = [Data]()
        sections.reserveCapacity(2 + numDcGroups + numGroups)
        sections.append(dcGlobal.finishToData())
        for _ in 0..<numDcGroups { sections.append(Data()) }
        sections.append(Data())            // AC global, empty
        // Each AC group section is an independent bitstream sharing the
        // immutable header/codebook — emit them concurrently and append
        // in group order (the TOC order), so the codestream is
        // byte-identical to the sequential loop's.
        let groupSections = parallelMap(numGroups) { (g: Int) -> Data? in
            var sec = BitWriter()
            do {
                try GroupHeader.default.write(to: &sec)
                if h.usePrefixCode {
                    let tw = TokenStreamWriter(header: h, codebook: c)
                    for (ctx, v) in perGroupOrdered[g] {
                        try tw.writeToken(context: ctx, value: v, to: &sec)
                    }
                } else {
                    var aw = try ANSTokenStreamWriter(header: h, codebook: c)
                    aw.reserveCapacity(perGroupOrdered[g].count)
                    for (ctx, v) in perGroupOrdered[g] {
                        try aw.writeToken(context: ctx, value: v)
                    }
                    try aw.finish(to: &sec)
                }
            } catch { return nil }
            sec.alignToByte()
            return sec.finishToData()
        }
        for s in groupSections {
            guard let s else { return nil }
            sections.append(s)
        }
        return sections
    }

    /// Cost + emit in one step — used where there is a single candidate
    /// (the greedy-tree multi-group path).
    private static func assembleMultiGroupContextSections(
        tree: ModularTree, numContexts n: Int,
        perGroupOrdered: [[(ctx: Int, val: UInt32)]],
        numDcGroups: Int, postCfg: HybridUintConfig
    ) -> [Data]? {
        guard let cost = costMultiGroupSections(
            tree: tree, numContexts: n, perGroupOrdered: perGroupOrdered,
            numDcGroups: numDcGroups, postCfg: postCfg) else { return nil }
        return emitMultiGroupSections(
            tree: tree, numContexts: n, perGroupOrdered: perGroupOrdered,
            numDcGroups: numDcGroups, header: cost.header, codebook: cost.codebook)
    }

    /// Multi-context candidate for the multi-group path — the analogue of
    /// `buildSingleSectionMultiContext`, but the property-15 WP-activity
    /// tree + per-context codebook live once in the DC-global section and
    /// every AC group section routes its tokens through that shared
    /// codebook. WP runs fresh per rect (matching the decoder's
    /// independent per-group decode), so the per-pixel property 15 — hence
    /// the context — is computed identically on both sides. Thresholds are
    /// global (pooled across all rects), so one tree serves every group.
    ///
    /// Returns the full section array (DC global + empty DC groups + empty
    /// AC global + per-group AC sections), or `nil` for a degenerate split.
    /// The caller cost-gates total bytes against the single-context array.
    private static func buildSectionsMultiContext(
        width: Int, height: Int,
        channels: [[Int32]], sampleHi: Int32,
        numGroupsX: Int, numGroupsY: Int,
        numGroups: Int, numDcGroups: Int, groupDim: Int
    ) throws -> [Data]? {
        guard width > 0, height > 0, !channels.isEmpty else { return nil }
        let postCfg = HybridUintConfig.raw4

        // Per-rect WP pass. Record (wpProp, packed residual) per pixel,
        // grouped by group in channel-major / row-major order — the SAME
        // order the AC sections emit tokens. Pool every wpProp to choose
        // global percentile thresholds. `propertyValue` is read BEFORE
        // `predict`, matching the decoder.
        // Per-(channel, group) rects are independent WP streams — run
        // them concurrently and merge into each group's channel-major
        // pixel list (the AC sections' token order). `propertyValue` is
        // read BEFORE `predict` in each rect, matching the decoder.
        let chCount = channels.count
        let rectPixels = parallelMap(chCount * numGroups) {
            (slot: Int) -> [(wpProp: Int32, token: UInt32)] in
            let ci = slot / numGroups
            let gi = slot % numGroups
            let gy = gi / numGroupsX, gx = gi % numGroupsX
            let pix = channels[ci]
            let rectX0 = gx * groupDim, rectY0 = gy * groupDim
            let rectW = min(groupDim, width - rectX0)
            let rectH = min(groupDim, height - rectY0)
            var rect = [Int32](repeating: 0, count: rectW * rectH)
            for ry in 0..<rectH {
                let s = (rectY0 + ry) * width + rectX0
                for rx in 0..<rectW { rect[ry * rectW + rx] = pix[s + rx] }
            }
            var wp = WeightedPredictor(header: .default, xsize: max(1, rectW))
            var out: [(wpProp: Int32, token: UInt32)] = []
            out.reserveCapacity(rectW * rectH)
            for ry in 0..<rectH {
                for rx in 0..<rectW {
                    let nbh = Neighbourhood(at: rx, ry, in: rect, width: rectW)
                    let wpProp = wp.propertyValue(x: rx, y: ry, xsize: rectW)
                    let pred = wp.predict(
                        x: rx, y: ry, xsize: rectW,
                        n: nbh.n, w: nbh.w, ne: nbh.ne,
                        nw: nbh.nw, nn: nbh.nn)
                    let actual = rect[ry * rectW + rx]
                    out.append((wpProp, ZigZag.pack(actual &- pred)))
                    wp.update(actual: actual, x: rx, y: ry, xsize: rectW)
                }
            }
            return out
        }
        var perGroupPixels: [[(wpProp: Int32, token: UInt32)]] =
            Array(repeating: [], count: numGroups)
        var allProps: [Int32] = []
        allProps.reserveCapacity(width * height * chCount)
        for ci in 0..<chCount {
            for gi in 0..<numGroups {
                let run = rectPixels[ci * numGroups + gi]
                perGroupPixels[gi].append(contentsOf: run)
                for p in run { allProps.append(p.wpProp) }
            }
        }
        guard !allProps.isEmpty else { return nil }
        allProps.sort()
        func pct(_ p: Double) -> Int32 {
            allProps[min(allProps.count - 1,
                         max(0, Int(Double(allProps.count) * p)))]
        }

        // Cost one N-bin activity-split candidate: route each group's
        // tokens through `ctxOf` to per-group (context, token) pairs and
        // compute the exact summed section bytes analytically. Only the
        // winning candidate is emitted, at the end.
        typealias Candidate = (
            bytes: Int, tree: ModularTree, n: Int,
            perGroupOrdered: [[(ctx: Int, val: UInt32)]],
            header: EntropySectionHeader, codebook: MultiClusterCodebook)
        func costForThresholds(_ thr: [Int32]) -> Candidate? {
            guard let (n, ctxOf, tree) =
                activitySplitTree(thresholds: thr) else { return nil }
            let perGroupOrdered = perGroupPixels.map { group in
                group.map { (ctx: ctxOf($0.wpProp), val: $0.token) }
            }
            guard let cost = costMultiGroupSections(
                tree: tree, numContexts: n, perGroupOrdered: perGroupOrdered,
                numDcGroups: numDcGroups, postCfg: postCfg) else { return nil }
            return (cost.bytes, tree, n, perGroupOrdered,
                    cost.header, cost.codebook)
        }

        // Try fixed 2-bin (median), 4-bin (quartile) and 8-bin (octile)
        // splits plus a learned 2-bin split; keep the smallest (first wins
        // ties, preserving the old assemble-all ordering). The caller
        // cost-gates the winner against single-context. Fixed splits are
        // only attempted when their thresholds are strictly increasing
        // (else the tree is degenerate).
        var best: Candidate?
        func consider(_ c: Candidate?) {
            guard let c else { return }
            if best == nil || c.bytes < best!.bytes { best = c }
        }
        let median = pct(0.5)
        consider(costForThresholds([median]))
        let q1 = pct(0.25), q2 = pct(0.5), q3 = pct(0.75)
        if q1 < q2, q2 < q3 { consider(costForThresholds([q1, q2, q3])) }
        let oct = (1...7).map { pct(Double($0) / 8.0) }
        if zip(oct, oct.dropFirst()).allSatisfy({ $0 < $1 }) {
            consider(costForThresholds(oct))
        }
        // Learned (entropy-optimal) 2/4/8-bin splits, cost-gated alongside
        // the fixed percentile sets. Each is skipped when it matches the
        // fixed set of the same size (already tried above).
        for l in learnedThresholdSets(
            pairs: perGroupPixels.flatMap { $0 }, postCfg: postCfg, maxDepth: 3) {
            let isFixed = (l.count == 1 && l == [median])
                || (l.count == 3 && l == [q1, q2, q3])
                || (l.count == 7 && l == oct)
            if !isFixed { consider(costForThresholds(l)) }
        }
        guard let win = best else { return nil }
        return emitMultiGroupSections(
            tree: win.tree, numContexts: win.n,
            perGroupOrdered: win.perGroupOrdered,
            numDcGroups: numDcGroups,
            header: win.header, codebook: win.codebook)
    }

    /// Greedy multi-property MA-tree candidate for the **multi-group** path
    /// — the analogue of `buildSingleSectionGreedyTree`. Runs WP fresh per
    /// rect (matching the decoder's independent per-group decode), records
    /// the djxl-verified property subset `{4,5,9,10,12,15}` + the WP token
    /// per pixel (in per-group write order), **learns the tree from a
    /// uniform subsample** (bounding the learner's cost on large images),
    /// then routes every pixel through `ModularTree.walk` — the decoder's
    /// exact walk — so contexts agree by construction. The tree lives once
    /// in DC global; each AC group routes through the shared codebook.
    /// Size-gated to bound the per-pixel property memory. Returns `nil` if
    /// the image is too large or the learner finds no useful split.
    private static func buildSectionsGreedyTree(
        width: Int, height: Int,
        channels: [[Int32]], sampleHi: Int32, effort: Int = 9,
        numGroupsX: Int, numGroupsY: Int,
        numGroups: Int, numDcGroups: Int, groupDim: Int
    ) -> [Data]? {
        guard width > 0, height > 0, !channels.isEmpty else { return nil }
        let n = width * height * channels.count
        // Memory gate: 6 props/pixel are kept for routing (~24 B/px).
        // ≤ 16M px bounds that near ~400 MB — an opt-in cost at the
        // effort ≥ 8 rung this candidate now lives on, and it covers the
        // large medical plates (e.g. 4096²) the old 4M-px gate silently
        // excluded. Larger frames skip greedy (activity split applies).
        guard n <= 16_000_000 else { return nil }
        let postCfg = HybridUintConfig.raw4
        let propIndices: [Int32] = [4, 5, 9, 10, 12, 15]
        let propCount = propIndices.count

        var perGroupProps = [[Int32]](repeating: [], count: numGroups)
        var perGroupTokens = [[UInt32]](repeating: [], count: numGroups)
        // Uniform learning subsample (≤ ~256K pixels).
        let sampleStride = max(1, n / 256_000)
        var sampleProps: [Int32] = []
        var sampleTok: [Int] = []
        var sampleMaxTok = 0
        var globalIdx = 0
        var props16 = [Int32](repeating: 0, count: 16)

        for (ci, pix) in channels.enumerated() {
            for gy in 0..<numGroupsY {
                for gx in 0..<numGroupsX {
                    let rectX0 = gx * groupDim, rectY0 = gy * groupDim
                    let rectW = min(groupDim, width - rectX0)
                    let rectH = min(groupDim, height - rectY0)
                    var rect = [Int32](repeating: 0, count: rectW * rectH)
                    for ry in 0..<rectH {
                        let s = (rectY0 + ry) * width + rectX0
                        for rx in 0..<rectW { rect[ry * rectW + rx] = pix[s + rx] }
                    }
                    var wp = WeightedPredictor(
                        header: .default, xsize: max(1, rectW))
                    let gi = gy * numGroupsX + gx
                    for ry in 0..<rectH {
                        for rx in 0..<rectW {
                            // Decoder per-rect edge fall-backs (rect-relative).
                            let left: Int32 = rx > 0 ? rect[ry * rectW + rx - 1]
                                : (ry > 0 ? rect[(ry - 1) * rectW + rx] : 0)
                            let top: Int32 = ry > 0 ? rect[(ry - 1) * rectW + rx] : left
                            let topLeft: Int32 = (rx > 0 && ry > 0)
                                ? rect[(ry - 1) * rectW + rx - 1] : left
                            let topRight: Int32 = (rx + 1 < rectW && ry > 0)
                                ? rect[(ry - 1) * rectW + rx + 1] : top
                            let leftLeft: Int32 = rx > 1 ? rect[ry * rectW + rx - 2] : left
                            let topTop: Int32 = ry > 1 ? rect[(ry - 2) * rectW + rx] : top
                            let wpProp = wp.propertyValue(x: rx, y: ry, xsize: rectW)
                            fillModularProperties(
                                into: &props16, staticChannel: Int32(ci), groupId: 0,
                                x: Int32(rx), y: Int32(ry),
                                top: top, left: left, topLeft: topLeft,
                                topRight: topRight, leftLeft: leftLeft,
                                topTop: topTop, wpProperty: wpProp)
                            for k in 0..<propCount {
                                perGroupProps[gi].append(props16[Int(propIndices[k])])
                            }
                            let pred = wp.predict(
                                x: rx, y: ry, xsize: rectW,
                                n: top, w: left, ne: topRight, nw: topLeft, nn: topTop)
                            let actual = rect[ry * rectW + rx]
                            let tok = ZigZag.pack(actual &- pred)
                            perGroupTokens[gi].append(tok)
                            let tk = Int(postCfg.encode(tok).token)
                            if globalIdx % sampleStride == 0 {
                                for k in 0..<propCount {
                                    sampleProps.append(props16[Int(propIndices[k])])
                                }
                                sampleTok.append(tk)
                                if tk > sampleMaxTok { sampleMaxTok = tk }
                            }
                            wp.update(actual: actual, x: rx, y: ry, xsize: rectW)
                            globalIdx += 1
                        }
                    }
                }
            }
        }
        guard sampleTok.count >= 2 else { return nil }
        // Leaf budget by effort (16 at e8, 32 at e9) — see the
        // single-section greedy builder for why the old 8-leaf cap
        // (simple context-map path only) no longer applies.
        let maxLeaves = effort >= 9 ? 32 : 16
        guard let (tree, _, numCtx) = greedyTreeAndContexts(
            propsFlat: sampleProps, tokBucket: sampleTok,
            pixelCount: sampleTok.count, propIndices: propIndices,
            maxTok: sampleMaxTok, maxLeaves: maxLeaves, minGain: 32.0),
            numCtx >= 2 else { return nil }
        // Route every pixel through the decoder's own walk → per-group
        // (context, token) pairs in write order.
        var perGroupOrdered = [[(ctx: Int, val: UInt32)]](
            repeating: [], count: numGroups)
        for g in 0..<numGroups {
            let toks = perGroupTokens[g]
            let props = perGroupProps[g]
            var ordered = [(ctx: Int, val: UInt32)]()
            ordered.reserveCapacity(toks.count)
            for i in 0..<toks.count {
                let base = i * propCount
                for k in 0..<propCount { props16[Int(propIndices[k])] = props[base + k] }
                guard let leaf = try? tree.walk(properties: props16) else { return nil }
                ordered.append((leaf.leafId, toks[i]))
            }
            perGroupOrdered[g] = ordered
        }
        return assembleMultiGroupContextSections(
            tree: tree, numContexts: numCtx, perGroupOrdered: perGroupOrdered,
            numDcGroups: numDcGroups, postCfg: postCfg)
    }

    /// Write the global tree section + global post-tree codebook the
    /// DC global section carries when `has_tree = 1`. Same shape as
    /// the single-group path, factored out so multi-group reuses it.
    private static func writeGlobalTreeAndPostCodebook(
        to w: inout BitWriter,
        postHeader: EntropySectionHeader,
        postCodebook: MultiClusterCodebook,
        rawPredictor: UInt32 = 5
    ) throws {
        let treeUintCfg = HybridUintConfig(
            splitExponent: 0, msbInToken: 0, lsbInToken: 0
        )
        let treeAlphabet = 16
        let treeLengths: [UInt8] = Array(repeating: 4, count: treeAlphabet)
        let treeTable = try PrefixCodeTable(lengths: treeLengths)
        let treeCodebook = MultiClusterCodebook(
            huffmanTables: [treeTable], ansCounts: [],
            alphabetSizes: [treeAlphabet]
        )
        let treeHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: 6),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [treeUintCfg]
        )
        try treeHeader.write(to: &w, numContexts: 6)
        try treeCodebook.write(to: &w, header: treeHeader)
        let tree = ModularTree(nodes: [
            ModularTreeNode(
                property: -1, splitVal: 0,
                leftChildOrLeafId: 0, rightChild: 0,
                predictor: .gradient,    // enum field unused on wire
                predictorOffset: 0,
                multiplier: 1,
                rawPredictor: rawPredictor   // 5 = ClampedGradient, 6 = WP
            )
        ])
        let treeWriter = TokenStreamWriter(
            header: treeHeader, codebook: treeCodebook
        )
        try tree.encode { ctx, val in
            try treeWriter.writeToken(context: ctx, value: val, to: &w)
        }
        try postHeader.write(to: &w, numContexts: 1)
        try postCodebook.write(to: &w, header: postHeader)
    }

    /// Build the section-0 body for a single-group N-channel modular
    /// frame: matrices DC marker + has-tree marker + global Gradient
    /// tree + shared post-tree Huffman codebook + GroupHeader + each
    /// channel's Huffman-coded residual stream. The histogram is
    /// pooled across all channels (decoder uses one shared codebook).
    /// `sampleHi` is the inclusive upper bound on the channel sample
    /// range — 255 for 8-bit, 65535 for 16-bit. The Gradient
    /// predictor's clamp is irrelevant for it (output already lies in
    /// [min(W,N), max(W,N)] ⊆ sample range), but the parameter is
    /// passed through for symmetry.
    private static func buildSingleSection(
        width: Int, height: Int,
        channels: [[Int32]], sampleHi: Int32,
        effort: Int = 9
    ) throws -> Data {
        let postCfg = HybridUintConfig.raw4
        // Cost-gate the predictor (ClampedGradient=5 vs Weighted
        // Predictor=6) AND the entropy coder (Huffman vs rANS), picking
        // the combination that actually encodes smallest. WP adapts to
        // local structure where ClampedGradient under-predicts; rANS
        // lifts the ≥1 bit/symbol Huffman floor. Both are decisive for
        // the lossless ratio on structured medical data.
        //
        // Stage A — the up-to-three independent full-image passes run
        // concurrently: gradient residuals + gate, WP residuals + gate,
        // and (effort ≥ 4) the shared WP per-pixel property pass that
        // feeds both split candidates. Results are consumed in the old
        // sequential order, so surfaced errors and every selection are
        // unchanged.
        typealias Gate = (header: EntropySectionHeader,
                          codebook: MultiClusterCodebook,
                          usePrefix: Bool, bits: Int)
        typealias Resid = (packedPerChannel: [[UInt32]], histo: [Int],
                           alphabetSize: Int, symbolsPerChannel: [[UInt16]],
                           totalExtraNBits: Int)
        typealias Shared = (propsFlat: [Int32], tokens: [UInt32],
                            tokBucket: [Int], maxTok: Int)
        enum StageA: Sendable {
            case gate(Resid, Result<Gate, any Error>)
            case shared(Shared)
        }
        let stageA = parallelMap(effort >= 4 ? 3 : 2) { (i: Int) -> StageA in
            switch i {
            case 0, 1:
                let r = computeModularResiduals(
                    width: width, height: height, channels: channels,
                    sampleHi: sampleHi, postCfg: postCfg, useWP: i == 1)
                return .gate(r, Result { try bestModularPostCodebook(
                    histo: r.histo, alphabetSize: r.alphabetSize,
                    postCfg: postCfg, symbolsPerChannel: r.symbolsPerChannel,
                    totalExtraNBits: r.totalExtraNBits) })
            default:
                return .shared(wpGreedyPerPixel(
                    width: width, height: height,
                    channels: channels, postCfg: postCfg))
            }
        }
        guard case let .gate(grad, gradRes) = stageA[0],
              case let .gate(wp, wpRes) = stageA[1] else {
            throw SpecModularEncoderError.unsupportedFrame(
                "internal: stage layout")
        }
        let gradBest = try gradRes.get()
        let wpBest = try wpRes.get()
        let useWP = wpBest.bits < gradBest.bits
        let chosen = useWP ? wpBest : gradBest
        let postHeader = chosen.header
        let postCodebook = chosen.codebook
        let postUsePrefix = chosen.usePrefix
        let packedPerChannel = useWP
            ? wp.packedPerChannel : grad.packedPerChannel
        let rawPredictor: UInt32 = useWP ? 6 : 5

        // Baseline single-context emission (tree section + post codebook
        // + the winner's token stream). A @Sendable closure so stage B
        // can overlap it with the split candidates at effort ≥ 4.
        let emitBaseline: @Sendable () -> Result<Data, any Error> = {
            Result {
                var sec = BitWriter()
                sec.writeBit(true)            // matrices_dc_default
                sec.writeBit(true)            // has_tree
                // Tree section — 6 contexts, 16-symbol flat tree-token
                // alphabet. splitExponent=0 keeps any pack(rawPredictor=5)
                // inside the token range 0..3.
                let treeUintCfg = HybridUintConfig(
                    splitExponent: 0, msbInToken: 0, lsbInToken: 0
                )
                let treeAlphabet = 16
                let treeLengths: [UInt8] = Array(repeating: 4, count: treeAlphabet)
                let treeTable = try PrefixCodeTable(lengths: treeLengths)
                let treeCodebook = MultiClusterCodebook(
                    huffmanTables: [treeTable], ansCounts: [],
                    alphabetSizes: [treeAlphabet]
                )
                let treeHeader = EntropySectionHeader(
                    lz77: .disabled,
                    contextMap: ContextMap.trivial(numContexts: 6),
                    usePrefixCode: true, logAlphaSize: 15,
                    uintConfigs: [treeUintCfg]
                )
                try treeHeader.write(to: &sec, numContexts: 6)
                try treeCodebook.write(to: &sec, header: treeHeader)
                let tree = ModularTree(nodes: [
                    ModularTreeNode(
                        property: -1, splitVal: 0,
                        leftChildOrLeafId: 0, rightChild: 0,
                        predictor: .gradient,   // enum field unused on wire
                        predictorOffset: 0,
                        multiplier: 1,
                        rawPredictor: rawPredictor
                    )
                ])
                let treeWriter = TokenStreamWriter(
                    header: treeHeader, codebook: treeCodebook
                )
                try tree.encode { ctx, val in
                    try treeWriter.writeToken(context: ctx, value: val, to: &sec)
                }
                try postHeader.write(to: &sec, numContexts: 1)
                try postCodebook.write(to: &sec, header: postHeader)
                try GroupHeader.default.write(to: &sec)
                // All channels' residuals route through tree leaf 0
                // (context 0) and share the post codebook. Huffman writes
                // inline; rANS buffers the whole sub-image and emits one
                // interleaved stream — matching the decoder's single
                // `TokenStreamReader` for the modular sub-image.
                if postUsePrefix {
                    let postWriter = TokenStreamWriter(
                        header: postHeader, codebook: postCodebook)
                    for packed in packedPerChannel {
                        for v in packed {
                            try postWriter.writeToken(context: 0, value: v, to: &sec)
                        }
                    }
                } else {
                    var aw = try ANSTokenStreamWriter(
                        header: postHeader, codebook: postCodebook)
                    aw.reserveCapacity(width * height * channels.count)
                    for packed in packedPerChannel {
                        for v in packed { try aw.writeToken(context: 0, value: v) }
                    }
                    try aw.finish(to: &sec)
                }
                sec.alignToByte()
                return sec.finishToData()
            }
        }
        // Candidates, smallest wins (all byte-exact through djxl):
        //  • single-context baseline — always,
        //  • activity split — property-15 WP-activity bins (effort ≥ 4),
        //  • greedy multi-property MA-tree (effort ≥ 8 — the costly
        //    learner rung; ratio plateaus near the activity split for
        //    most natural content, so the default effort 7 skips it and
        //    efforts 8/9 buy progressively larger learned trees).
        // The extra candidates are full encodes gated by `effort`; both
        // consume the stage-A shared WP pass. Stage B runs the baseline
        // emission and the candidates concurrently; the size comparisons
        // happen afterwards in the old order, so output is unchanged.
        if effort < 4 {
            return try emitBaseline().get()
        }
        guard case let .shared(wpShared) = stageA[2] else {
            throw SpecModularEncoderError.unsupportedFrame(
                "internal: stage layout")
        }
        enum StageB: Sendable {
            case base(Result<Data, any Error>)
            case cand(Data?)
        }
        let stageB = parallelMap(effort >= 8 ? 3 : 2) { (i: Int) -> StageB in
            switch i {
            case 0:
                return .base(emitBaseline())
            case 1:
                let d = try? buildSingleSectionMultiContext(
                    width: width, height: height,
                    channels: channels, sampleHi: sampleHi,
                    precomputed: (wpShared.propsFlat, wpShared.tokens))
                return .cand(d ?? nil)
            default:
                return .cand(buildSingleSectionGreedyTree(
                    width: width, height: height,
                    channels: channels, sampleHi: sampleHi, effort: effort,
                    precomputed: wpShared))
            }
        }
        guard case let .base(baseRes) = stageB[0] else {
            throw SpecModularEncoderError.unsupportedFrame(
                "internal: stage layout")
        }
        var best = try baseRes.get()
        if case let .cand(multiData) = stageB[1], let multiData,
           multiData.count < best.count {
            best = multiData
        }
        if stageB.count > 2, case let .cand(greedyData) = stageB[2],
           let greedyData, greedyData.count < best.count {
            best = greedyData
        }
        return best
    }

    /// Write the tree section (6-context tree-token entropy section +
    /// codebook + the encoded tree) for an arbitrary `ModularTree`. The
    /// codebook is built from the **actual** tree tokens — the flat
    /// 16-symbol shortcut the trivial single-leaf path uses can't
    /// represent the larger tokens a property split + split-value
    /// produce. All 6 tree-decode contexts share one histogram.
    private static func writeModularTreeSectionOnly(
        to w: inout BitWriter, tree: ModularTree
    ) throws {
        let treeUintCfg = HybridUintConfig(
            splitExponent: 0, msbInToken: 0, lsbInToken: 0)
        var histo = [Int](repeating: 0, count: treeUintCfg.maxToken + 1)
        var maxTok = 0
        try tree.encode { _, val in
            let t = Int(treeUintCfg.encode(val).token)
            histo[t] += 1
            if t > maxTok { maxTok = t }
        }
        let alpha = max(2, maxTok + 1)
        let lens = lengthLimitedCanonicalHuffman(
            counts: Array(histo[0..<alpha]), maxLength: 15, alphabetSize: alpha)
        let treeTable = try PrefixCodeTable(lengths: lens)
        let treeCodebook = MultiClusterCodebook(
            huffmanTables: [treeTable], ansCounts: [], alphabetSizes: [alpha])
        let treeHeader = EntropySectionHeader(
            lz77: .disabled, contextMap: ContextMap.trivial(numContexts: 6),
            usePrefixCode: true, logAlphaSize: 15, uintConfigs: [treeUintCfg])
        try treeHeader.write(to: &w, numContexts: 6)
        try treeCodebook.write(to: &w, header: treeHeader)
        let treeWriter = TokenStreamWriter(
            header: treeHeader, codebook: treeCodebook)
        try tree.encode { ctx, val in
            try treeWriter.writeToken(context: ctx, value: val, to: &w)
        }
    }

    /// Assemble a complete single-section Modular body for a given MA-tree
    /// and per-pixel `(context, residual-token)` routing: `matrices_dc` +
    /// `has_tree` + the tree section + the post codebook (Huffman vs rANS,
    /// cost-gated by encoding both) + `GroupHeader` + the context-routed
    /// token stream. Shared by the activity-split and greedy multi-property
    /// paths. Returns `nil` for a degenerate / unencodable routing (an
    /// empty context, or a codebook that won't serialise).
    /// Analytically cost one multi-context single-section candidate:
    /// the EXACT total section bytes (matrices bits + tree section +
    /// entropy header + codebook + GroupHeader + token stream, byte-
    /// aligned) it would assemble to, plus the chosen post header /
    /// codebook — without emitting the token stream. The caller compares
    /// candidates by these byte counts (identical to comparing assembled
    /// `Data.count`s) and emits only the winner.
    private static func costMultiContextSection(
        tree: ModularTree, numContexts n: Int,
        ordered: [(ctx: Int, val: UInt32)], postCfg: HybridUintConfig
    ) -> (bytes: Int, header: EntropySectionHeader,
          codebook: MultiClusterCodebook)? {
        guard n >= 1, !ordered.isEmpty else { return nil }
        var histo = [[Int]](
            repeating: [Int](repeating: 0, count: postCfg.maxToken + 1), count: n)
        var maxTok = 0
        // One tokenisation pass: histograms for codebook building, plus
        // the expanded (cluster, symbol) sequence and extra-bit total the
        // analytic costing consumes. Contexts map to clusters via the
        // identity map this section shape always uses.
        var symbols = [UInt16](repeating: 0, count: ordered.count)
        var clusters = [UInt8](repeating: 0, count: ordered.count)
        var totalExtraNBits = 0
        for (i, t) in ordered.enumerated() {
            let exp = postCfg.encode(t.val)
            let tk = Int(exp.token)
            histo[t.ctx][tk] += 1
            if tk > maxTok { maxTok = tk }
            symbols[i] = UInt16(truncatingIfNeeded: exp.token)
            clusters[i] = UInt8(truncatingIfNeeded: t.ctx)
            totalExtraNBits += exp.extraNBits
        }
        for c in 0..<n where histo[c].reduce(0, +) == 0 { return nil }
        let alpha = maxTok + 1
        guard let ctxMap = try? ContextMap(
            numClusters: n, map: (0..<n).map { UInt8($0) }) else { return nil }
        let cfgs = Array(repeating: postCfg, count: n)
        // Everything before the token stream, measured with the real
        // writers on a scratch (no per-pixel content in any of it).
        func prefixBits(
            _ h: EntropySectionHeader, _ c: MultiClusterCodebook
        ) -> Int {
            var w = BitWriter()
            w.writeBit(true)           // matrices_dc_default
            w.writeBit(true)           // has_tree
            do {
                try writeModularTreeSectionOnly(to: &w, tree: tree)
                try h.write(to: &w, numContexts: n)
                try c.write(to: &w, header: h)
                try GroupHeader.default.write(to: &w)
            } catch { return Int.max }
            return w.bitCount
        }
        // Huffman candidate (one table per context). Exact stream size:
        // Σ histo[c][s]·codeLen[c][s] + Σ extraNBits.
        let huffTables: [PrefixCodeTable]
        do {
            huffTables = try (0..<n).map { c in
                try PrefixCodeTable(lengths: lengthLimitedCanonicalHuffman(
                    counts: Array(histo[c][0..<alpha]), maxLength: 15,
                    alphabetSize: alpha))
            }
        } catch { return nil }
        let huffCodebook = MultiClusterCodebook(
            huffmanTables: huffTables, ansCounts: [],
            alphabetSizes: Array(repeating: alpha, count: n))
        let huffHeader = EntropySectionHeader(
            lz77: .disabled, contextMap: ctxMap,
            usePrefixCode: true, logAlphaSize: 15, uintConfigs: cfgs)
        var best: (EntropySectionHeader, MultiClusterCodebook) =
            (huffHeader, huffCodebook)
        var bestBits = prefixBits(huffHeader, huffCodebook)
        if bestBits != Int.max {
            var streamBits = totalExtraNBits
            var ok = true
            outer: for c in 0..<n {
                let lens = huffTables[c].lengths
                for s in 0..<alpha where histo[c][s] > 0 {
                    if Int(lens[s]) == 0 { ok = false; break outer }
                    streamBits += histo[c][s] * Int(lens[s])
                }
            }
            bestBits = ok ? bestBits + streamBits : Int.max
        }
        // rANS candidate (one histogram per context). Exact stream size:
        // 32-bit init + 16 bits per refill + the extra bits, refills from
        // the bare reverse walk.
        var wires: [[Int32]] = []
        var maxWire = 0
        var ansOK = true
        for c in 0..<n {
            guard let dist = try? ANSDistribution(
                rawFrequencies: histo[c][0..<alpha].map { UInt32(max(0, $0)) })
            else { ansOK = false; break }
            var scratch = BitWriter()
            guard let wire = try? SpecANSDistribution.writeHistogram(
                dist.frequencies.map { Int32($0) }, to: &scratch)
            else { ansOK = false; break }
            wires.append(wire); maxWire = max(maxWire, wire.count)
        }
        if ansOK {
            var logAlpha = 5
            while (1 << logAlpha) < maxWire && logAlpha < 8 { logAlpha += 1 }
            if maxWire <= (1 << logAlpha) {
                let ansHeader = EntropySectionHeader(
                    lz77: .disabled, contextMap: ctxMap,
                    usePrefixCode: false, logAlphaSize: logAlpha,
                    uintConfigs: cfgs)
                let ansCodebook = MultiClusterCodebook(
                    huffmanTables: [], ansCounts: wires,
                    alphabetSizes: wires.map { $0.count })
                var b = prefixBits(ansHeader, ansCodebook)
                if b != Int.max,
                   let aw = try? ANSTokenStreamWriter(
                       header: ansHeader, codebook: ansCodebook),
                   let r = try? aw.refillWordCount(
                       symbols: symbols, clusters: clusters) {
                    b += 32 + 16 * r + totalExtraNBits
                } else {
                    b = Int.max
                }
                if b < bestBits { best = (ansHeader, ansCodebook); bestBits = b }
            }
        }
        guard bestBits != Int.max else { return nil }
        return ((bestBits + 7) / 8, best.0, best.1)
    }

    /// Emit the full section a `costMultiContextSection` result describes.
    /// Byte count equals the cost's `bytes` exactly.
    private static func emitMultiContextSection(
        tree: ModularTree, numContexts n: Int,
        ordered: [(ctx: Int, val: UInt32)],
        header postHeader: EntropySectionHeader,
        codebook postCodebook: MultiClusterCodebook
    ) -> Data? {
        var sec = BitWriter()
        sec.writeBit(true)            // matrices_dc_default
        sec.writeBit(true)            // has_tree
        do {
            try writeModularTreeSectionOnly(to: &sec, tree: tree)
            try postHeader.write(to: &sec, numContexts: n)
            try postCodebook.write(to: &sec, header: postHeader)
            try GroupHeader.default.write(to: &sec)
            if postHeader.usePrefixCode {
                let tw = TokenStreamWriter(header: postHeader, codebook: postCodebook)
                for (ctx, v) in ordered {
                    try tw.writeToken(context: ctx, value: v, to: &sec)
                }
            } else {
                var aw = try ANSTokenStreamWriter(header: postHeader, codebook: postCodebook)
                aw.reserveCapacity(ordered.count)
                for (ctx, v) in ordered { try aw.writeToken(context: ctx, value: v) }
                try aw.finish(to: &sec)
            }
        } catch { return nil }
        sec.alignToByte()
        return sec.finishToData()
    }

    /// Cost + emit in one step — used where there is a single candidate
    /// (the greedy-tree path), so the winner emission is the only one.
    private static func assembleMultiContextSection(
        tree: ModularTree, numContexts n: Int,
        ordered: [(ctx: Int, val: UInt32)], postCfg: HybridUintConfig
    ) -> Data? {
        guard let cost = costMultiContextSection(
            tree: tree, numContexts: n, ordered: ordered, postCfg: postCfg)
        else { return nil }
        return emitMultiContextSection(
            tree: tree, numContexts: n, ordered: ordered,
            header: cost.header, codebook: cost.codebook)
    }

    /// Multi-context single-section candidate: split residuals by the
    /// **WP-error property** (property 15 — local activity) into two
    /// contexts, each with its own histogram. Flat regions (low error)
    /// and active regions (high error) have very different residual
    /// distributions, so separating them beats one pooled histogram.
    /// Returns the full section bytes, or `nil` for a degenerate split.
    ///
    /// Both leaves use WP (rawPredictor 6); the property-15 decision node
    /// makes the decoder run WP to compute the property and walk the tree,
    /// so the encoder (which reuses the same `WeightedPredictor` +
    /// `propertyValue` in the decoder's order) assigns identical contexts.
    private static func buildSingleSectionMultiContext(
        width: Int, height: Int, channels: [[Int32]], sampleHi: Int32,
        precomputed: (propsFlat: [Int32], tokens: [UInt32])? = nil
    ) throws -> Data? {
        guard width > 0, height > 0, !channels.isEmpty else { return nil }
        let postCfg = HybridUintConfig.raw4
        // Per pixel (channel-major, row-major): the WP-activity property
        // (property 15) and the WP residual token. When the caller already
        // ran the shared WP pass (`wpGreedyPerPixel`, effort ≥ 4), reuse it —
        // property 15 is slot 5 of the 6-property block; this is byte-exactly
        // the same `(wpProp, token)` this builder used to compute inline.
        var perPixel: [(wpProp: Int32, token: UInt32)] = []
        perPixel.reserveCapacity(width * height * channels.count)
        if let pc = precomputed {
            let count = pc.tokens.count
            perPixel.reserveCapacity(count)
            for i in 0..<count {
                perPixel.append((pc.propsFlat[i * 6 + 5], pc.tokens[i]))
            }
        } else {
            // `propertyValue` is read BEFORE `predict`, matching the decoder.
            for pix in channels {
                var wp = WeightedPredictor(header: .default, xsize: max(1, width))
                for y in 0..<height {
                    for x in 0..<width {
                        let nbh = Neighbourhood(at: x, y, in: pix, width: width)
                        let wpProp = wp.propertyValue(x: x, y: y, xsize: width)
                        let pred = wp.predict(
                            x: x, y: y, xsize: width,
                            n: nbh.n, w: nbh.w, ne: nbh.ne, nw: nbh.nw, nn: nbh.nn)
                        let actual = pix[y * width + x]
                        perPixel.append((wpProp, ZigZag.pack(actual &- pred)))
                        wp.update(actual: actual, x: x, y: y, xsize: width)
                    }
                }
            }
        }
        guard !perPixel.isEmpty else { return nil }
        let sortedProps = perPixel.map { $0.wpProp }.sorted()
        func pct(_ p: Double) -> Int32 {
            sortedProps[min(sortedProps.count - 1,
                            max(0, Int(Double(sortedProps.count) * p)))]
        }

        // Cost one N-bin WP-activity split candidate (exact section bytes,
        // no emission). The tree is a balanced property-15 decision tree
        // in the decoder's fill layout; the per-pixel context mirrors the
        // tree walk (property > split → leftChild). The winner — and only
        // the winner — is emitted at the end.
        typealias Candidate = (
            bytes: Int, tree: ModularTree, n: Int,
            ordered: [(ctx: Int, val: UInt32)],
            header: EntropySectionHeader, codebook: MultiClusterCodebook)
        func costForThresholds(_ thr: [Int32]) -> Candidate? {
            guard let (n, ctxOf, tree) =
                activitySplitTree(thresholds: thr) else { return nil }
            var ordered: [(ctx: Int, val: UInt32)] = []
            ordered.reserveCapacity(perPixel.count)
            for (wpProp, tok) in perPixel { ordered.append((ctxOf(wpProp), tok)) }
            guard let cost = costMultiContextSection(
                tree: tree, numContexts: n, ordered: ordered, postCfg: postCfg)
            else { return nil }
            return (cost.bytes, tree, n, ordered, cost.header, cost.codebook)
        }

        // Try fixed 2-bin (median), 4-bin (quartile) and 8-bin (octile)
        // WP-activity splits plus a learned 2-bin split; keep whichever is
        // smallest (first wins ties, preserving the old assemble-all
        // ordering). The caller cost-gates against the single-context
        // section. Fixed splits are only attempted when their thresholds
        // are strictly increasing.
        var best: Candidate?
        func consider(_ c: Candidate?) {
            guard let c else { return }
            if best == nil || c.bytes < best!.bytes { best = c }
        }
        let median = pct(0.5)
        consider(costForThresholds([median]))
        let q1 = pct(0.25), q2 = pct(0.5), q3 = pct(0.75)
        if q1 < q2, q2 < q3 { consider(costForThresholds([q1, q2, q3])) }
        let oct = (1...7).map { pct(Double($0) / 8.0) }
        if zip(oct, oct.dropFirst()).allSatisfy({ $0 < $1 }) {
            consider(costForThresholds(oct))
        }
        // Learned (entropy-optimal) 2/4/8-bin splits, cost-gated alongside
        // the fixed percentile sets. Each is skipped when it matches the
        // fixed set of the same size (already tried above).
        for l in learnedThresholdSets(
            pairs: perPixel, postCfg: postCfg, maxDepth: 3) {
            let isFixed = (l.count == 1 && l == [median])
                || (l.count == 3 && l == [q1, q2, q3])
                || (l.count == 7 && l == oct)
            if !isFixed { consider(costForThresholds(l)) }
        }
        guard let win = best else { return nil }
        return emitMultiContextSection(
            tree: win.tree, numContexts: win.n, ordered: win.ordered,
            header: win.header, codebook: win.codebook)
    }

    /// Sorts the first `m` elements of `a` ascending (signed `Int64`) by LSD
    /// byte-radix, using `tmp` as ping-pong scratch and `counts` as a reusable
    /// 8×256 histogram block (all reused across calls — no allocation here).
    /// Produces exactly the order `Array.sort()` would: `Int64` is totally
    /// ordered and equal keys are interchangeable, so any consumer of the
    /// sorted values sees identical results. Passes whose byte is constant
    /// across the prefix are skipped (a stable counting pass over a constant
    /// byte is the identity permutation). The top byte is sign-biased so the
    /// unsigned bucket order matches signed order.
    private static func radixSortInt64Prefix(
        _ a: inout [Int64], tmp: inout [Int64], counts: inout [Int], count m: Int
    ) {
        guard m > 1 else { return }
        for i in 0..<(8 * 256) { counts[i] = 0 }
        a.withUnsafeBufferPointer { ap in
            counts.withUnsafeMutableBufferPointer { cp in
                for i in 0..<m {
                    let v = UInt64(bitPattern: ap[i])
                    cp[Int(v & 0xff)] += 1
                    cp[256 + Int((v >> 8) & 0xff)] += 1
                    cp[512 + Int((v >> 16) & 0xff)] += 1
                    cp[768 + Int((v >> 24) & 0xff)] += 1
                    cp[1024 + Int((v >> 32) & 0xff)] += 1
                    cp[1280 + Int((v >> 40) & 0xff)] += 1
                    cp[1536 + Int((v >> 48) & 0xff)] += 1
                    cp[1792 + Int(((v >> 56) & 0xff) ^ 0x80)] += 1
                }
            }
        }
        var offsets = [Int](repeating: 0, count: 256)
        var inA = true
        for pass in 0..<8 {
            let base = pass * 256
            // Constant byte ⇒ stable pass is the identity: skip it.
            var constant = false
            for b in 0..<256 where counts[base + b] == m { constant = true; break }
            if constant { continue }
            var running = 0
            for b in 0..<256 {
                offsets[b] = running
                running += counts[base + b]
            }
            let shift = UInt64(pass * 8)
            let isTop = pass == 7
            func scatter(_ src: UnsafeBufferPointer<Int64>,
                         _ dst: UnsafeMutableBufferPointer<Int64>) {
                offsets.withUnsafeMutableBufferPointer { op in
                    for i in 0..<m {
                        let e = src[i]
                        var byte = Int((UInt64(bitPattern: e) >> shift) & 0xff)
                        if isTop { byte ^= 0x80 }
                        dst[op[byte]] = e
                        op[byte] += 1
                    }
                }
            }
            if inA {
                a.withUnsafeBufferPointer { ap in
                    tmp.withUnsafeMutableBufferPointer { tp in scatter(ap, tp) }
                }
            } else {
                tmp.withUnsafeBufferPointer { tp in
                    a.withUnsafeMutableBufferPointer { ap in scatter(tp, ap) }
                }
            }
            inA.toggle()
        }
        if !inA {
            tmp.withUnsafeBufferPointer { tp in
                a.withUnsafeMutableBufferPointer { ap in
                    for i in 0..<m { ap[i] = tp[i] }
                }
            }
        }
    }

    /// Learn a greedy multi-property MA-tree (cjxl-style) from per-pixel
    /// property vectors + residual-token buckets. **Best-first** splitting:
    /// at each step the current leaf whose best `(property, threshold)`
    /// split yields the largest residual-token-entropy reduction is split,
    /// until the leaf budget is hit or no split clears `minGain`.
    /// `propsFlat[i*propCount + k]` is pixel `i`'s value of property
    /// `propIndices[k]` (an explicit, not-necessarily-contiguous list of
    /// libjxl property indices). The emitted decision nodes record the
    /// actual libjxl property index, and the per-pixel context mirrors
    /// `ModularTree.walk` (`property > split → leftChild`); the tree is
    /// linearised in the decoder's level-order (BFS) fill with leafIds in
    /// encounter order, so the decoder — computing the same properties and
    /// assigning leafIds the same way — agrees by construction. Returns
    /// `nil` if no split clears `minGain` (i.e. a single context).
    private static func greedyTreeAndContexts(
        propsFlat: [Int32], tokBucket: [Int],
        pixelCount n: Int, propIndices: [Int32],
        maxTok: Int, maxLeaves: Int, minGain: Double
    ) -> (tree: ModularTree, contexts: [Int], numContexts: Int)? {
        let propCount = propIndices.count
        guard n >= 2, propCount >= 1 else { return nil }

        // Memoise `c·log₂c` for every count that can occur (0…n). The
        // best-first sweep updates running Σ count·log₂count millions of
        // times; computing `log2` there dominated the encoder. Filling
        // this table costs n `log2` calls once instead. Values are
        // identical to `Double(c)*log2(Double(c))`, so output is unchanged.
        var clogc = [Double](repeating: 0, count: n + 1)
        for c in 2...max(2, n) where c <= n {
            clogc[c] = Double(c) * log2(Double(c))
        }
        func term(_ c: Int) -> Double { clogc[c] }
        func histCost(_ h: [Int], _ total: Int) -> Double {
            if total <= 1 { return 0 }
            var s = 0.0
            for c in h where c > 1 { s += clogc[c] }
            return clogc[total] - s
        }

        final class GNode {
            var idxs: [Int]
            var prop: Int32 = -1     // actual property index; -1 until split
            var split: Int32 = 0
            var left: GNode?
            var right: GNode?
            var bestK: Int = -1      // candidate position of best split prop
            var bestSplit: Int32 = 0
            var bestGain: Double = -1
            init(_ i: [Int]) { idxs = i }
        }

        // Scratch shared by every computeBest call (one allocation for the
        // whole learn instead of one per node × property — the sort buffer
        // alone is up to 2 MB per use at the 256 K-pixel subsample).
        var packedBuf = [Int64](repeating: 0, count: n)
        var radixBuf = [Int64](repeating: 0, count: n)
        var radixCounts = [Int](repeating: 0, count: 8 * 256)
        var loBuf = [Int](repeating: 0, count: maxTok + 1)

        // Cache the best (property, threshold) split for `node` by sweeping
        // each candidate property's activity-sorted order and tracking the
        // running Σ count·log₂count of each side (O(1) per boundary).
        func computeBest(
            _ node: GNode,
            _ packedBuf: inout [Int64], _ radixBuf: inout [Int64],
            _ radixCounts: inout [Int], _ loBuf: inout [Int]
        ) {
            node.bestGain = -1; node.bestK = -1
            let m = node.idxs.count
            if m < 2 { return }
            var nodeHist = [Int](repeating: 0, count: maxTok + 1)
            for i in node.idxs { nodeHist[tokBucket[i]] += 1 }
            let nodeCost = histCost(nodeHist, m)
            var nodeS = 0.0
            for c in nodeHist where c > 1 { nodeS += term(c) }
            for k in 0..<propCount {
                // Pack each pixel's (property value, token bucket) into one
                // Int64 — `key << 16 | tok` is monotonic in key for any
                // Int32 — and radix-sort the prefix (identical order to
                // `.sort()`, ~4× faster on these widths and allocation-free;
                // this sort dominated effort-7 encode). Ties in key are
                // processed together by the sweep, so the chosen split is
                // identical to a key-only sort.
                for (i, idx) in node.idxs.enumerated() {
                    packedBuf[i] = (Int64(propsFlat[idx * propCount + k]) << 16)
                        | Int64(tokBucket[idx])
                }
                radixSortInt64Prefix(
                    &packedBuf, tmp: &radixBuf, counts: &radixCounts, count: m)
                var hi = nodeHist
                var hiTot = m
                var hiS = nodeS
                for t in 0...maxTok { loBuf[t] = 0 }
                var loTot = 0
                var loS = 0.0
                var j = 0
                while j < m {
                    let v = packedBuf[j] >> 16
                    while j < m && (packedBuf[j] >> 16) == v {
                        let tk = Int(packedBuf[j] & 0xffff)
                        hiS -= term(hi[tk]); hi[tk] -= 1; hiS += term(hi[tk]); hiTot -= 1
                        loS -= term(loBuf[tk]); loBuf[tk] += 1; loS += term(loBuf[tk]); loTot += 1
                        j += 1
                    }
                    if hiTot > 0 {
                        let loCost = loTot <= 1 ? 0 : clogc[loTot] - loS
                        let hiCost = clogc[hiTot] - hiS
                        let gain = nodeCost - (loCost + hiCost)
                        if gain > node.bestGain {
                            node.bestGain = gain; node.bestK = k
                            node.bestSplit = Int32(v)
                        }
                    }
                }
            }
        }

        let root = GNode(Array(0..<n))
        computeBest(root, &packedBuf, &radixBuf, &radixCounts, &loBuf)
        var leaves: [GNode] = [root]
        while leaves.count < maxLeaves {
            var bi = -1
            var bg = minGain
            for (i, l) in leaves.enumerated() where l.bestGain > bg {
                bg = l.bestGain; bi = i
            }
            if bi < 0 { break }
            let node = leaves[bi]
            let k = node.bestK
            let s = node.bestSplit
            var leftIdxs = [Int](); var rightIdxs = [Int]()
            leftIdxs.reserveCapacity(node.idxs.count)
            rightIdxs.reserveCapacity(node.idxs.count)
            for i in node.idxs {
                if propsFlat[i * propCount + k] > s { leftIdxs.append(i) }
                else { rightIdxs.append(i) }
            }
            if leftIdxs.isEmpty || rightIdxs.isEmpty { node.bestGain = -1; continue }
            node.prop = propIndices[k]
            node.split = s
            let L = GNode(leftIdxs); let R = GNode(rightIdxs)
            node.left = L; node.right = R
            node.idxs = []
            computeBest(L, &packedBuf, &radixBuf, &radixCounts, &loBuf)
            computeBest(R, &packedBuf, &radixBuf, &radixCounts, &loBuf)
            leaves.remove(at: bi)
            leaves.append(L); leaves.append(R)
        }
        if leaves.count < 2 { return nil }

        // Linearise BFS → ModularTree: array index = dequeue order, a
        // decision's children take the next two slots, leafIds in BFS
        // encounter order — exactly the decoder's fill. Fill the per-pixel
        // context from each surviving leaf's pixel set.
        var nodesOut = [ModularTreeNode]()
        var contexts = [Int](repeating: 0, count: n)
        var queue: [GNode] = [root]
        var head = 0
        var leafCounter = 0
        while head < queue.count {
            let g = queue[head]; head += 1
            if g.left == nil {
                let lid = leafCounter; leafCounter += 1
                nodesOut.append(ModularTreeNode(
                    property: -1, splitVal: 0,
                    leftChildOrLeafId: lid, rightChild: 0,
                    predictor: .gradient, predictorOffset: 0,
                    multiplier: 1, rawPredictor: 6))
                for i in g.idxs { contexts[i] = lid }
            } else {
                let leftIdx = queue.count
                let rightIdx = queue.count + 1
                queue.append(g.left!); queue.append(g.right!)
                nodesOut.append(ModularTreeNode(
                    property: g.prop, splitVal: g.split,
                    leftChildOrLeafId: leftIdx, rightChild: rightIdx,
                    predictor: .gradient, predictorOffset: 0,
                    multiplier: 1, rawPredictor: 6))
            }
        }
        return (ModularTree(nodes: nodesOut), contexts, leafCounter)
    }

    /// Greedy multi-property MA-tree candidate (cjxl-style) for the
    /// single-section path. Computes a djxl-verified subset of the
    /// neighbour-derived libjxl properties (|top|, |left|, gradient input,
    /// two directional gradients, WP-error) per pixel — with the decoder's
    /// exact edge fall-backs — plus the WP residual, learns a
    /// tree that branches on whichever property best separates the residual
    /// distribution at each node, and assembles the section. All leaves use
    /// WP (rawPredictor 6), so the decoder runs WP and computes property 15
    /// regardless of which properties the tree actually uses. Cost-gated by
    /// the caller against the single-context and activity-split candidates;
    /// `nil` when the learner finds no useful split.
    /// The shared WP per-pixel pass: for each pixel (channel-major,
    /// row-major) the 6 greedy MA-tree properties `[4,5,9,10,12,15]`, the
    /// weighted-predictor residual token, its post-config token bucket, and
    /// the max bucket. `buildSingleSection` computes this **once** at
    /// effort ≥ 4 and hands it to both `buildSingleSectionMultiContext`
    /// (WP-activity split — needs property 15 + the token) and
    /// `buildSingleSectionGreedyTree` (needs all 6 + bucket), eliminating two
    /// redundant full-image WP predictor passes per encode. Edge fall-backs +
    /// `propertyValue`/`predict`/`update` order mirror the decoder exactly, so
    /// the values (and hence the emitted bytes) are identical to each
    /// builder's former inline loop.
    static func wpGreedyPerPixel(
        width: Int, height: Int, channels: [[Int32]], postCfg: HybridUintConfig
    ) -> (propsFlat: [Int32], tokens: [UInt32], tokBucket: [Int], maxTok: Int) {
        let propCount = 6
        let n = width * height * channels.count
        var propsFlat = [Int32](repeating: 0, count: n * propCount)
        var tokens = [UInt32](repeating: 0, count: n)
        var tokBucket = [Int](repeating: 0, count: n)
        var maxTok = 0
        var pi = 0
        for pix in channels {
            var wp = WeightedPredictor(header: .default, xsize: max(1, width))
            for y in 0..<height {
                let rowBase = y * width
                let prevRow = (y - 1) * width
                let prev2Row = (y - 2) * width
                for x in 0..<width {
                    let left: Int32 = x > 0 ? pix[rowBase + x - 1]
                        : (y > 0 ? pix[prevRow + x] : 0)
                    let top: Int32 = y > 0 ? pix[prevRow + x] : left
                    let topLeft: Int32 = (x > 0 && y > 0) ? pix[prevRow + x - 1] : left
                    let topRight: Int32 = (x + 1 < width && y > 0)
                        ? pix[prevRow + x + 1] : top
                    let topTop: Int32 = y > 1 ? pix[prev2Row + x] : top
                    let wpProp = wp.propertyValue(x: x, y: y, xsize: width)
                    let b = pi * propCount
                    propsFlat[b + 0] = top < 0 ? (0 &- top) : top      // 4 |top|
                    propsFlat[b + 1] = left < 0 ? (0 &- left) : left   // 5 |left|
                    propsFlat[b + 2] = left &+ top &- topLeft           // 9
                    propsFlat[b + 3] = left &- topLeft                  // 10
                    propsFlat[b + 4] = top &- topRight                  // 12
                    propsFlat[b + 5] = wpProp                           // 15
                    let pred = wp.predict(
                        x: x, y: y, xsize: width,
                        n: top, w: left, ne: topRight, nw: topLeft, nn: topTop)
                    let actual = pix[rowBase + x]
                    let tok = ZigZag.pack(actual &- pred)
                    tokens[pi] = tok
                    let tk = Int(postCfg.encode(tok).token)
                    tokBucket[pi] = tk
                    if tk > maxTok { maxTok = tk }
                    wp.update(actual: actual, x: x, y: y, xsize: width)
                    pi += 1
                }
            }
        }
        return (propsFlat, tokens, tokBucket, maxTok)
    }

    private static func buildSingleSectionGreedyTree(
        width: Int, height: Int, channels: [[Int32]], sampleHi: Int32,
        effort: Int = 9,
        precomputed: (propsFlat: [Int32], tokens: [UInt32],
                      tokBucket: [Int], maxTok: Int)? = nil
    ) -> Data? {
        guard width > 0, height > 0, !channels.isEmpty else { return nil }
        let postCfg = HybridUintConfig.raw4
        // Only properties whose `fillModularProperties` formula is verified
        // byte-exact against `djxl`: |top|, |left|, the gradient-predictor
        // input, two FFV1 directional gradients, and the WP-error property.
        // (Properties 6,7,8,11,13,14 are intentionally excluded — some of
        // those formulas diverge from libjxl, so a tree branching on them
        // round-trips through our decoder but desyncs djxl. Widening this
        // set means first reconciling `fillModularProperties` with libjxl.)
        let propIndices: [Int32] = [4, 5, 9, 10, 12, 15]
        let propCount = propIndices.count
        let n = width * height * channels.count
        // Reuse the shared WP pass when the caller already ran it (effort ≥ 4
        // path); otherwise compute it here so other callers/tests still work.
        let shared = precomputed ?? wpGreedyPerPixel(
            width: width, height: height, channels: channels, postCfg: postCfg)
        let propsFlat = shared.propsFlat
        let tokens = shared.tokens
        let tokBucket = shared.tokBucket
        let maxTok = shared.maxTok
        // Leaf budget by effort: 16 at effort 8, 32 at effort 9. More
        // than 8 contexts switches `ContextMap.write` onto the full
        // entropy-coded path — djxl-byte-verified for 16/18/26-cluster
        // maps (E5), so the old 8-leaf cap (whose comment predated that
        // verification) is lifted; each section is still validated
        // end-to-end through djxl by the test gates. minGain stays the
        // splitting floor, so trees only grow where the entropy drop
        // pays for the extra context.
        // Learn the tree from a uniform subsample (≤ ~256K pixels), matching
        // the multi-group path and bounding the learner's cost on large
        // multi-channel frames. For the common ≤256K case stride is 1 — the
        // sample IS every pixel, so the tree (and output) is identical to
        // learning on all pixels. Routing then walks the tree per pixel via
        // the decoder's own `ModularTree.walk`, so contexts agree exactly.
        let maxLeaves = effort >= 9 ? 32 : 16
        let stride = max(1, n / 256_000)
        let sampleProps: [Int32]
        let sampleTok: [Int]
        var sampleMaxTok = 0
        if stride == 1 {
            sampleProps = propsFlat; sampleTok = tokBucket; sampleMaxTok = maxTok
        } else {
            var sp = [Int32](); var st = [Int]()
            sp.reserveCapacity((n / stride + 1) * propCount)
            var i = 0
            while i < n {
                let b = i * propCount
                for k in 0..<propCount { sp.append(propsFlat[b + k]) }
                let tk = tokBucket[i]
                st.append(tk)
                if tk > sampleMaxTok { sampleMaxTok = tk }
                i += stride
            }
            sampleProps = sp; sampleTok = st
        }
        guard sampleTok.count >= 2,
              let (tree, _, numCtx) = greedyTreeAndContexts(
                propsFlat: sampleProps, tokBucket: sampleTok,
                pixelCount: sampleTok.count, propIndices: propIndices,
                maxTok: sampleMaxTok, maxLeaves: maxLeaves, minGain: 32.0),
              numCtx >= 2 else { return nil }
        var props16 = [Int32](repeating: 0, count: 16)
        var ordered: [(ctx: Int, val: UInt32)] = []
        ordered.reserveCapacity(n)
        for i in 0..<n {
            let b = i * propCount
            for k in 0..<propCount { props16[Int(propIndices[k])] = propsFlat[b + k] }
            guard let leaf = try? tree.walk(properties: props16) else { return nil }
            ordered.append((leaf.leafId, tokens[i]))
        }
        return assembleMultiContextSection(
            tree: tree, numContexts: numCtx, ordered: ordered, postCfg: postCfg)
    }

    /// Pick the smaller of a Huffman or rANS post codebook for one
    /// pooled residual histogram + its token streams, returning
    /// `(header, codebook, usePrefixCode)`. rANS lifts the ≥1 bit/symbol
    /// Huffman floor. The sizes are **exact, computed analytically** —
    /// equal to the bit counts the former trial encodes measured:
    /// Huffman is stateless (`Σ histo[s]·codeLen[s] + Σ extraNBits`),
    /// and a rANS stream is `32 + 16·refills + Σ extraNBits` where the
    /// refill count comes from the bare reverse state walk
    /// (`refillWordCount`) — no trial bit emission. Shared by the
    /// single-section and multi-group Modular paths.
    private static func bestModularPostCodebook(
        histo histoIn: [Int], alphabetSize alphabetSizeIn: Int,
        postCfg: HybridUintConfig,
        symbolsPerChannel: [[UInt16]], totalExtraNBits: Int
    ) throws -> (header: EntropySectionHeader,
                 codebook: MultiClusterCodebook,
                 usePrefix: Bool, bits: Int) {
        // A constant / single-token sub-image (e.g. a 1×1 frame, or any
        // all-equal region) yields a 1-symbol histogram. A 1-symbol
        // *alphabet* can't carry a complete prefix code (the Huffman pad
        // needs a second slot), so widen to ≥ 2 — the extra symbol has
        // count 0 and is never emitted, but makes the code Kraft-complete
        // and djxl-valid.
        let alphabetSize = max(2, alphabetSizeIn)
        let histo = histoIn.count >= alphabetSize ? histoIn
            : histoIn + [Int](repeating: 0, count: alphabetSize - histoIn.count)
        // Huffman candidate.
        let huffLengths = lengthLimitedCanonicalHuffman(
            counts: histo, maxLength: 15, alphabetSize: alphabetSize)
        let huffTable = try PrefixCodeTable(lengths: huffLengths)
        let huffCodebook = MultiClusterCodebook(
            huffmanTables: [huffTable], ansCounts: [],
            alphabetSizes: [alphabetSize])
        let huffHeader = EntropySectionHeader(
            lz77: .disabled, contextMap: ContextMap.trivial(numContexts: 1),
            usePrefixCode: true, logAlphaSize: 15, uintConfigs: [postCfg])

        // rANS candidate (on-wire quantised distribution).
        var ansCand: (EntropySectionHeader, MultiClusterCodebook)?
        if let dist = try? ANSDistribution(
            rawFrequencies: histo.map { UInt32(max(0, $0)) }) {
            let normalised = dist.frequencies.map { Int32($0) }
            var scratch = BitWriter()
            if let wire = try? SpecANSDistribution.writeHistogram(
                normalised, to: &scratch) {
                var logAlpha = 5
                while (1 << logAlpha) < wire.count && logAlpha < 8 {
                    logAlpha += 1
                }
                if wire.count <= (1 << logAlpha) {
                    ansCand = (
                        EntropySectionHeader(
                            lz77: .disabled,
                            contextMap: ContextMap.trivial(numContexts: 1),
                            usePrefixCode: false, logAlphaSize: logAlpha,
                            uintConfigs: [postCfg]),
                        MultiClusterCodebook(
                            huffmanTables: [], ansCounts: [wire],
                            alphabetSizes: [wire.count]))
                }
            }
        }

        // Header + codebook bits, measured on a small scratch writer with
        // the same writers the real section uses.
        func headerCodebookBits(
            _ h: EntropySectionHeader, _ c: MultiClusterCodebook
        ) -> Int {
            var w = BitWriter()
            do {
                try h.write(to: &w, numContexts: 1)
                try c.write(to: &w, header: h)
            } catch { return Int.max }
            return w.bitCount
        }

        // Huffman: stateless, so token-stream bits are exactly
        // Σ histo[s]·codeLen[s] + Σ extraNBits. A counted symbol with no
        // codeword would have thrown in emission — treat as unencodable.
        var huffBits = headerCodebookBits(huffHeader, huffCodebook)
        if huffBits != Int.max {
            let lens = huffTable.lengths
            var streamBits = totalExtraNBits
            var ok = true
            for s in 0..<alphabetSize where histo[s] > 0 {
                if Int(lens[s]) == 0 { ok = false; break }
                streamBits += histo[s] * Int(lens[s])
            }
            huffBits = ok ? huffBits + streamBits : Int.max
        }

        // rANS: 32-bit init + one 16-bit word per refill + the extra
        // bits. Only the reverse state walk (whose renorm decisions
        // depend on the alias slots) has to run. The section is ONE
        // interleaved stream spanning every channel back-to-back, so
        // the walk runs over the flattened symbol sequence.
        var ansBits = Int.max
        if let cand = ansCand {
            let hc = headerCodebookBits(cand.0, cand.1)
            if hc != Int.max,
               let aw = try? ANSTokenStreamWriter(
                   header: cand.0, codebook: cand.1) {
                let all: [UInt16]
                if symbolsPerChannel.count == 1 {
                    all = symbolsPerChannel[0]
                } else {
                    var flat: [UInt16] = []
                    flat.reserveCapacity(
                        symbolsPerChannel.reduce(0) { $0 + $1.count })
                    for s in symbolsPerChannel { flat.append(contentsOf: s) }
                    all = flat
                }
                if let r = try? aw.refillWordCount(symbols: all) {
                    ansBits = hc + 32 + 16 * r + totalExtraNBits
                }
            }
        }

        guard let cand = ansCand else {
            return (huffHeader, huffCodebook, true, huffBits)
        }
        return ansBits < huffBits
            ? (cand.0, cand.1, false, ansBits)
            : (huffHeader, huffCodebook, true, huffBits)
    }

    /// Compute packed (ZigZag) prediction residuals for every channel of
    /// a single-section Modular sub-image, plus the pooled token
    /// histogram. `useWP` selects libjxl's adaptive Weighted Predictor
    /// (rawPredictor 6, reusing the decoder's `WeightedPredictor` struct
    /// so encode/decode agree by construction) over ClampedGradient
    /// (rawPredictor 5). All channels share tree leaf 0.
    private static func computeModularResiduals(
        width: Int, height: Int, channels: [[Int32]], sampleHi: Int32,
        postCfg: HybridUintConfig, useWP: Bool
    ) -> (packedPerChannel: [[UInt32]], histo: [Int], alphabetSize: Int,
          symbolsPerChannel: [[UInt16]], totalExtraNBits: Int) {
        var packedPerChannel = [[UInt32]]()
        packedPerChannel.reserveCapacity(channels.count)
        var symbolsPerChannel = [[UInt16]]()
        symbolsPerChannel.reserveCapacity(channels.count)
        var fullHisto = [Int](repeating: 0, count: postCfg.maxToken + 1)
        var maxUsedToken = 0
        var totalExtraNBits = 0
        for pix32 in channels {
            var packed = [UInt32]()
            packed.reserveCapacity(width * height)
            var symbols = [UInt16]()
            symbols.reserveCapacity(width * height)
            if useWP {
                var wp = WeightedPredictor(
                    header: .default, xsize: max(1, width))
                for y in 0..<height {
                    for x in 0..<width {
                        let nbh = Neighbourhood(at: x, y, in: pix32, width: width)
                        let pred = wp.predict(
                            x: x, y: y, xsize: width,
                            n: nbh.n, w: nbh.w, ne: nbh.ne, nw: nbh.nw, nn: nbh.nn)
                        let actual = pix32[y * width + x]
                        let p = ZigZag.pack(actual &- pred)
                        let exp = postCfg.encode(p)
                        let t = Int(exp.token)
                        fullHisto[t] += 1
                        if t > maxUsedToken { maxUsedToken = t }
                        packed.append(p)
                        symbols.append(UInt16(truncatingIfNeeded: exp.token))
                        totalExtraNBits += exp.extraNBits
                        wp.update(actual: actual, x: x, y: y, xsize: width)
                    }
                }
            } else {
                for y in 0..<height {
                    for x in 0..<width {
                        let nbh = Neighbourhood(at: x, y, in: pix32, width: width)
                        let pred = Predictor.gradient.apply(
                            to: nbh, lo: 0, hi: sampleHi)
                        let p = ZigZag.pack(pix32[y * width + x] &- pred)
                        let exp = postCfg.encode(p)
                        let t = Int(exp.token)
                        fullHisto[t] += 1
                        if t > maxUsedToken { maxUsedToken = t }
                        packed.append(p)
                        symbols.append(UInt16(truncatingIfNeeded: exp.token))
                        totalExtraNBits += exp.extraNBits
                    }
                }
            }
            packedPerChannel.append(packed)
            symbolsPerChannel.append(symbols)
        }
        return (packedPerChannel, Array(fullHisto[0..<(maxUsedToken + 1)]),
                maxUsedToken + 1, symbolsPerChannel, totalExtraNBits)
    }

    /// Reject sizes outside the supported encoder range. Lifted from
    /// the original 256² cap once `buildSections` learned to split
    /// large images into multiple groups.
    private static func validateSize(width: Int, height: Int) throws {
        precondition(width > 0 && height > 0)
        // Modular coding is pixel-based (no DCT block alignment), and the
        // group tiler crops partial edge rects — so arbitrary dimensions
        // are supported (essential for arbitrary-size medical images).
        guard width <= 16384 && height <= 16384 else {
            throw SpecModularEncoderError.unsupportedFrame(
                "encoder currently requires 1 ≤ width,height ≤ 16384"
            )
        }
    }

    /// Build the shared image-level prelude (signature, SizeHeader,
    /// ImageMetadata, CustomTransformData) for a Modular
    /// codestream. `animation` is `nil` for single-frame
    /// codestreams and a libjxl-default 100-tps `AnimationHeader`
    /// for multi-frame animations.
    static func writeModularPrelude(
        width: Int, height: Int,
        bitsPerSample: UInt32,
        colorSpace: ColorSpaceID,
        extraChannels: [ExtraChannelInfo],
        animation: AnimationHeader?
    ) throws -> Data {
        let colorEncoding: ColorEncoding
        switch colorSpace {
        case .grayscale: colorEncoding = .grayscaleD65
        case .rgb:       colorEncoding = .srgb
        default:
            throw SpecModularEncoderError.unsupportedFrame(
                "writeModularPrelude: unsupported colorSpace "
                + "\(colorSpace)"
            )
        }
        var w = BitWriter()
        w.write(bits: 8, value: 0xFF)
        w.write(bits: 8, value: 0x0A)
        try SizeHeader(
            xsize: UInt32(width), ysize: UInt32(height)
        ).write(to: &w)
        let meta = ImageMetadata(
            allDefault: false, orientation: 1,
            intrinsicSize: nil, preview: nil, animation: animation,
            bitDepth: BitDepth(
                floatingPoint: false, bitsPerSample: bitsPerSample
            ),
            modular16BitBufferSufficient: true,
            extraChannels: extraChannels,
            xybEncoded: false,
            colorEncoding: colorEncoding,
            intensityTarget: 255.0, minNits: 0.0,
            relativeToMaxDisplay: false, linearBelow: 0.0
        )
        try meta.write(to: &w)
        // CustomTransformData all_default = 1 (xyb_encoded=false ⇒
        // single bit). See note in `encodeConstantGrayscale`.
        w.writeBit(true)
        w.alignToByte()
        return w.finishToData()
    }

    /// Build one Modular frame chunk (FrameHeader + TOC + section
    /// payloads). Used for both single-frame and multi-frame
    /// codestreams. `isLast = false` on non-last frames in an
    /// animation; `haveAnimation = true` when the metadata
    /// declares animation.
    static func writeModularFrameChunk(
        extraChannels: [ExtraChannelInfo],
        built: EncodedSections,
        isLast: Bool,
        animationFrame: AnimationFrame,
        haveAnimation: Bool
    ) throws -> Data {
        var w = BitWriter()
        let fh = FrameHeader(
            allDefault: false,
            frameType: .regular, encoding: .modular,
            flags: 0, colorTransform: .none,
            chromaSubsampling: .default,
            upsampling: 1, extraChannelUpsampling: [],
            groupSizeShift: built.groupSizeShift,
            xQmScale: 2, bQmScale: 2,
            passes: .default, dcLevel: 0,
            customSizeOrOrigin: false,
            frameOrigin: (0, 0), frameSize: nil,
            blendingInfo: .default,
            extraChannelBlendingInfo: [],
            animationFrame: animationFrame,
            isLast: isLast,
            saveAsReference: 0,
            saveBeforeColorTransform: true,
            name: "",
            loopFilter: LoopFilter(
                allDefault: false, gab: false, epfIters: 0
            )
        )
        let ctx = FrameHeaderContext(
            xybEncoded: false,
            numExtraChannels: extraChannels.count,
            haveAnimation: haveAnimation, haveTimecodes: false
        )
        try fh.write(to: &w, context: ctx)
        var entrySizes = [UInt32]()
        entrySizes.reserveCapacity(built.sections.count)
        var offsets = [UInt64]()
        offsets.reserveCapacity(built.sections.count + 1)
        var cumulative: UInt64 = 0
        offsets.append(0)
        for s in built.sections {
            entrySizes.append(UInt32(s.count))
            cumulative &+= UInt64(s.count)
            offsets.append(cumulative)
        }
        let toc = TOC(
            hasPermutation: false,
            entrySizes: entrySizes,
            offsets: offsets
        )
        try toc.write(to: &w)
        var out = w.finishToData()
        for s in built.sections { out.append(s) }
        return out
    }

    /// Build the outer codestream layer (signature, SizeHeader,
    /// ImageMetadata, CustomTransformData, FrameHeader, TOC) for a
    /// single-section single-group 8-bit Modular frame in the
    /// requested colour space (`grayscale` or `rgb`) and append the
    /// caller-supplied section 0 payload.
    private static func writeOuterCodestream(
        width: Int, height: Int,
        bitsPerSample: UInt32,
        colorSpace: ColorSpaceID,
        extraChannels: [ExtraChannelInfo],
        built: EncodedSections
    ) throws -> Data {
        var out = try writeModularPrelude(
            width: width, height: height,
            bitsPerSample: bitsPerSample,
            colorSpace: colorSpace,
            extraChannels: extraChannels, animation: nil)
        out.append(try writeModularFrameChunk(
            extraChannels: extraChannels,
            built: built,
            isLast: true,
            animationFrame: .default,
            haveAnimation: false))
        return out
    }

    /// Encode N RGB / RGBA frames as a multi-frame lossless
    /// Modular JPEG XL animation. All frames must share the same
    /// dimensions. `frames[i].channels` is `[r, g, b]` (RGB) or
    /// `[r, g, b, a]` (RGBA), each an Int32 array of length
    /// `width*height`. `hasAlpha` declares a single 8-bit alpha
    /// extra channel. `durations` is per-frame in tps units (the
    /// metadata declares 100 tps so each unit is 10 ms by default).
    /// 8-bit RGB/RGBA convenience wrapper over
    /// `encodeModularAnimation`.
    package static func encodeModularAnimation8(
        width: Int, height: Int, hasAlpha: Bool,
        frames: [[[Int32]]],
        durations: [UInt32]
    ) throws -> Data {
        try encodeModularAnimation(
            width: width, height: height,
            bitsPerSample: 8,
            colorSpace: .rgb, hasAlpha: hasAlpha,
            frames: frames, durations: durations)
    }

    /// Encode N modular frames as a multi-frame lossless JPEG XL
    /// animation. Generalised over bit depth (8 or 16), colour
    /// space (`.grayscale` or `.rgb`), and alpha presence. All
    /// frames must agree on dimensions and channel count.
    /// `frames[i]` is `[gray]` / `[gray, alpha]` / `[r, g, b]` /
    /// `[r, g, b, a]` per the (colorSpace, hasAlpha) combination.
    package static func encodeModularAnimation(
        width: Int, height: Int,
        bitsPerSample: UInt32,
        colorSpace: ColorSpaceID,
        hasAlpha: Bool,
        frames: [[[Int32]]],
        durations: [UInt32]
    ) throws -> Data {
        guard !frames.isEmpty else {
            throw SpecModularEncoderError.unsupportedFrame(
                "encodeModularAnimation: empty frames array")
        }
        guard durations.count == frames.count else {
            throw SpecModularEncoderError.unsupportedFrame(
                "encodeModularAnimation: durations count "
                + "(\(durations.count)) ≠ frames count "
                + "(\(frames.count))")
        }
        guard bitsPerSample == 8 || bitsPerSample == 16 else {
            throw SpecModularEncoderError.unsupportedFrame(
                "encodeModularAnimation: bitsPerSample must be "
                + "8 or 16 (got \(bitsPerSample))")
        }
        let colorChans: Int
        switch colorSpace {
        case .grayscale: colorChans = 1
        case .rgb:       colorChans = 3
        default:
            throw SpecModularEncoderError.unsupportedFrame(
                "encodeModularAnimation: unsupported colorSpace "
                + "\(colorSpace)")
        }
        let expectedChans = colorChans + (hasAlpha ? 1 : 0)
        for (i, f) in frames.enumerated() {
            guard f.count == expectedChans else {
                throw SpecModularEncoderError.unsupportedFrame(
                    "encodeModularAnimation: frame \(i) has "
                    + "\(f.count) channels, expected "
                    + "\(expectedChans)")
            }
        }
        let sampleHi = Int32((Int64(1) << bitsPerSample) - 1)
        var sectionsPerFrame: [EncodedSections] = []
        sectionsPerFrame.reserveCapacity(frames.count)
        for f in frames {
            sectionsPerFrame.append(try buildSections(
                width: width, height: height,
                channels: f, sampleHi: sampleHi))
        }
        let extraChannels: [ExtraChannelInfo] = hasAlpha
            ? [ExtraChannelInfo(
                type: .alpha,
                bitDepth: BitDepth(
                    floatingPoint: false,
                    bitsPerSample: bitsPerSample),
                dimShift: 0, name: "")]
            : []
        let animation = AnimationHeader(
            tpsNumerator: 100, tpsDenominator: 1,
            numLoops: 0, haveTimecodes: false)
        var out = try writeModularPrelude(
            width: width, height: height,
            bitsPerSample: bitsPerSample,
            colorSpace: colorSpace,
            extraChannels: extraChannels,
            animation: animation)
        for (i, built) in sectionsPerFrame.enumerated() {
            let isLast = (i == sectionsPerFrame.count - 1)
            let af = AnimationFrame(
                duration: durations[i], timecode: 0)
            out.append(try writeModularFrameChunk(
                extraChannels: extraChannels,
                built: built,
                isLast: isLast,
                animationFrame: af,
                haveAnimation: true))
        }
        return out
    }
}

/// Smallest power of two ≥ `n` (and ≥ 1). Used to size simple,
/// fully-subscribed Huffman alphabets.
@inline(__always)
private func nextPowerOfTwo(_ n: Int) -> Int {
    if n <= 1 { return 1 }
    return 1 << (Int.bitWidth - (n - 1).leadingZeroBitCount)
}

@inline(__always)
private func log2Floor(_ x: Int) -> Int {
    precondition(x > 0)
    return 63 - UInt64(x).leadingZeroBitCount
}

private extension BitWriter {
    @inline(__always)
    mutating func write(bits count: Int, value: Int) {
        write(bits: count, value: UInt32(value))
    }
}
