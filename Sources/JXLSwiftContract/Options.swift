// SPDX-License-Identifier: MIT
import Foundation
import JXLSwift

public enum CompressionMode: Sendable, Equatable {
    case lossless, nearLossless(maximumAbsoluteError: Int), lossy
}
public enum CopyPolicy: Sendable { case requireSharedStorage, allowCopy }
public enum MetadataPolicy: Sendable { case preserve, discardAncillary }
public enum Backend: Sendable { case scalarCPU, accelerated }
public enum ExecutionPolicy: Sendable { case automatic, scalarCPU, preferred(Backend), required(Backend) }

/// Independent admission ceilings. No allocation may infer a larger budget from input.
public struct ResourceLimits: Sendable, Equatable {
    public let maximumCompressedBytes: Int
    public let maximumDecodedBytes: Int
    public let maximumWorkspaceBytes: Int
    public let maximumPixels: Int
    public let maximumDimension: Int
    public let maximumFrames: Int
    public let maximumMetadataBytes: Int
    public let maximumICCBytes: Int
    public let maximumNestingDepth: Int
    public let maximumWorkers: Int
    public let deadlineSeconds: Double
    public let maximumMemoryBytes: Int

    public init(maximumCompressedBytes: Int = 256 * 1024 * 1024,
                maximumDecodedBytes: Int = 512 * 1024 * 1024,
                maximumWorkspaceBytes: Int = 512 * 1024 * 1024,
                maximumPixels: Int = 64_000_000, maximumDimension: Int = 1_000_000,
                maximumFrames: Int = 256, maximumMetadataBytes: Int = 16 * 1024 * 1024,
                maximumICCBytes: Int = 4 * 1024 * 1024, maximumNestingDepth: Int = 32,
                maximumWorkers: Int = min(ProcessInfo.processInfo.activeProcessorCount, 8),
                deadlineSeconds: Double = 120, maximumMemoryBytes: Int = 1024 * 1024 * 1024) throws {
        guard [maximumCompressedBytes, maximumDecodedBytes, maximumWorkspaceBytes, maximumPixels,
               maximumDimension, maximumFrames, maximumMetadataBytes, maximumICCBytes,
               maximumNestingDepth, maximumWorkers, maximumMemoryBytes].allSatisfy({ $0 > 0 }),
              deadlineSeconds.isFinite, deadlineSeconds > 0 else {
            throw CodecError(.invalidArgument, "Resource limits must be positive and finite.")
        }
        self.maximumCompressedBytes = maximumCompressedBytes
        self.maximumDecodedBytes = maximumDecodedBytes
        self.maximumWorkspaceBytes = maximumWorkspaceBytes
        self.maximumPixels = maximumPixels; self.maximumDimension = maximumDimension
        self.maximumFrames = maximumFrames; self.maximumMetadataBytes = maximumMetadataBytes
        self.maximumICCBytes = maximumICCBytes; self.maximumNestingDepth = maximumNestingDepth
        self.maximumWorkers = maximumWorkers; self.deadlineSeconds = deadlineSeconds
        self.maximumMemoryBytes = maximumMemoryBytes
    }

    // This private constructor is used only with fixed, reviewed constants.
    private init(watch: Bool) {
        maximumCompressedBytes = (watch ? 16 : 256) * 1024 * 1024
        maximumDecodedBytes = (watch ? 32 : 512) * 1024 * 1024
        maximumWorkspaceBytes = (watch ? 32 : 512) * 1024 * 1024
        maximumPixels = 64_000_000; maximumDimension = 1_000_000; maximumFrames = 256
        maximumMetadataBytes = 16 * 1024 * 1024; maximumICCBytes = 4 * 1024 * 1024
        maximumNestingDepth = 32
        maximumWorkers = watch ? 2 : max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        deadlineSeconds = watch ? 30 : 120
        maximumMemoryBytes = (watch ? 64 : 1024) * 1024 * 1024
    }
    public static let general = Self(watch: false)
    public static let watch = Self(watch: true)
    #if os(watchOS)
    public static let `default` = watch
    #else
    public static let `default` = general
    #endif
}

public struct ProgressUpdate: Sendable, Equatable {
    public enum Phase: Sendable { case inspecting, processing, completed }
    public let phase: Phase
    public let completedUnits: Int
    public let totalUnits: Int?
    public init(phase: Phase, completedUnits: Int, totalUnits: Int? = nil) throws {
        guard completedUnits >= 0, totalUnits.map({ $0 >= completedUnits }) ?? true else {
            throw CodecError(.invalidArgument, "Invalid progress count.")
        }
        self.phase = phase; self.completedUnits = completedUnits; self.totalUnits = totalUnits
    }
}

/// Callbacks are serial within an operation, outside locks, on the generic executor.
public struct EncodeOptions: Sendable {
    public let resourceLimits: ResourceLimits
    public let executionPolicy: ExecutionPolicy
    public let copyPolicy: CopyPolicy
    public let metadataPolicy: MetadataPolicy
    public let progress: (@Sendable (ProgressUpdate) -> Void)?
    public init(resourceLimits: ResourceLimits = .default, executionPolicy: ExecutionPolicy = .automatic,
                copyPolicy: CopyPolicy = .requireSharedStorage, metadataPolicy: MetadataPolicy = .preserve,
                progress: (@Sendable (ProgressUpdate) -> Void)? = nil) {
        self.resourceLimits = resourceLimits; self.executionPolicy = executionPolicy
        self.copyPolicy = copyPolicy; self.metadataPolicy = metadataPolicy; self.progress = progress
    }
}

public struct DecodeOptions: Sendable {
    public let resourceLimits: ResourceLimits
    public let executionPolicy: ExecutionPolicy
    public let copyPolicy: CopyPolicy
    public let metadataPolicy: MetadataPolicy
    public let progress: (@Sendable (ProgressUpdate) -> Void)?
    public init(resourceLimits: ResourceLimits = .default, executionPolicy: ExecutionPolicy = .automatic,
                copyPolicy: CopyPolicy = .requireSharedStorage, metadataPolicy: MetadataPolicy = .preserve,
                progress: (@Sendable (ProgressUpdate) -> Void)? = nil) {
        self.resourceLimits = resourceLimits; self.executionPolicy = executionPolicy
        self.copyPolicy = copyPolicy; self.metadataPolicy = metadataPolicy; self.progress = progress
    }
}
