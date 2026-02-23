// Example: DICOM-Compatible Workflow
//
// Demonstrates JXLSwift's DICOM-awareness support for medical imaging
// workflows.  JXLSwift has zero DICOM library dependencies — it provides
// the pixel storage types and metadata pass-through needed to integrate
// into a DICOM pipeline.
//
// Key types:
//   ImageFrame.medical12bit / medical16bit / medicalSigned16bit  — convenience constructors
//   PixelType.int16                                              — signed Hounsfield units
//   PhotometricInterpretation                                    — DICOM photometric hint
//   WindowLevel / WindowLevel CT presets                        — display windowing
//   MedicalImageMetadata                                         — DICOM metadata pass-through
//   MedicalImageValidator                                        — dimension / bit-depth checks
//   MedicalImageSeries                                           — multi-slice CT / MR stacks
//   EncodingOptions.medicalLossless                             — lossless preset

import Foundation
import JXLSwift

func dicomWorkflowExample() throws {
    print("=== DICOM-Compatible Workflow Example ===\n")

    // 1. CT image — 16-bit signed Hounsfield units (–1024 to +3071)
    //    Use the medicalSigned16bit convenience constructor
    var ctFrame = ImageFrame.medicalSigned16bit(
        width: 512,
        height: 512,
        windowLevels: [
            .ctAbdomen,   // Preset for abdominal soft tissue
            .ctLung,      // Preset for lung parenchyma
            .ctBone,      // Preset for bone
        ]
    )

    // Fill with synthetic HU values (air ≈ –1000, water = 0, bone ≈ +700)
    for y in 0..<ctFrame.height {
        for x in 0..<ctFrame.width {
            // Simulate a gradient from air (−1000 HU) to bone (+700 HU)
            let hu = Int16(-1000 + (x + y) * 1700 / (ctFrame.width + ctFrame.height))
            ctFrame.setPixelSigned(x: x, y: y, channel: 0, value: hu)
        }
    }

    // 2. Validate that the frame meets medical imaging requirements
    try MedicalImageValidator.validate(ctFrame)
    print("Validation passed for CT frame (\(ctFrame.width)×\(ctFrame.height))")

    // 3. Encode losslessly — bit-perfect reproduction is mandatory for diagnostics
    let encoder = JXLEncoder(options: .medicalLossless)
    let result = try encoder.encode(ctFrame)

    print("Encoded CT : \(result.stats.compressedSize) bytes  " +
          "(\(String(format: "%.2f", result.stats.compressionRatio))×)")

    // 4. Round-trip decode and verify a pixel
    let decoder = JXLDecoder()
    let decoded = try decoder.decode(result.data)
    let originalHU = ctFrame.getPixelSigned(x: 100, y: 100, channel: 0)
    let decodedHU  = decoded.getPixelSigned(x: 100, y: 100, channel: 0)
    print("HU (100,100) — original: \(originalHU), decoded: \(decodedHU)")
    assert(originalHU == decodedHU, "Lossless round-trip failed for CT image")
    print("✅ Lossless round-trip verified")

    // 5. Multi-slice series (e.g. a CT stack)
    let sliceCount = 10
    var slices: [ImageFrame] = []
    for slice in 0..<sliceCount {
        var s = ImageFrame.medical16bit(width: 64, height: 64)
        for y in 0..<64 {
            for x in 0..<64 {
                s.setPixel(x: x, y: y, channel: 0,
                            value: UInt16(slice * 6000 + x * 10))
            }
        }
        slices.append(s)
    }

    let series = try MedicalImageSeries(frames: slices,
                                         description: "Synthetic CT Stack")
    print("\nCT series: \(series.frameCount) slices, " +
          "\(series.width)×\(series.height), \(series.pixelType)")

    // Encode the full series as an animated JXL
    let seriesOptions = EncodingOptions(
        mode: .lossless,
        animationConfig: series.animationConfig,
        modularMode: true
    )
    let seriesEncoder = JXLEncoder(options: seriesOptions)
    let seriesResult = try seriesEncoder.encode(series.frames)
    print("Series compressed: \(seriesResult.stats.compressedSize) bytes")
    print("✅ DICOM workflow example complete")
}

// Run the example
do {
    try dicomWorkflowExample()
} catch {
    print("Error: \(error)")
}
