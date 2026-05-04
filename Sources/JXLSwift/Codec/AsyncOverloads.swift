// Async overloads for `JXLEncoder` / `JXLDecoder` — Phase B.7 of
// the family-API-parity migration. Mirrors J2KSwift's
// `J2KEncoder.encode(_:) async throws` / `J2KDecoder.decode(_:)
// async throws` shape, letting callers write codec-agnostic code
// that swaps libraries by import only.
//
// Implementation: each async overload simply runs the existing sync
// implementation. The encoder/decoder workload is CPU-bound and
// already short for typical inputs; we don't yet shell out to a
// background queue (no thread pool needed). The async overload
// exists for source-compatibility with J2KSwift call sites and
// for future progress-streaming work (Phase B.8).
//
// See [Documentation/FAMILY-API-PARITY.md](../../../Documentation/FAMILY-API-PARITY.md).

import Foundation

extension JXLEncoder {

    /// Async overload of ``encode(_:)``. Mirrors J2KSwift's
    /// `J2KEncoder.encode(_:) async throws -> Data`.
    ///
    /// Currently a thin wrapper around the synchronous encode —
    /// the work is CPU-bound and runs on the calling task's
    /// executor. Future revisions may dispatch to a dedicated
    /// thread pool when frame size justifies it.
    public func encode(_ frame: ImageFrame) async throws -> EncodedImage {
        // Disambiguate: bind to the sync overload's function type
        // so the compiler picks the non-async version (otherwise
        // `self.encode(frame)` recurses into this async overload).
        let syncEncode: (ImageFrame) throws -> EncodedImage = self.encode
        return try syncEncode(frame)
    }

    /// Async overload for multi-frame encode. Mirrors the
    /// single-frame async pattern.
    public func encode(_ frames: [ImageFrame]) async throws -> EncodedImage {
        let syncEncode: ([ImageFrame]) throws -> EncodedImage = self.encode
        return try syncEncode(frames)
    }
}

extension JXLDecoder {

    /// Async overload of ``decode(_:)``. Mirrors J2KSwift's
    /// `J2KDecoder.decode(_:) async throws -> J2KImage`.
    public func decode(_ data: Data) async throws -> ImageFrame {
        let syncDecode: (Data) throws -> ImageFrame = self.decode
        return try syncDecode(data)
    }

    /// Async overload of ``decodeAll(_:)`` for multi-frame inputs.
    public func decodeAll(_ data: Data) async throws -> [ImageFrame] {
        let syncDecodeAll: (Data) throws -> [ImageFrame] = self.decodeAll
        return try syncDecodeAll(data)
    }
}
