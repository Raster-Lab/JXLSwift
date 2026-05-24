// Encoding configuration: mode, effort, and a few common knobs that map
// directly onto libjxl's `JxlEncoderFrameSettings`.

import Foundation

/// What kind of compression to apply.
public enum CompressionMode: Sendable, Equatable {
    /// Bit-exact lossless compression. Maps to libjxl distance = 0.0.
    case lossless
    /// Quality-driven lossy compression. `quality` is a 0…100 score where
    /// 90 is visually lossless on photographic content and 100 is near-
    /// transparent. Mapped to libjxl distance via the standard quality→
    /// distance curve from `cjxl --quality`.
    case lossy(quality: Float)
    /// Distance-driven lossy compression. Smaller is higher quality.
    /// `0.0` is lossless. The libjxl-recommended sweet spot is `1.0`.
    /// Maximum value is `25.0`.
    case distance(Float)
}

/// libjxl effort levels. Higher = slower + smaller output.
public enum EncodingEffort: Int, Sendable {
    case lightning = 1
    case thunder   = 2
    case falcon    = 3
    case cheetah   = 4
    case hare      = 5
    case wombat    = 6
    case squirrel  = 7
    case kitten    = 8
    case tortoise  = 9
}

/// Encoding configuration. Sensible defaults for the common case.
public struct EncodingOptions: Sendable {
    public var mode: CompressionMode
    public var effort: EncodingEffort
    /// Use libjxl's progressive DC encoding (multi-pass delivery).
    public var progressive: Bool
    /// Number of decoder threads to spawn during encoding. `0` means
    /// "let libjxl pick".
    public var numThreads: Int
    /// Use the project-internal M0 placeholder format instead of
    /// throwing `.notImplemented`. The output **is not** a JPEG XL
    /// file — it carries the project-internal `0x4D30` marker so a
    /// future spec-compliant decoder can recognise and reject it.
    /// Useful as a working lossless codec while the real Phase M
    /// pipeline is built out. See `MinimalLosslessCodec`.
    public var useM0Placeholder: Bool
    /// When `useM0Placeholder` is true, controls the M0 effort knob
    /// (`.balanced` tries every predictor + RCT variant; `.fast`
    /// skips the search for ~3× faster encode). Ignored otherwise.
    public var m0Effort: M0Effort
    /// Wrap the codestream in an ISOBMFF (`.jxl`) container instead
    /// of emitting it naked. Real-world tooling (browsers, OS image
    /// loaders, `djxl`) accepts both, but the wrapped form is the
    /// canonical on-disk representation and the only one that can
    /// later carry sidecar data (EXIF, JUMBF, JPEG-reconstruct
    /// boxes). Defaults to true to match cjxl's behaviour.
    public var containerWrap: Bool
    /// VarDCT-only: apply the libjxl 5×5 inverse-Gaborish
    /// sharpening pre-pass to XYB pixels before the forward DCT,
    /// and write `lf.gab = true` in the frame header so the decoder
    /// runs the matching forward Gaborish smoothing pass. Defaults
    /// to `true` (libjxl-default behaviour). Ignored for lossless
    /// (Modular) encodes — those don't go through VarDCT.
    public var gaborish: Bool
    /// VarDCT-only: per-block variance-driven adaptive
    /// quantisation factor. Smoother cells get a coarser QF
    /// (= fewer bits on near-zero AC), textured cells get a finer
    /// one (= preserve detail). Defaults to `true` (libjxl-like
    /// adaptive quant behaviour). Ignored for lossless encodes.
    public var adaptiveQF: Bool
    /// Multi-frame only: per-frame duration in libjxl-default
    /// 100-tps timestamp units (= 10 ms each). Default 10 → 100 ms
    /// per frame. Applied uniformly to every frame in an animation
    /// encode (`JXLEncoder.encode([ImageFrame])`); ignored for
    /// single-frame encodes. Overridden by `frameDurations` when
    /// that is set.
    public var defaultFrameDuration: UInt32
    /// Multi-frame only: per-frame duration override. When non-nil,
    /// must have one entry per frame (`count == frames.count`);
    /// when nil, every frame uses `defaultFrameDuration`. Lets
    /// callers do variable-pace animations (slow intro frame, fast
    /// middle, slow end frame, …).
    public var frameDurations: [UInt32]?

    public init(
        mode: CompressionMode = .lossy(quality: 90),
        effort: EncodingEffort = .squirrel,
        progressive: Bool = false,
        numThreads: Int = 0,
        useM0Placeholder: Bool = false,
        m0Effort: M0Effort = .balanced,
        containerWrap: Bool = true,
        gaborish: Bool = true,
        adaptiveQF: Bool = true,
        defaultFrameDuration: UInt32 = 10,
        frameDurations: [UInt32]? = nil
    ) {
        self.mode = mode
        self.effort = effort
        self.progressive = progressive
        self.numThreads = numThreads
        self.useM0Placeholder = useM0Placeholder
        self.m0Effort = m0Effort
        self.containerWrap = containerWrap
        self.gaborish = gaborish
        self.adaptiveQF = adaptiveQF
        self.defaultFrameDuration = defaultFrameDuration
        self.frameDurations = frameDurations
    }

    /// The libjxl distance value that this configuration maps to. Used
    /// by the encoder when calling `JxlEncoderSetFrameDistance`.
    public var distance: Float {
        switch mode {
        case .lossless:
            return 0.0
        case .distance(let d):
            return max(0.0, min(d, 25.0))
        case .lossy(let q):
            // libjxl's quality→distance curve, mirroring `cjxl --quality`.
            // Source: lib/jxl/encoder/encoder.cc.
            let qq = max(0.0, min(q, 100.0))
            if qq >= 100 { return 0.0 }
            if qq >= 30  { return 0.1 + (100 - qq) * 0.09 }
            return 53.0 / 3000.0 * qq * qq - 23.0 / 20.0 * qq + 25.0
        }
    }
}

// MARK: - Family-parity factory presets

extension EncodingOptions {

    /// Bit-exact lossless preset. Mirrors J2KSwift's
    /// `J2KConfiguration.lossless`. Distance = 0.0; effort
    /// `.squirrel` for a balance of speed and compression.
    public static var lossless: EncodingOptions {
        EncodingOptions(mode: .lossless, effort: .squirrel)
    }

    /// High-quality lossy preset (~95 % equivalent quality).
    /// Mirrors J2KSwift's `J2KConfiguration.highQuality`. Distance
    /// = 0.55, effort `.kitten` for stronger compression at higher
    /// quality.
    public static var highQuality: EncodingOptions {
        EncodingOptions(mode: .lossy(quality: 95), effort: .kitten)
    }

    /// Balanced preset (~90 % quality). Mirrors J2KSwift's
    /// `J2KConfiguration.balanced`. The recommended default for
    /// most use cases. Distance ≈ 1.0, effort `.squirrel`.
    public static var balanced: EncodingOptions {
        EncodingOptions(mode: .lossy(quality: 90), effort: .squirrel)
    }

    /// Fast preset — favours encode speed over compression ratio.
    /// Mirrors J2KSwift's `J2KConfiguration.fast`. Distance ≈ 1.0,
    /// effort `.hare` (faster than balanced).
    public static var fast: EncodingOptions {
        EncodingOptions(mode: .lossy(quality: 90), effort: .hare)
    }
}

/// Family-parity wrapper for ``EncodingOptions``. Mirrors
/// J2KSwift's `J2KConfiguration` (high-level: `quality` + `lossless`)
/// so callers can write codec-agnostic code that switches between
/// libraries by name only.
///
/// `JXLConfiguration` is a thin shim over `EncodingOptions`. The
/// `quality: Double` is a 0.0..1.0 score (J2KSwift convention)
/// mapped to the libjxl quality scale (0..100) at construction time.
///
/// See [Documentation/FAMILY-API-PARITY.md](../../../Documentation/FAMILY-API-PARITY.md)
/// for the full alignment plan.
public struct JXLConfiguration: Sendable {
    /// Quality factor, 0.0 to 1.0. Higher = better visual fidelity
    /// at the cost of larger output. Mirrors J2KSwift's
    /// `J2KConfiguration.quality`.
    public let quality: Double

    /// When `true`, distance is forced to 0 (bit-exact lossless)
    /// regardless of `quality`. Mirrors J2KSwift's
    /// `J2KConfiguration.lossless`.
    public let lossless: Bool

    /// Creates a configuration. `quality` is 0.0 (worst) to
    /// 1.0 (best). `lossless = true` forces bit-exact regardless
    /// of `quality`.
    public init(quality: Double = 0.9, lossless: Bool = false) {
        self.quality = quality
        self.lossless = lossless
    }

    // MARK: - Factory presets matching J2KSwift

    /// Bit-exact lossless. Distance = 0.0.
    public static var lossless: JXLConfiguration {
        JXLConfiguration(quality: 1.0, lossless: true)
    }

    /// High-quality lossy (`quality = 0.95`).
    public static var highQuality: JXLConfiguration {
        JXLConfiguration(quality: 0.95, lossless: false)
    }

    /// Balanced (`quality = 0.9`). Recommended default.
    public static var balanced: JXLConfiguration {
        JXLConfiguration(quality: 0.9, lossless: false)
    }

    /// Fast lossy (`quality = 0.75`). Trades quality for speed.
    public static var fast: JXLConfiguration {
        JXLConfiguration(quality: 0.75, lossless: false)
    }

    /// Convert to the canonical ``EncodingOptions`` used by
    /// ``JXLEncoder``. The conversion maps:
    /// - `lossless = true` → `mode = .lossless`
    /// - else → `mode = .lossy(quality: quality * 100)`
    public var encodingOptions: EncodingOptions {
        if lossless {
            return EncodingOptions(mode: .lossless)
        }
        let q = max(0.0, min(quality, 1.0))
        return EncodingOptions(mode: .lossy(quality: Float(q * 100)))
    }
}

extension JXLEncoder {
    /// Family-parity convenience init. Mirrors J2KSwift's
    /// `J2KEncoder.init(configuration:)`. Internally constructs
    /// the canonical ``EncodingOptions`` via
    /// ``JXLConfiguration/encodingOptions``.
    public init(configuration: JXLConfiguration) {
        self.init(options: configuration.encodingOptions)
    }
}

/// Statistics returned alongside an encoded image.
public struct CompressionStats: Sendable {
    public let originalSize: Int
    public let compressedSize: Int
    public let encodingTime: TimeInterval

    public var compressionRatio: Double {
        guard compressedSize > 0 else { return 0 }
        return Double(originalSize) / Double(compressedSize)
    }

    public init(originalSize: Int, compressedSize: Int, encodingTime: TimeInterval) {
        self.originalSize = originalSize
        self.compressedSize = compressedSize
        self.encodingTime = encodingTime
    }
}

/// The result of a successful encode.
public struct EncodedImage: Sendable {
    public let data: Data
    public let stats: CompressionStats

    public init(data: Data, stats: CompressionStats) {
        self.data = data
        self.stats = stats
    }
}
