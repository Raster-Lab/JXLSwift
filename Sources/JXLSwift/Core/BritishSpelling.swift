/// British English spelling aliases for JXLSwift public API types
///
/// JXLSwift uses British English throughout its documentation, comments, and
/// error messages. These type aliases allow British-English spellings alongside
/// the canonical American-English spellings so that no existing API contracts
/// are broken.
///
/// Both spellings are fully interchangeable; they refer to exactly the same
/// underlying type.
///
/// Note: `ColourSpace` is intentionally absent from this file because the name
/// is already used by the spec-level ``ColourSpace`` enum in `CodestreamHeader`
/// (the JPEG XL §11.4 colour space indicator).  The public, user-facing colour
/// space type is ``ColorSpace`` and should be used directly.

// MARK: - Colour Primaries

/// British-English alias for ``ColorPrimaries``.
///
/// Both `ColourPrimaries` and `ColorPrimaries` refer to the same type.
/// Use whichever spelling you prefer — they are interchangeable.
public typealias ColourPrimaries = ColorPrimaries
