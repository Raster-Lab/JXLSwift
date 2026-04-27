// JPEG XL codestream signature (ISO/IEC 18181-1 §C.3.1).
//
// Every codestream — whether naked or packaged inside a `jxlc`/`jxlp`
// container box — begins with the two-byte sequence `FF 0A`.

import Foundation

public let codestreamSignatureBytes: [UInt8] = [0xFF, 0x0A]

/// Whether `data` starts with the codestream signature.
public func hasCodestreamSignature(_ data: Data) -> Bool {
    data.count >= 2
        && data[data.startIndex]     == 0xFF
        && data[data.startIndex + 1] == 0x0A
}
