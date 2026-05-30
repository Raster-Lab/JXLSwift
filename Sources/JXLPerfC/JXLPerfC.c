// JXLPerfC.c — scaffolding placeholders. See include/JXLPerfC.h for the
// boundary discipline (byte-equivalent to scalar Swift, test-gated).

#include "JXLPerfC.h"

int jxlperf_c_version(void) {
    return 1;
}

uint64_t jxlperf_fnv1a(const uint8_t *buf, size_t len) {
    // FNV-1a 64-bit: standard offset basis + prime per
    // http://www.isthe.com/chongo/tech/comp/fnv/.
    uint64_t h = 14695981039346656037ULL;
    const uint64_t p = 1099511628211ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= (uint64_t)buf[i];
        h *= p;
    }
    return h;
}
