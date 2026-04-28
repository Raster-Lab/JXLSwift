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
    case squeeze(SpecSqueezeError)
    case paletteNotImplemented
    case channelOutOfRange(begin: UInt32, num: UInt32, channels: Int)
    case squeezeBadResidualLayout
    case squeezeRangeInvalid(begin: UInt32, num: UInt32, channels: Int)
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
            try applyInverseSqueeze(image: &image, transform: t)
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

/// Inverse Squeeze: walk the squeeze parameter list in reverse
/// order, undoing each step. For each step:
///   • The LL channels (the source channels at begin..end) are
///     combined with their corresponding residual placeholders to
///     recover full-resolution channels.
///   • Residuals were inserted at `offset = end + 1` (in_place=true)
///     or `image.channels.size()` (in_place=false). After undoing,
///     the residual placeholders are removed.
private func applyInverseSqueeze(
    image: inout ModularImage, transform t: ModularTransform
) throws {
    let params = t.squeezes.isEmpty
        ? defaultSqueezeParameters(image: image)
        : t.squeezes
    // Undo each parameter step in REVERSE.
    for param in params.reversed() {
        let begin = Int(param.beginC)
        let num = Int(param.numC)
        let end = begin + num - 1
        guard begin >= 0, num > 0, end < image.channels.count else {
            throw InverseTransformsError.squeezeRangeInvalid(
                begin: param.beginC, num: param.numC,
                channels: image.channels.count
            )
        }
        // The residual placeholders sit either right after `end` (in
        // place) or appended at the end of the channel list.
        let resOffset: Int
        if param.inPlace {
            resOffset = end + 1
        } else {
            resOffset = image.channels.count - num
        }
        guard resOffset >= 0, resOffset + num <= image.channels.count else {
            throw InverseTransformsError.squeezeBadResidualLayout
        }
        // Replace each LL channel with the unsqueezed full-res
        // channel; remember to remove the residual placeholders
        // afterwards.
        for k in 0..<num {
            let llIdx = begin + k
            let resIdx = resOffset + k
            let ll = image.channels[llIdx]
            let residual = image.channels[resIdx]
            let combined: ModularChannel
            do {
                if param.horizontal {
                    combined = try SpecSqueeze.inverseHorizontal(
                        ll: ll, residual: residual
                    )
                } else {
                    combined = try SpecSqueeze.inverseVertical(
                        ll: ll, residual: residual
                    )
                }
            } catch let e as SpecSqueezeError {
                throw InverseTransformsError.squeeze(e)
            }
            image.channels[llIdx] = combined
        }
        // Remove residual placeholders. Iterate from highest index
        // down so removal indices stay valid.
        for k in (0..<num).reversed() {
            image.channels.remove(at: resOffset + k)
        }
        // Update meta-channel count if this step touched meta channels.
        if begin < image.nbMetaChannels {
            image.nbMetaChannels &-= num
        }
    }
}
