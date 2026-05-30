// FrameHeader — per-frame metadata for a JXL frame.
//
// ISO/IEC 18181-1 §C.8.1. Every JXL frame starts with this header.
// Fields cover frame type (regular / DC / reference / progressive),
// encoding mode (VarDCT vs Modular), upsampling, group size, animation
// timing, blending info, restoration filters, and a name string. The
// spec compresses common-case values into a single `all_default` bit
// — when it's set, every field defaults and *no other bits are emitted*.
//
// This file mirrors libjxl `FrameHeader::VisitFields` in
// `lib/jxl/frame_header.cc`. The all_default=false branch reads/writes
// every spec field, with the same conditional gates libjxl uses (e.g.
// `chroma_subsampling` only when `color_transform == kYCbCr`,
// `animation_frame` only when the surrounding `ImageMetadata` declared
// an animation, etc.). Callers pass an optional
// `FrameHeaderContext` that carries the bits of surrounding metadata
// the spec needs to gate fields — `xybEncoded`, `numExtraChannels`,
// `haveAnimation`, `haveTimecodes`. When omitted, defaults are
// assumed (no XYB encoding, no extras, no animation).
//
// Note: a real decoder reads the FrameHeader directly from a frame's
// codestream; the context comes from the surrounding ImageMetadata
// already parsed. The "context" struct here just makes the API
// explicit instead of relying on an implicit global.

import Foundation

package enum FrameHeaderError: Error, Sendable, Equatable {
    case bitstream(BitstreamError)
    case unsupportedField(String)
    case invalidValue(String)
}

/// Frame type per §C.8.1.
package enum FrameType: UInt32, Sendable, Equatable, CaseIterable {
    /// Regular frame.
    case regular     = 0
    /// DC frame (low-frequency only — used for progressive coding).
    case dcFrame     = 1
    /// Reference frame for later use.
    case referenceOnly = 2
    /// Progressive-render skip-frame.
    case skipProgressive = 3
}

/// Coding strategy per §C.8.1.
public enum FrameEncoding: UInt32, Sendable, Equatable {
    case varDCT  = 0
    case modular = 1
}

/// Color transform applied to the frame content. Spec §C.8.1.
package enum ColorTransform: UInt32, Sendable, Equatable {
    case xyb   = 0
    case none  = 1
    case yCbCr = 2
}

/// Blend mode for compositing this frame onto the canvas.
/// Spec §C.8.1 (BlendMode enum).
package enum BlendMode: UInt32, Sendable, Equatable {
    /// `sample = new` — most common; the new frame replaces the old.
    case replace            = 0
    /// `sample = old + new`.
    case add                = 1
    /// Alpha-aware blend (see libjxl frame_header.h for formula).
    case blend              = 2
    /// Add scaled by alpha.
    case alphaWeightedAdd   = 3
    /// `sample = old * new` — multiplicative.
    case mul                = 4
}

/// YCbCr chroma subsampling — three 2-bit codes (one per channel).
/// Mode 0 = no subsampling, 1 = 2:1 horizontal, 2 = 2:1 vertical,
/// 3 = 2:1 both. Only emitted when `color_transform == kYCbCr` and
/// `(flags & UseDcFrame) == 0`.
package struct YCbCrChromaSubsampling: Sendable, Equatable {
    /// Per-channel mode for Y, Cb, Cr.
    package let channelModes: (UInt32, UInt32, UInt32)

    package init(y: UInt32 = 0, cb: UInt32 = 0, cr: UInt32 = 0) {
        self.channelModes = (y, cb, cr)
    }

    package static let `default` = YCbCrChromaSubsampling()

    package static func == (lhs: YCbCrChromaSubsampling, rhs: YCbCrChromaSubsampling) -> Bool {
        return lhs.channelModes.0 == rhs.channelModes.0
            && lhs.channelModes.1 == rhs.channelModes.1
            && lhs.channelModes.2 == rhs.channelModes.2
    }

    package func write(to w: inout BitWriter) {
        w.write(bits: 2, value: channelModes.0)
        w.write(bits: 2, value: channelModes.1)
        w.write(bits: 2, value: channelModes.2)
    }

    package static func read(from r: inout BitReader) throws -> YCbCrChromaSubsampling {
        let y = try r.read(bits: 2)
        let cb = try r.read(bits: 2)
        let cr = try r.read(bits: 2)
        return YCbCrChromaSubsampling(y: y, cb: cb, cr: cr)
    }

    /// libjxl `kHShift` / `kVShift` — the per-mode horizontal /
    /// vertical right-shift exponents. Mode is the 2-bit
    /// `channel_mode_[c]` value; the shift is `1 << kHShift[mode]`
    /// samples per block in each dimension.
    private static let kHShift: [Int] = [0, 1, 1, 0]
    private static let kVShift: [Int] = [0, 1, 0, 1]

    /// `channel_mode_[c]` as an `Int` for color channel `c`
    /// (0 = X/Cb, 1 = Y, 2 = B/Cr — the libjxl
    /// `YCbCrChromaSubsampling` ordering, which is how the values
    /// are stored on the wire).
    @inline(__always)
    private func mode(_ c: Int) -> Int {
        switch c {
        case 0: return Int(channelModes.0)
        case 1: return Int(channelModes.1)
        default: return Int(channelModes.2)
        }
    }

    /// libjxl `MaxHShift()` — `max_c kHShift[channel_mode_[c]]`.
    package var maxHShift: Int {
        max(Self.kHShift[mode(0)],
            max(Self.kHShift[mode(1)], Self.kHShift[mode(2)]))
    }
    /// libjxl `MaxVShift()`.
    package var maxVShift: Int {
        max(Self.kVShift[mode(0)],
            max(Self.kVShift[mode(1)], Self.kVShift[mode(2)]))
    }

    /// libjxl `HShift(c) = maxhs - kHShift[channel_mode_[c]]` for
    /// color channel `c` (0 = X/Cb, 1 = Y, 2 = B/Cr). The result
    /// is the per-block horizontal right-shift this channel's plane
    /// uses relative to the (full-resolution) frame block grid.
    @inline(__always)
    package func hShift(_ c: Int) -> Int {
        return maxHShift - Self.kHShift[mode(c)]
    }
    /// libjxl `VShift(c)`.
    @inline(__always)
    package func vShift(_ c: Int) -> Int {
        return maxVShift - Self.kVShift[mode(c)]
    }

    /// True when all three channels are full-resolution (4:4:4).
    package var is444: Bool {
        return hShift(0) == 0 && vShift(0) == 0
            && hShift(1) == 0 && vShift(1) == 0
            && hShift(2) == 0 && vShift(2) == 0
    }
}

/// Per-frame blending info — how the frame composites onto the
/// canvas, optionally referencing a previous reference frame.
package struct BlendingInfo: Sendable, Equatable {
    package let mode: BlendMode
    /// Which extra channel acts as alpha for blending. Only emitted
    /// for `Blend` / `AlphaWeightedAdd` when there are extras.
    package let alphaChannel: UInt32
    /// Clamp colour samples to [0, 1] during the blend. Only emitted
    /// for blend modes that involve alpha or `Mul`.
    package let clamp: Bool
    /// Source frame index (0–3). Only emitted if `mode != Replace` or
    /// the frame is a partial crop.
    package let source: UInt32

    package init(mode: BlendMode = .replace,
                alphaChannel: UInt32 = 0,
                clamp: Bool = false,
                source: UInt32 = 0) {
        self.mode = mode
        self.alphaChannel = alphaChannel
        self.clamp = clamp
        self.source = source
    }

    package static let `default` = BlendingInfo()

    package func write(
        to w: inout BitWriter,
        numExtraChannels: Int,
        isPartialFrame: Bool
    ) throws {
        // BlendMode: U32(0, 1, 2, 3+u(2)) per libjxl VisitBlendMode.
        try w.writeU32(mode.rawValue, distributions: (
            .literal(0), .literal(1), .literal(2),
            .offset(constant: 3, extraBits: 2)
        ))
        let usesAlpha = (mode == .blend || mode == .alphaWeightedAdd)
        if numExtraChannels > 0 && usesAlpha {
            try w.writeU32(alphaChannel, distributions: (
                .literal(0), .literal(1), .literal(2),
                .offset(constant: 3, extraBits: 3)
            ))
        }
        if (numExtraChannels > 0 && usesAlpha) || mode == .mul {
            w.writeBit(clamp)
        }
        if mode != .replace || isPartialFrame {
            try w.writeU32(source, distributions: (
                .literal(0), .literal(1), .literal(2), .literal(3)
            ))
        }
    }

    package static func read(
        from r: inout BitReader,
        numExtraChannels: Int,
        isPartialFrame: Bool
    ) throws -> BlendingInfo {
        let modeRaw = try r.readU32((
            .literal(0), .literal(1), .literal(2),
            .offset(constant: 3, extraBits: 2)
        ))
        guard let mode = BlendMode(rawValue: modeRaw) else {
            throw FrameHeaderError.invalidValue("blend_mode \(modeRaw)")
        }
        let usesAlpha = (mode == .blend || mode == .alphaWeightedAdd)
        var alphaChannel: UInt32 = 0
        if numExtraChannels > 0 && usesAlpha {
            alphaChannel = try r.readU32((
                .literal(0), .literal(1), .literal(2),
                .offset(constant: 3, extraBits: 3)
            ))
        }
        var clamp = false
        if (numExtraChannels > 0 && usesAlpha) || mode == .mul {
            clamp = try r.readBit()
        }
        var source: UInt32 = 0
        if mode != .replace || isPartialFrame {
            source = try r.readU32((
                .literal(0), .literal(1), .literal(2), .literal(3)
            ))
        }
        return BlendingInfo(
            mode: mode, alphaChannel: alphaChannel,
            clamp: clamp, source: source
        )
    }
}

/// Animation timing for a single frame. Only emitted when the
/// surrounding `ImageMetadata.animation` is non-nil.
package struct AnimationFrame: Sendable, Equatable {
    /// Duration in tps units, or 0 for "show until next frame".
    package let duration: UInt32
    /// SMPTE timecode — only emitted when the metadata's
    /// `haveTimecodes` is true.
    package let timecode: UInt32

    package init(duration: UInt32 = 0, timecode: UInt32 = 0) {
        self.duration = duration
        self.timecode = timecode
    }

    package static let `default` = AnimationFrame()

    package func write(
        to w: inout BitWriter,
        haveAnimation: Bool, haveTimecodes: Bool
    ) throws {
        if haveAnimation {
            try w.writeU32(duration, distributions: (
                .literal(0), .literal(1),
                .offset(constant: 0, extraBits: 8),
                .offset(constant: 0, extraBits: 32)
            ))
        }
        if haveTimecodes {
            w.write(bits: 32, value: timecode)
        }
    }

    package static func read(
        from r: inout BitReader,
        haveAnimation: Bool, haveTimecodes: Bool
    ) throws -> AnimationFrame {
        var duration: UInt32 = 0
        if haveAnimation {
            duration = try r.readU32((
                .literal(0), .literal(1),
                .offset(constant: 0, extraBits: 8),
                .offset(constant: 0, extraBits: 32)
            ))
        }
        var timecode: UInt32 = 0
        if haveTimecodes {
            timecode = try r.read(bits: 32)
        }
        return AnimationFrame(duration: duration, timecode: timecode)
    }
}

/// Progressive-pass configuration for the frame.
package struct Passes: Sendable, Equatable {
    package let numPasses: UInt32
    package let numDownsample: UInt32
    /// Per-pass shift for non-final passes. `shift[numPasses - 1]` is
    /// always 0 (not transmitted).
    package let shifts: [UInt32]
    /// Downsample factor for each level.
    package let downsamples: [UInt32]
    /// Last-pass index for each downsample level.
    package let lastPasses: [UInt32]

    package init(numPasses: UInt32 = 1,
                numDownsample: UInt32 = 0,
                shifts: [UInt32] = [],
                downsamples: [UInt32] = [],
                lastPasses: [UInt32] = []) {
        self.numPasses = numPasses
        self.numDownsample = numDownsample
        self.shifts = shifts
        self.downsamples = downsamples
        self.lastPasses = lastPasses
    }

    package static let `default` = Passes()

    package func write(to w: inout BitWriter) throws {
        // num_passes — `U32(1, 2, 3, 4+u(3))`.
        try w.writeU32(numPasses, distributions: (
            .literal(1), .literal(2), .literal(3),
            .offset(constant: 4, extraBits: 3)
        ))
        if numPasses == 1 { return }
        // num_downsample — `U32(0, 1, 2, 3+u(1))`.
        try w.writeU32(numDownsample, distributions: (
            .literal(0), .literal(1), .literal(2),
            .offset(constant: 3, extraBits: 1)
        ))
        // shifts[0..numPasses-2] — 2 raw bits each. The trailing shift
        // is always 0 and not emitted.
        for i in 0..<Int(numPasses) - 1 {
            let s = i < shifts.count ? shifts[i] : 0
            w.write(bits: 2, value: s)
        }
        for i in 0..<Int(numDownsample) {
            let d = i < downsamples.count ? downsamples[i] : 1
            try w.writeU32(d, distributions: (
                .literal(1), .literal(2), .literal(4), .literal(8)
            ))
        }
        for i in 0..<Int(numDownsample) {
            let lp = i < lastPasses.count ? lastPasses[i] : 0
            try w.writeU32(lp, distributions: (
                .literal(0), .literal(1), .literal(2),
                .offset(constant: 0, extraBits: 3)
            ))
        }
    }

    package static func read(from r: inout BitReader) throws -> Passes {
        let numPasses = try r.readU32((
            .literal(1), .literal(2), .literal(3),
            .offset(constant: 4, extraBits: 3)
        ))
        if numPasses == 1 {
            return Passes(numPasses: 1, numDownsample: 0,
                          shifts: [0], downsamples: [], lastPasses: [])
        }
        let numDownsample = try r.readU32((
            .literal(0), .literal(1), .literal(2),
            .offset(constant: 3, extraBits: 1)
        ))
        var shifts = [UInt32]()
        shifts.reserveCapacity(Int(numPasses))
        for _ in 0..<Int(numPasses) - 1 {
            shifts.append(try r.read(bits: 2))
        }
        shifts.append(0)
        var downsamples = [UInt32]()
        downsamples.reserveCapacity(Int(numDownsample))
        for _ in 0..<Int(numDownsample) {
            downsamples.append(try r.readU32((
                .literal(1), .literal(2), .literal(4), .literal(8)
            )))
        }
        var lastPasses = [UInt32]()
        lastPasses.reserveCapacity(Int(numDownsample))
        for _ in 0..<Int(numDownsample) {
            lastPasses.append(try r.readU32((
                .literal(0), .literal(1), .literal(2),
                .offset(constant: 0, extraBits: 3)
            )))
        }
        return Passes(numPasses: numPasses, numDownsample: numDownsample,
                      shifts: shifts, downsamples: downsamples,
                      lastPasses: lastPasses)
    }
}

/// Restoration / loop-filter configuration. Mirrors libjxl
/// `LoopFilter::VisitFields` in lib/jxl/loop_filter.cc.
///
/// The decoder reads every field; the writer currently only emits the
/// `all_default = 1` shortcut. The non-default write path (custom
/// Gaborish weights, EPF custom LUTs, etc.) is incremental future
/// work — the read path covers it so we can cross-validate against
/// cjxl-emitted frames.
package struct LoopFilter: Sendable, Equatable {
    package let allDefault: Bool
    /// Gaborish smoothing on (default true).
    package let gab: Bool
    /// EPF iteration count (default 2, range 0..3 per `Bits(2)`).
    package let epfIters: UInt32

    package init(allDefault: Bool = true,
                gab: Bool = true,
                epfIters: UInt32 = 2) {
        self.allDefault = allDefault
        self.gab = gab
        self.epfIters = epfIters
    }

    package static let `default` = LoopFilter()

    package func write(to w: inout BitWriter) throws {
        if allDefault {
            w.writeBit(true)
            // BeginExtensions U64.
            w.writeU64(0)
            return
        }
        // Non-default path. We support two configurations:
        //   • `gab=false, epfIters=0` — Modular frames
        //     (`enc_frame.cc::LoopFilterFromParams`).
        //   • `gab=true,  epfIters=0` with default Gaborish weights —
        //     the VarDCT encoder's Gaborish-on path. The Gaborish
        //     block is `gabCustom=false` (use the libjxl defaults
        //     the decoder already knows).
        // Custom Gaborish weights + EPF tables (which need the
        // full F16 stream from loop_filter.cc) are not yet wired up.
        guard epfIters == 0 else {
            throw FrameHeaderError.unsupportedField(
                "non-default LoopFilter writer (epfIters > 0)"
            )
        }
        w.writeBit(false)            // all_default = 0
        w.writeBit(gab)              // gab flag
        if gab {
            w.writeBit(false)        // gabCustom = false (defaults)
        }
        w.write(bits: 2, value: epfIters) // epf_iters = 0
        w.writeU64(0)                // BeginExtensions U64
    }

    /// Read a LoopFilter. `isModular` gates a few EPF sub-blocks per
    /// libjxl loop_filter.cc — Modular and VarDCT take different
    /// branches inside the EPF section.
    package static func read(
        from r: inout BitReader, isModular: Bool
    ) throws -> LoopFilter {
        let isDefault = try r.readBit()
        if isDefault {
            // BeginExtensions U64 follows even on the default path.
            _ = try r.readU64()
            if ProcessInfo.processInfo.environment["JXL_TRACE_AC"] != nil {
                FileHandle.standardError.write(Data(
                    "TRACE_LF allDefault=true gab=true gabCustom=N/A\n".utf8))
            }
            return LoopFilter(allDefault: true)
        }
        // Gaborish flag.
        let gab = try r.readBit()
        var gabCustom: Bool = false
        if gab {
            gabCustom = try r.readBit()
            if gabCustom {
                // 6 × F16 for X/Y/B weight pairs.
                for _ in 0..<6 { _ = try r.read(bits: 16) }
            }
        }
        // (epf trace flag values logged below after read)
        // EPF iters — raw u(2). Default 2.
        let epfIters = try r.read(bits: 2)
        var epfSharpCustom = false
        var epfWeightCustom = false
        var epfSigmaCustom = false
        if epfIters > 0 {
            if !isModular {
                epfSharpCustom = try r.readBit()
                if epfSharpCustom {
                    // 8 entries of the per-sharpness LUT, each F16.
                    for _ in 0..<8 { _ = try r.read(bits: 16) }
                }
            }
            epfWeightCustom = try r.readBit()
            if epfWeightCustom {
                // 3 channel scales + 2 zeroflush thresholds.
                for _ in 0..<5 { _ = try r.read(bits: 16) }
            }
            epfSigmaCustom = try r.readBit()
            if epfSigmaCustom {
                if !isModular {
                    _ = try r.read(bits: 16)   // epf_quant_mul
                }
                // 3 × F16: pass-0 sigma, pass-2 sigma, border SAD.
                for _ in 0..<3 { _ = try r.read(bits: 16) }
            }
            if isModular {
                _ = try r.read(bits: 16)   // epf_sigma_for_modular
            }
        }
        // Extensions: U64.
        _ = try r.readU64()
        if ProcessInfo.processInfo.environment["JXL_TRACE_AC"] != nil {
            FileHandle.standardError.write(Data(
                "TRACE_LF allDefault=false gab=\(gab) gabCustom=\(gabCustom) epfIters=\(epfIters) epfSharpCustom=\(epfSharpCustom) epfWeightCustom=\(epfWeightCustom) epfSigmaCustom=\(epfSigmaCustom)\n".utf8))
        }
        return LoopFilter(allDefault: false, gab: gab, epfIters: epfIters)
    }
}

/// Surrounding-metadata context the FrameHeader needs to know which
/// fields appear on the wire. All values default to "no extras, no
/// animation, no XYB" — fine for a typical lossless image.
package struct FrameHeaderContext: Sendable, Equatable {
    package let xybEncoded: Bool
    package let numExtraChannels: Int
    package let haveAnimation: Bool
    package let haveTimecodes: Bool

    package init(xybEncoded: Bool = false,
                numExtraChannels: Int = 0,
                haveAnimation: Bool = false,
                haveTimecodes: Bool = false) {
        self.xybEncoded = xybEncoded
        self.numExtraChannels = numExtraChannels
        self.haveAnimation = haveAnimation
        self.haveTimecodes = haveTimecodes
    }

    package static let `default` = FrameHeaderContext()
}

package struct FrameHeader: Sendable, Equatable {
    package let allDefault: Bool
    package let frameType: FrameType
    package let encoding: FrameEncoding
    package let flags: UInt64
    package let colorTransform: ColorTransform
    package let chromaSubsampling: YCbCrChromaSubsampling
    package let upsampling: UInt32
    package let extraChannelUpsampling: [UInt32]
    package let groupSizeShift: UInt32
    package let xQmScale: UInt32
    package let bQmScale: UInt32
    package let passes: Passes
    package let dcLevel: UInt32
    package let customSizeOrOrigin: Bool
    package let frameOrigin: (x: Int32, y: Int32)
    package let frameSize: SizeHeader?
    package let blendingInfo: BlendingInfo
    package let extraChannelBlendingInfo: [BlendingInfo]
    package let animationFrame: AnimationFrame
    package let isLast: Bool
    package let saveAsReference: UInt32
    package let saveBeforeColorTransform: Bool
    package let name: String
    package let loopFilter: LoopFilter

    package init(
        allDefault: Bool = false,
        frameType: FrameType = .regular,
        encoding: FrameEncoding = .varDCT,
        flags: UInt64 = 0,
        colorTransform: ColorTransform = .xyb,
        chromaSubsampling: YCbCrChromaSubsampling = .default,
        upsampling: UInt32 = 1,
        extraChannelUpsampling: [UInt32] = [],
        groupSizeShift: UInt32 = 1,
        xQmScale: UInt32 = 3,
        bQmScale: UInt32 = 2,
        passes: Passes = .default,
        dcLevel: UInt32 = 0,
        customSizeOrOrigin: Bool = false,
        frameOrigin: (x: Int32, y: Int32) = (0, 0),
        frameSize: SizeHeader? = nil,
        blendingInfo: BlendingInfo = .default,
        extraChannelBlendingInfo: [BlendingInfo] = [],
        animationFrame: AnimationFrame = .default,
        isLast: Bool = true,
        saveAsReference: UInt32 = 0,
        saveBeforeColorTransform: Bool = false,
        name: String = "",
        loopFilter: LoopFilter = .default
    ) {
        self.allDefault = allDefault
        self.frameType = frameType
        self.encoding = encoding
        self.flags = flags
        self.colorTransform = colorTransform
        self.chromaSubsampling = chromaSubsampling
        self.upsampling = upsampling
        self.extraChannelUpsampling = extraChannelUpsampling
        self.groupSizeShift = groupSizeShift
        self.xQmScale = xQmScale
        self.bQmScale = bQmScale
        self.passes = passes
        self.dcLevel = dcLevel
        self.customSizeOrOrigin = customSizeOrOrigin
        self.frameOrigin = frameOrigin
        self.frameSize = frameSize
        self.blendingInfo = blendingInfo
        self.extraChannelBlendingInfo = extraChannelBlendingInfo
        self.animationFrame = animationFrame
        self.isLast = isLast
        self.saveAsReference = saveAsReference
        self.saveBeforeColorTransform = saveBeforeColorTransform
        self.name = name
        self.loopFilter = loopFilter
    }

    package static func == (lhs: FrameHeader, rhs: FrameHeader) -> Bool {
        return lhs.allDefault == rhs.allDefault
            && lhs.frameType == rhs.frameType
            && lhs.encoding == rhs.encoding
            && lhs.flags == rhs.flags
            && lhs.colorTransform == rhs.colorTransform
            && lhs.chromaSubsampling == rhs.chromaSubsampling
            && lhs.upsampling == rhs.upsampling
            && lhs.extraChannelUpsampling == rhs.extraChannelUpsampling
            && lhs.groupSizeShift == rhs.groupSizeShift
            && lhs.xQmScale == rhs.xQmScale
            && lhs.bQmScale == rhs.bQmScale
            && lhs.passes == rhs.passes
            && lhs.dcLevel == rhs.dcLevel
            && lhs.customSizeOrOrigin == rhs.customSizeOrOrigin
            && lhs.frameOrigin.x == rhs.frameOrigin.x
            && lhs.frameOrigin.y == rhs.frameOrigin.y
            && lhs.frameSize == rhs.frameSize
            && lhs.blendingInfo == rhs.blendingInfo
            && lhs.extraChannelBlendingInfo == rhs.extraChannelBlendingInfo
            && lhs.animationFrame == rhs.animationFrame
            && lhs.isLast == rhs.isLast
            && lhs.saveAsReference == rhs.saveAsReference
            && lhs.saveBeforeColorTransform == rhs.saveBeforeColorTransform
            && lhs.name == rhs.name
            && lhs.loopFilter == rhs.loopFilter
    }

    /// Spec defaults: regular VarDCT XYB-encoded frame at upsampling=1
    /// with one pass, no crop, default blending (replace), is_last=1.
    /// `all_default=1` reduces this whole structure to a single bit.
    package static let `default` = FrameHeader(allDefault: true)

    /// Convenience: a single-frame Modular lossless header — what
    /// `MinimalLosslessCodec` will use once it migrates off the `M0`
    /// placeholder. No XYB, no animation, group_size_shift=1.
    package static func singleFrameModularLossless() -> FrameHeader {
        FrameHeader(
            allDefault: false,
            frameType: .regular,
            encoding: .modular,
            flags: 0,
            colorTransform: .none,
            upsampling: 1,
            groupSizeShift: 1,
            isLast: true
        )
    }

    /// True iff this header equals the spec default in every
    /// serialisable field — i.e. the writer can emit just one bit.
    var isSpecDefault: Bool {
        frameType == .regular
            && encoding == .varDCT
            && flags == 0
            && colorTransform == .xyb
            && upsampling == 1
            && extraChannelUpsampling.isEmpty
            && passes == .default
            && !customSizeOrOrigin
            && blendingInfo == .default
            && extraChannelBlendingInfo.isEmpty
            && animationFrame == .default
            && isLast
            && saveAsReference == 0
            && name.isEmpty
            && loopFilter == .default
    }

    /// True iff this frame can be referenced by later frames. Mirrors
    /// libjxl's `CanBeReferenced()`.
    var canBeReferenced: Bool {
        return !isLast && frameType != .dcFrame
            && (animationFrame.duration == 0 || saveAsReference != 0)
    }

    /// Whether this is a partial frame (origin offset or size smaller
    /// than the canvas). Used to gate `BlendingInfo.source`.
    var isPartialFrame: Bool {
        // Without canvas dimensions in scope we can only detect
        // origin offset > 0 here. The caller (a real decoder) would
        // also compare against the canvas. This is sufficient for
        // round-trip purposes since the encoder writes the same field
        // states back.
        return customSizeOrOrigin && (frameOrigin.x > 0 || frameOrigin.y > 0)
    }
}

extension FrameHeader {

    /// Serialise the frame header. `context` carries the bits of
    /// surrounding `ImageMetadata` the spec needs to gate fields
    /// (`xybEncoded`, `numExtraChannels`, `haveAnimation`,
    /// `haveTimecodes`).
    package func write(
        to w: inout BitWriter,
        context: FrameHeaderContext = .default
    ) throws {
        // all_default — single-bit shortcut for the spec-default frame.
        if isSpecDefault && allDefault {
            w.writeBit(true)
            return
        }
        w.writeBit(false)

        // frame_type — `U32(0, 1, 2, 3)`, just a 2-bit literal field.
        try w.writeU32(frameType.rawValue, distributions: (
            .literal(0), .literal(1), .literal(2), .literal(3)
        ))

        // is_modular — Bool.
        w.writeBit(encoding == .modular)

        // flags — U64.
        w.writeU64(flags)

        // Color transform. XYB encoding is implicit; otherwise emit a
        // 1-bit alternate flag (1 = YCbCr, 0 = None).
        if !context.xybEncoded {
            let alternate = (colorTransform == .yCbCr)
            w.writeBit(alternate)
        }

        // Chroma subsampling — only when YCbCr and not a DC-frame use.
        let useDcFrame = (flags & FrameFlag.useDcFrame.rawValue) != 0
        if colorTransform == .yCbCr && !useDcFrame {
            chromaSubsampling.write(to: &w)
        }

        // Upsampling — only when not a DC-frame use.
        if !useDcFrame {
            try w.writeU32(upsampling, distributions: (
                .literal(1), .literal(2), .literal(4), .literal(8)
            ))
            // Extra channel upsampling — one per extra channel.
            if context.numExtraChannels > 0 {
                for i in 0..<context.numExtraChannels {
                    let v = i < extraChannelUpsampling.count
                        ? extraChannelUpsampling[i] : 1
                    try w.writeU32(v, distributions: (
                        .literal(1), .literal(2), .literal(4), .literal(8)
                    ))
                }
            }
        }

        // Modular- or VarDCT-specific.
        if encoding == .modular {
            w.write(bits: 2, value: groupSizeShift)
        }
        if encoding == .varDCT && colorTransform == .xyb {
            w.write(bits: 3, value: xQmScale)
            w.write(bits: 3, value: bQmScale)
        }

        // Passes — only if not ReferenceOnly.
        if frameType != .referenceOnly {
            try passes.write(to: &w)
        }

        // dc_level — only if DCFrame.
        if frameType == .dcFrame {
            try w.writeU32(dcLevel, distributions: (
                .literal(1), .literal(2), .literal(3), .literal(4)
            ))
        }

        // custom_size_or_origin — only if not DCFrame.
        if frameType != .dcFrame {
            w.writeBit(customSizeOrOrigin)
            if customSizeOrOrigin {
                let originSizeDist: (UInt32Distribution, UInt32Distribution,
                                     UInt32Distribution, UInt32Distribution) = (
                    .bits(8),
                    .offset(constant: 256, extraBits: 11),
                    .offset(constant: 2304, extraBits: 14),
                    .offset(constant: 18688, extraBits: 30)
                )
                if frameType == .regular || frameType == .skipProgressive {
                    try w.writeU32(packSigned(frameOrigin.x), distributions: originSizeDist)
                    try w.writeU32(packSigned(frameOrigin.y), distributions: originSizeDist)
                }
                let xs = frameSize?.xsize ?? 0
                let ys = frameSize?.ysize ?? 0
                try w.writeU32(xs, distributions: originSizeDist)
                try w.writeU32(ys, distributions: originSizeDist)
            }
        }

        // Blending info / animation / is_last — only if Regular or
        // SkipProgressive.
        if frameType == .regular || frameType == .skipProgressive {
            try blendingInfo.write(
                to: &w,
                numExtraChannels: context.numExtraChannels,
                isPartialFrame: isPartialFrame
            )
            for i in 0..<context.numExtraChannels {
                let bi = i < extraChannelBlendingInfo.count
                    ? extraChannelBlendingInfo[i] : .default
                try bi.write(
                    to: &w,
                    numExtraChannels: context.numExtraChannels,
                    isPartialFrame: isPartialFrame
                )
            }
            if context.haveAnimation {
                try animationFrame.write(
                    to: &w,
                    haveAnimation: context.haveAnimation,
                    haveTimecodes: context.haveTimecodes
                )
            }
            w.writeBit(isLast)
        }

        // save_as_reference — only if !DCFrame and !is_last.
        if frameType != .dcFrame && !isLast {
            try w.writeU32(saveAsReference, distributions: (
                .literal(0), .literal(1), .literal(2), .literal(3)
            ))
        }

        // save_before_color_transform — conditional. Emitted in two
        // disjoint cases:
        //   1. CanBeReferenced and BlendMode==Replace and not partial
        //      and (Regular or SkipProgressive).
        //   2. ReferenceOnly.
        if frameType != .dcFrame {
            let canRef = canBeReferenced
            let case1 = canRef && blendingInfo.mode == .replace
                && !isPartialFrame
                && (frameType == .regular || frameType == .skipProgressive)
            let case2 = (frameType == .referenceOnly)
            if case1 || case2 {
                w.writeBit(saveBeforeColorTransform)
            }
        }

        // Name — `VisitNameString` is a U32-prefixed UTF-8 byte array.
        try writeNameString(name, to: &w)

        // Loop filter — Bundle, has its own all_default bit + extensions tail.
        try loopFilter.write(to: &w)

        // Extensions — U64 (BeginExtensions in libjxl).
        w.writeU64(0)
    }

    package static func read(
        from r: inout BitReader,
        context: FrameHeaderContext = .default
    ) throws -> FrameHeader {
        do {
            let allDefaultBit = try r.readBit()
            if allDefaultBit {
                return FrameHeader.default
            }

            let frameTypeRaw = try r.readU32((
                .literal(0), .literal(1), .literal(2), .literal(3)
            ))
            let frameType = FrameType(rawValue: frameTypeRaw) ?? .regular

            let isModular = try r.readBit()
            let encoding: FrameEncoding = isModular ? .modular : .varDCT

            let flags = try r.readU64()
            let useDcFrame = (flags & FrameFlag.useDcFrame.rawValue) != 0

            let colorTransform: ColorTransform
            if context.xybEncoded {
                colorTransform = .xyb
            } else {
                let alternate = try r.readBit()
                colorTransform = alternate ? .yCbCr : .none
            }

            let chromaSubsampling: YCbCrChromaSubsampling
            if colorTransform == .yCbCr && !useDcFrame {
                chromaSubsampling = try YCbCrChromaSubsampling.read(from: &r)
            } else {
                chromaSubsampling = .default
            }

            var upsampling: UInt32 = 1
            var extraChannelUpsampling = [UInt32]()
            if !useDcFrame {
                upsampling = try r.readU32((
                    .literal(1), .literal(2), .literal(4), .literal(8)
                ))
                if context.numExtraChannels > 0 {
                    extraChannelUpsampling.reserveCapacity(context.numExtraChannels)
                    for _ in 0..<context.numExtraChannels {
                        let v = try r.readU32((
                            .literal(1), .literal(2), .literal(4), .literal(8)
                        ))
                        extraChannelUpsampling.append(v)
                    }
                }
            }

            var groupSizeShift: UInt32 = 1
            if encoding == .modular {
                groupSizeShift = try r.read(bits: 2)
            }
            var xQmScale: UInt32 = 3
            var bQmScale: UInt32 = 2
            if encoding == .varDCT && colorTransform == .xyb {
                xQmScale = try r.read(bits: 3)
                bQmScale = try r.read(bits: 3)
            }

            var passes = Passes.default
            if frameType != .referenceOnly {
                passes = try Passes.read(from: &r)
            }

            var dcLevel: UInt32 = 0
            if frameType == .dcFrame {
                dcLevel = try r.readU32((
                    .literal(1), .literal(2), .literal(3), .literal(4)
                ))
            }

            var customSizeOrOrigin = false
            var frameOrigin: (x: Int32, y: Int32) = (0, 0)
            var frameSize: SizeHeader? = nil
            if frameType != .dcFrame {
                customSizeOrOrigin = try r.readBit()
                if customSizeOrOrigin {
                    let dist: (UInt32Distribution, UInt32Distribution,
                               UInt32Distribution, UInt32Distribution) = (
                        .bits(8),
                        .offset(constant: 256, extraBits: 11),
                        .offset(constant: 2304, extraBits: 14),
                        .offset(constant: 18688, extraBits: 30)
                    )
                    if frameType == .regular || frameType == .skipProgressive {
                        let ux = try r.readU32(dist)
                        let uy = try r.readU32(dist)
                        frameOrigin = (unpackSigned(ux), unpackSigned(uy))
                    }
                    let xs = try r.readU32(dist)
                    let ys = try r.readU32(dist)
                    if xs == 0 || ys == 0 {
                        throw FrameHeaderError.invalidValue(
                            "zero frame size"
                        )
                    }
                    frameSize = SizeHeader(xsize: xs, ysize: ys)
                }
            }

            // For computing isPartialFrame we use the same field as
            // the writer (origin > 0). Real decoders also compare to
            // the canvas — fine for round-trip purposes.
            let partial = customSizeOrOrigin
                && (frameOrigin.x > 0 || frameOrigin.y > 0)

            var blendingInfo = BlendingInfo.default
            var extraChannelBlendingInfo = [BlendingInfo]()
            var animationFrame = AnimationFrame.default
            var isLast = true
            if frameType == .regular || frameType == .skipProgressive {
                blendingInfo = try BlendingInfo.read(
                    from: &r,
                    numExtraChannels: context.numExtraChannels,
                    isPartialFrame: partial
                )
                extraChannelBlendingInfo.reserveCapacity(context.numExtraChannels)
                for _ in 0..<context.numExtraChannels {
                    extraChannelBlendingInfo.append(try BlendingInfo.read(
                        from: &r,
                        numExtraChannels: context.numExtraChannels,
                        isPartialFrame: partial
                    ))
                }
                if context.haveAnimation {
                    animationFrame = try AnimationFrame.read(
                        from: &r,
                        haveAnimation: context.haveAnimation,
                        haveTimecodes: context.haveTimecodes
                    )
                }
                isLast = try r.readBit()
            } else {
                isLast = false
            }

            var saveAsReference: UInt32 = 0
            if frameType != .dcFrame && !isLast {
                saveAsReference = try r.readU32((
                    .literal(0), .literal(1), .literal(2), .literal(3)
                ))
            }

            var saveBeforeColorTransform = false
            if frameType != .dcFrame {
                // CanBeReferenced uses isLast, frameType, animation,
                // saveAsReference — all already known.
                let canRef = !isLast && frameType != .dcFrame
                    && (animationFrame.duration == 0 || saveAsReference != 0)
                let case1 = canRef && blendingInfo.mode == .replace
                    && !partial
                    && (frameType == .regular || frameType == .skipProgressive)
                let case2 = (frameType == .referenceOnly)
                if case1 || case2 {
                    saveBeforeColorTransform = try r.readBit()
                } else {
                    saveBeforeColorTransform = true
                }
            } else {
                saveBeforeColorTransform = true
            }

            let name = try readNameString(from: &r)
            let loopFilter = try LoopFilter.read(
                from: &r, isModular: encoding == .modular
            )

            // Extensions — U64.
            _ = try r.readU64()

            return FrameHeader(
                allDefault: false,
                frameType: frameType, encoding: encoding,
                flags: flags, colorTransform: colorTransform,
                chromaSubsampling: chromaSubsampling,
                upsampling: upsampling,
                extraChannelUpsampling: extraChannelUpsampling,
                groupSizeShift: groupSizeShift,
                xQmScale: xQmScale, bQmScale: bQmScale,
                passes: passes, dcLevel: dcLevel,
                customSizeOrOrigin: customSizeOrOrigin,
                frameOrigin: frameOrigin, frameSize: frameSize,
                blendingInfo: blendingInfo,
                extraChannelBlendingInfo: extraChannelBlendingInfo,
                animationFrame: animationFrame,
                isLast: isLast,
                saveAsReference: saveAsReference,
                saveBeforeColorTransform: saveBeforeColorTransform,
                name: name, loopFilter: loopFilter
            )
        } catch let e as BitstreamError {
            throw FrameHeaderError.bitstream(e)
        }
    }
}

/// Bit positions in the `flags` U64. Match libjxl `FrameHeader::Flags`.
package enum FrameFlag: UInt64 {
    case noise                  = 0x01
    case patches                = 0x02
    case splines                = 0x10
    case useDcFrame             = 0x20
    case skipAdaptiveDcSmoothing = 0x80
}

// MARK: - Helpers

/// Pack a signed 32-bit value into the unsigned encoding libjxl uses
/// (`PackSigned` — same zig-zag pattern as Modular residuals).
@inline(__always)
private func packSigned(_ v: Int32) -> UInt32 {
    let signMask = UInt32(bitPattern: v &>> 31)
    return UInt32(bitPattern: v &<< 1) ^ signMask
}

/// Inverse of `packSigned`.
@inline(__always)
private func unpackSigned(_ u: UInt32) -> Int32 {
    let lsb = u & 1
    let signMask = UInt32(bitPattern: -Int32(bitPattern: lsb))
    return Int32(bitPattern: (u &>> 1) ^ signMask)
}

/// Per libjxl `VisitNameString` — U32(0, 1+u(4), 17+u(5), 49+u(10))
/// for the byte length, then raw u(8) per byte.
private func writeNameString(_ s: String, to w: inout BitWriter) throws {
    let bytes = Array(s.utf8)
    try w.writeU32(UInt32(bytes.count), distributions: (
        .literal(0),
        .offset(constant: 0, extraBits: 4),
        .offset(constant: 16, extraBits: 5),
        .offset(constant: 48, extraBits: 10)
    ))
    for b in bytes {
        w.write(bits: 8, value: UInt32(b))
    }
}

private func readNameString(from r: inout BitReader) throws -> String {
    let len = try r.readU32((
        .literal(0),
        .offset(constant: 0, extraBits: 4),
        .offset(constant: 16, extraBits: 5),
        .offset(constant: 48, extraBits: 10)
    ))
    var bytes = [UInt8]()
    bytes.reserveCapacity(Int(len))
    for _ in 0..<Int(len) {
        bytes.append(UInt8(try r.read(bits: 8)))
    }
    return String(bytes: bytes, encoding: .utf8) ?? ""
}
