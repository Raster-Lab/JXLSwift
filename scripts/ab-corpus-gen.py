#!/usr/bin/env python3
# ab-corpus-gen.py — deterministic synthetic corpus for the byte-identity
# A/B harness (scripts/ab-check.sh). Every optimisation that claims
# byte-identical output is gated by re-encoding this corpus and comparing
# hashes against a stored baseline. Seeded; regenerating produces identical
# files. Dev-time tooling only — no comparative numbers, no third-party data.
import math
import os
import random
import struct
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/jxl-ab/corpus"
os.makedirs(OUT, exist_ok=True)


def pgm16(name, w, h, fn):
    random.seed(name)
    buf = bytearray(f"P5\n{w} {h}\n65535\n".encode())
    for y in range(h):
        for x in range(w):
            v = max(0, min(65535, int(fn(x, y))))
            buf += struct.pack(">H", v)
    open(os.path.join(OUT, name), "wb").write(bytes(buf))


def pgm8(name, w, h, fn):
    random.seed(name)
    buf = bytearray(f"P5\n{w} {h}\n255\n".encode())
    for y in range(h):
        for x in range(w):
            buf.append(max(0, min(255, int(fn(x, y)))))
    open(os.path.join(OUT, name), "wb").write(bytes(buf))


def ppm(name, w, h, fn, maxval=255):
    random.seed(name)
    buf = bytearray(f"P6\n{w} {h}\n{maxval}\n".encode())
    pack = (lambda v: struct.pack(">H", v)) if maxval > 255 else (lambda v: bytes([v]))
    for y in range(h):
        for x in range(w):
            for v in fn(x, y):
                buf += pack(max(0, min(maxval, int(v))))
    open(os.path.join(OUT, name), "wb").write(bytes(buf))


def pam_rgba(name, w, h, fn):
    random.seed(name)
    hdr = (
        f"P7\nWIDTH {w}\nHEIGHT {h}\nDEPTH 4\nMAXVAL 255\n"
        "TUPLTYPE RGB_ALPHA\nENDHDR\n"
    )
    buf = bytearray(hdr.encode())
    for y in range(h):
        for x in range(w):
            for v in fn(x, y):
                buf.append(max(0, min(255, int(v))))
    open(os.path.join(OUT, name), "wb").write(bytes(buf))


def ct(x, y, w, h):
    cx, cy, r = w / 2, h / 2, w * 0.42
    d = math.hypot(x - cx, y - cy)
    if d > r:
        return 30 + random.gauss(0, 4)
    base = 18000 + 9000 * math.sin(x * 0.011) + 7000 * math.cos(y * 0.013)
    base += 6000 * math.exp(-((d / r) ** 2) * 3)
    return base + random.gauss(0, 60)


# 16-bit gray: the medical reference shapes (single group, multi-group, >4Mpx)
pgm16("ct512.pgm", 512, 512, lambda x, y: ct(x, y, 512, 512))
pgm16("ct600.pgm", 600, 600, lambda x, y: ct(x, y, 600, 600))
pgm16(
    "grad16_2080.pgm",
    2080,
    2080,
    lambda x, y: 200 * (x // 64) + 90 * (y // 64) + random.gauss(0, 12),
)
# 8-bit gray: noise+structure, constant, odd dims
pgm8(
    "noise8_384.pgm",
    384,
    384,
    lambda x, y: 128 + 60 * math.sin(x * 0.07) + random.gauss(0, 22),
)
pgm8("const64.pgm", 64, 64, lambda x, y: 137)
pgm8("tiny7x5.pgm", 7, 5, lambda x, y: (x * 41 + y * 17) % 256)
# colour
ppm(
    "rgb8_256.ppm",
    256,
    256,
    lambda x, y: (
        120 + 80 * math.sin(x * 0.05),
        110 + 70 * math.cos(y * 0.04),
        90 + 50 * math.sin((x + y) * 0.03) + random.gauss(0, 9),
    ),
)
ppm(
    "rgb16_300.ppm",
    300,
    300,
    lambda x, y: (
        20000 + 9000 * math.sin(x * 0.03) + random.gauss(0, 40),
        18000 + 8000 * math.cos(y * 0.025),
        15000 + 6000 * math.sin((x - y) * 0.02),
    ),
    maxval=65535,
)
pam_rgba(
    "rgba8_160.pam",
    160,
    160,
    lambda x, y: (
        100 + 70 * math.sin(x * 0.06),
        140 + 60 * math.cos(y * 0.05),
        90 + 40 * math.sin((x + 2 * y) * 0.02),
        255 if (x // 20 + y // 20) % 2 == 0 else 128 + x % 64,
    ),
)
print(f"corpus written to {OUT}: {sorted(os.listdir(OUT))}")
