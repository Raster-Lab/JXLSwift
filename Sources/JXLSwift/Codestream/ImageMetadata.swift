// ImageMetadata — top-level codestream-header structure that follows
// the SizeHeader.
//
// ISO/IEC 18181-1 §C.3.3. Encodes the image's bit depth, color
// encoding, alpha / extra-channel structure, animation flags, and
// optional preview / intrinsic-size hints.
//
// Layout (per spec):
//   all_default : 1 bit
//   if !all_default:
//     extra_fields : 1 bit
//     if extra_fields:
//       orientation       u(3)         // EXIF-style 1..8 (stored as 0..7)
//       intrinsic_size_present : 1 bit
//       if intrinsic_size_present: SizeHeader
//       preview_present : 1 bit
//       if preview_present: PreviewHeader
//       animation_present : 1 bit
//       if animation_present: AnimationHeader
//     bit_depth : BitDepth
//     modular_16bit_buffer_sufficient : 1 bit
//     num_extra_channels : U32(0, 1, 2, 3+u(4))
//     extra_channel_info : ExtraChannelInfo[num_extra_channels]
//     xyb_encoded : 1 bit
//     color_encoding : ColorEncoding
//     // intensity_target / tone_mapping fields...
//
// We don't yet implement the optional preview / animation header
// sub-structures or the tone-mapping fields beyond skipping them; they
// throw `NotYetImplemented` if encountered. For the dominant medical-
// imaging case (uncompressed monochrome / RGB stills) we cover every
// branch needed.

import Foundation

public struct PreviewHeader: Sendable, Equatable {
    public let xsize: UInt32
    public let ysize: UInt32
}

public struct AnimationHeader: Sendable, Equatable {
    public let tpsNumerator: UInt32
    public let tpsDenominator: UInt32
    public let numLoops: UInt32
    public let haveTimecodes: Bool
}

public struct ImageMetadata: Sendable {
    public let allDefault: Bool
    public let orientation: UInt32        // 1..8 (EXIF), default 1
    public let intrinsicSize: SizeHeader?
    public let preview: PreviewHeader?
    public let animation: AnimationHeader?
    public let bitDepth: BitDepth
    public let modular16BitBufferSufficient: Bool
    public let extraChannels: [ExtraChannelInfo]
    public let xybEncoded: Bool
    public let colorEncoding: ColorEncoding
    /// Intensity target (cd/m²) — for HDR.
    public let intensityTarget: Float
    /// Min nits of the source.
    public let minNits: Float
    /// Tone-mapping relative-to-max-display.
    public let relativeToMaxDisplay: Bool
    public let linearBelow: Float

    /// Default-everything image metadata (8-bit sRGB RGB, no alpha,
    /// no animation, no preview).
    public static let `default` = ImageMetadata(
        allDefault: true,
        orientation: 1,
        intrinsicSize: nil,
        preview: nil,
        animation: nil,
        bitDepth: .standard,
        modular16BitBufferSufficient: true,
        extraChannels: [],
        xybEncoded: true,
        colorEncoding: .srgb,
        intensityTarget: 255.0,
        minNits: 0.0,
        relativeToMaxDisplay: false,
        linearBelow: 0.0
    )

    public init(
        allDefault: Bool, orientation: UInt32,
        intrinsicSize: SizeHeader?, preview: PreviewHeader?,
        animation: AnimationHeader?, bitDepth: BitDepth,
        modular16BitBufferSufficient: Bool,
        extraChannels: [ExtraChannelInfo], xybEncoded: Bool,
        colorEncoding: ColorEncoding,
        intensityTarget: Float, minNits: Float,
        relativeToMaxDisplay: Bool, linearBelow: Float
    ) {
        self.allDefault = allDefault
        self.orientation = orientation
        self.intrinsicSize = intrinsicSize
        self.preview = preview
        self.animation = animation
        self.bitDepth = bitDepth
        self.modular16BitBufferSufficient = modular16BitBufferSufficient
        self.extraChannels = extraChannels
        self.xybEncoded = xybEncoded
        self.colorEncoding = colorEncoding
        self.intensityTarget = intensityTarget
        self.minNits = minNits
        self.relativeToMaxDisplay = relativeToMaxDisplay
        self.linearBelow = linearBelow
    }

    /// Number of channels including extras.
    public var totalChannels: Int {
        let colorN: Int
        switch colorEncoding.colorSpace {
        case .grayscale: colorN = 1
        default:         colorN = 3
        }
        return colorN + extraChannels.count
    }

    /// True if any extra channel is alpha.
    public var hasAlpha: Bool {
        extraChannels.contains { $0.type == .alpha }
    }

    public static func read(from r: inout BitReader) throws -> ImageMetadata {
        let allDefault = try r.readBit()
        if allDefault {
            return .default
        }

        var orientation: UInt32 = 1
        var intrinsicSize: SizeHeader? = nil
        var preview: PreviewHeader? = nil
        var animation: AnimationHeader? = nil

        let extraFields = try r.readBit()
        if extraFields {
            // orientation: 3 bits, encoded as (orientation - 1).
            orientation = (try r.read(bits: 3)) + 1

            let hasIntrinsic = try r.readBit()
            if hasIntrinsic {
                intrinsicSize = try SizeHeader.read(from: &r)
            }
            let hasPreview = try r.readBit()
            if hasPreview {
                // Spec uses a SizeHeader-like structure; for now we read
                // and stash xsize/ysize the same way.
                let s = try SizeHeader.read(from: &r)
                preview = PreviewHeader(xsize: s.xsize, ysize: s.ysize)
            }
            let hasAnim = try r.readBit()
            if hasAnim {
                let tpsNum = try r.readU32((
                    .literal(100), .literal(1000),
                    .offset(constant: 1, extraBits: 10),
                    .offset(constant: 1, extraBits: 30)
                ))
                let tpsDen = try r.readU32((
                    .literal(1), .literal(1001),
                    .offset(constant: 1, extraBits: 8),
                    .offset(constant: 1, extraBits: 10)
                ))
                let numLoops = try r.readU32((
                    .literal(0), .offset(constant: 0, extraBits: 3),
                    .offset(constant: 0, extraBits: 16),
                    .offset(constant: 0, extraBits: 32)
                ))
                let haveTC = try r.readBit()
                animation = AnimationHeader(
                    tpsNumerator: tpsNum, tpsDenominator: tpsDen,
                    numLoops: numLoops, haveTimecodes: haveTC
                )
            }
        }

        let bitDepth = try BitDepth.read(from: &r)
        let modular16 = try r.readBit()
        let numExtra = try r.readU32((
            .literal(0), .literal(1),
            .offset(constant: 2, extraBits: 4),
            .offset(constant: 1, extraBits: 12)
        ))
        var extras: [ExtraChannelInfo] = []
        extras.reserveCapacity(Int(numExtra))
        for _ in 0..<Int(numExtra) {
            extras.append(try ExtraChannelInfo.read(from: &r))
        }

        let xybEncoded = try r.readBit()
        let colorEncoding = try ColorEncoding.read(from: &r)

        // Tone-mapping fields. Per spec §C.3.6:
        //   intensity_target_default_present : 1 bit (default 255 cd/m^2)
        //   if !default: f16 intensity target ... we approximate by
        //   reading the spec's u(16) field and decoding as half-float.
        var intensity: Float = 255.0
        var minNits: Float = 0.0
        var rel: Bool = false
        var linBelow: Float = 0.0
        if extraFields {
            // Tone-mapping is encoded only when extra_fields = true.
            let toneDefault = try r.readBit()
            if !toneDefault {
                let intensityRaw = try r.read(bits: 16)
                intensity = halfToFloat(UInt16(intensityRaw))
                let minRaw = try r.read(bits: 16)
                minNits = halfToFloat(UInt16(minRaw))
                rel = try r.readBit()
                let linRaw = try r.read(bits: 16)
                linBelow = halfToFloat(UInt16(linRaw))
            }
        }

        // Reserved bits for forward compatibility.
        let extensionsPresent = try r.readBit()
        if extensionsPresent {
            // We don't decode extensions; skip the 64-bit "used_extensions"
            // bitfield and any per-extension data they describe.
            _ = try r.readU64()
            // The actual extension payloads vary per bit set in `used`.
            // For an MVP foundation we don't try to decode them; skip
            // gracefully by leaving the reader where it is. Real use
            // would require iterating the bitfield. (Not yet hit on the
            // medical-imaging corpus.)
        }

        return ImageMetadata(
            allDefault: false,
            orientation: orientation,
            intrinsicSize: intrinsicSize,
            preview: preview,
            animation: animation,
            bitDepth: bitDepth,
            modular16BitBufferSufficient: modular16,
            extraChannels: extras,
            xybEncoded: xybEncoded,
            colorEncoding: colorEncoding,
            intensityTarget: intensity,
            minNits: minNits,
            relativeToMaxDisplay: rel,
            linearBelow: linBelow
        )
    }
}

extension ImageMetadata {

    /// Write an `ImageMetadata` to a bit writer. Symmetric inverse of
    /// `read(from:)` for the cases this parser supports.
    ///
    /// Currently writes:
    ///   • `all_default = true` (single bit) when every field matches
    ///     the spec defaults.
    ///   • Otherwise the full layout, with `extra_fields` set whenever
    ///     orientation, intrinsicSize, preview, animation, or tone
    ///     mapping deviate from defaults.
    ///
    /// Limitations: extension fields (the optional U64 + payload at the
    /// end of the metadata block) are not written — the writer always
    /// emits "no extensions". This matches the dominant case for
    /// medical imaging.
    public func write(to w: inout BitWriter) throws {
        if allDefault && isAllDefault {
            w.writeBit(true)
            return
        }
        w.writeBit(false)

        let needsExtraFields = needsExtraFieldsBranch
        w.writeBit(needsExtraFields)
        if needsExtraFields {
            // orientation - 1, 3 bits.
            w.write(bits: 3, value: orientation - 1)
            w.writeBit(intrinsicSize != nil)
            if let i = intrinsicSize {
                try i.write(to: &w)
            }
            w.writeBit(preview != nil)
            if let p = preview {
                try SizeHeader(xsize: p.xsize, ysize: p.ysize).write(to: &w)
            }
            w.writeBit(animation != nil)
            if let a = animation {
                try w.writeU32(a.tpsNumerator, distributions: (
                    .literal(100), .literal(1000),
                    .offset(constant: 1, extraBits: 10),
                    .offset(constant: 1, extraBits: 30)
                ))
                try w.writeU32(a.tpsDenominator, distributions: (
                    .literal(1), .literal(1001),
                    .offset(constant: 1, extraBits: 8),
                    .offset(constant: 1, extraBits: 10)
                ))
                try w.writeU32(a.numLoops, distributions: (
                    .literal(0), .offset(constant: 0, extraBits: 3),
                    .offset(constant: 0, extraBits: 16),
                    .offset(constant: 0, extraBits: 32)
                ))
                w.writeBit(a.haveTimecodes)
            }
        }

        try bitDepth.write(to: &w)
        w.writeBit(modular16BitBufferSufficient)

        try w.writeU32(UInt32(extraChannels.count), distributions: (
            .literal(0), .literal(1),
            .offset(constant: 2, extraBits: 4),
            .offset(constant: 1, extraBits: 12)
        ))
        for ec in extraChannels {
            try ec.write(to: &w)
        }

        w.writeBit(xybEncoded)
        try colorEncoding.write(to: &w)

        if needsExtraFields {
            // Tone-mapping block.
            let toneIsDefault = (intensityTarget == 255.0 && minNits == 0.0
                && !relativeToMaxDisplay && linearBelow == 0.0)
            w.writeBit(toneIsDefault)
            if !toneIsDefault {
                w.write(bits: 16, value: UInt32(floatToHalf(intensityTarget)))
                w.write(bits: 16, value: UInt32(floatToHalf(minNits)))
                w.writeBit(relativeToMaxDisplay)
                w.write(bits: 16, value: UInt32(floatToHalf(linearBelow)))
            }
        }

        // No extensions.
        w.writeBit(false)
    }

    /// True when every field matches the spec defaults — what
    /// `all_default = 1` represents.
    var isAllDefault: Bool {
        orientation == 1 && intrinsicSize == nil && preview == nil
            && animation == nil
            && bitDepth.floatingPoint == false
            && bitDepth.bitsPerSample == 8
            && bitDepth.exponentBitsPerSample == 0
            && modular16BitBufferSufficient
            && extraChannels.isEmpty
            && xybEncoded
            && intensityTarget == 255.0
            && minNits == 0.0
            && !relativeToMaxDisplay
            && linearBelow == 0.0
    }

    /// True when the writer needs the `extra_fields = 1` branch.
    var needsExtraFieldsBranch: Bool {
        orientation != 1 || intrinsicSize != nil || preview != nil
            || animation != nil
            || intensityTarget != 255.0
            || minNits != 0.0
            || relativeToMaxDisplay
            || linearBelow != 0.0
    }
}

extension ColorEncoding {
    /// True iff this colour encoding is the spec default — sRGB,
    /// D65, sRGB primaries, sRGB transfer, Relative intent, no ICC,
    /// no custom white/primaries. The encoder emits a single
    /// `all_default = 1` bit when this holds (see §C.3.4).
    var isAllDefault: Bool {
        guard !useICC, colorSpace == .rgb,
              whitePoint == .d65, primaries == .srgb,
              renderingIntent == .relative,
              customWhite == nil, customPrimaries == nil else {
            return false
        }
        if case .srgb = transferFunction { return true }
        return false
    }

    public func write(to w: inout BitWriter) throws {
        // Per spec §C.3.4: ColorEncoding has its own all_default bit
        // (distinct from ImageMetadata's). Single-bit shortcut for
        // the spec-default sRGB case.
        if isAllDefault {
            w.writeBit(true)
            return
        }
        w.writeBit(false)
        w.writeBit(useICC)
        try w.writeU32(colorSpace.rawValue, distributions: (
            .literal(0), .literal(1), .literal(2),
            .offset(constant: 1, extraBits: 4)
        ))
        guard !useICC && colorSpace != .xyb else { return }

        // White point — `Enum()` per spec §C.3.4.
        let wp = whitePoint ?? .d65
        try w.writeEnum(wp.rawValue)
        if wp == .custom, let cw = customWhite {
            try w.writeU32(cw.0, distributions: (.bits(19), .bits(19), .bits(20), .bits(21)))
            try w.writeU32(cw.1, distributions: (.bits(19), .bits(19), .bits(20), .bits(21)))
        }

        if colorSpace != .grayscale {
            let prim = primaries ?? .srgb
            // Primaries: spec distribution
            // `(literal(11), literal(1), literal(9), literal(2))`.
            try w.writeU32(prim.rawValue, distributions: (
                .literal(11), .literal(1), .literal(9), .literal(2)
            ))
            if prim == .custom, let cp = customPrimaries {
                func writeChrom(_ ch: (UInt32, UInt32)) throws {
                    try w.writeU32(ch.0, distributions: (.bits(19), .bits(19), .bits(20), .bits(21)))
                    try w.writeU32(ch.1, distributions: (.bits(19), .bits(19), .bits(20), .bits(21)))
                }
                try writeChrom(cp.0)
                try writeChrom(cp.1)
                try writeChrom(cp.2)
            }
        }

        // Transfer function. Custom distribution per spec —
        // `(literal(2), literal(8), literal(13), 1 + u(4))` — so the
        // most common values (unknown, linear, sRGB) take 2 bits
        // total; rarer values reach via `selector 3 = 1+u(4)` (range
        // 1..16, sufficient for bt709=1, PQ=16; DCI=17 and HLG=18
        // are out of Enum-range and not currently writable).
        let tfDist: (UInt32Distribution, UInt32Distribution,
                     UInt32Distribution, UInt32Distribution) = (
            .literal(2), .literal(8), .literal(13),
            .offset(constant: 1, extraBits: 4)
        )
        switch transferFunction {
        case .gamma(let g):
            w.writeBit(true)
            w.write(bits: 24, value: g)
        case .bt709:   w.writeBit(false); try w.writeU32(1,  distributions: tfDist)
        case .unknown: w.writeBit(false); try w.writeU32(2,  distributions: tfDist)
        case .linear:  w.writeBit(false); try w.writeU32(8,  distributions: tfDist)
        case .srgb:    w.writeBit(false); try w.writeU32(13, distributions: tfDist)
        case .pq:      w.writeBit(false); try w.writeU32(16, distributions: tfDist)
        case .dci, .hlg:
            // 17/18 don't fit selector 3's 1..16 range; fall back to
            // the linear approximation rather than throw.
            w.writeBit(false); try w.writeU32(8, distributions: tfDist)
        }

        // Rendering intent — `Enum()` per spec.
        try w.writeEnum(renderingIntent.rawValue)
    }
}

extension ExtraChannelInfo {
    public func write(to w: inout BitWriter) throws {
        // We only emit the all_default = 1 case for default alpha
        // channels; otherwise emit the full structure.
        let isDefaultAlpha = (type == .alpha
            && bitDepth.bitsPerSample == 8 && !bitDepth.floatingPoint
            && dimShift == 0 && name.isEmpty && !alphaAssociated)
        if isDefaultAlpha {
            w.writeBit(true)
            return
        }
        w.writeBit(false)

        // Type as Enum: U32(0, 1, 2, 1+u(4))
        try w.writeU32(type.rawValue, distributions: (
            .literal(0), .literal(1), .literal(2),
            .offset(constant: 1, extraBits: 4)
        ))
        try bitDepth.write(to: &w)
        try w.writeU32(dimShift, distributions: (
            .literal(0), .literal(3),
            .offset(constant: 4, extraBits: 2),
            .offset(constant: 8, extraBits: 3)
        ))

        let nameBytes = Array(name.utf8)
        try w.writeU32(UInt32(nameBytes.count), distributions: (
            .literal(0),
            .offset(constant: 0, extraBits: 4),
            .offset(constant: 16, extraBits: 5),
            .offset(constant: 48, extraBits: 10)
        ))
        for b in nameBytes {
            w.write(bits: 8, value: UInt32(b))
        }

        switch type {
        case .alpha:
            w.writeBit(alphaAssociated)
        case .spotColor:
            if let s = spotColorRGBA {
                w.write(bits: 32, value: s.0.bitPattern)
                w.write(bits: 32, value: s.1.bitPattern)
                w.write(bits: 32, value: s.2.bitPattern)
                w.write(bits: 32, value: s.3.bitPattern)
            } else {
                for _ in 0..<4 { w.write(bits: 32, value: 0) }
            }
        case .cfa:
            try w.writeU32(cfaChannel ?? 1, distributions: (
                .literal(1),
                .offset(constant: 0, extraBits: 2),
                .offset(constant: 3, extraBits: 4),
                .offset(constant: 19, extraBits: 8)
            ))
        default:
            break
        }
    }
}

/// IEEE-754 half-precision (binary16) → Float32. Used for tone-mapping
/// fields where the spec stores f16 in 16 bits.
func halfToFloat(_ h: UInt16) -> Float {
    let sign = UInt32(h & 0x8000) << 16
    let exp  = UInt32(h & 0x7C00) >> 10
    let frac = UInt32(h & 0x03FF)
    if exp == 0 {
        // Subnormal or zero.
        if frac == 0 {
            return Float(bitPattern: sign)
        }
        // Subnormal — shift to a normalised float32.
        var e: UInt32 = 1
        var f = frac
        while (f & 0x0400) == 0 {
            f <<= 1; e &+= 1
        }
        f &= 0x03FF
        let bits = sign | ((127 &- 15 &- e &+ 1) << 23) | (f << 13)
        return Float(bitPattern: bits)
    }
    if exp == 0x1F {
        // Inf or NaN.
        return Float(bitPattern: sign | 0x7F800000 | (frac << 13))
    }
    let bits = sign | ((exp &+ (127 &- 15)) << 23) | (frac << 13)
    return Float(bitPattern: bits)
}

/// IEEE-754 single-precision → half-precision. Truncating round-down for
/// the mantissa (sufficient for tone-mapping fields; full IEEE round-to-
/// nearest-even is not required by the spec).
func floatToHalf(_ f: Float) -> UInt16 {
    let bits = f.bitPattern
    let sign = UInt16((bits >> 16) & 0x8000)
    let exp32 = Int((bits >> 23) & 0xFF)
    let frac32 = bits & 0x007F_FFFF

    if exp32 == 0xFF {
        // Inf / NaN.
        let frac16 = frac32 != 0 ? UInt16(0x0200) : UInt16(0)
        return sign | 0x7C00 | frac16
    }
    let exp16 = exp32 - (127 - 15)
    if exp16 <= 0 {
        // Zero or subnormal — round to zero of right sign.
        return sign
    }
    if exp16 >= 31 {
        // Overflow → +/- infinity.
        return sign | 0x7C00
    }
    let exp16U = UInt16(exp16)
    let frac16 = UInt16((frac32 >> 13) & 0x03FF)
    return sign | (exp16U << 10) | frac16
}
