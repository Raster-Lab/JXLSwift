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

        guard let effortLevel = EncodingEffort(rawValue: effort) else {
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

        let options = EncodingOptions(
            mode: mode,
            effort: effortLevel,
            progressive: progressive,
            responsiveEncoding: responsive,
            responsiveConfig: responsiveConfig,
            useHardwareAcceleration: !noAccelerate,
            useAccelerate: !noAccelerate,
            useMetal: !noMetal,
            regionOfInterest: regionOfInterest
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

        var frame = ImageFrame(
            width: width,
            height: height,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            orientation: UInt32(orientation)
        )

        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let r = UInt16((x * 255) / max(frame.width - 1, 1))
                let g = UInt16((y * 255) / max(frame.height - 1, 1))
                let b = UInt16(128)
                frame.setPixel(x: x, y: y, channel: 0, value: r)
                frame.setPixel(x: x, y: y, channel: 1, value: g)
                frame.setPixel(x: x, y: y, channel: 2, value: b)
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
                print("  Effort:      \(effortLevel) (\(effort))")
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

