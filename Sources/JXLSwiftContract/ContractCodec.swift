// SPDX-License-Identifier: MIT
//
// The shared-contract codec surface for JPEG XL.
//
// This module exists separately from `JXLSwift` because three of the
// contract's names — `CompressionMode`, `EncodedImage` and `ImageMetadata` —
// are already public API there with different meanings. POL-03 anticipates
// exactly this: the contract "defines a specification, not a runtime module",
// and "identically named types from different modules are distinct Swift
// types". A separate module keeps the canonical names rather than prefixing
// them, and leaves JXLSwift's public API untouched.
//
// The codec-touching work lives behind a `package` seam in JXLSwift, where it
// can reach the Modular encoder and decoder. This module owns descriptors,
// owners and lifecycles, and never sees a codec internal.
//
// Scope is MEM-03's initial shared layout: one plane, one component, unsigned
// 16-bit, little-endian, even `rowBytes >= width * 2`, no subsampling,
// lossless Modular.

import Foundation
import JXLSwift

public struct JXLContractCodec: Sendable {
    public init(options: EncodingOptions = EncodingOptions(mode: .lossless)) {
        self.options = options
    }
    private let options: EncodingOptions

    /// What this surface can actually do, as opposed to what the contract
    /// describes. POL-08: planned capability is not reported as present.
    public static var capabilities: CodecCapabilities {
        CodecCapabilities(
            formats: ["JPEG XL"],
            compressionModes: [.lossless],
            sampleTypes: [.unsignedInteger],
            meaningfulPrecision: 9...16,
            layouts: ["greyscale16"],
            availableBackends: [.scalarCPU],
            canInspect: true, canEncode: true, canDecode: true)
    }

    // MARK: - Inspection

    /// Describe the output layout a decode would produce, without decoding
    /// (MEM-10).
    public func inspect(_ data: Data, limits: ResourceLimits = .default) throws -> ImageDescriptor {
        let info = try Self.inspection(data, limits: limits)
        return try ImageDescriptor.greyscale16(
            width: info.width, height: info.height,
            meaningfulBits: info.bitsPerSample, limits: limits)
    }

    // MARK: - Encode

    /// Encode an `Image` whose samples stay where the caller put them.
    public func encode(_ image: Image,
                       configuration: EncoderConfiguration = .default,
                       options encodeOptions: EncodeOptions = EncodeOptions()) throws -> (Data, OperationReport) {
        let started = Date()
        guard configuration.mode == .lossless else {
            throw CodecError(.unsupportedFeature, "This surface encodes the lossless mode only.")
        }
        let layout = try SharedLayout(descriptor: image.descriptor, policy: encodeOptions.copyPolicy)
        try image.descriptor.validate(limits: encodeOptions.resourceLimits)

        let data: Data = try image.storage.withUnsafeBytes { raw in
            try layout.checkCapacity(raw.count)
            try Task.checkCancellation()
            // The borrow exists only inside this closure, so the pointer
            // cannot outlive the caller's storage (MEM-08).
            let region = UnsafeRawBufferPointer(
                rebasing: raw[layout.offset..<(layout.offset + layout.extent)])
            do {
                return try JXLEncoder(options: options).encodeGreyscale16(
                    from: region, width: layout.width, height: layout.height,
                    rowBytes: layout.rowBytes)
            } catch let error as JXLSharedPlaneError {
                throw Self.mapped(error)
            }
        }

        let report = OperationReport(
            backend: .scalarCPU, fidelity: .exactSamples,
            // No copy events: samples were read in place.
            copyEvents: [], pixelAllocationCount: 0, peakPixelBytes: 0,
            // MEM-10 (0.6.0) requires the workspace bound to be stated.
            peakWorkspaceBytes: JXLEncoder.greyscale16WorkspaceBytes(
                width: layout.width, height: layout.height),
            elapsedSeconds: Date().timeIntervalSince(started))
        return (data, report)
    }

    // MARK: - Decode

    /// Decode into the caller's destination, writing final samples straight
    /// into its allocation (MEM-10).
    @discardableResult
    public func decode(_ data: Data, into destination: ImageDestination,
                       configuration: DecoderConfiguration = DecoderConfiguration(),
                       options decodeOptions: DecodeOptions = DecodeOptions()) throws -> (Image, OperationReport) {
        let started = Date()
        _ = configuration
        let layout = try SharedLayout(descriptor: destination.descriptor, policy: decodeOptions.copyPolicy)
        let info = try Self.inspection(data, limits: decodeOptions.resourceLimits)
        guard info.width == layout.width, info.height == layout.height else {
            throw CodecError(.incompatibleImageLayout,
                "Codestream is \(info.width)x\(info.height); destination is \(layout.width)x\(layout.height).")
        }
        guard info.bitsPerSample == layout.meaningfulBits else {
            throw CodecError(.incompatibleImageLayout,
                "Codestream is \(info.bitsPerSample)-bit; destination declares \(layout.meaningfulBits).")
        }

        // One exclusive write, sealed on success and invalidated on failure by
        // `ImageDestination.write`.
        let image = try destination.write { raw in
            try layout.checkCapacity(raw.count)
            try Task.checkCancellation()
            let region = UnsafeMutableRawBufferPointer(
                rebasing: raw[layout.offset..<(layout.offset + layout.extent)])
            do {
                try JXLDecoder().decodeGreyscale16(
                    data, into: region, rowBytes: layout.rowBytes)
            } catch let error as JXLSharedPlaneError {
                throw Self.mapped(error)
            }
        }

        let report = OperationReport(
            backend: .scalarCPU, fidelity: .exactSamples, copyEvents: [],
            pixelAllocationCount: 0, peakPixelBytes: 0,
            // The Modular decoder's Int32 channel plane: four bytes per sample.
            peakWorkspaceBytes: layout.sampleCount * MemoryLayout<Int32>.size,
            elapsedSeconds: Date().timeIntervalSince(started))
        return (image, report)
    }

    /// Allocating convenience. MEM-10 requires this and the caller-destination
    /// decode to use the same final-output path, so it allocates a destination
    /// and calls the method above rather than having a path of its own.
    public func decode(_ data: Data,
                       configuration: DecoderConfiguration = DecoderConfiguration(),
                       options decodeOptions: DecodeOptions = DecodeOptions()) throws -> (Image, OperationReport) {
        let descriptor = try inspect(data, limits: decodeOptions.resourceLimits)
        let destination = try ImageDestination.allocate(
            descriptor: descriptor, limits: decodeOptions.resourceLimits)
        return try decode(data, into: destination, configuration: configuration, options: decodeOptions)
    }

    // MARK: - Helpers

    private static func inspection(_ data: Data, limits: ResourceLimits) throws -> JXLSharedInspection {
        guard data.count <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Compressed input exceeds the operation budget.")
        }
        let info: JXLSharedInspection
        do {
            info = try JXLDecoder().sharedInspect(data)
        } catch let error as JXLSharedPlaneError {
            throw mapped(error)
        } catch {
            throw CodecError(.malformedInput, "JPEG XL inspection failed: \(error)")
        }
        guard info.isGreyscale else {
            throw CodecError(.unsupportedFeature, "This surface handles single-channel greyscale.")
        }
        guard info.bitsPerSample > 8, info.bitsPerSample <= 16 else {
            throw CodecError(.unsupportedFeature,
                "The shared layout is 16-bit storage; codestream is \(info.bitsPerSample)-bit.")
        }
        return info
    }

    private static func mapped(_ error: JXLSharedPlaneError) -> CodecError {
        switch error {
        case .notSupported(let message): CodecError(.unsupportedFeature, message)
        case .malformed(let message): CodecError(.malformedInput, message)
        }
    }
}

// MARK: - Shared layout

/// The MEM-03 profile read off a descriptor, with MEM-04's checked arithmetic
/// resolved once so neither codec direction repeats it.
struct SharedLayout {
    let width: Int, height: Int, meaningfulBits: Int
    let offset: Int, rowBytes: Int, extent: Int, sampleCount: Int

    init(descriptor: ImageDescriptor, policy: CopyPolicy) throws {
        guard descriptor.planes.count == 1, descriptor.components.count == 1,
              descriptor.components.first == .grey, descriptor.colour == .greyscale,
              descriptor.alpha == .absent else {
            throw CodecError(.incompatibleImageLayout,
                "This surface requires the single-plane greyscale shared layout.")
        }
        guard descriptor.sampleType == .unsignedInteger, descriptor.storageBits == 16 else {
            throw CodecError(.incompatibleImageLayout, "The shared layout is unsigned 16-bit storage.")
        }
        guard descriptor.byteOrder == .littleEndian else {
            // Representable, but it is a copy, and under `requireSharedStorage`
            // a copy is the thing being excluded.
            throw CodecError(.incompatibleImageLayout,
                "The shared layout is little-endian; this descriptor is big-endian.")
        }
        let plane = descriptor.planes[0]
        guard plane.pixelStride == 2, plane.sampleStride == 2 else {
            throw CodecError(.incompatibleImageLayout,
                "The shared layout is a two-byte sample and pixel stride.")
        }
        guard plane.rowBytes % 2 == 0, plane.rowBytes >= descriptor.width * 2 else {
            throw CodecError(.incompatibleImageLayout, "rowBytes must be even and at least width * 2.")
        }
        guard plane.offset % 2 == 0 else {
            throw CodecError(.incompatibleImageLayout,
                "Plane offset must be two-byte aligned for 16-bit samples.")
        }
        // Every layout this surface accepts is already shareable, so the
        // default path never silently becomes a copy (MEM-12).
        _ = policy

        width = descriptor.width
        height = descriptor.height
        meaningfulBits = descriptor.meaningfulBits
        offset = plane.offset
        rowBytes = plane.rowBytes
        extent = try checkedAdd(checkedMultiply(descriptor.height - 1, plane.rowBytes),
                                checkedMultiply(descriptor.width, 2))
        sampleCount = try checkedMultiply(descriptor.width, descriptor.height)
    }

    /// MEM-04: the last byte touched, checked against the retained allocation.
    func checkCapacity(_ byteCount: Int) throws {
        let needed = try checkedAdd(offset, extent)
        guard byteCount >= needed else {
            throw CodecError(.storageUnavailable,
                "Storage holds \(byteCount) bytes; the layout needs \(needed).")
        }
    }
}
