// ModularImage — list of channels carrying the on-the-wire geometry
// for a Modular sub-bitstream.
//
// ISO/IEC 18181-1 §C.7 (libjxl `lib/jxl/modular/modular_image.h`).
// A Modular image is a list of channels, each with its own
// `(width, height, hshift, vshift)`. Initial channels come from the
// frame metadata (color channels + extra channels); after the
// `GroupHeader.transforms` are meta-applied the list grows or shrinks
// (Squeeze adds residual channels, Palette removes coloured channels
// and adds an index channel, RCT keeps the count but reassigns
// semantics).
//
// **`hshift` / `vshift`** track how many times each channel has been
// halved by Squeeze. The on-the-wire dimension at decode time is
// `(xsize >> hshift, ysize >> vshift)` rounded up. After the inverse
// transform pass, all colour channels return to the same geometry
// as channel 0.
//
// **`nbMetaChannels`** counts channels at the front that don't carry
// pixel data (palette tables, etc.). In our minimal scope we don't
// emit Palette, so `nbMetaChannels == 0` for files we can decode.

import Foundation

/// One channel inside a `ModularImage`. Pixel data is row-major
/// `[Int32]`, `width × height`. `hshift` / `vshift` count how many
/// Squeeze halvings have been applied (initial 0 = full resolution).
package struct ModularChannel: Sendable, Equatable {
    package var width: Int
    package var height: Int
    package var hshift: Int
    package var vshift: Int
    package var pixels: [Int32]

    package init(width: Int, height: Int,
                hshift: Int = 0, vshift: Int = 0,
                pixels: [Int32]? = nil) {
        self.width = width
        self.height = height
        self.hshift = hshift
        self.vshift = vshift
        self.pixels = pixels ?? [Int32](repeating: 0, count: width * height)
    }
}

package struct ModularImage: Sendable, Equatable {
    package var channels: [ModularChannel]
    package var nbMetaChannels: Int

    package init(channels: [ModularChannel], nbMetaChannels: Int = 0) {
        self.channels = channels
        self.nbMetaChannels = nbMetaChannels
    }

    /// Construct a fresh ModularImage with `nbColor + nbExtra`
    /// channels at full resolution (no transforms applied yet).
    package static func fresh(
        xsize: Int, ysize: Int, nbColor: Int, nbExtra: Int = 0
    ) -> ModularImage {
        var chs = [ModularChannel]()
        chs.reserveCapacity(nbColor + nbExtra)
        for _ in 0..<(nbColor + nbExtra) {
            chs.append(ModularChannel(width: xsize, height: ysize))
        }
        return ModularImage(channels: chs, nbMetaChannels: 0)
    }
}

package enum MetaApplyError: Error, Sendable {
    case unsupportedRCTType(UInt32)
    case paletteUnsupported
    case paletteRangeInvalid(begin: UInt32, numC: UInt32, channels: Int)
    case paletteUnequalChannels(begin: UInt32, numC: UInt32)
    case squeezeMetaMix
    case squeezeMetaInPlace
    case squeezeRangeInvalid(begin: UInt32, num: UInt32, channels: Int)
    case squeezeShiftOverflow
    case squeezeEmptyChannel
}

/// Mirror of libjxl `Transform::MetaApply` — apply each transform's
/// **geometry** changes to `image.channels` (no pixel data is read or
/// written). Order matters: transforms are applied in the order they
/// appear in the GroupHeader's transform list, and inverse transforms
/// run in reverse order on the decoded channels.
///
/// Currently handles RCT (no geometry change) and Squeeze (channel
/// list reshape). Palette is rejected with `.paletteUnsupported` —
/// not yet ported.
package func metaApplyTransforms(
    image: inout ModularImage, transforms: [ModularTransform]
) throws {
    for t in transforms {
        switch t.id {
        case .rct:
            // Geometry is unchanged.
            continue
        case .palette:
            try metaApplyPalette(image: &image, transform: t)
        case .squeeze:
            try metaApplySqueeze(image: &image, params: t.squeezes)
        }
    }
}

/// Apply `MetaPalette` to `image.channels`. Mirrors libjxl
/// `lib/jxl/modular/transform/palette.cc::MetaPalette`. The forward
/// Palette transform replaces channels `[begin_c, begin_c+numC-1]`
/// with a single index channel at position `begin_c`; a meta channel
/// holding the palette table (size `(nb_colors + nb_deltas) × numC`,
/// hshift=-1, vshift=-1) is inserted at position 0.
///
/// **Pre-condition:** the channels in the range must all have the
/// same `(w, h, hshift, vshift)`. We mirror libjxl's
/// `CheckEqualChannels`.
private func metaApplyPalette(
    image: inout ModularImage, transform t: ModularTransform
) throws {
    let beginC = Int(t.beginC)
    let nb = Int(t.numC)
    let endC = beginC + nb - 1
    guard nb >= 1, beginC >= 0, endC < image.channels.count else {
        throw MetaApplyError.paletteRangeInvalid(
            begin: t.beginC, numC: t.numC,
            channels: image.channels.count
        )
    }
    // Check equal dims across the palette range. Half-open range so
    // `numC == 1` (endC == beginC) is a no-op rather than a `1...0`
    // range trap.
    let ref = image.channels[beginC]
    for c in (beginC + 1)..<(endC + 1) {
        let ch = image.channels[c]
        if ch.width != ref.width || ch.height != ref.height
            || ch.hshift != ref.hshift || ch.vshift != ref.vshift {
            throw MetaApplyError.paletteUnequalChannels(
                begin: t.beginC, numC: t.numC
            )
        }
    }
    // Update meta-channel count (libjxl branches on whether the
    // palette range overlaps the existing meta range).
    if beginC >= image.nbMetaChannels {
        // Palette is on normal channels: gain one meta channel
        // (the palette table).
        image.nbMetaChannels &+= 1
    } else {
        // Palette is on meta channels: lose nb-1 meta channels
        // and gain one (palette table).
        image.nbMetaChannels &+= 2 - nb
    }
    // Drop channels [beginC+1, endC] (keep beginC; it becomes the
    // index channel).
    if nb > 1 {
        image.channels.removeSubrange((beginC + 1)...endC)
    }
    // Insert the palette table channel at position 0.
    let paletteW = Int(t.nbColors) + Int(t.nbDeltas)
    let paletteH = nb
    image.channels.insert(
        ModularChannel(width: paletteW, height: paletteH,
                       hshift: -1, vshift: -1),
        at: 0
    )
}

/// Default-squeeze-parameter generator — mirror of libjxl
/// `DefaultSqueezeParameters`. Returns the implicit list when the
/// transform's `squeezes` array is empty.
package func defaultSqueezeParameters(
    image: ModularImage
) -> [ModularTransform.SqueezeParams] {
    let kMaxFirstPreviewSize: Int = 8
    let nbChannels = image.channels.count - image.nbMetaChannels
    var out: [ModularTransform.SqueezeParams] = []
    if nbChannels < 1 { return out }
    let firstColor = image.nbMetaChannels
    var w = image.channels[firstColor].width
    var h = image.channels[firstColor].height

    // 4:2:0 chroma branch: if channels 1 and 2 match channel 0,
    // squeeze them first.
    if nbChannels > 2,
       image.channels[firstColor + 1].width == w,
       image.channels[firstColor + 1].height == h {
        out.append(ModularTransform.SqueezeParams(
            horizontal: true, inPlace: false,
            beginC: UInt32(firstColor + 1), numC: 2
        ))
        out.append(ModularTransform.SqueezeParams(
            horizontal: false, inPlace: false,
            beginC: UInt32(firstColor + 1), numC: 2
        ))
    }
    // Main channel-list squeeze.
    let beginAll = UInt32(firstColor)
    let numAll = UInt32(nbChannels)
    let wide = w > h

    if !wide, h > kMaxFirstPreviewSize {
        out.append(ModularTransform.SqueezeParams(
            horizontal: false, inPlace: true,
            beginC: beginAll, numC: numAll
        ))
        h = (h + 1) / 2
    }
    while w > kMaxFirstPreviewSize || h > kMaxFirstPreviewSize {
        if w > kMaxFirstPreviewSize {
            out.append(ModularTransform.SqueezeParams(
                horizontal: true, inPlace: true,
                beginC: beginAll, numC: numAll
            ))
            w = (w + 1) / 2
        }
        if h > kMaxFirstPreviewSize {
            out.append(ModularTransform.SqueezeParams(
                horizontal: false, inPlace: true,
                beginC: beginAll, numC: numAll
            ))
            h = (h + 1) / 2
        }
    }
    return out
}

/// Apply `MetaSqueeze` to `image.channels`. For each squeeze step:
/// the input channels at `[beginC, beginC+numC)` are halved along
/// the chosen axis, and a placeholder channel of equal halved size
/// is inserted right after them (`in_place=true`) or at the end
/// (`in_place=false`). The caller-supplied `params` may be empty;
/// libjxl uses `DefaultSqueezeParameters` to fill them in then.
private func metaApplySqueeze(
    image: inout ModularImage,
    params paramsIn: [ModularTransform.SqueezeParams]
) throws {
    let params = paramsIn.isEmpty
        ? defaultSqueezeParameters(image: image)
        : paramsIn
    for param in params {
        let begin = Int(param.beginC)
        let num = Int(param.numC)
        let end = begin + num - 1
        guard begin >= 0, num > 0, end < image.channels.count else {
            throw MetaApplyError.squeezeRangeInvalid(
                begin: param.beginC, num: param.numC,
                channels: image.channels.count
            )
        }
        // Validate meta-channel rules.
        if begin < image.nbMetaChannels {
            if end >= image.nbMetaChannels {
                throw MetaApplyError.squeezeMetaMix
            }
            if !param.inPlace {
                throw MetaApplyError.squeezeMetaInPlace
            }
            image.nbMetaChannels &+= num
        }
        let offset = param.inPlace ? end + 1 : image.channels.count
        // Insert placeholders one at a time. We compute their sizes
        // from the still-full source channel BEFORE shrinking.
        // libjxl inserts at `offset + (c - beginc)` so the existing
        // tail is pushed right consistently.
        var insertions: [(Int, ModularChannel)] = []
        insertions.reserveCapacity(num)
        for c in begin...end {
            let w = image.channels[c].width
            let h = image.channels[c].height
            if image.channels[c].hshift > 30 || image.channels[c].vshift > 30 {
                throw MetaApplyError.squeezeShiftOverflow
            }
            if w == 0 || h == 0 {
                throw MetaApplyError.squeezeEmptyChannel
            }
            var newW = w
            var newH = h
            var resW = w
            var resH = h
            if param.horizontal {
                newW = (w + 1) / 2
                if image.channels[c].hshift >= 0 {
                    image.channels[c].hshift &+= 1
                }
                resW = w - newW
                resH = h
            } else {
                newH = (h + 1) / 2
                if image.channels[c].vshift >= 0 {
                    image.channels[c].vshift &+= 1
                }
                resW = w
                resH = h - newH
            }
            image.channels[c].width = newW
            image.channels[c].height = newH
            image.channels[c].pixels = [Int32](
                repeating: 0, count: newW * newH
            )
            let placeholder = ModularChannel(
                width: resW, height: resH,
                hshift: image.channels[c].hshift,
                vshift: image.channels[c].vshift
            )
            insertions.append((offset + (c - begin), placeholder))
        }
        // Apply insertions in order. Since each insertion shifts the
        // subsequent positions, the libjxl formula `offset + (c -
        // beginc)` already accounts for that — each successive
        // insertion's index is one greater than the previous, which
        // is correct because the previous insertion pushed the array
        // by one slot at that exact position.
        for (idx, ch) in insertions {
            image.channels.insert(ch, at: idx)
        }
    }
}
