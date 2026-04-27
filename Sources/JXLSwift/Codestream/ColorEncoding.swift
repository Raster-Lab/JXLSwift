// ColorEncoding — declares the input image's colour space.
//
// ISO/IEC 18181-1 §C.3.4. Either named primaries / white point /
// transfer function / rendering intent, or an embedded ICC profile.
// JXL also has an "XYB" coding mode for the encoder's internal use,
// indicated separately on `ImageMetadata.xybEncoded`; here we model the
// declared input colour only.

import Foundation

/// Predefined CIE-1931-based colour-space identifiers (§C.3.4).
public enum ColorSpaceID: UInt32, Sendable, Equatable, CaseIterable {
    case rgb       = 0
    case grayscale = 1
    case xyb       = 2     // emitted by encoders, not user-supplied input
    case unknown   = 3
}

/// White-point reference (§C.3.4).
public enum WhitePoint: UInt32, Sendable, Equatable, CaseIterable {
    case d65       = 1
    case custom    = 2
    case e         = 10
    case dci       = 11
}

/// Named-primaries enum (§C.3.4).
public enum Primaries: UInt32, Sendable, Equatable, CaseIterable {
    case srgb      = 1
    case custom    = 2
    case bt2100    = 9
    case p3        = 11
}

/// Transfer-function enum (§C.3.4). The named cases match libjxl's
/// `JxlTransferFunction`; `gamma` is encoded with a u(24)+1 bit field.
public enum TransferFunction: Sendable, Equatable {
    case bt709
    case unknown
    case linear
    case srgb
    case pq
    case dci
    case hlg
    case gamma(UInt32) // 24-bit value
}

/// Rendering intent (§C.3.4).
public enum RenderingIntent: UInt32, Sendable, Equatable, CaseIterable {
    case perceptual = 0
    case relative   = 1
    case saturation = 2
    case absolute   = 3
}

/// A parsed `ColorEncoding`.
///
/// Note: not `Equatable` because the optional custom-white / custom-
/// primaries fields are tuple-typed (Swift can't synthesise `==` for
/// types containing tuples). Compare specific fields in tests.
public struct ColorEncoding: Sendable {
    public let useICC: Bool
    public let colorSpace: ColorSpaceID
    public let whitePoint: WhitePoint?     // nil for grayscale/unknown spaces
    public let primaries: Primaries?       // nil for grayscale/xyb
    public let transferFunction: TransferFunction
    public let renderingIntent: RenderingIntent
    /// (white_x, white_y) when whitePoint == .custom, else nil.
    public let customWhite: (UInt32, UInt32)?
    /// Custom primaries when primaries == .custom.
    public let customPrimaries: ((UInt32, UInt32), (UInt32, UInt32), (UInt32, UInt32))?

    public init(
        useICC: Bool,
        colorSpace: ColorSpaceID,
        whitePoint: WhitePoint?,
        primaries: Primaries?,
        transferFunction: TransferFunction,
        renderingIntent: RenderingIntent,
        customWhite: (UInt32, UInt32)? = nil,
        customPrimaries: ((UInt32, UInt32), (UInt32, UInt32), (UInt32, UInt32))? = nil
    ) {
        self.useICC = useICC
        self.colorSpace = colorSpace
        self.whitePoint = whitePoint
        self.primaries = primaries
        self.transferFunction = transferFunction
        self.renderingIntent = renderingIntent
        self.customWhite = customWhite
        self.customPrimaries = customPrimaries
    }

    /// Implementation-defined sRGB equality check (Sendable Equatable
    /// requires structural equality; we provide the standard sRGB tuple
    /// as a static for convenience).
    public static let srgb = ColorEncoding(
        useICC: false, colorSpace: .rgb, whitePoint: .d65, primaries: .srgb,
        transferFunction: .srgb, renderingIntent: .relative
    )

    public static let grayscaleD65 = ColorEncoding(
        useICC: false, colorSpace: .grayscale, whitePoint: .d65, primaries: nil,
        transferFunction: .srgb, renderingIntent: .relative
    )

    /// Read a `ColorEncoding` per §C.3.4. Position must be at the
    /// `all_default` bit when called.
    public static func read(from r: inout BitReader) throws -> ColorEncoding {
        // Per spec §C.3.4: ColorEncoding has its own all_default bit
        // (distinct from ImageMetadata.allDefault). When set, the
        // ColorEncoding equals the spec default — sRGB / D65 / sRGB
        // primaries / sRGB transfer / Relative intent.
        let allDefault = try r.readBit()
        if allDefault {
            return .srgb
        }
        let useICC = try r.readBit()
        // 2-bit ColorSpace selector. The spec uses a U32(0,1,2,1+u(4))
        // pattern that maps 0→RGB, 1→Gray, 2→XYB, 3→Unknown for the first
        // three; the offset(1+u(4)) reaches values up to 16 but most are
        // reserved.
        let csRaw = try r.readU32((
            .literal(0), .literal(1), .literal(2),
            .offset(constant: 1, extraBits: 4)
        ))
        let cs = ColorSpaceID(rawValue: csRaw) ?? .unknown

        var wp: WhitePoint? = nil
        var customWhite: (UInt32, UInt32)? = nil
        var prim: Primaries? = nil
        var customPrim: ((UInt32, UInt32), (UInt32, UInt32), (UInt32, UInt32))? = nil
        var transfer: TransferFunction = .srgb
        var intent: RenderingIntent = .relative

        if !useICC && cs != .xyb {
            // White point. Spec §C.3.4 encodes this as `Enum()` —
            // i.e. `U32(0, 1, 2, 1+u(4))` — not a per-value-literal
            // distribution. Values 1, 2, 10, 11 are the named
            // WhitePoint variants; selector 3 reaches 1..16 via
            // `1 + u(4)`.
            let wpRaw = try r.readEnum()
            wp = WhitePoint(rawValue: wpRaw)
            if wp == .custom {
                customWhite = (try r.readU32((
                    .bits(19), .bits(19), .bits(20), .bits(21)
                )), try r.readU32((
                    .bits(19), .bits(19), .bits(20), .bits(21)
                )))
            }

            if cs != .grayscale {
                // Primaries — uses spec-specific distribution
                // `(literal(1), literal(2), literal(9), literal(11))`,
                // i.e. the named Primaries values are mapped 1:1 to
                // selectors. This was *not* `Enum()` — the
                // diagnostic against a cjxl-produced Rec.2100 PQ
                // file caught the bug: cjxl writes selector 2 =
                // literal(9) (BT2100); our Enum-based parser was
                // reading selector 2 = literal(2) = .custom and
                // then consuming customPrim's extra bits, throwing
                // every later field out of alignment.
                let pRaw = try r.readU32((
                    .literal(1), .literal(2), .literal(9), .literal(11)
                ))
                prim = Primaries(rawValue: pRaw)
                if prim == .custom {
                    func chrom() throws -> (UInt32, UInt32) {
                        let a = try r.readU32((.bits(19), .bits(19), .bits(20), .bits(21)))
                        let b = try r.readU32((.bits(19), .bits(19), .bits(20), .bits(21)))
                        return (a, b)
                    }
                    let red = try chrom()
                    let green = try chrom()
                    let blue = try chrom()
                    customPrim = (red, green, blue)
                }
            }

            // Transfer function. The spec's U32 distribution here is
            // **not** `Enum()` — it's `(literal(2), literal(8),
            // literal(13), 1 + u(4))` so the common values (unknown,
            // linear, sRGB) are 2-bit selector + 0 extras while less
            // common ones (PQ=16, DCI=17, HLG=18) reach via
            // `selector 3 = 1+u(4)`. Note: bt709 (value 1) and gamma
            // are handled separately — bt709 is reachable via
            // selector 3, gamma uses the 24-bit gamma path above.
            let isGamma = try r.readBit()
            if isGamma {
                let g = try r.read(bits: 24)
                transfer = .gamma(g)
            } else {
                let tfRaw = try r.readU32((
                    .literal(2), .literal(8), .literal(13),
                    .offset(constant: 1, extraBits: 4)
                ))
                switch tfRaw {
                case 1:  transfer = .bt709
                case 2:  transfer = .unknown
                case 8:  transfer = .linear
                case 13: transfer = .srgb
                case 16: transfer = .pq
                case 17: transfer = .dci
                case 18: transfer = .hlg
                default: transfer = .unknown
                }
            }

            // Rendering intent — `Enum()` ranges 0..16; the named
            // `RenderingIntent` enum only covers 0..3.
            let intentRaw = try r.readEnum()
            intent = RenderingIntent(rawValue: intentRaw) ?? .relative
        }

        return ColorEncoding(
            useICC: useICC, colorSpace: cs,
            whitePoint: wp, primaries: prim,
            transferFunction: transfer, renderingIntent: intent,
            customWhite: customWhite, customPrimaries: customPrim
        )
    }
}
