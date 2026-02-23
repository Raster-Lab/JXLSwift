/// Encode subcommand — encode raw pixel data to JPEG XL
///
/// Encodes a source image (or generates a test pattern) to JPEG XL format.

import ArgumentParser
import Foundation
import JXLSwift

struct Encode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Encode an image to JPEG XL format"
    )

    @Option(name: .shortAndLong, help: "Output file path")
    var output: String = "output.jxl"

    @Option(name: .shortAndLong, help: "Quality level (0–100, default 90). Ignored when --lossless is set.")
    var quality: Float = 90

    @Option(name: .shortAndLong, help: "Distance parameter (overrides quality). Lower is higher quality.")
    var distance: Float?

    @Option(name: .shortAndLong, help: "Encoding effort (1–9, default 7)")
    var effort: Int = 7

    @Flag(name: .shortAndLong, help: "Use lossless compression")
    var lossless: Bool = false
    
    @Flag(name: .long, help: "Enable progressive encoding (DC → AC refinement passes)")
    var progressive: Bool = false
    
    @Flag(name: .long, help: "Enable responsive encoding (quality-layered progressive delivery)")
    var responsive: Bool = false
    
    @Option(name: .long, help: "Number of quality layers for responsive encoding (2-8, default 3)")
    var qualityLayers: Int?

    @Flag(help: "Disable hardware acceleration")
    var noAccelerate: Bool = false

    @Flag(help: "Disable Metal GPU acceleration")
    var noMetal: Bool = false

    @Option(name: .shortAndLong, help: "Width of test image to generate")
    var width: Int = 256

    @Option(name: .long, help: "Height of test image to generate")
    var height: Int = 256
    
    @Option(name: .long, help: "EXIF orientation (1-8, default 1). 1=normal, 6=90°CW, 3=180°, 8=270°CW")
    var orientation: Int = 1
    
    @Option(name: .long, help: "Region of interest (x,y,width,height). Example: --roi 10,20,100,80")
    var roi: String?
    
    @Option(name: .long, help: "Quality boost for ROI region (0-50, default 10)")
    var roiQualityBoost: Float = 10.0
    
    @Option(name: .long, help: "Feathering width for ROI edges in pixels (default 16)")
    var roiFeather: Int = 16
    
    @Flag(name: .long, help: "Enable reference frame encoding for animations (reduces file size for video-like content)")
    var referenceFrames: Bool = false
    
    @Option(name: .long, help: "Keyframe interval for reference encoding (default 30 frames)")
    var keyframeInterval: Int?
    
    @Flag(name: .long, help: "Enable patch encoding to copy repeated regions from reference frames (requires --reference-frames)")
    var patches: Bool = false
    
    @Option(name: .long, help: "Patch encoding preset: aggressive, balanced, conservative, screen (default: balanced)")
    var patchPreset: String?
    
    @Flag(name: .long, help: "Enable noise synthesis to add film grain or texture")
    var noise: Bool = false
    
    @Option(name: .long, help: "Noise amplitude (0.0-1.0, default 0.35). Higher values add more grain.")
    var noiseAmplitude: Float?
    
    @Option(name: .long, help: "Noise preset: subtle, moderate, heavy, film (default: moderate)")
    var noisePreset: String?
    
    @Flag(name: .long, help: "Enable spline encoding for vector overlays (line art, edges, diagrams)")
    var splines: Bool = false
    
    @Option(name: .long, help: "Spline preset: subtle, moderate, artistic (default: moderate)")
    var splinePreset: String?

    // MARK: - British / American dual-spelling options

    /// Colour space for the encoded image.
    /// Accepts both American (`--color-space`) and British (`--colour-space`) spellings.
    @Option(
        name: [.customLong("color-space"), .customLong("colour-space")],
        help: "Colour space for the test image: sRGB, linearRGB, grayscale, displayP3 (default: sRGB)"
    )
    var colorSpace: String?

    /// Maximise compression at the cost of encoding speed (equivalent to `--effort 9`).
    /// Accepts both American (`--optimize`) and British (`--optimise`) spellings.
    @Flag(
        name: [.customLong("optimize"), .customLong("optimise")],
        help: "Maximise compression ratio (sets effort to 9 — tortoise). Accepts both --optimize and --optimise."
    )
    var optimise: Bool = false

    @Flag(name: .long, help: "Show verbose output")
    var verbose: Bool = false

    @Flag(name: .long, help: "Suppress all output except errors")
    var quiet: Bool = false

    func run() throws {
        if verbose && !quiet {
            print("JXLSwift v\(JXLSwift.version)")
            print("Standard: ISO/IEC \(JXLSwift.standardVersion)")
            print()
        }

        // Build encoding options
        let mode: CompressionMode
        if lossless {
            mode = .lossless
        } else if let d = distance {
            mode = .distance(d)
        } else {
            mode = .lossy(quality: quality)
        }

        // --optimise/--optimize overrides --effort to maximum (9)
        let resolvedEffort = optimise ? 9 : effort
        guard let effortLevel = EncodingEffort(rawValue: resolvedEffort) else {
            print("Error: Effort must be between 1 and 9", to: &standardError)
            throw JXLExitCode.invalidArguments
        }
        
        // Build responsive config if enabled
        let responsiveConfig: ResponsiveConfig?
        if responsive {
            if let layers = qualityLayers {
                guard layers >= 2 && layers <= 8 else {
                    print("Error: Quality layers must be between 2 and 8", to: &standardError)
                    throw JXLExitCode.invalidArguments
                }
                responsiveConfig = ResponsiveConfig(layerCount: layers)
            } else {
                responsiveConfig = .threeLayers  // Default
            }
        } else {
            responsiveConfig = nil
        }
        
        // Parse ROI if provided
        let regionOfInterest: RegionOfInterest?
        if let roiStr = roi {
            let components = roiStr.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard components.count == 4 else {
                print("Error: ROI must be in format 'x,y,width,height' (e.g., '10,20,100,80')", to: &standardError)
                throw JXLExitCode.invalidArguments
            }
            
            let (x, y, w, h) = (components[0], components[1], components[2], components[3])
            
            // Validate ROI values
            guard x >= 0 && y >= 0 && w > 0 && h > 0 else {
                print("Error: ROI coordinates must be non-negative and dimensions must be positive", to: &standardError)
                throw JXLExitCode.invalidArguments
            }
            
            regionOfInterest = RegionOfInterest(
                x: x,
                y: y,
                width: w,
                height: h,
                qualityBoost: roiQualityBoost,
                featherWidth: roiFeather
            )
        } else {
            regionOfInterest = nil
        }
        
        // Build reference frame config if enabled
        let referenceFrameConfig: ReferenceFrameConfig?
        if referenceFrames {
            if let interval = keyframeInterval {
                guard interval >= 1 else {
                    print("Error: Keyframe interval must be at least 1", to: &standardError)
                    throw JXLExitCode.invalidArguments
                }
                referenceFrameConfig = ReferenceFrameConfig(keyframeInterval: interval)
            } else {
                referenceFrameConfig = .balanced  // Default
            }
        } else {
            referenceFrameConfig = nil
        }
        
        // Build patch config if enabled
        let patchConfig: PatchConfig?
        if patches {
            // Patches require reference frames
            guard referenceFrames else {
                print("Error: --patches requires --reference-frames to be enabled", to: &standardError)
                throw JXLExitCode.invalidArguments
            }
            
            if let preset = patchPreset {
                switch preset.lowercased() {
                case "aggressive":
                    patchConfig = .aggressive
                case "balanced":
                    patchConfig = .balanced
                case "conservative":
                    patchConfig = .conservative
                case "screen":
                    patchConfig = .screenContent
                default:
                    print("Error: Unknown patch preset '\(preset)'. Use: aggressive, balanced, conservative, or screen", to: &standardError)
                    throw JXLExitCode.invalidArguments
                }
            } else {
                patchConfig = .balanced  // Default
            }
        } else {
            patchConfig = nil
        }
        
        // Build noise config if enabled
        let noiseConfig: NoiseConfig?
        if noise {
            if let preset = noisePreset {
                switch preset.lowercased() {
                case "subtle":
                    noiseConfig = .subtle
                case "moderate":
                    noiseConfig = .moderate
                case "heavy":
                    noiseConfig = .heavy
                case "film":
                    noiseConfig = .filmGrain
                default:
                    print("Error: Unknown noise preset '\(preset)'. Use: subtle, moderate, heavy, or film", to: &standardError)
                    throw JXLExitCode.invalidArguments
                }
            } else if let amplitude = noiseAmplitude {
                // Custom amplitude
                guard amplitude >= 0.0 && amplitude <= 1.0 else {
                    print("Error: Noise amplitude must be between 0.0 and 1.0", to: &standardError)
                    throw JXLExitCode.invalidArguments
                }
                noiseConfig = NoiseConfig(enabled: true, amplitude: amplitude)
            } else {
                // Default to moderate preset
                noiseConfig = .moderate
            }
        } else {
            noiseConfig = nil
        }
        
        // Build spline config if enabled
        let splineConfig: SplineConfig?
        if splines {
            if let preset = splinePreset {
                switch preset.lowercased() {
                case "subtle":
                    splineConfig = .subtle
                case "moderate":
                    splineConfig = .moderate
                case "artistic":
                    splineConfig = .artistic
                default:
                    print("Error: Unknown spline preset '\(preset)'. Use: subtle, moderate, or artistic", to: &standardError)
                    throw JXLExitCode.invalidArguments
                }
            } else {
                // Default to moderate preset
                splineConfig = .moderate
            }
        } else {
            splineConfig = nil
        }

        let options = EncodingOptions(
            mode: mode,
            effort: effortLevel,
            progressive: progressive,
            responsiveEncoding: responsive,
            responsiveConfig: responsiveConfig,
            useHardwareAcceleration: !noAccelerate,
            useAccelerate: !noAccelerate,
            useMetal: !noMetal,
            regionOfInterest: regionOfInterest,
            referenceFrameConfig: referenceFrameConfig,
            patchConfig: patchConfig,
            noiseConfig: noiseConfig,
            splineConfig: splineConfig
        )

        // Generate a test image (until file I/O is implemented)
        if verbose && !quiet {
            print("Generating \(width)×\(height) test image...")
        }
        
        // Validate orientation
        guard orientation >= 1 && orientation <= 8 else {
            print("Error: Orientation must be between 1 and 8", to: &standardError)
            throw JXLExitCode.invalidArguments
        }

        // Resolve --color-space / --colour-space option
        let resolvedColorSpace: ColorSpace
        let isGrayscale: Bool
        if let cs = colorSpace {
            switch cs.lowercased() {
            case "srgb":
                resolvedColorSpace = .sRGB
                isGrayscale = false
            case "linearrgb", "linear":
                resolvedColorSpace = .linearRGB
                isGrayscale = false
            case "grayscale", "greyscale":
                resolvedColorSpace = .grayscale
                isGrayscale = true
            case "displayp3", "display-p3":
                resolvedColorSpace = .displayP3
                isGrayscale = false
            default:
                print("Error: Unknown colour space '\(cs)'. Supported values: sRGB, linearRGB, grayscale, displayP3", to: &standardError)
                throw JXLExitCode.invalidArguments
            }
        } else {
            resolvedColorSpace = .sRGB
            isGrayscale = false
        }

        var frame = ImageFrame(
            width: width,
            height: height,
            channels: isGrayscale ? 1 : 3,
            pixelType: .uint8,
            colorSpace: resolvedColorSpace,
            orientation: UInt32(orientation)
        )

        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let r = UInt16((x * 255) / max(frame.width - 1, 1))
                let g = UInt16((y * 255) / max(frame.height - 1, 1))
                let b = UInt16(128)
                if frame.channels == 1 {
                    // Grayscale: use a simple luminance approximation
                    let luma = UInt16((UInt32(r) * 299 + UInt32(g) * 587 + UInt32(b) * 114) / 1000)
                    frame.setPixel(x: x, y: y, channel: 0, value: luma)
                } else {
                    frame.setPixel(x: x, y: y, channel: 0, value: r)
                    frame.setPixel(x: x, y: y, channel: 1, value: g)
                    frame.setPixel(x: x, y: y, channel: 2, value: b)
                }
            }
        }

        // Encode
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)

        // Write output
        let url = URL(fileURLWithPath: output)
        try result.data.write(to: url)

        // Print statistics
        if !quiet {
            print("Encoded \(width)×\(height) image to \(output)")
            print("  Original:    \(formatBytes(result.stats.originalSize))")
            print("  Compressed:  \(formatBytes(result.stats.compressedSize))")
            print("  Ratio:       \(String(format: "%.2f", result.stats.compressionRatio))×")
            print("  Time:        \(String(format: "%.3f", result.stats.encodingTime))s")

            if verbose {
                print("  Mode:        \(lossless ? "lossless" : "lossy")\(progressive ? " (progressive)" : "")")
                print("  Effort:      \(effortLevel) (\(resolvedEffort))\(optimise ? " (maximised via --optimise)" : "")")
                print("  Colour space: \(colorSpace ?? "sRGB")")
                print("  Orientation: \(orientation)")
                if let roi = regionOfInterest {
                    print("  ROI:         (\(roi.x),\(roi.y)) \(roi.width)×\(roi.height)")
                    print("  ROI Boost:   +\(String(format: "%.1f", roi.qualityBoost)) quality")
                    print("  ROI Feather: \(roi.featherWidth)px")
                }
                if !lossless {
                    if let d = distance {
                        print("  Distance:    \(d)")
                    } else {
                        print("  Quality:     \(quality)")
                    }
                }
            }
        }
    }
}

