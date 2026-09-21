// SPDX-License-Identifier: MIT
import Foundation
import JXLSwift

/// No codec-specific controls are implemented during contract feasibility.
public struct CodecOptions: Sendable, Equatable { public init() {} }
public struct EncoderConfiguration: Sendable, Equatable {
    public let mode: CompressionMode
    public let codecOptions: CodecOptions
    public init(mode: CompressionMode = .lossless, codecOptions: CodecOptions = .init()) throws {
        if case .nearLossless(let bound) = mode, bound <= 0 {
            throw CodecError(.invalidArgument, "Near-lossless error must be positive.")
        }
        guard mode == .lossless else {
            throw CodecError(.unsupportedFeature, "Only the default lossless configuration is modelled in Milestone 1.")
        }
        self.mode = mode; self.codecOptions = codecOptions
    }
    private init() { mode = .lossless; codecOptions = .init() }
    public static let `default` = Self()
}
public struct DecoderConfiguration: Sendable, Equatable {
    public let codecOptions: CodecOptions
    public init(codecOptions: CodecOptions = .init()) { self.codecOptions = codecOptions }
}

public struct CodecCapabilities: Sendable, Equatable {
    public let formats: [String]
    public let compressionModes: [CompressionMode]
    public let sampleTypes: [SampleType]
    public let meaningfulPrecision: ClosedRange<Int>?
    public let layouts: [String]
    public let availableBackends: [Backend]
    public let canInspect: Bool
    public let canEncode: Bool
    public let canDecode: Bool
    public static let contractOnly = Self(formats: [], compressionModes: [], sampleTypes: [],
        meaningfulPrecision: nil, layouts: [], availableBackends: [],
        canInspect: false, canEncode: false, canDecode: false)
}

public struct CopyEvent: Sendable, Equatable {
    public let reason: String
    public let bytesMoved: Int
    public let sourceLayout: String
    public let destinationLayout: String
    public init(reason: String, bytesMoved: Int, sourceLayout: String, destinationLayout: String) throws {
        guard bytesMoved >= 0 else { throw CodecError(.invalidArgument, "Copy byte count must not be negative.") }
        self.reason = reason; self.bytesMoved = bytesMoved
        self.sourceLayout = sourceLayout; self.destinationLayout = destinationLayout
    }
}
public enum Fidelity: Sendable, Equatable { case exactSamples, boundedError(Int), lossy, originalBitstream }
public struct OperationReport: Sendable, Equatable {
    public let backend: Backend
    public let fallbackReason: String?
    public let fidelity: Fidelity
    public let copyEvents: [CopyEvent]
    public let pixelAllocationCount: Int?
    public let peakPixelBytes: Int?
    public let peakWorkspaceBytes: Int?
    public let elapsedSeconds: Double?
    public init(backend: Backend, fallbackReason: String? = nil, fidelity: Fidelity,
                copyEvents: [CopyEvent] = [], pixelAllocationCount: Int? = nil,
                peakPixelBytes: Int? = nil, peakWorkspaceBytes: Int? = nil, elapsedSeconds: Double? = nil) {
        self.backend = backend; self.fallbackReason = fallbackReason; self.fidelity = fidelity
        self.copyEvents = copyEvents; self.pixelAllocationCount = pixelAllocationCount
        self.peakPixelBytes = peakPixelBytes; self.peakWorkspaceBytes = peakWorkspaceBytes
        self.elapsedSeconds = elapsedSeconds
    }
}
public struct ImageInfo: Sendable {
    public let format: String
    public let descriptor: ImageDescriptor
    public let frameCount: Int
    public let metadata: ImageMetadata
}
public struct EncodingDescription: Sendable, Equatable {
    public let format: String
    public let mode: CompressionMode
}
public struct EncodedImage: Sendable {
    public let data: Data
    public let encoding: EncodingDescription
    public let report: OperationReport
}
public struct DecodedImage: Sendable {
    public let image: Image
    public let report: OperationReport
}

/// Contract feasibility holder. No real compressed format is supported yet.
public struct Encoder: Sendable {
    public let configuration: EncoderConfiguration
    public static let capabilities = CodecCapabilities.contractOnly
    public var capabilities: CodecCapabilities { Self.capabilities }
    public init(configuration: EncoderConfiguration = .default) throws { self.configuration = configuration }

    /// `@concurrent` explicitly selects the generic executor (available since Swift 6.2).
    @concurrent public func encode(_ image: Image, options: EncodeOptions = .init()) async throws -> EncodedImage {
        try Task.checkCancellation()
        try validateOperation(options.resourceLimits, options.executionPolicy)
        guard image.storage.byteCount <= options.resourceLimits.maximumDecodedBytes,
              image.storage.byteCount <= options.resourceLimits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Image exceeds operation limits.")
        }
        throw CodecError(.unsupportedFeature, "Codec algorithms are deferred; Milestone 1 provides API and storage only.")
    }
}

/// Inspection and both decode call shapes deliberately reject compressed input.
public struct Decoder: Sendable {
    public let configuration: DecoderConfiguration
    public static let capabilities = CodecCapabilities.contractOnly
    public var capabilities: CodecCapabilities { Self.capabilities }
    public init(configuration: DecoderConfiguration = .init()) throws { self.configuration = configuration }

    public func inspect(_ data: Data, options: DecodeOptions = .init()) throws -> ImageInfo {
        try validateInput(data, options)
        throw CodecError(.unsupportedFeature, "Format inspection is deferred until codec migration.")
    }
    @concurrent public func decode(_ data: Data, options: DecodeOptions = .init()) async throws -> DecodedImage {
        try Task.checkCancellation()
        try validateInput(data, options)
        throw CodecError(.unsupportedFeature, "Codec algorithms are deferred; no image was decoded.")
    }
    @concurrent public func decode(_ data: Data, into destination: ImageDestination,
                                  options: DecodeOptions = .init()) async throws -> DecodedImage {
        try Task.checkCancellation()
        try validateInput(data, options)
        // Preflight rejection performs no write; the caller may still initialise it.
        throw CodecError(.unsupportedFeature, "Codec algorithms are deferred; destination was not written.")
    }
}

private func validateOperation(_ limits: ResourceLimits, _ policy: ExecutionPolicy) throws {
    if case .required(.accelerated) = policy {
        throw CodecError(.backendUnavailable, "No accelerated backend is implemented.")
    }
}
private func validateInput(_ data: Data, _ options: DecodeOptions) throws {
    try validateOperation(options.resourceLimits, options.executionPolicy)
    guard data.count <= options.resourceLimits.maximumCompressedBytes,
          data.count <= options.resourceLimits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "Compressed input exceeds operation limits.")
    }
}
