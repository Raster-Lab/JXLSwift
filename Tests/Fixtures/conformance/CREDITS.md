# Conformance test vectors

The `input.jxl` files under this directory are official JPEG XL conformance
test vectors taken verbatim from the **JPEG XL Project** conformance corpus:

> <https://github.com/libjxl/conformance> — `testcases/<name>/input.jxl`

They are redistributed here, unmodified, under that repository's BSD-3-Clause
licence (© the JPEG XL Project Authors) solely as test data for JXLSwift's
conformance gate (`Tests/JXLSwiftTests/ConformanceTests.swift`). They are
**test data, not source** — no libjxl code is vendored (CLAUDE.md constraint 4).

Only a tiny, curated **lossless** subset is committed so the gate runs green by
default without a network fetch:

| vector | bytes | what it exercises |
|---|---|---|
| `lz77_flower` | ~103 KB | lossless Modular RGB 8-bit with LZ77 back-references |
| `alpha_triangles` | 61 B | 9-bit RGBA Modular; out-of-gamut samples that must clamp to the declared bit-depth range on output |

To run the gate against the **full** conformance corpus, point the harness at a
local checkout via the `JXL_CONFORMANCE_DIR` environment variable (a directory
containing `<name>/input.jxl` sub-directories). See
`scripts/fetch-conformance.sh`.
