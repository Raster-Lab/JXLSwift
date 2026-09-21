// SPDX-License-Identifier: MIT
import Foundation
import JXLSwift

public enum SampleType: Sendable { case unsignedInteger, signedInteger, floatingPoint }
public enum ByteOrder: Sendable { case littleEndian, bigEndian, native }
public enum ComponentRole: Sendable, Equatable {
    case grey, red, green, blue, alpha
    case uninterpreted(String)
}
public enum ColourInterpretation: Sendable { case greyscale, rgb, unknown }
public enum AlphaInterpretation: Sendable { case absent, straight, premultiplied }

/// Byte capacity is measured from the beginning of the complete allocation,
/// including `offset`. All strides are positive, in bytes.
public struct PlaneDescriptor: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let components: [Int]
    public let offset: Int
    public let sampleStride: Int
    public let pixelStride: Int
    public let rowBytes: Int
    public let byteCount: Int

    public init(width: Int, height: Int, components: [Int] = [0], offset: Int = 0,
                sampleStride: Int = 2, pixelStride: Int = 2, rowBytes: Int,
                byteCount: Int) throws {
        guard width > 0, height > 0, offset >= 0, sampleStride > 0,
              pixelStride > 0, rowBytes > 0, byteCount > 0,
              !components.isEmpty, components.allSatisfy({ $0 >= 0 }),
              Set(components).count == components.count else {
            throw CodecError(.invalidArgument, "Invalid plane geometry or component mapping.")
        }
        self.width = width; self.height = height; self.components = components
        self.offset = offset; self.sampleStride = sampleStride
        self.pixelStride = pixelStride; self.rowBytes = rowBytes; self.byteCount = byteCount
    }
}

/// Validated layout; meaningful integer bits are low aligned within each word.
/// This milestone supports complete, unsubsampled planes. Subsampling is rejected.
public struct ImageDescriptor: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let sampleType: SampleType
    public let storageBits: Int
    public let meaningfulBits: Int
    public let byteOrder: ByteOrder
    public let components: [ComponentRole]
    public let colour: ColourInterpretation
    public let alpha: AlphaInterpretation
    public let planes: [PlaneDescriptor]
    public let iccProfile: Data?
    public let requiredByteCount: Int

    public init(width: Int, height: Int, sampleType: SampleType = .unsignedInteger,
                storageBits: Int = 16, meaningfulBits: Int = 16,
                byteOrder: ByteOrder = .littleEndian, components: [ComponentRole] = [.grey],
                colour: ColourInterpretation = .greyscale, alpha: AlphaInterpretation = .absent,
                planes: [PlaneDescriptor], iccProfile: Data? = nil,
                limits: ResourceLimits = .default) throws {
        guard width > 0, height > 0, !components.isEmpty, !planes.isEmpty else {
            throw CodecError(.invalidArgument, "Image dimensions and component counts must be positive.")
        }
        guard width <= limits.maximumDimension, height <= limits.maximumDimension else {
            throw CodecError(.resourceLimitExceeded, "Image dimension limit exceeded.")
        }
        let pixels = try checkedMultiply(width, height)
        guard pixels <= limits.maximumPixels else {
            throw CodecError(.resourceLimitExceeded, "Image pixel limit exceeded.")
        }
        guard storageBits == 8 || storageBits == 16 || (storageBits == 32 && sampleType == .floatingPoint),
              meaningfulBits > 0, meaningfulBits <= storageBits,
              sampleType != .floatingPoint || meaningfulBits == 32 else {
            throw CodecError(.invalidArgument, "Unsupported storage width or meaningful precision.")
        }
        guard (iccProfile?.count ?? 0) <= limits.maximumICCBytes else {
            throw CodecError(.resourceLimitExceeded, "ICC profile limit exceeded.")
        }
        switch colour {
        case .greyscale:
            guard components.contains(.grey), !components.contains(.red),
                  !components.contains(.green), !components.contains(.blue) else {
                throw CodecError(.invalidArgument, "Greyscale component meaning is inconsistent.")
            }
        case .rgb:
            guard components.contains(.red), components.contains(.green), components.contains(.blue),
                  !components.contains(.grey) else {
                throw CodecError(.invalidArgument, "RGB component meaning is inconsistent.")
            }
        case .unknown: break
        }
        guard (alpha == .absent) == !components.contains(.alpha) else {
            throw CodecError(.invalidArgument, "Alpha component meaning is inconsistent.")
        }
        let sampleBytes = storageBits / 8
        var mapped = Set<Int>()
        var ranges: [Range<Int>] = []
        var required = 0
        for plane in planes {
            guard plane.width == width, plane.height == height else {
                throw CodecError(.unsupportedFeature, "Subsampled planes are not implemented in this milestone.")
            }
            for component in plane.components {
                guard component < components.count, mapped.insert(component).inserted else {
                    throw CodecError(.invalidArgument, "Each component must occur in exactly one plane.")
                }
            }
            guard plane.offset % sampleBytes == 0, plane.sampleStride % sampleBytes == 0,
                  plane.pixelStride % sampleBytes == 0, plane.rowBytes % sampleBytes == 0,
                  plane.sampleStride >= sampleBytes else {
                throw CodecError(.incompatibleImageLayout, "Sample offsets and strides must be aligned.")
            }
            let componentEnd = try checkedAdd(checkedMultiply(plane.components.count - 1, plane.sampleStride), sampleBytes)
            guard plane.pixelStride >= componentEnd else {
                throw CodecError(.incompatibleImageLayout, "Components overlap inside a pixel.")
            }
            let rowPayload = try checkedAdd(checkedMultiply(plane.width - 1, plane.pixelStride), componentEnd)
            guard plane.rowBytes >= rowPayload else {
                throw CodecError(.incompatibleImageLayout, "Plane row stride is shorter than its sample payload.")
            }
            let end = try checkedAdd(plane.offset, checkedAdd(checkedMultiply(plane.height - 1, plane.rowBytes), rowPayload))
            guard end <= plane.byteCount else {
                throw CodecError(.incompatibleImageLayout, "Plane sample range exceeds its declared capacity.")
            }
            guard plane.byteCount <= limits.maximumDecodedBytes else {
                throw CodecError(.resourceLimitExceeded, "Decoded storage limit exceeded.")
            }
            let range = plane.offset..<end
            guard !ranges.contains(where: { $0.overlaps(range) }) else {
                throw CodecError(.incompatibleImageLayout, "Writable plane ranges overlap.")
            }
            ranges.append(range)
            required = max(required, plane.byteCount)
        }
        guard mapped.count == components.count else {
            throw CodecError(.invalidArgument, "A component has no plane.")
        }
        self.width = width; self.height = height; self.sampleType = sampleType
        self.storageBits = storageBits; self.meaningfulBits = meaningfulBits
        self.byteOrder = byteOrder == .native ? (UInt16(littleEndian: 1) == 1 ? .littleEndian : .bigEndian) : byteOrder
        self.components = components; self.colour = colour; self.alpha = alpha
        self.planes = planes; self.iccProfile = iccProfile; self.requiredByteCount = required
    }

    func validate(limits: ResourceLimits) throws {
        guard width <= limits.maximumDimension, height <= limits.maximumDimension,
              try checkedMultiply(width, height) <= limits.maximumPixels,
              requiredByteCount <= limits.maximumDecodedBytes,
              (iccProfile?.count ?? 0) <= limits.maximumICCBytes,
              (iccProfile?.count ?? 0) <= limits.maximumMetadataBytes else {
            throw CodecError(.resourceLimitExceeded, "Image descriptor exceeds operation limits.")
        }
    }

    /// Required shared greyscale profile, with optional even row padding and prefix.
    public static func greyscale16(width: Int, height: Int, meaningfulBits: Int = 16,
                                   rowBytes: Int? = nil, offset: Int = 0,
                                   limits: ResourceLimits = .default) throws -> Self {
        guard width > 0, height > 0, offset >= 0 else {
            throw CodecError(.invalidArgument, "Image dimensions must be positive.")
        }
        let row = try rowBytes ?? checkedMultiply(width, 2)
        let capacity = try checkedAdd(offset, checkedMultiply(row, height))
        let plane = try PlaneDescriptor(width: width, height: height, offset: offset,
                                        rowBytes: row, byteCount: capacity)
        return try Self(width: width, height: height, meaningfulBits: meaningfulBits,
                        planes: [plane], limits: limits)
    }
}
