/// Bitstream writer for JPEG XL format
///
/// Handles writing bits and bytes to create a JPEG XL codestream

import Foundation

/// Bitstream writer
struct BitstreamWriter {
    /// Output data buffer
    private(set) var data: Data
    
    /// Current byte being written
    private var currentByte: UInt8
    
    /// Number of bits written in current byte (0-7)
    private var bitPosition: Int
    
    init() {
        self.data = Data()
        self.currentByte = 0
        self.bitPosition = 0
    }
    
    // MARK: - Bit Writing
    
    /// Write a single bit
    mutating func writeBit(_ bit: Bool) {
        if bit {
            currentByte |= (1 << (7 - bitPosition))
        }
        bitPosition += 1
        
        if bitPosition == 8 {
            data.append(currentByte)
            currentByte = 0
            bitPosition = 0
        }
    }
    
    /// Write multiple bits (up to 32)
    mutating func writeBits(_ value: UInt32, count: Int) {
        precondition(count <= 32)
        for i in (0..<count).reversed() {
            let bit = (value & (1 << i)) != 0
            writeBit(bit)
        }
    }
    
    /// Write a byte
    mutating func writeByte(_ byte: UInt8) {
        if bitPosition == 0 {
            data.append(byte)
        } else {
            writeBits(UInt32(byte), count: 8)
        }
    }
    
    /// Write raw data
    mutating func writeData(_ newData: Data) {
        flushByte()
        data.append(newData)
    }
    
    /// Flush current byte
    mutating func flushByte() {
        if bitPosition > 0 {
            data.append(currentByte)
            currentByte = 0
            bitPosition = 0
        }
    }
    
    // MARK: - JPEG XL Specific
    
    /// Write JPEG XL signature (magic bytes)
    mutating func writeSignature() throws {
        // JPEG XL signature: 0xFF 0x0A
        writeByte(0xFF)
        writeByte(0x0A)
    }
    
    /// Write image header
    mutating func writeImageHeader(frame: ImageFrame) throws {
        flushByte()
        
        // Size header - simplified version
        // Real JPEG XL uses variable-length encoding
        writeU32(UInt32(frame.width))
        writeU32(UInt32(frame.height))
        
        // Bit depth
        writeByte(UInt8(frame.bitsPerSample))
        
        // Number of channels
        writeByte(UInt8(frame.channels))
        
        // Color space indicator
        writeByte(0) // sRGB for now
        
        // Has alpha
        writeBit(frame.hasAlpha)
        
        flushByte()
    }
    
    /// Write unsigned 32-bit integer
    mutating func writeU32(_ value: UInt32) {
        writeByte(UInt8((value >> 24) & 0xFF))
        writeByte(UInt8((value >> 16) & 0xFF))
        writeByte(UInt8((value >> 8) & 0xFF))
        writeByte(UInt8(value & 0xFF))
    }
    
    /// Write variable-length integer (used in JPEG XL)
    mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 128 {
            writeByte(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        writeByte(UInt8(v & 0x7F))
    }
}

/// Bitstream reader (for testing and future decoding)
struct BitstreamReader {
    private let data: Data
    private var bytePosition: Int
    private var bitPosition: Int
    private var currentByte: UInt8
    
    init(data: Data) {
        self.data = data
        self.bytePosition = 0
        self.bitPosition = 0
        self.currentByte = data.isEmpty ? 0 : data[0]
    }
    
    mutating func readBit() -> Bool? {
        guard bytePosition < data.count else { return nil }
        
        let bit = (currentByte & (1 << (7 - bitPosition))) != 0
        bitPosition += 1
        
        if bitPosition == 8 {
            bytePosition += 1
            if bytePosition < data.count {
                currentByte = data[bytePosition]
            }
            bitPosition = 0
        }
        
        return bit
    }
    
    mutating func readByte() -> UInt8? {
        guard bytePosition < data.count else { return nil }
        
        if bitPosition == 0 {
            let byte = data[bytePosition]
            bytePosition += 1
            if bytePosition < data.count {
                currentByte = data[bytePosition]
            }
            return byte
        } else {
            var result: UInt32 = 0
            for _ in 0..<8 {
                guard let bit = readBit() else { return nil }
                result = (result << 1) | (bit ? 1 : 0)
            }
            return UInt8(result)
        }
    }

    /// Skip remaining bits in the current byte to reach the next byte boundary.
    ///
    /// If the reader is already aligned (bitPosition == 0), this is a no-op.
    /// Otherwise, the remaining `8 - bitPosition` bits are discarded.
    mutating func skipToByteAlignment() {
        if bitPosition > 0 {
            let remaining = 8 - bitPosition
            for _ in 0..<remaining {
                _ = readBit()
            }
        }
    }
}
