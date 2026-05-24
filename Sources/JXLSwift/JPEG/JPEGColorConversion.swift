// YCbCr → RGB colour conversion for JFIF / standard JPEG output —
// twelfth step on the Phase J road. JFIF (the dominant JPEG
// profile) uses BT.601 with full-range pivots (the spec calls
// these "PC" pivots — chroma 0..255 maps to −128..+127 after
// subtracting 128, and luma 0..255 maps to 0..255 directly,
// no studio-range head-/foot-room).
//
// JFIF formula (CCIR 601 full-range, ITU-R BT.601-7 inverse):
//
//     R = Y + 1.402   · (Cr − 128)
//     G = Y − 0.344136· (Cb − 128) − 0.714136 · (Cr − 128)
//     B = Y + 1.772   · (Cb − 128)
//
// Clamped to [0, 255]. Grayscale JPEGs (single Y component) pass
// through unchanged.
//
// Adobe-marker JPEGs that use YCCK / CMYK colour transforms hit
// a different code path — those land here as a follow-on.

import Foundation

public enum JPEGColorConversion {

    /// Convert a triplet of equal-size sample planes (Y, Cb, Cr)
    /// to a row-major RGB byte buffer of the same dimensions.
    /// All three planes must share `width` × `height`; callers
    /// upsample subsampled chroma via
    /// `JPEGPixelAssembler.upsampleNearest(...)` first.
    public static func ycbcrToRGB8(
        y: JPEGSamplePlane,
        cb: JPEGSamplePlane,
        cr: JPEGSamplePlane
    ) -> [UInt8] {
        precondition(y.width == cb.width && cb.width == cr.width
            && y.height == cb.height && cb.height == cr.height,
            "ycbcrToRGB8: all three planes must share dimensions")
        let n = y.width * y.height
        var rgb = [UInt8](repeating: 0, count: n * 3)
        for i in 0..<n {
            let Y = Float(y.samples[i])
            let Cb = Float(cb.samples[i]) - 128
            let Cr = Float(cr.samples[i]) - 128
            let r = Y + 1.402 * Cr
            let g = Y - 0.344136 * Cb - 0.714136 * Cr
            let b = Y + 1.772 * Cb
            rgb[i * 3 + 0] = clamp8(r)
            rgb[i * 3 + 1] = clamp8(g)
            rgb[i * 3 + 2] = clamp8(b)
        }
        return rgb
    }

    /// Single grayscale plane → row-major grayscale byte buffer.
    /// Just a typed convenience over the `Int32 → UInt8` clamp.
    public static func grayscaleToBuffer(
        _ plane: JPEGSamplePlane
    ) -> [UInt8] {
        return plane.samples.map { s -> UInt8 in
            if s < 0 { return 0 }
            if s > 255 { return 255 }
            return UInt8(s)
        }
    }

    private static func clamp8(_ v: Float) -> UInt8 {
        let r = v.rounded(.toNearestOrAwayFromZero)
        if r < 0 { return 0 }
        if r > 255 { return 255 }
        return UInt8(r)
    }
}
