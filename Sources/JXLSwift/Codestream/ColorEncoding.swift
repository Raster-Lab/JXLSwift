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
        // ColorSpace via Enum() — `U32(0, 1, 2+u(4), 18+u(6))`. Named
        // values: 0=RGB, 1=Gray, 2=XYB, 3=Unknown. Spec §C.3.4.
        let csRaw = try r.readEnum()
        let cs = ColorSpaceID(rawValue: csRaw) ?? .unknown

        var wp: WhitePoint? = nil
        var customWhite: (UInt32, UInt32)? = nil
        var prim: Primaries? = nil
        var customPrim: ((UInt32, UInt32), (UInt32, UInt32), (UInt32, UInt32))? = nil
        var transfer: TransferFunction = .srgb
        var intent: RenderingIntent = .relative

        if !useICC {
            // Per-field skip flags match libjxl exactly:
            //   • XYB colour space implies WhitePoint = D65 (no wp bits
            //     on the wire — `ImplicitWhitePoint()` returns true).
            //   • Grayscale and XYB have no primaries (`HasPrimaries()`
            //     returns false).
            //   • TF and rendering intent are still read for both
            //     XYB and grayscale.
            let implicitWhitePoint = (cs == .xyb)
            let hasPrimaries = (cs != .grayscale && cs != .xyb)

            if !implicitWhitePoint {
                // White point — `Enum()` per spec §C.3.4. Named values
                // 1=D65, 2=custom, 10=E, 11=DCI.
                let wpRaw = try r.readEnum()
                wp = WhitePoint(rawValue: wpRaw)
                if wp == .custom {
                    customWhite = (try r.readU32((
                        .bits(19), .bits(19), .bits(20), .bits(21)
                    )), try r.readU32((
                        .bits(19), .bits(19), .bits(20), .bits(21)
                    )))
                }
            } else {
                wp = .d65   // implied
            }

            if hasPrimaries {
                // Primaries via `Enum()` — `U32(0, 1, 2+u(4), 18+u(6))`.
                // Named values 1=sRGB, 2=custom, 9=BT2100/Rec.2100,
                // 11=DCI-P3. cjxl reaches 9 and 11 via `selector 2 +
                // u(4)` with offset 2.
                let pRaw = try r.readEnum()
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

            // Transfer function. After a `have_gamma` u(1) flag,
            // gamma path reads a u(24) gamma value, otherwise the TF
            // is encoded as Enum() — `U32(0, 1, 2+u(4), 18+u(6))`.
            // Named values: 1=BT.709, 2=Unknown, 8=Linear, 13=sRGB,
            // 16=PQ, 17=DCI-P3, 18=HLG. The Enum extended slot
            // (`18+u(6)`) is what makes HLG (=18) and DCI (=17)
            // reachable — the previous `1+u(4)` distribution capped
            // at 16 and silently corrupted parsing for those files.
            let isGamma = try r.readBit()
            if isGamma {
                let g = try r.read(bits: 24)
                transfer = .gamma(g)
            } else {
                let tfRaw = try r.readEnum()
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

            // Rendering intent — `Enum()`.
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
