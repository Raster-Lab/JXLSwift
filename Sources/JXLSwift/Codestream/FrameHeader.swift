// FrameHeader — per-frame metadata for a JXL frame.
//
// ISO/IEC 18181-1 §C.8.1. Every JXL frame starts with this header.
// Fields cover frame type (regular / DC / reference / progressive),
// encoding mode (VarDCT vs Modular), upsampling, group size, animation
// timing, blending info, restoration filters, and a name string. The
// spec compresses common-case values into a single `all_default` bit
// — when it's set, *no other fields are emitted* and the decoder uses
// every field's default value.
//
// **What this file implements:**
//
//   1. The full conceptual `FrameHeader` Swift struct with the spec
//      defaults clearly labelled.
//   2. The `all_default = true` codec path, which is just `u(1) = 1`
//      and is provably spec-correct.
//   3. A **best-effort, project-internal** layout for the
//      `all_default = false` case covering only the fields a 1×1
//      single-frame Modular lossless image needs:
//        - frame_type      u(2)
//        - encoding        u(1)
//        - flags           u(8)              // placeholder — real
//                                            // spec uses U64()
//        - group_size_shift u(2) (Modular only)
//        - is_last         u(1)
//        - frame_size:     1 bit + maybe SizeHeader
//      Other fields (animation, blending, name, restoration) are
//      assumed at their defaults; a future spec-compliant
//      implementation will widen this.
//
// **Caveat:** the all_default-false layout above is *not* byte-for-
// byte spec compliant. The spec uses `U64()` for `flags`, has
// `do_YCbCr` / `upsampling` / `ec_upsampling` fields, and has a
// blending-info structure I don't yet model. This file gives us a
// round-trippable per-frame header for our own
// encode/decode/inspect workflow; producing files that `djxl` can
// decode will need a wider implementation against the spec.

import Foundation

public enum FrameHeaderError: Error, Sendable, Equatable {
    case bitstream(BitstreamError)
    case unsupportedField(String)
}

/// Frame type per §C.8.1.
public enum FrameType: UInt32, Sendable, Equatable, CaseIterable {
    /// Regular frame — the only type currently supported.
    case regular     = 0
    /// DC frame (low-frequency only).
    case dcFrame     = 1
    /// Reference frame for later use.
    case reference   = 2
    /// Progressive-render skip-frame.
    case skipProgressive = 3
}

/// Coding strategy per §C.8.1.
public enum FrameEncoding: UInt32, Sendable, Equatable {
    case varDCT  = 0
    case modular = 1
}

public struct FrameHeader: Sendable, Equatable {
    public let allDefault: Bool
    public let frameType: FrameType
    public let encoding: FrameEncoding
    public let flags: UInt64
    public let groupSizeShift: UInt32
    public let isLast: Bool
    /// `nil` means "frame size matches the image's full size" (the
    /// have_crop=false default). Non-nil indicates a partial-frame
    /// crop or a reference frame with explicit dimensions.
    public let frameSize: SizeHeader?

    public init(
        allDefault: Bool = false,
        frameType: FrameType = .regular,
        encoding: FrameEncoding = .varDCT,
        flags: UInt64 = 0,
        groupSizeShift: UInt32 = 1,
        isLast: Bool = true,
        frameSize: SizeHeader? = nil
    ) {
        self.allDefault = allDefault
        self.frameType = frameType
        self.encoding = encoding
        self.flags = flags
        self.groupSizeShift = groupSizeShift
        self.isLast = isLast
        self.frameSize = frameSize
    }

    /// Spec defaults: regular VarDCT frame, no flags, group_size_shift=1
    /// (=> 512×512 groups), last frame, full-image size, etc.
    public static let `default` = FrameHeader(
        allDefault: true,
        frameType: .regular,
        encoding: .varDCT,
        flags: 0,
        groupSizeShift: 1,
        isLast: true,
        frameSize: nil
    )

    /// Convenience: a single-frame lossless Modular header, the
    /// shape `MinimalLosslessCodec` would migrate to once we replace
    /// its placeholder marker with this struct.
    public static func singleFrameModularLossless() -> FrameHeader {
        FrameHeader(
            allDefault: false,
            frameType: .regular,
            encoding: .modular,
            flags: 0,
            groupSizeShift: 1,
            isLast: true,
            frameSize: nil
        )
    }
}

extension FrameHeader {

    /// Serialise the frame header. The all_default=true path emits a
    /// single bit and is spec-correct; the false path uses the
    /// project-internal layout documented at the top of this file.
    public func write(to w: inout BitWriter) throws {
        w.writeBit(allDefault)
        if allDefault { return }
        w.write(bits: 2, value: frameType.rawValue)
        w.write(bits: 1, value: encoding.rawValue)
        // Placeholder: u(8) for flags. Real spec uses U64().
        guard flags <= 0xFF else {
            throw FrameHeaderError.unsupportedField("flags > 0xFF (placeholder limit)")
        }
        w.write(bits: 8, value: UInt32(flags))
        if encoding == .modular {
            guard groupSizeShift <= 3 else {
                throw FrameHeaderError.unsupportedField("group_size_shift > 3")
            }
            w.write(bits: 2, value: groupSizeShift)
        }
        w.writeBit(isLast)
        // have_crop: 1 bit. true → emit a SizeHeader; false → frame
        // covers the full image at (0, 0).
        let haveCrop = (frameSize != nil)
        w.writeBit(haveCrop)
        if let s = frameSize {
            do { try s.write(to: &w) }
            catch let e as BitstreamError { throw FrameHeaderError.bitstream(e) }
        }
    }

    /// Deserialise. Mirrors `write(to:)`.
    public static func read(from r: inout BitReader) throws -> FrameHeader {
        let allDefault: Bool
        do { allDefault = try r.readBit() }
        catch let e as BitstreamError { throw FrameHeaderError.bitstream(e) }
        if allDefault {
            return FrameHeader.default
        }
        do {
            let ftRaw = try r.read(bits: 2)
            let frameType = FrameType(rawValue: ftRaw) ?? .regular
            let encRaw = try r.read(bits: 1)
            let encoding = FrameEncoding(rawValue: encRaw) ?? .varDCT
            let flagsByte = try r.read(bits: 8)
            let flags = UInt64(flagsByte)
            let groupSizeShift: UInt32
            if encoding == .modular {
                groupSizeShift = try r.read(bits: 2)
            } else {
                groupSizeShift = 1
            }
            let isLast = try r.readBit()
            let haveCrop = try r.readBit()
            let frameSize: SizeHeader? =
                haveCrop ? try SizeHeader.read(from: &r) : nil
            return FrameHeader(
                allDefault: false,
                frameType: frameType,
                encoding: encoding,
                flags: flags,
                groupSizeShift: groupSizeShift,
                isLast: isLast,
                frameSize: frameSize
            )
        } catch let e as BitstreamError {
            throw FrameHeaderError.bitstream(e)
        }
    }
}
