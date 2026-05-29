// SpecModularEncoder — pure-Swift, spec-compliant Modular encoder.
//
// **Status**: lossless Modular path is feature-complete for the
// integer pixel layouts the project's primary use cases need:
// 8-bit grayscale, 8-bit RGB, 8-bit RGBA, 9..16-bit grayscale,
// 9..16-bit RGB, 9..16-bit RGBA. All round-trip through both OUR
// decoder AND libjxl `djxl` 0.11.2 at any size up to 8192×8192
// (multiple-of-8). Multi-group encoding lights up automatically
// for >512² inputs. Wired through `JXLEncoder.encode(_:)` and
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

public enum SpecModularEncoderError: Error, Sendable {
    case notImplemented(String)
    case unsupportedFrame(String)
}

public enum SpecModularEncoder {

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
    public static func encodeConstantGrayscale(
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

        // 2. Build the outer codestream.
        var w = BitWriter()
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
    public static func encodeGrayscale8(
        width: Int, height: Int, pixels: [UInt8]
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
            sampleHi: 255
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
    ///   - width: Image width in pixels (multiple of 8, ≤ 8192).
    ///   - height: Image height (multiple of 8, ≤ 8192).
    ///   - bitsPerSample: 9..16. Pixels must lie in
    ///     `[0, 2^bitsPerSample - 1]`. The codestream's
    ///     `BitDepth.bitsPerSample` records this exactly so a
    ///     downstream `djxl` decode emits samples in the matching
    ///     range.
    ///   - pixels: Row-major `UInt16` buffer of length
    ///     `width * height`.
    public static func encodeGrayscale16(
        width: Int, height: Int,
        bitsPerSample: UInt32 = 16,
        pixels: [UInt16]
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
            sampleHi: sampleHi
        )
        return try writeOuterCodestream(
            width: width, height: height,
            bitsPerSample: bitsPerSample,
            colorSpace: .grayscale, extraChannels: [], built: built
        )
    }

    /// Encode a high-bit-depth RGB image (9..16-bit per channel).
    /// Same pipeline as `encodeGrayscale16`, just three channels
    /// sharing one pooled-histogram Huffman codebook.
    ///
    /// - Parameters:
    ///   - width: Image width (multiple of 8, ≤ 8192).
    ///   - height: Image height (multiple of 8, ≤ 8192).
    ///   - bitsPerSample: 9..16. Per-channel sample range bound.
    ///   - r/g/b: Row-major `UInt16` buffers of length
    ///     `width * height`.
    public static func encodeRGB16(
        width: Int, height: Int,
        bitsPerSample: UInt32 = 16,
        r: [UInt16], g: [UInt16], b: [UInt16]
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
            sampleHi: sampleHi
        )
        return try writeOuterCodestream(
            width: width, height: height,
            bitsPerSample: bitsPerSample,
            colorSpace: .rgb, extraChannels: [], built: built
        )
    }

    /// Encode a high-bit-depth RGBA image (9..16-bit per channel)
    /// with a 16-bit alpha extra channel.
    public static func encodeRGBA16(
        width: Int, height: Int,
        bitsPerSample: UInt32 = 16,
        r: [UInt16], g: [UInt16], b: [UInt16], a: [UInt16]
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
            sampleHi: sampleHi
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
    public static func encodeRGB8(
        width: Int, height: Int,
        r: [UInt8], g: [UInt8], b: [UInt8]
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
            sampleHi: 255
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
    public static func encodeRGBA8(
        width: Int, height: Int,
        r: [UInt8], g: [UInt8], b: [UInt8], a: [UInt8]
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
            sampleHi: 255
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
        channels: [[Int32]], sampleHi: Int32
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
                channels: channels, sampleHi: sampleHi
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
        let predictor: Predictor = .gradient
        let postCfg = HybridUintConfig.raw4
        // For each (group, channel) collect packed residual list.
        // Indexed [groupIdx][channelIdx].
        var perGroupPerChannelPacked: [[[UInt32]]] = Array(
            repeating: Array(repeating: [], count: channels.count),
            count: numGroups
        )
        var fullHisto = [Int](repeating: 0, count: postCfg.maxToken + 1)
        var maxUsedToken = 0
        for ci in 0..<channels.count {
            let pix = channels[ci]
            // Channels at this layer are full-resolution (no shift),
            // so a channel's per-axis groupDim equals the frame's.
            for gy in 0..<numGroupsY {
                for gx in 0..<numGroupsX {
                    let rectX0 = gx * groupDim
                    let rectY0 = gy * groupDim
                    let rectW = min(groupDim, width - rectX0)
                    let rectH = min(groupDim, height - rectY0)
                    // Copy the rect into a row-major buffer so
                    // `Neighbourhood(at:y:in:width:)` resolves
                    // edge fall-backs against the rect (matching the
                    // decoder's per-rect decode loop).
                    var rect = [Int32](
                        repeating: 0, count: rectW * rectH
                    )
                    for ry in 0..<rectH {
                        let srcStart = (rectY0 + ry) * width + rectX0
                        for rx in 0..<rectW {
                            rect[ry * rectW + rx] = pix[srcStart + rx]
                        }
                    }
                    var packed = [UInt32]()
                    packed.reserveCapacity(rectW * rectH)
                    for ry in 0..<rectH {
                        for rx in 0..<rectW {
                            let nbh = Neighbourhood(
                                at: rx, ry, in: rect, width: rectW
                            )
                            let predicted = predictor.apply(
                                to: nbh, lo: 0, hi: sampleHi
                            )
                            let residual = rect[ry * rectW + rx] &- predicted
                            let p = ZigZag.pack(residual)
                            let exp = postCfg.encode(p)
                            let t = Int(exp.token)
                            fullHisto[t] += 1
                            if t > maxUsedToken { maxUsedToken = t }
                            packed.append(p)
                        }
                    }
                    let groupIdx = gy * numGroupsX + gx
                    perGroupPerChannelPacked[groupIdx][ci] = packed
                }
            }
        }

        let alphabetSize = maxUsedToken + 1
        let histo = Array(fullHisto[0..<alphabetSize])
        let postLengths = lengthLimitedCanonicalHuffman(
            counts: histo, maxLength: 15, alphabetSize: alphabetSize
        )
        let postLeafTable = try PrefixCodeTable(lengths: postLengths)
        let postCodebook = MultiClusterCodebook(
            huffmanTables: [postLeafTable], ansCounts: [],
            alphabetSizes: [alphabetSize]
        )
        let postHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: 1),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [postCfg]
        )

        // DC global section: matrices_dc, has_tree, tree+codebook,
        // GroupHeader. No inline pixel data because all channels are
        // larger than groupDim in at least one axis (true whenever
        // the frame itself is multi-group).
        var dcGlobal = BitWriter()
        dcGlobal.writeBit(true)            // matrices_dc_default
        dcGlobal.writeBit(true)            // has_tree
        try writeGlobalTreeAndPostCodebook(
            to: &dcGlobal,
            postHeader: postHeader, postCodebook: postCodebook
        )
        try GroupHeader.default.write(to: &dcGlobal)
        dcGlobal.alignToByte()
        let dcGlobalData = dcGlobal.finishToData()

        // One empty section per DC group + one empty AC global. They
        // carry no Modular data; libjxl reports 0-byte TOC sizes here.
        let dcGroupEmpty = Data()
        let acGlobalEmpty = Data()

        // Per-group AC sections.
        var acSections = [Data]()
        acSections.reserveCapacity(numGroups)
        for groupIdx in 0..<numGroups {
            var sec = BitWriter()
            try GroupHeader.default.write(to: &sec)
            let postWriter = TokenStreamWriter(
                header: postHeader, codebook: postCodebook
            )
            for ci in 0..<channels.count {
                let packed = perGroupPerChannelPacked[groupIdx][ci]
                for v in packed {
                    try postWriter.writeToken(
                        context: 0, value: v, to: &sec
                    )
                }
            }
            sec.alignToByte()
            acSections.append(sec.finishToData())
        }

        var sections = [Data]()
        sections.reserveCapacity(2 + numDcGroups + numGroups)
        sections.append(dcGlobalData)
        for _ in 0..<numDcGroups { sections.append(dcGroupEmpty) }
        sections.append(acGlobalEmpty)
        sections.append(contentsOf: acSections)
        return EncodedSections(
            groupSizeShift: groupSizeShift, sections: sections
        )
    }

    /// Write the global tree section + global post-tree codebook the
    /// DC global section carries when `has_tree = 1`. Same shape as
    /// the single-group path, factored out so multi-group reuses it.
    private static func writeGlobalTreeAndPostCodebook(
        to w: inout BitWriter,
        postHeader: EntropySectionHeader,
        postCodebook: MultiClusterCodebook
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
                predictor: .gradient,
                predictorOffset: 0,
                multiplier: 1,
                rawPredictor: 5  // libjxl ClampedGradient
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
        channels: [[Int32]], sampleHi: Int32
    ) throws -> Data {
        let predictor: Predictor = .gradient
        // libjxl raw predictor ID for ClampedGradient (5) — see
        // `LibjxlPredictor.swift`. Differs from our internal
        // `PredictorID.gradient.rawValue` (4), which is libjxl
        // "Select".
        let rawPredictor: UInt32 = 5
        let postCfg = HybridUintConfig.raw4
        // Compute residuals + pooled histogram across channels.
        var packedPerChannel = [[UInt32]]()
        packedPerChannel.reserveCapacity(channels.count)
        var fullHisto = [Int](repeating: 0, count: postCfg.maxToken + 1)
        var maxUsedToken = 0
        for pix32 in channels {
            var packed = [UInt32]()
            packed.reserveCapacity(width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let nbh = Neighbourhood(
                        at: x, y, in: pix32, width: width
                    )
                    let predicted = predictor.apply(
                        to: nbh, lo: 0, hi: sampleHi
                    )
                    let residual = pix32[y * width + x] &- predicted
                    let p = ZigZag.pack(residual)
                    let exp = postCfg.encode(p)
                    let t = Int(exp.token)
                    fullHisto[t] += 1
                    if t > maxUsedToken { maxUsedToken = t }
                    packed.append(p)
                }
            }
            packedPerChannel.append(packed)
        }
        let alphabetSize = maxUsedToken + 1
        let histo = Array(fullHisto[0..<alphabetSize])
        let postLengths = lengthLimitedCanonicalHuffman(
            counts: histo, maxLength: 15, alphabetSize: alphabetSize
        )
        let postLeafTable = try PrefixCodeTable(lengths: postLengths)
        let postCodebook = MultiClusterCodebook(
            huffmanTables: [postLeafTable], ansCounts: [],
            alphabetSizes: [alphabetSize]
        )
        let postHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: 1),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [postCfg]
        )

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
                predictor: predictor,
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
        let postWriter = TokenStreamWriter(
            header: postHeader, codebook: postCodebook
        )
        for packed in packedPerChannel {
            for v in packed {
                try postWriter.writeToken(
                    context: 0, value: v, to: &sec
                )
            }
        }
        sec.alignToByte()
        return sec.finishToData()
    }

    /// Reject sizes outside the supported encoder range. Lifted from
    /// the original 256² cap once `buildSections` learned to split
    /// large images into multiple groups.
    private static func validateSize(width: Int, height: Int) throws {
        precondition(width > 0 && height > 0)
        // Modular coding is pixel-based (no DCT block alignment), and the
        // group tiler crops partial edge rects — so arbitrary dimensions
        // are supported (essential for arbitrary-size medical images).
        guard width <= 8192 && height <= 8192 else {
            throw SpecModularEncoderError.unsupportedFrame(
                "encoder currently requires 1 ≤ width,height ≤ 8192"
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
    public static func encodeModularAnimation8(
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
    public static func encodeModularAnimation(
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
