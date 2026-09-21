// SPDX-License-Identifier: MIT
//
// TEST-09 evidence for the shared-contract surface.
//
// The bar the contract sets: the shipped path is unchanged, encode-side proofs
// compare codestreams rather than samples, padding cannot reach the output,
// decode writes the caller's allocation exactly, the ownership lifecycle is
// exercised including its failure paths, and the checks are shown to be
// load-bearing.

import Foundation
import Testing
import JXLSwiftContract
import JXLSwift

@Suite("Contract image layer")
struct ContractImageLayerTests {

    /// Deterministic content distinct enough to expose a mis-stride or a
    /// dropped row; an all-zero image would hide both.
    static func sample(_ x: Int, _ y: Int, bits: Int = 16) -> UInt16 {
        let maxValue = UInt32(1 << bits) - 1
        let v = UInt32(truncatingIfNeeded: x &* 7 &+ y &* 131 &+ ((x ^ y) << 3))
        return UInt16(v % (maxValue + 1))
    }

    static func descriptor(width: Int, height: Int, bits: Int = 16,
                           pad: Int = 0, offset: Int = 0) throws -> ImageDescriptor {
        try ImageDescriptor.greyscale16(
            width: width, height: height, meaningfulBits: bits,
            rowBytes: width * 2 + pad, offset: offset)
    }

    static func filledImage(width: Int, height: Int, bits: Int = 16,
                            pad: Int = 0, offset: Int = 0) throws -> Image {
        let d = try descriptor(width: width, height: height, bits: bits, pad: pad, offset: offset)
        return try ImageDestination.allocate(descriptor: d)
            .writeUInt16 { x, y in sample(x, y, bits: bits) }
    }

    /// The ordinary, established API encoding the same samples, for comparison.
    static func ordinaryCodestream(width: Int, height: Int, bits: Int = 16) throws -> Data {
        var frame = ImageFrame(width: width, height: height, channels: 1,
                               pixelType: .uint16, colorSpace: .grayscale)
        var bytes = [UInt8](repeating: 0, count: width * height * 2)
        for y in 0..<height {
            for x in 0..<width {
                let v = sample(x, y, bits: bits)
                let o = (y * width + x) * 2
                bytes[o] = UInt8(truncatingIfNeeded: v)
                bytes[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
            }
        }
        frame.data = bytes
        return try JXLEncoder(options: EncodingOptions(mode: .lossless)).encode(frame).data
    }

    // MARK: - Encode

    @Test(arguments: [0, 6, 64])
    func contractEncodeMatchesTheEstablishedEncoderByteForByte(pad: Int) throws {
        // Byte identity tests the whole input path at once. Sample comparison
        // would pass even if the layer read the wrong bytes in the right order.
        for (w, h) in [(37, 23), (64, 48), (129, 77)] {
            let image = try Self.filledImage(width: w, height: h, pad: pad)
            let (contract, report) = try JXLContractCodec().encode(image)
            let ordinary = try Self.ordinaryCodestream(width: w, height: h)
            #expect(contract == ordinary, "\(w)x\(h) pad=\(pad): codestreams diverge")
            #expect(report.copyEvents.isEmpty)
            #expect(report.pixelAllocationCount == 0)
            #expect(report.fidelity == .exactSamples)
            // MEM-10 (0.6.0): the workspace bound is stated, not implied.
            #expect(report.peakWorkspaceBytes == w * h * 4)
        }
    }

    @Test func rowPaddingNeverReachesTheCodestream() throws {
        let (w, h, pad) = (64, 48, 16)
        let d = try Self.descriptor(width: w, height: h, pad: pad)
        let clean = try Self.filledImage(width: w, height: h, pad: pad)
        let storage = try OwnedImageStorage(byteCount: d.requiredByteCount)
        let lease = try storage.reserveWrite()
        try storage.withUnsafeMutableBytes(lease: lease) { bytes in
            for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: 0x5A &+ i) }
            for y in 0..<h {
                for x in 0..<w {
                    let v = Self.sample(x, y)
                    let o = y * (w * 2 + pad) + x * 2
                    bytes[o] = UInt8(truncatingIfNeeded: v)
                    bytes[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
                }
            }
        }
        let poisoned = try Image(descriptor: d, storage: try storage.finishAndSeal(lease: lease))
        #expect(try JXLContractCodec().encode(clean).0 == (try JXLContractCodec().encode(poisoned).0),
                "padding bytes changed the codestream")
    }

    @Test func aNonZeroPlaneOffsetIsHonoured() throws {
        let (w, h) = (48, 31)
        let image = try Self.filledImage(width: w, height: h, pad: 4, offset: 32)
        #expect(try JXLContractCodec().encode(image).0 == (try Self.ordinaryCodestream(width: w, height: h)))
    }

    // MARK: - Decode

    @Test(arguments: [0, 6, 64])
    func decodeWritesTheCallerDestinationExactly(pad: Int) throws {
        for (w, h) in [(37, 23), (64, 48), (129, 77)] {
            let codestream = try Self.ordinaryCodestream(width: w, height: h)
            let destination = try ImageDestination.allocate(
                descriptor: try Self.descriptor(width: w, height: h, pad: pad))
            let allocationID = destination.storage.allocationID
            let (image, report) = try JXLContractCodec().decode(codestream, into: destination)

            // MEM-13: identity, exact samples, no intermediate frame.
            #expect(image.storage.allocationID == allocationID)
            #expect(report.pixelAllocationCount == 0)
            #expect(report.copyEvents.isEmpty)
            #expect(report.peakWorkspaceBytes == w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    #expect(try image.sampleUInt16(x: x, y: y) == Self.sample(x, y),
                            "\(w)x\(h) pad=\(pad) mismatch at \(x),\(y)")
                }
            }
        }
    }

    @Test func theAllocatingConvenienceAgreesWithTheDestinationPath() throws {
        let (w, h) = (96, 61)
        let codestream = try Self.ordinaryCodestream(width: w, height: h)
        let (allocated, _) = try JXLContractCodec().decode(codestream)
        let destination = try ImageDestination.allocate(
            descriptor: try Self.descriptor(width: w, height: h, pad: 10))
        let (intoCaller, _) = try JXLContractCodec().decode(codestream, into: destination)
        for y in 0..<h {
            for x in 0..<w {
                #expect(try allocated.sampleUInt16(x: x, y: y)
                        == (try intoCaller.sampleUInt16(x: x, y: y)))
            }
        }
    }

    @Test func roundTripThroughTheContractSurfaceOnly() throws {
        let (w, h) = (80, 53)
        let source = try Self.filledImage(width: w, height: h, pad: 4)
        let (codestream, _) = try JXLContractCodec().encode(source)
        let destination = try ImageDestination.allocate(
            descriptor: try Self.descriptor(width: w, height: h, pad: 22))
        // Different strides each side, so a stride cannot be mistaken for width.
        let (decoded, _) = try JXLContractCodec().decode(codestream, into: destination)
        for y in 0..<h {
            for x in 0..<w {
                #expect(try decoded.sampleUInt16(x: x, y: y) == (try source.sampleUInt16(x: x, y: y)))
            }
        }
    }

    @Test func inspectionDescribesWhatDecodeProduces() throws {
        let codestream = try Self.ordinaryCodestream(width: 129, height: 77)
        let described = try JXLContractCodec().inspect(codestream)
        let (decoded, _) = try JXLContractCodec().decode(codestream)
        #expect(described.width == decoded.descriptor.width)
        #expect(described.height == decoded.descriptor.height)
        #expect(described.meaningfulBits == decoded.descriptor.meaningfulBits)
        #expect(described.storageBits == 16)
        #expect(described.byteOrder == .littleEndian)
    }

    // MARK: - Failure paths and lifecycle

    @Test func mismatchedDestinationsAreRefused() throws {
        let codestream = try Self.ordinaryCodestream(width: 64, height: 48)
        let codec = JXLContractCodec()
        #expect(throws: CodecError.self) {
            try codec.decode(codestream,
                into: try ImageDestination.allocate(descriptor: try Self.descriptor(width: 32, height: 48)))
        }
        #expect(throws: CodecError.self) {
            try codec.decode(codestream,
                into: try ImageDestination.allocate(descriptor: try Self.descriptor(width: 64, height: 24)))
        }
        #expect(throws: CodecError.self) {
            try codec.decode(codestream,
                into: try ImageDestination.allocate(descriptor: try Self.descriptor(width: 64, height: 48, bits: 12)))
        }
    }

    @Test func aDestinationGrantsOneWriteOnly() throws {
        let codestream = try Self.ordinaryCodestream(width: 32, height: 16)
        let destination = try ImageDestination.allocate(
            descriptor: try Self.descriptor(width: 32, height: 16))
        _ = try JXLContractCodec().decode(codestream, into: destination)
        // MEM-06: the destination is sealed; a second writer is rejected.
        #expect(throws: CodecError.self) {
            try JXLContractCodec().decode(codestream, into: destination)
        }
    }

    @Test func preflightRejectionLeavesTheDestinationReusable() throws {
        // "Preflight rejection before a write begins does not invalidate a
        // caller's existing destination reservation." A truncated codestream
        // breaks the container box length, so it is refused while parsing,
        // before any sample is written.
        let full = try Self.ordinaryCodestream(width: 64, height: 48)
        let destination = try ImageDestination.allocate(
            descriptor: try Self.descriptor(width: 64, height: 48))
        #expect(throws: CodecError.self) {
            try JXLContractCodec().decode(full.prefix(full.count / 2), into: destination)
        }
        let (image, _) = try JXLContractCodec().decode(full, into: destination)
        for y in stride(from: 0, to: 48, by: 7) {
            for x in stride(from: 0, to: 64, by: 9) {
                #expect(try image.sampleUInt16(x: x, y: y) == Self.sample(x, y))
            }
        }
    }

    @Test func aFailureDuringTheWriteInvalidatesTheDestination() throws {
        // The other half: "Once a fill/write operation begins, thrown errors
        // or cancellation invalidate it and prevent image publication."
        //
        // Which failures land on which side of that boundary is a codec
        // property, not a contract one, and it differs across the suite: this
        // library and JPEG-LS refuse a truncated stream in preflight, while
        // jpegli settles geometry from the frame header first and fails
        // mid-write. So the input here is chosen to reach the write — bytes
        // corrupted inside the entropy-coded data, with the container intact.
        let full = try Self.ordinaryCodestream(width: 64, height: 48)
        var bytes = [UInt8](full)
        let at = Int(Double(bytes.count) * 0.6)
        for i in at..<min(at + 6, bytes.count) { bytes[i] ^= 0x5A }
        let destination = try ImageDestination.allocate(
            descriptor: try Self.descriptor(width: 64, height: 48))
        #expect(throws: (any Error).self) {
            try JXLContractCodec().decode(Data(bytes), into: destination)
        }
        // No partial samples are published: the destination is invalid, so
        // even a valid codestream cannot now be written to it.
        #expect(throws: (any Error).self) {
            try JXLContractCodec().decode(full, into: destination)
        }
    }

    @Test func layoutsOutsideTheSharedProfileAreRefused() throws {
        let bigEndian = try ImageDescriptor(
            width: 32, height: 16, storageBits: 16, meaningfulBits: 16,
            byteOrder: .bigEndian, components: [.grey], colour: .greyscale,
            planes: [try PlaneDescriptor(width: 32, height: 16, rowBytes: 64, byteCount: 1024)])
        #expect(throws: CodecError.self) {
            try JXLContractCodec().decode(try Self.ordinaryCodestream(width: 32, height: 16),
                                          into: try ImageDestination.allocate(descriptor: bigEndian))
        }
    }

    @Test func resourceLimitsAreEnforced() throws {
        let codestream = try Self.ordinaryCodestream(width: 64, height: 48)
        let tight = try ResourceLimits(maximumCompressedBytes: 16)
        #expect(throws: CodecError.self) {
            try JXLContractCodec().decode(codestream, options: DecodeOptions(resourceLimits: tight))
        }
    }

    @Test func capabilitiesReportWhatIsImplemented() {
        // POL-08: planned capability is not reported as present.
        let c = JXLContractCodec.capabilities
        #expect(c.canEncode); #expect(c.canDecode); #expect(c.canInspect)
        #expect(c.compressionModes == [.lossless])
        #expect(c.layouts == ["greyscale16"])
        #expect(c.availableBackends == [.scalarCPU])
    }
}
