// Image-quality metrics — PSNR / MSE / MAE / max error / bit-exact.
// Used by `jxl compare` and by any caller that wants a quantitative
// fidelity comparison between two `ImageFrame`s of matching shape.
//
// Mirrors J2KSwift's `Compare.swift` metrics surface so a
// codec-agnostic comparison harness can be built on top of either
// library.

import Foundation

/// Per-channel + overall image-quality metrics.
public struct ImageMetrics: Sendable {
    public let perChannel: [ChannelMetrics]
    public let overallMSE: Double
    public let overallMAE: Double
    public let overallMaxError: Int
    public let overallPSNR: Double  // .infinity if MSE == 0
    public let bitExact: Bool
    public let width: Int
    public let height: Int
    public let channels: Int
    public let bitsPerSample: Int

    public struct ChannelMetrics: Sendable {
        public let channel: Int
        public let mse: Double
        public let mae: Double
        public let maxError: Int
        public let psnr: Double  // .infinity if MSE == 0
        public let bitExact: Bool
    }

    /// Compute metrics over two pixel-shape-matched `ImageFrame`s.
    /// Caller must ensure dimensions / channels / pixelType match.
    public static func compute(reference ref: ImageFrame,
                                test t: ImageFrame) -> ImageMetrics {
        precondition(
            ref.width == t.width && ref.height == t.height &&
            ref.channels == t.channels && ref.pixelType == t.pixelType,
            "ImageMetrics.compute requires matching frame shapes")

        let bps = ref.pixelType.bitsPerSample
        let maxVal = Double((1 << min(bps, 31)) - 1)
        let pixelsPerChannel = ref.width * ref.height
        var perChannel: [ChannelMetrics] = []
        perChannel.reserveCapacity(ref.channels)
        var sumMSE = 0.0
        var sumMAE = 0.0
        var maxAcrossChannels = 0

        for c in 0..<ref.channels {
            var channelSqErr = 0.0
            var channelAbsErr = 0.0
            var channelMaxErr = 0
            for y in 0..<ref.height {
                for x in 0..<ref.width {
                    let r = Int(ref.getPixel(x: x, y: y, channel: c))
                    let v = Int(t.getPixel(x: x, y: y, channel: c))
                    let d = r - v
                    let ad = abs(d)
                    channelSqErr += Double(d * d)
                    channelAbsErr += Double(ad)
                    if ad > channelMaxErr { channelMaxErr = ad }
                }
            }
            let mse = channelSqErr / Double(pixelsPerChannel)
            let mae = channelAbsErr / Double(pixelsPerChannel)
            let psnr = mse > 0 ? 10.0 * log10(maxVal * maxVal / mse) : .infinity
            let bitExactCh = channelMaxErr == 0
            perChannel.append(ChannelMetrics(
                channel: c, mse: mse, mae: mae,
                maxError: channelMaxErr, psnr: psnr, bitExact: bitExactCh))
            sumMSE += mse
            sumMAE += mae
            if channelMaxErr > maxAcrossChannels {
                maxAcrossChannels = channelMaxErr
            }
        }

        let cf = Double(ref.channels)
        let overallMSE = sumMSE / cf
        let overallMAE = sumMAE / cf
        let overallPSNR = overallMSE > 0
            ? 10.0 * log10(maxVal * maxVal / overallMSE)
            : .infinity
        let bitExact = perChannel.allSatisfy { $0.bitExact }

        return ImageMetrics(
            perChannel: perChannel,
            overallMSE: overallMSE,
            overallMAE: overallMAE,
            overallMaxError: maxAcrossChannels,
            overallPSNR: overallPSNR,
            bitExact: bitExact,
            width: ref.width, height: ref.height,
            channels: ref.channels,
            bitsPerSample: bps)
    }

    /// Produce human-readable text output mirroring `j2k compare`.
    public func printText(reference: String, test: String, quiet: Bool) {
        print("Image Comparison:")
        print("  Reference:    \(reference)")
        print("  Test:         \(test)")
        print("  Dimensions:   \(width)×\(height), \(channels) channel(s), \(bitsPerSample)bpp")
        print("")
        print("  Bit-exact:    \(bitExact ? "YES ✓" : "NO ✗")")
        print("  Overall:")
        if overallPSNR.isInfinite {
            print("    PSNR:       Inf (lossless)")
        } else {
            print("    PSNR:       \(String(format: "%.4f", overallPSNR)) dB")
        }
        print("    MSE:        \(String(format: "%.6f", overallMSE))")
        print("    MAE:        \(String(format: "%.6f", overallMAE))")
        print("    Max error:  \(overallMaxError)")

        if !quiet && channels > 1 {
            print("")
            print("  Per-channel:")
            for cm in perChannel {
                let psnrStr = cm.psnr.isInfinite
                    ? "Inf"
                    : String(format: "%.4f", cm.psnr)
                print("    [\(cm.channel)] PSNR=\(psnrStr) dB " +
                      "MSE=\(String(format: "%.6f", cm.mse)) " +
                      "MAE=\(String(format: "%.6f", cm.mae)) " +
                      "max=\(cm.maxError) " +
                      "bit-exact=\(cm.bitExact ? "Y" : "N")")
            }
        }
    }

    /// Produce JSON output mirroring `j2k compare --json`.
    public func jsonOutput(reference: String, test: String) -> String {
        // Hand-rolled JSON to avoid Foundation's quirks with
        // `Double.infinity`. Matches j2k's shape closely.
        var s = "{\n"
        s += "  \"reference\": \"\(reference)\",\n"
        s += "  \"test\": \"\(test)\",\n"
        s += "  \"width\": \(width),\n"
        s += "  \"height\": \(height),\n"
        s += "  \"channels\": \(channels),\n"
        s += "  \"bitsPerSample\": \(bitsPerSample),\n"
        s += "  \"overall\": {\n"
        s += "    \"psnr\": \(jsonNumber(overallPSNR)),\n"
        s += "    \"mse\": \(overallMSE),\n"
        s += "    \"mae\": \(overallMAE),\n"
        s += "    \"maxError\": \(overallMaxError),\n"
        s += "    \"bitExact\": \(bitExact)\n"
        s += "  },\n"
        s += "  \"perChannel\": [\n"
        for (i, cm) in perChannel.enumerated() {
            s += "    {\n"
            s += "      \"channel\": \(cm.channel),\n"
            s += "      \"psnr\": \(jsonNumber(cm.psnr)),\n"
            s += "      \"mse\": \(cm.mse),\n"
            s += "      \"mae\": \(cm.mae),\n"
            s += "      \"maxError\": \(cm.maxError),\n"
            s += "      \"bitExact\": \(cm.bitExact)\n"
            s += "    }\(i < perChannel.count - 1 ? "," : "")\n"
        }
        s += "  ]\n"
        s += "}"
        return s
    }

    private func jsonNumber(_ v: Double) -> String {
        if v.isInfinite { return "\"Infinity\"" }
        if v.isNaN { return "\"NaN\"" }
        return "\(v)"
    }
}
