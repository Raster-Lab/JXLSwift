// ColorCorrelationMap — JPEG XL's chroma-from-luma (CfL) decorrelator.
//
// For VarDCT-XYB frames, the X and B chroma planes are heavily
// correlated with the Y luma plane. CfL exploits this by storing
// per-tile slope coefficients that say "X ≈ Y · slopeX" — the
// encoder subtracts `Y · slopeX` from X before quantising, the
// decoder adds it back.
//
// Spec: ISO/IEC 18181-1 §K.5. libjxl: `lib/jxl/chroma_from_luma.h`,
// `lib/jxl/chroma_from_luma.cc`. Per-tile slopes (`ytox_map`,
// `ytob_map`) are signed 8-bit ints; the actual slope is
// `base_correlation + slope_int / color_factor` (libjxl
// `ColorCorrelation::YtoXRatio`).
//
// **Status**: standalone math (apply / unapply for a single 8×8
// block). The bitstream layout for the tile maps + DC offsets
// lives in the AC-global section and lands when that decoder path
// catches up — for now this struct gives later code a clean place
// to plug into.

import Foundation

/// One color-correlation tile covers `kColorTileDim × kColorTileDim`
/// pixels (= 8 × 8 blocks per tile when the spec's `kBlockDim = 8`).
public let kColorTileDim: Int = 64
/// Same as above expressed in 8×8 blocks.
public let kColorTileDimInBlocks: Int = kColorTileDim / 8
/// libjxl's `kDefaultColorFactor` — the divisor that converts the
/// signed-byte tile slope to a fractional Y→X / Y→B ratio.
public let kDefaultColorFactor: UInt32 = 84
/// Spec-default base correlation for the X channel (no a-priori
/// correlation between Y and X).
public let kBaseCorrelationX: Float = 0.0
/// Spec-default base correlation for B (libjxl `kYToBRatio`).
public let kBaseCorrelationB: Float = 1.0

/// Per-frame chroma-from-luma parameters that apply to every tile.
/// Mirrors libjxl `ColorCorrelation` minus the JPEG-reconstruct
/// helpers we don't need here.
public struct ColorCorrelation: Sendable, Equatable {
    /// Y→X tile-slope divisor. Larger values give finer-grained
    /// adjustment; libjxl's encoder may emit non-default values for
    /// content with unusual chroma-luma correlation.
    public var colorFactor: UInt32
    /// `ytox_dc` / `ytob_dc` — DC-plane Y-to-chroma correlation
    /// offsets, in the same int32 units the tile slopes use.
    public var ytoxDC: Int32
    public var ytobDC: Int32
    /// Frame-level base ratios (constants per spec; left as fields
    /// in case future profiles flex them).
    public var baseCorrelationX: Float
    public var baseCorrelationB: Float

    public init(
        colorFactor: UInt32 = kDefaultColorFactor,
        ytoxDC: Int32 = 0,
        ytobDC: Int32 = 0,
        baseCorrelationX: Float = kBaseCorrelationX,
        baseCorrelationB: Float = kBaseCorrelationB
    ) {
        self.colorFactor = colorFactor
        self.ytoxDC = ytoxDC
        self.ytobDC = ytobDC
        self.baseCorrelationX = baseCorrelationX
        self.baseCorrelationB = baseCorrelationB
    }

    /// Convert a signed-byte tile slope into the actual `Y→X`
    /// multiplier the decoder applies inside the tile.
    @inline(__always)
    public func ytoXRatio(slope: Int32) -> Float {
        return baseCorrelationX + Float(slope) / Float(colorFactor)
    }

    @inline(__always)
    public func ytoBRatio(slope: Int32) -> Float {
        return baseCorrelationB + Float(slope) / Float(colorFactor)
    }

    /// DC-plane scalars — the X / B DC residuals are decorrelated
    /// against Y DC by these factors.
    public var ytoxDCRatio: Float { ytoXRatio(slope: ytoxDC) }
    public var ytobDCRatio: Float { ytoBRatio(slope: ytobDC) }

    /// Read libjxl `ColorCorrelation::DecodeDC`. 1-bit
    /// `all_default` shortcut + the full non-default branch:
    ///   - `color_factor` U32(Val(84), Val(256), 2+u(8), 258+u(16))
    ///   - `base_correlation_x` F16 (range [-4, 4])
    ///   - `base_correlation_b` F16 (range [kYToBRatio - 4, +4])
    ///   - `ytox_dc` 8-bit unsigned shifted by `Int8.min`
    ///   - `ytob_dc` 8-bit unsigned shifted by `Int8.min`
    public static func readDC(
        from r: inout BitReader
    ) throws -> ColorCorrelation {
        let allDefault: Bool
        do { allDefault = try r.readBit() }
        catch let e as BitstreamError {
            throw ColorCorrelationError.bitstream(e)
        }
        if allDefault { return ColorCorrelation() }
        // libjxl `kColorFactorDist`: U32(Val(84), Val(256),
        // 2+u(8), 258+u(16)).
        let colorFactor: UInt32
        do {
            colorFactor = try r.readU32((
                .literal(kDefaultColorFactor),
                .literal(256),
                .offset(constant: 2, extraBits: 8),
                .offset(constant: 258, extraBits: 16)
            ))
        } catch let e as BitstreamError {
            throw ColorCorrelationError.bitstream(e)
        }
        let baseX: Float
        let baseB: Float
        do {
            let xBits = try r.read(bits: 16)
            baseX = halfToFloat(UInt16(xBits))
            let bBits = try r.read(bits: 16)
            baseB = halfToFloat(UInt16(bBits))
        } catch let e as BitstreamError {
            throw ColorCorrelationError.bitstream(e)
        }
        // libjxl rejects out-of-range base correlations.
        guard abs(baseX) <= 4.0 else {
            throw ColorCorrelationError.outOfRange(
                "base_correlation_x = \(baseX) outside [-4, 4]"
            )
        }
        guard abs(baseB - kBaseCorrelationB) <= 4.0 else {
            throw ColorCorrelationError.outOfRange(
                "base_correlation_b = \(baseB) outside "
                + "[\(kBaseCorrelationB) ± 4]"
            )
        }
        let ytoxRaw: UInt32, ytobRaw: UInt32
        do {
            ytoxRaw = try r.read(bits: 8)
            ytobRaw = try r.read(bits: 8)
        } catch let e as BitstreamError {
            throw ColorCorrelationError.bitstream(e)
        }
        // libjxl: `static_cast<int>(read) + Int8.min`. The 8-bit
        // unsigned read is biased by 128 to recover the signed
        // value in [-128, 127].
        let ytoxDC = Int32(ytoxRaw) - 128
        let ytobDC = Int32(ytobRaw) - 128
        return ColorCorrelation(
            colorFactor: colorFactor,
            ytoxDC: ytoxDC, ytobDC: ytobDC,
            baseCorrelationX: baseX, baseCorrelationB: baseB
        )
    }

    /// Compatibility shim: the older skeleton throws
    /// `.notDefault` when the bitstream specifies a custom
    /// ColorCorrelation. Now that we have the full reader, route
    /// through it. Kept as a separate entry point so callers can
    /// distinguish "I expect default" from "give me whatever's
    /// here".
    public static func readDCDefaultOrThrow(
        from r: inout BitReader
    ) throws -> ColorCorrelation {
        return try readDC(from: &r)
    }
}

public enum ColorCorrelationError: Error, Sendable {
    case bitstream(BitstreamError)
    case notDefault
    case outOfRange(String)
}

/// Per-tile slope maps for a frame. Each map covers
/// `ceil(xsize / kColorTileDim) × ceil(ysize / kColorTileDim)` tiles;
/// each entry is a signed byte (-128…127).
public struct ColorCorrelationMap: Sendable, Equatable {
    public var base: ColorCorrelation
    public var ytox: [Int8]   // row-major, length tilesX * tilesY
    public var ytob: [Int8]   // row-major, length tilesX * tilesY
    public let tilesX: Int
    public let tilesY: Int

    public init(xsize: Int, ysize: Int, base: ColorCorrelation = .init()) {
        self.base = base
        self.tilesX = (xsize + kColorTileDim - 1) / kColorTileDim
        self.tilesY = (ysize + kColorTileDim - 1) / kColorTileDim
        let n = tilesX * tilesY
        self.ytox = [Int8](repeating: 0, count: n)
        self.ytob = [Int8](repeating: 0, count: n)
    }

    /// Look up the X-channel slope for the tile that contains
    /// pixel `(x, y)`.
    @inline(__always)
    public func ytoxAt(_ x: Int, _ y: Int) -> Int32 {
        let tx = x / kColorTileDim
        let ty = y / kColorTileDim
        return Int32(ytox[ty * tilesX + tx])
    }

    @inline(__always)
    public func ytobAt(_ x: Int, _ y: Int) -> Int32 {
        let tx = x / kColorTileDim
        let ty = y / kColorTileDim
        return Int32(ytob[ty * tilesX + tx])
    }
}

public enum ChromaFromLuma {

    /// Encoder-side: `residualX = X - Y · YtoX(slope)`. Caller
    /// applies this per-pixel before quantising the X plane.
    /// Same shape (`yPlane`, `xPlane` are aligned, length
    /// `width * height`).
    public static func decorrelateX(
        x xPlane: inout [Float], y yPlane: [Float],
        width: Int, height: Int, map: ColorCorrelationMap
    ) {
        precondition(xPlane.count == width * height &&
                     yPlane.count == width * height)
        for yy in 0..<height {
            for xx in 0..<width {
                let slope = map.ytoxAt(xx, yy)
                let r = map.base.ytoXRatio(slope: slope)
                xPlane[yy * width + xx] -= yPlane[yy * width + xx] * r
            }
        }
    }

    /// Decoder-side: `X = residualX + Y · YtoX(slope)`. Caller
    /// applies this per-pixel after dequantising.
    public static func recorrelateX(
        x xPlane: inout [Float], y yPlane: [Float],
        width: Int, height: Int, map: ColorCorrelationMap
    ) {
        precondition(xPlane.count == width * height &&
                     yPlane.count == width * height)
        for yy in 0..<height {
            for xx in 0..<width {
                let slope = map.ytoxAt(xx, yy)
                let r = map.base.ytoXRatio(slope: slope)
                xPlane[yy * width + xx] += yPlane[yy * width + xx] * r
            }
        }
    }

    /// Same as `decorrelateX` but for the B plane.
    public static func decorrelateB(
        b bPlane: inout [Float], y yPlane: [Float],
        width: Int, height: Int, map: ColorCorrelationMap
    ) {
        precondition(bPlane.count == width * height &&
                     yPlane.count == width * height)
        for yy in 0..<height {
            for xx in 0..<width {
                let slope = map.ytobAt(xx, yy)
                let r = map.base.ytoBRatio(slope: slope)
                bPlane[yy * width + xx] -= yPlane[yy * width + xx] * r
            }
        }
    }

    /// Inverse of `decorrelateB`.
    public static func recorrelateB(
        b bPlane: inout [Float], y yPlane: [Float],
        width: Int, height: Int, map: ColorCorrelationMap
    ) {
        precondition(bPlane.count == width * height &&
                     yPlane.count == width * height)
        for yy in 0..<height {
            for xx in 0..<width {
                let slope = map.ytobAt(xx, yy)
                let r = map.base.ytoBRatio(slope: slope)
                bPlane[yy * width + xx] += yPlane[yy * width + xx] * r
            }
        }
    }
}
