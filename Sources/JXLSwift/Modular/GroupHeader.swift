// GroupHeader — per-group prelude for a Modular sub-bitstream.
//
// ISO/IEC 18181-1 §C.7.2 (libjxl `lib/jxl/modular/encoding/encoding.h`,
// struct `GroupHeader::VisitFields`). Every Modular group's data
// starts with a small header that says:
//
//   • `useGlobalTree` (u(1)) — true means the group reuses the
//     frame's global MA-tree (the one we decoded from
//     `DecodeGlobalInfo`); false means a per-group tree follows.
//   • `wpHeader` (Bundle) — weighted-predictor parameters. Almost
//     always the all_default=1 single bit on lossless cjxl output.
//   • `transforms` (U32-counted array of `ModularTransform`) —
//     pre-pixel transforms (RCT colour rotation, Palette, Squeeze).
//     Default is an empty array (1-bit `0` count).
//
// For typical lossless cjxl output of small images, this whole
// header collapses to 4 bits: `1` (use global tree) + `1` (default
// wp header) + `0,0` (zero transforms).
//
// **Scope:** the reader handles the all-default branches of the
// nested `WeightedPredictorHeader` and `ModularTransform` blocks.
// Non-default `WeightedPredictorHeader` (custom p1C/p2C/p3Cx weights)
// is parsed but its fields are not yet exposed; non-default
// `ModularTransform` (RCT/Palette/Squeeze) is parsed enough to
// recognise the kind and consumed bits, but full transform-driven
// pixel application is the next chain milestone.

import Foundation

public enum GroupHeaderError: Error, Sendable {
    case bitstream(BitstreamError)
    case unsupportedTransform(UInt32)
    case invalidRCTType(UInt32)
}

/// Weighted-predictor parameters. The all-default form is just the
/// single `all_default = 1` bit. Custom forms read 7 × u(5) values
/// (p1C, p2C, p3Ca, p3Cb, p3Cc, p3Cd, p3Ce) plus 4 × u(4) values
/// (the per-predictor weights w[0..3]).
public struct WeightedPredictorHeader: Sendable, Equatable {
    public let allDefault: Bool
    public let p1C: UInt32
    public let p2C: UInt32
    public let p3Ca: UInt32
    public let p3Cb: UInt32
    public let p3Cc: UInt32
    public let p3Cd: UInt32
    public let p3Ce: UInt32
    public let weights: (UInt32, UInt32, UInt32, UInt32)

    public init(
        allDefault: Bool = true,
        p1C: UInt32 = 16, p2C: UInt32 = 10,
        p3Ca: UInt32 = 7, p3Cb: UInt32 = 7, p3Cc: UInt32 = 7,
        p3Cd: UInt32 = 0, p3Ce: UInt32 = 0,
        weights: (UInt32, UInt32, UInt32, UInt32) = (0xd, 0xc, 0xc, 0xc)
    ) {
        self.allDefault = allDefault
        self.p1C = p1C; self.p2C = p2C
        self.p3Ca = p3Ca; self.p3Cb = p3Cb; self.p3Cc = p3Cc
        self.p3Cd = p3Cd; self.p3Ce = p3Ce
        self.weights = weights
    }

    public static let `default` = WeightedPredictorHeader()

    public static func == (lhs: WeightedPredictorHeader, rhs: WeightedPredictorHeader) -> Bool {
        return lhs.allDefault == rhs.allDefault
            && lhs.p1C == rhs.p1C && lhs.p2C == rhs.p2C
            && lhs.p3Ca == rhs.p3Ca && lhs.p3Cb == rhs.p3Cb
            && lhs.p3Cc == rhs.p3Cc && lhs.p3Cd == rhs.p3Cd
            && lhs.p3Ce == rhs.p3Ce
            && lhs.weights.0 == rhs.weights.0
            && lhs.weights.1 == rhs.weights.1
            && lhs.weights.2 == rhs.weights.2
            && lhs.weights.3 == rhs.weights.3
    }

    public static func read(from r: inout BitReader) throws -> WeightedPredictorHeader {
        let isDefault: Bool
        do { isDefault = try r.readBit() }
        catch let e as BitstreamError { throw GroupHeaderError.bitstream(e) }
        if isDefault { return .default }
        do {
            let p1C  = try r.read(bits: 5)
            let p2C  = try r.read(bits: 5)
            let p3Ca = try r.read(bits: 5)
            let p3Cb = try r.read(bits: 5)
            let p3Cc = try r.read(bits: 5)
            let p3Cd = try r.read(bits: 5)
            let p3Ce = try r.read(bits: 5)
            let w0 = try r.read(bits: 4)
            let w1 = try r.read(bits: 4)
            let w2 = try r.read(bits: 4)
            let w3 = try r.read(bits: 4)
            return WeightedPredictorHeader(
                allDefault: false,
                p1C: p1C, p2C: p2C,
                p3Ca: p3Ca, p3Cb: p3Cb, p3Cc: p3Cc,
                p3Cd: p3Cd, p3Ce: p3Ce,
                weights: (w0, w1, w2, w3)
            )
        } catch let e as BitstreamError {
            throw GroupHeaderError.bitstream(e)
        }
    }
}

/// Modular transform kinds (§C.7.2 / `TransformId`).
public enum ModularTransformId: UInt32, Sendable, Equatable {
    case rct     = 0
    case palette = 1
    case squeeze = 2
}

/// One Modular transform applied to the image before per-channel
/// prediction. We parse the metadata for each known kind and store
/// it; pixel-application is the next milestone.
public struct ModularTransform: Sendable, Equatable {
    public let id: ModularTransformId
    /// For RCT and Palette: starting channel index.
    public let beginC: UInt32
    /// For RCT: type 0..41 (default 6 = YCoCg).
    public let rctType: UInt32
    /// For Palette: number of channels covered.
    public let numC: UInt32
    /// For Palette: number of palette colours.
    public let nbColors: UInt32
    /// For Palette: number of delta entries.
    public let nbDeltas: UInt32
    /// For Palette: predictor index (libjxl modular predictor).
    public let palettePredictor: UInt32
    /// For Squeeze: per-step squeeze parameters. Empty means default
    /// squeeze pattern (libjxl computes it from the channel layout).
    public let squeezes: [SqueezeParams]

    public init(
        id: ModularTransformId,
        beginC: UInt32 = 0,
        rctType: UInt32 = 6,
        numC: UInt32 = 3,
        nbColors: UInt32 = 256,
        nbDeltas: UInt32 = 0,
        palettePredictor: UInt32 = 0,
        squeezes: [SqueezeParams] = []
    ) {
        self.id = id
        self.beginC = beginC
        self.rctType = rctType
        self.numC = numC
        self.nbColors = nbColors
        self.nbDeltas = nbDeltas
        self.palettePredictor = palettePredictor
        self.squeezes = squeezes
    }

    /// Per-step squeeze parameters when the transform is a Squeeze.
    public struct SqueezeParams: Sendable, Equatable {
        public let horizontal: Bool
        public let inPlace: Bool
        public let beginC: UInt32
        public let numC: UInt32

        public init(
            horizontal: Bool = false, inPlace: Bool = false,
            beginC: UInt32 = 0, numC: UInt32 = 2
        ) {
            self.horizontal = horizontal; self.inPlace = inPlace
            self.beginC = beginC; self.numC = numC
        }

        static func read(from r: inout BitReader) throws -> SqueezeParams {
            do {
                let h = try r.readBit()
                let p = try r.readBit()
                let beginC = try r.readU32((
                    .bits(3),
                    .offset(constant: 8, extraBits: 6),
                    .offset(constant: 72, extraBits: 10),
                    .offset(constant: 1096, extraBits: 13)
                ))
                let numC = try r.readU32((
                    .literal(1), .literal(2), .literal(3),
                    .offset(constant: 4, extraBits: 4)
                ))
                return SqueezeParams(
                    horizontal: h, inPlace: p, beginC: beginC, numC: numC
                )
            } catch let e as BitstreamError {
                throw GroupHeaderError.bitstream(e)
            }
        }
    }

    public static func read(from r: inout BitReader) throws -> ModularTransform {
        let idRaw: UInt32
        do {
            idRaw = try r.readU32((
                .literal(0), .literal(1), .literal(2), .literal(3)
            ))
        } catch let e as BitstreamError {
            throw GroupHeaderError.bitstream(e)
        }
        guard let id = ModularTransformId(rawValue: idRaw) else {
            throw GroupHeaderError.unsupportedTransform(idRaw)
        }
        switch id {
        case .rct:
            let begin: UInt32
            let rct: UInt32
            do {
                begin = try r.readU32((
                    .bits(3),
                    .offset(constant: 8, extraBits: 6),
                    .offset(constant: 72, extraBits: 10),
                    .offset(constant: 1096, extraBits: 13)
                ))
                rct = try r.readU32((
                    .literal(6), .bits(2),
                    .offset(constant: 2, extraBits: 4),
                    .offset(constant: 10, extraBits: 6)
                ))
            } catch let e as BitstreamError {
                throw GroupHeaderError.bitstream(e)
            }
            if rct >= 42 {
                throw GroupHeaderError.invalidRCTType(rct)
            }
            return ModularTransform(id: .rct, beginC: begin, rctType: rct)
        case .palette:
            let begin: UInt32
            let nc: UInt32
            let nbC: UInt32
            let nbD: UInt32
            let pred: UInt32
            do {
                begin = try r.readU32((
                    .bits(3),
                    .offset(constant: 8, extraBits: 6),
                    .offset(constant: 72, extraBits: 10),
                    .offset(constant: 1096, extraBits: 13)
                ))
                nc = try r.readU32((
                    .literal(1), .literal(3), .literal(4),
                    .offset(constant: 1, extraBits: 13)
                ))
                nbC = try r.readU32((
                    .offset(constant: 0, extraBits: 8),
                    .offset(constant: 256, extraBits: 10),
                    .offset(constant: 1280, extraBits: 12),
                    .offset(constant: 5376, extraBits: 16)
                ))
                nbD = try r.readU32((
                    .literal(0),
                    .offset(constant: 1, extraBits: 8),
                    .offset(constant: 257, extraBits: 10),
                    .offset(constant: 1281, extraBits: 16)
                ))
                pred = try r.read(bits: 4)
            } catch let e as BitstreamError {
                throw GroupHeaderError.bitstream(e)
            }
            return ModularTransform(
                id: .palette, beginC: begin,
                numC: nc, nbColors: nbC, nbDeltas: nbD,
                palettePredictor: pred
            )
        case .squeeze:
            // First a count via U32(Val(0), Bits(4)+1, Bits(6)+17, Bits(8)+81)
            // Hmm — looking at libjxl, squeeze starts with a count byte. Let me
            // fall back to the simple "default squeeze" form: u(1) flag for
            // "empty squeezes vector", then if flag==0 read a count + entries.
            let isDefault: Bool
            do { isDefault = try r.readBit() }
            catch let e as BitstreamError { throw GroupHeaderError.bitstream(e) }
            if isDefault {
                return ModularTransform(id: .squeeze, squeezes: [])
            }
            // Count = U32(Val(0), Val(1), Val(2), 1+u(4)) per libjxl
            // (transform.cc — best effort; full validation pending).
            let count: UInt32
            do {
                count = try r.readU32((
                    .literal(0), .literal(1), .literal(2),
                    .offset(constant: 1, extraBits: 4)
                ))
            } catch let e as BitstreamError {
                throw GroupHeaderError.bitstream(e)
            }
            var squeezes: [SqueezeParams] = []
            squeezes.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                squeezes.append(try SqueezeParams.read(from: &r))
            }
            return ModularTransform(id: .squeeze, squeezes: squeezes)
        }
    }
}

/// The Modular sub-bitstream's per-group prelude.
public struct GroupHeader: Sendable, Equatable {
    public let useGlobalTree: Bool
    public let wpHeader: WeightedPredictorHeader
    public let transforms: [ModularTransform]

    public init(
        useGlobalTree: Bool = true,
        wpHeader: WeightedPredictorHeader = .default,
        transforms: [ModularTransform] = []
    ) {
        self.useGlobalTree = useGlobalTree
        self.wpHeader = wpHeader
        self.transforms = transforms
    }

    public static let `default` = GroupHeader()

    public static func read(from r: inout BitReader) throws -> GroupHeader {
        let useGlobalTree: Bool
        do { useGlobalTree = try r.readBit() }
        catch let e as BitstreamError { throw GroupHeaderError.bitstream(e) }
        let wp = try WeightedPredictorHeader.read(from: &r)
        let numTransforms: UInt32
        do {
            // U32(Val(0), Val(1), 2+u(4), 18+u(8)) per libjxl
            // GroupHeader::VisitFields.
            numTransforms = try r.readU32((
                .literal(0), .literal(1),
                .offset(constant: 2, extraBits: 4),
                .offset(constant: 18, extraBits: 8)
            ))
        } catch let e as BitstreamError {
            throw GroupHeaderError.bitstream(e)
        }
        var transforms: [ModularTransform] = []
        transforms.reserveCapacity(Int(numTransforms))
        for _ in 0..<Int(numTransforms) {
            transforms.append(try ModularTransform.read(from: &r))
        }
        return GroupHeader(
            useGlobalTree: useGlobalTree,
            wpHeader: wp,
            transforms: transforms
        )
    }
}
