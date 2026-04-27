// ExtraChannelInfo — declares per-extra-channel metadata.
//
// ISO/IEC 18181-1 §C.3.7. JXL supports up to 256 extra channels beyond
// the colour samples; common types are alpha, depth maps, thermal, and
// optional spot colours. Each ExtraChannelInfo records its semantic
// type, bit depth, dim shift (sub-sampled channels), and a name.

import Foundation

public enum ExtraChannelType: UInt32, Sendable, Equatable, CaseIterable {
    case alpha       = 0
    case depth       = 1
    case spotColor   = 2
    case selectionMask = 3
    case black       = 4    // CMYK black
    case cfa         = 5    // raw colour-filter-array
    case thermal     = 6
    case nonOptional = 7
    case optional    = 8

    public var isAlpha: Bool { self == .alpha }
}

public struct ExtraChannelInfo: Sendable {
    public let type: ExtraChannelType
    public let bitDepth: BitDepth
    /// The channel is sub-sampled by `2^dimShift` along each axis.
    public let dimShift: UInt32
    public let name: String
    /// True if the alpha channel is premultiplied (only meaningful when
    /// `type == .alpha`).
    public let alphaAssociated: Bool
    /// Spot-color RGBA when `type == .spotColor`.
    public let spotColorRGBA: (Float, Float, Float, Float)?
    /// CFA channel index when `type == .cfa`.
    public let cfaChannel: UInt32?

    public init(
        type: ExtraChannelType,
        bitDepth: BitDepth,
        dimShift: UInt32,
        name: String,
        alphaAssociated: Bool = false,
        spotColorRGBA: (Float, Float, Float, Float)? = nil,
        cfaChannel: UInt32? = nil
    ) {
        self.type = type
        self.bitDepth = bitDepth
        self.dimShift = dimShift
        self.name = name
        self.alphaAssociated = alphaAssociated
        self.spotColorRGBA = spotColorRGBA
        self.cfaChannel = cfaChannel
    }

    /// Read a single ExtraChannelInfo (§C.3.7).
    public static func read(from r: inout BitReader) throws -> ExtraChannelInfo {
        let allDefault = try r.readBit()
        if allDefault {
            return ExtraChannelInfo(
                type: .alpha,
                bitDepth: .standard,
                dimShift: 0,
                name: ""
            )
        }
        let typeRaw = try r.readEnum()
        let type = ExtraChannelType(rawValue: typeRaw) ?? .optional
        let bitDepth = try BitDepth.read(from: &r)
        let dimShift = try r.readU32((
            .literal(0), .literal(3),
            .offset(constant: 4, extraBits: 2),
            .offset(constant: 8, extraBits: 3)
        ))
        let nameLen = try r.readU32((
            .literal(0),
            .offset(constant: 0, extraBits: 4),
            .offset(constant: 16, extraBits: 5),
            .offset(constant: 48, extraBits: 10)
        ))
        var nameBytes = [UInt8]()
        nameBytes.reserveCapacity(Int(nameLen))
        for _ in 0..<Int(nameLen) {
            nameBytes.append(UInt8(try r.read(bits: 8)))
        }
        let name = String(bytes: nameBytes, encoding: .utf8) ?? ""

        var alphaAssociated = false
        var spotRGBA: (Float, Float, Float, Float)? = nil
        var cfaIdx: UInt32? = nil

        switch type {
        case .alpha:
            alphaAssociated = try r.readBit()
        case .spotColor:
            // 4 × float32 RGBA values, raw 32-bit
            let rr = Float(bitPattern: try r.read(bits: 32))
            let gg = Float(bitPattern: try r.read(bits: 32))
            let bb = Float(bitPattern: try r.read(bits: 32))
            let aa = Float(bitPattern: try r.read(bits: 32))
            spotRGBA = (rr, gg, bb, aa)
        case .cfa:
            cfaIdx = try r.readU32((
                .literal(1), .offset(constant: 0, extraBits: 2),
                .offset(constant: 3, extraBits: 4),
                .offset(constant: 19, extraBits: 8)
            ))
        default:
            break
        }

        return ExtraChannelInfo(
            type: type, bitDepth: bitDepth, dimShift: dimShift,
            name: name, alphaAssociated: alphaAssociated,
            spotColorRGBA: spotRGBA, cfaChannel: cfaIdx
        )
    }
}
