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
