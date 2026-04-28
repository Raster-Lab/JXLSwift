// InverseTransforms — apply the GroupHeader's inverse transform chain
// to a fully-decoded `ModularImage`.
//
// ISO/IEC 18181-1 §C.7 (libjxl `lib/jxl/modular/encoding/encoding.cc::
// ModularDecode`). After every channel in `ModularImage.channels`
// has been filled by `decodeAllChannels(...)`, the transforms in
// `GroupHeader.transforms` are applied **in reverse order** to
// recover the original colour channels:
//
//   For each transform t (last → first):
//     • RCT  → `SpecRCT.inverse` on channels [t.beginC, t.beginC + 2]
//     • Squeeze → for each step (last → first): combine LL + HL into
//       the original full-resolution channel
//     • Palette → not yet implemented
//
// Order matters: cjxl emits the forward transforms in the order
// they're applied during encoding; the decoder must invert that
// order to undo them.

import Foundation

public enum InverseTransformsError: Error, Sendable {
    case rct(SpecRCTError)
    case squeezeNotImplemented
    case paletteNotImplemented
    case channelOutOfRange(begin: UInt32, num: UInt32, channels: Int)
}

/// Apply inverse transforms to `image.channels` in reverse order,
/// matching libjxl's `Image::undo_transforms` flow. Mutates
/// `image.channels` in place. Mismatch / unsupported transforms
/// throw — callers can recover by skipping the inverse pass and
/// presenting raw channel values, but pixel correctness against
/// djxl requires the inverse pass to succeed.
public func applyInverseTransforms(
    image: inout ModularImage, transforms: [ModularTransform]
) throws {
    for t in transforms.reversed() {
        switch t.id {
        case .rct:
            try applyInverseRCT(image: &image, transform: t)
        case .squeeze:
            // Squeeze inverse needs the LL+HL → full-res combine
            // logic threaded across 2D channel buffers. The
            // existing `Squeeze.inverseHorizontal/Vertical`
            // primitives operate on 1D arrays — wiring them
            // through ModularChannel pairs is the next step.
            throw InverseTransformsError.squeezeNotImplemented
        case .palette:
            throw InverseTransformsError.paletteNotImplemented
        }
    }
}

private func applyInverseRCT(
    image: inout ModularImage, transform t: ModularTransform
) throws {
    let begin = Int(t.beginC)
    guard begin >= 0, begin + 2 < image.channels.count else {
        throw InverseTransformsError.channelOutOfRange(
            begin: t.beginC, num: 3,
            channels: image.channels.count
        )
    }
    var c0 = image.channels[begin].pixels
    var c1 = image.channels[begin + 1].pixels
    var c2 = image.channels[begin + 2].pixels
    do {
        try SpecRCT.inverse(
            rctType: t.rctType,
            channel0: &c0, channel1: &c1, channel2: &c2
        )
    } catch let e as SpecRCTError {
        throw InverseTransformsError.rct(e)
    }
    image.channels[begin].pixels = c0
    image.channels[begin + 1].pixels = c1
    image.channels[begin + 2].pixels = c2
}
