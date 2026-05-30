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

package enum InverseTransformsError: Error, Sendable {
    case rct(SpecRCTError)
    case squeeze(SpecSqueezeError)
    case paletteNotImplemented
    case paletteMissingTable
    case paletteUnsupportedDelta
    case paletteUnsupportedPredictor(UInt32)
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
package func applyInverseTransforms(
    image: inout ModularImage, transforms: [ModularTransform]
) throws {
    for t in transforms.reversed() {
        switch t.id {
        case .rct:
            try applyInverseRCT(image: &image, transform: t)
        case .squeeze:
            try applyInverseSqueeze(image: &image, transform: t)
        case .palette:
            try applyInversePalette(image: &image, transform: t)
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

/// Inverse Palette transform — libjxl
/// `lib/jxl/modular/transform/palette.cc::InvPalette`. After
/// MetaPalette ran during the forward pass, `image.channels[0]` is
/// the palette table (size `(nb_colors + nb_deltas) × nb`) and
/// `image.channels[begin_c + 1]` is the per-pixel index channel.
/// This routine expands the index channel into `nb` separate output
/// channels and removes the palette table.
///
/// **Currently supports**: the simple lookup case
/// (`nb_deltas == 0` and `predictor == Zero`). Delta-palette and
/// predicted variants throw structured errors. The lookup honours
/// libjxl's `palette_internal::GetPaletteValue` fall-backs for
/// negative indices (delta palette) and out-of-range positive
/// indices (RGB cube fall-back), which appear in cjxl-emitted
/// streams even when `nb_deltas == 0`.
private func applyInversePalette(
    image: inout ModularImage, transform t: ModularTransform
) throws {
    guard image.nbMetaChannels >= 1, !image.channels.isEmpty else {
        throw InverseTransformsError.paletteMissingTable
    }
    let nb = Int(t.numC)
    let nbDeltas = Int(t.nbDeltas)
    let predictor = t.palettePredictor
    if nbDeltas != 0 {
        throw InverseTransformsError.paletteUnsupportedDelta
    }
    if predictor != 0 {
        // Predictor 0 = Zero (libjxl `Predictor::Zero`). Other
        // predictor IDs require the per-pixel predict + add path.
        throw InverseTransformsError.paletteUnsupportedPredictor(predictor)
    }
    // Index channel is at position `begin_c + 1` (begin_c is the new
    // location of the index channel after MetaPalette inserted the
    // palette table at position 0). libjxl: `c0 = begin_c + 1`.
    let beginC = Int(t.beginC)
    let c0 = beginC + 1
    guard c0 < image.channels.count else {
        throw InverseTransformsError.channelOutOfRange(
            begin: t.beginC, num: t.numC,
            channels: image.channels.count
        )
    }
    let palette = image.channels[0]
    let indexChannel = image.channels[c0]
    let w = indexChannel.width
    let h = indexChannel.height
    let paletteSize = palette.width
    // Insert nb-1 fresh channels right after c0 (libjxl inserts in
    // a loop so the pre-existing tail is pushed right by nb-1).
    if nb > 1 {
        for _ in 1..<nb {
            image.channels.insert(
                ModularChannel(width: w, height: h,
                               hshift: indexChannel.hshift,
                               vshift: indexChannel.vshift),
                at: c0 + 1
            )
        }
    }
    // Save the index channel's pixels (we'll overwrite c0 with c=0
    // output, so capture indices first).
    let indices = indexChannel.pixels
    // bit_depth — libjxl uses min(input.bitdepth, 24). For our
    // current scope we don't track bitdepth in ModularImage, so
    // approximate with 8 (cjxl-typical for RGB inputs). Real
    // wiring should pull this from ImageMetadata; tracked as a
    // follow-up.
    let bitDepth = 8
    for c in 0..<nb {
        var out = [Int32](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let idx = Int(indices[y * w + x])
                let v = paletteValue(
                    palette: palette, index: idx, c: c,
                    paletteSize: paletteSize,
                    bitDepth: bitDepth
                )
                out[y * w + x] = v
            }
        }
        image.channels[c0 + c].pixels = out
    }
    // Remove the palette table from position 0.
    image.channels.removeFirst()
    // Update meta-channel count (libjxl's logic).
    if c0 - 1 >= image.nbMetaChannels {
        // Palette was on normal channels: lose 1 meta channel
        // (the palette table).
        image.nbMetaChannels &-= 1
    } else {
        // Palette was on meta channels: regain `2 - nb` meta
        // channels.
        image.nbMetaChannels &-= 2 - nb
    }
}

/// libjxl `palette_internal::GetPaletteValue`. Looks up the palette
/// table for `index` in [0, paletteSize); for indices outside that
/// range, returns synthetic fall-back values per the spec
/// (delta-palette table for `index < 0`, RGB cube fall-backs for
/// `index >= paletteSize`).
private func paletteValue(
    palette: ModularChannel, index: Int, c: Int,
    paletteSize: Int, bitDepth: Int
) -> Int32 {
    let kRgbChannels = 3
    let kSmallCube = 4
    let kSmallCubeBits = 2
    let kLargeCube = 5
    let kLargeCubeOffset = kSmallCube * kSmallCube * kSmallCube
    if index < 0 {
        // Delta-palette fallback. 72-entry table, alternating sign.
        if c >= kRgbChannels { return 0 }
        let kDelta: [(Int32, Int32, Int32)] = [
            (0, 0, 0), (4, 4, 4), (11, 0, 0), (0, 0, -13),
            (0, -12, 0), (-10, -10, -10), (-18, -18, -18), (-27, -27, -27),
            (-18, -18, 0), (0, 0, -32), (-32, 0, 0), (-37, -37, -37),
            (0, -32, -32), (24, 24, 45), (50, 50, 50), (-45, -24, -24),
            (-24, -45, -45), (0, -24, -24), (-34, -34, 0), (-24, 0, -24),
            (-45, -45, -24), (64, 64, 64), (-32, 0, -32), (0, -32, 0),
            (-32, 0, 32), (-24, -45, -24), (45, 24, 45), (24, -24, -45),
            (-45, -24, 24), (80, 80, 80), (64, 0, 0), (0, 0, -64),
            (0, -64, -64), (-24, -24, 45), (96, 96, 96), (64, 64, 0),
            (45, -24, -24), (34, -34, 0), (112, 112, 112), (24, -45, -45),
            (45, 45, -24), (0, -32, 32), (24, -24, 45), (0, 96, 96),
            (45, -24, 24), (24, -45, -24), (-24, -45, 24), (0, -64, 0),
            (96, 0, 0), (128, 128, 128), (64, 0, 64), (144, 144, 144),
            (96, 96, 0), (-36, -36, 36), (45, -24, -45), (45, -45, -24),
            (0, 0, -96), (0, 128, 128), (0, 96, 0), (45, 24, -45),
            (-128, 0, 0), (24, -45, 24), (-45, 24, -45), (64, 0, -64),
            (64, -64, -64), (96, 0, 96), (45, -45, 24), (24, 45, -45),
            (64, 64, -64), (128, 128, 0), (0, 0, -128), (-24, 45, -45)
        ]
        var idx2 = -(index + 1)
        idx2 %= 1 + 2 * (kDelta.count - 1)
        let half = (idx2 + 1) >> 1
        let entry = kDelta[half]
        let multiplier: Int32 = (idx2 & 1) == 0 ? -1 : 1
        var result: Int32
        switch c {
        case 0: result = entry.0 &* multiplier
        case 1: result = entry.1 &* multiplier
        default: result = entry.2 &* multiplier
        }
        if bitDepth > 8 {
            result &*= Int32(1 &<< (bitDepth - 8))
        }
        return result
    }
    if index < paletteSize {
        // Direct palette lookup. Palette layout: row c contains the
        // c-th component for each palette entry (libjxl's
        // `palette[c * onerow + index]` with `onerow = palette.w`).
        if c >= palette.height { return 0 }
        let p = palette.pixels[c * palette.width + index]
        return p
    }
    // index >= paletteSize: synthetic cube fall-backs.
    if c >= kRgbChannels { return 0 }
    let smallCubeEnd = paletteSize + kLargeCubeOffset
    if index < smallCubeEnd {
        // Small-cube fall-back.
        let i0 = index - paletteSize
        let i1 = i0 >> (c * kSmallCubeBits)
        let v = i1 % kSmallCube
        // libjxl's Scale<kSmallCube>: (value * ((1<<bitDepth) - 1)) >> 2.
        let scaled = (UInt64(v) * (UInt64(1 << bitDepth) - 1)) >> 2
        return Int32(scaled) &+ Int32(1 &<< max(0, bitDepth - 3))
    }
    // Large-cube fall-back.
    var i0 = index - smallCubeEnd
    switch c {
    case 1: i0 /= kLargeCube
    case 2: i0 /= kLargeCube * kLargeCube
    default: break
    }
    let v = i0 % kLargeCube
    // Scale<kLargeCube - 1>: divide by 4.
    let scaled = (UInt64(v) * (UInt64(1 << bitDepth) - 1)) >> 2
    return Int32(scaled)
}
