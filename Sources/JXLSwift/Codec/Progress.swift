// Progress reporting types for `JXLEncoder` / `JXLDecoder`. Phase
// B.8 of the family-API-parity migration. Mirrors J2KSwift's
// `EncoderProgressUpdate` / `DecoderProgressUpdate` shape so
// callers can write codec-agnostic progress UI.
//
// JXL encoding/decoding goes through different stages than JPEG 2000
// (no wavelets, no rate control), so the per-stage enum is JXL-
// specific — but the OUTER struct shape (`stage`, `progress`,
// `overallProgress`) matches J2KSwift exactly.
//
// **Granularity caveat (current state)**: the present encoder/
// decoder implementations don't yet emit fine-grained progress
// updates internally. The Phase B.8 wiring calls the callback at
// the BOUNDARIES of major operations (start = 0.0, end = 1.0).
// Future revisions will add per-stage updates as the codec lands
// more pipeline stages.
//
// See [Documentation/FAMILY-API-PARITY.md](../../../Documentation/FAMILY-API-PARITY.md).

import Foundation

/// Distinct stages of the JXL encode pipeline that can be surfaced
/// to a progress callback. JXL-specific (no wavelet stage, etc.).
public enum JXLEncodingStage: String, Sendable, CaseIterable {
    case preprocessing = "Preprocessing"
    case colorTransform = "Color Transform"
    case modularEncode = "Modular Encode"
    case varDCTEncode = "VarDCT Encode"
    case containerWrap = "Container Wrap"
    case complete = "Complete"
}

/// Distinct stages of the JXL decode pipeline.
public enum JXLDecodingStage: String, Sendable, CaseIterable {
    case containerParse = "Container Parse"
    case headerParse = "Header Parse"
    case entropyDecode = "Entropy Decode"
    case modularDecode = "Modular Decode"
    case varDCTDecode = "VarDCT Decode"
    case restorationFilter = "Restoration Filter"
    case colorTransformInverse = "Color Transform Inverse"
    case pixelOutput = "Pixel Output"
    case complete = "Complete"
}

/// Progress update emitted by ``JXLEncoder/encode(_:progress:)``.
/// Mirrors J2KSwift's `EncoderProgressUpdate`.
public struct JXLEncoderProgressUpdate: Sendable {
    /// The current encoding stage.
    public let stage: JXLEncodingStage

    /// Progress within the current stage, 0.0 to 1.0.
    public let progress: Double

    /// Overall encoding progress, 0.0 to 1.0.
    public let overallProgress: Double

    public init(stage: JXLEncodingStage,
                progress: Double, overallProgress: Double) {
        self.stage = stage
        self.progress = progress
        self.overallProgress = overallProgress
    }
}

/// Progress update emitted by ``JXLDecoder/decode(_:progress:)``.
/// Mirrors J2KSwift's `DecoderProgressUpdate`.
public struct JXLDecoderProgressUpdate: Sendable {
    /// The current decoding stage.
    public let stage: JXLDecodingStage

    /// Progress within the current stage, 0.0 to 1.0.
    public let progress: Double

    /// Overall decoding progress, 0.0 to 1.0.
    public let overallProgress: Double

    public init(stage: JXLDecodingStage,
                progress: Double, overallProgress: Double) {
        self.stage = stage
        self.progress = progress
        self.overallProgress = overallProgress
    }
}

// MARK: - Progress-callback overloads

extension JXLEncoder {

    /// Encode with progress reporting. Mirrors J2KSwift's
    /// `J2KEncoder.encode(_:progress:) async throws`.
    ///
    /// **Granularity:** the current implementation calls `progress`
    /// at the start (0.0) and end (1.0) of the encode. Future
    /// revisions will emit per-stage updates as the encoder grows
    /// more internal stages.
    public func encode(
        _ frame: ImageFrame,
        progress: ((JXLEncoderProgressUpdate) -> Void)?
    ) async throws -> EncodedImage {
        progress?(JXLEncoderProgressUpdate(
            stage: .preprocessing,
            progress: 0.0, overallProgress: 0.0))

        let syncEncode: (ImageFrame) throws -> EncodedImage = self.encode
        let result = try syncEncode(frame)

        progress?(JXLEncoderProgressUpdate(
            stage: .complete,
            progress: 1.0, overallProgress: 1.0))
        return result
    }

    /// Multi-frame variant of ``encode(_:progress:)``.
    public func encode(
        _ frames: [ImageFrame],
        progress: ((JXLEncoderProgressUpdate) -> Void)?
    ) async throws -> EncodedImage {
        progress?(JXLEncoderProgressUpdate(
            stage: .preprocessing,
            progress: 0.0, overallProgress: 0.0))

        let syncEncode: ([ImageFrame]) throws -> EncodedImage = self.encode
        let result = try syncEncode(frames)

        progress?(JXLEncoderProgressUpdate(
            stage: .complete,
            progress: 1.0, overallProgress: 1.0))
        return result
    }
}

extension JXLDecoder {

    /// Decode with progress reporting. Mirrors J2KSwift's
    /// `J2KDecoder.decode(_:progress:) async throws`.
    public func decode(
        _ data: Data,
        progress: ((JXLDecoderProgressUpdate) -> Void)?
    ) async throws -> ImageFrame {
        progress?(JXLDecoderProgressUpdate(
            stage: .containerParse,
            progress: 0.0, overallProgress: 0.0))

        let syncDecode: (Data) throws -> ImageFrame = self.decode
        let result = try syncDecode(data)

        progress?(JXLDecoderProgressUpdate(
            stage: .complete,
            progress: 1.0, overallProgress: 1.0))
        return result
    }

    /// Multi-frame variant of ``decode(_:progress:)``.
    public func decodeAll(
        _ data: Data,
        progress: ((JXLDecoderProgressUpdate) -> Void)?
    ) async throws -> [ImageFrame] {
        progress?(JXLDecoderProgressUpdate(
            stage: .containerParse,
            progress: 0.0, overallProgress: 0.0))

        let syncDecodeAll: (Data) throws -> [ImageFrame] = self.decodeAll
        let result = try syncDecodeAll(data)

        progress?(JXLDecoderProgressUpdate(
            stage: .complete,
            progress: 1.0, overallProgress: 1.0))
        return result
    }
}
