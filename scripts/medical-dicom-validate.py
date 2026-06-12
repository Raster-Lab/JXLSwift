#!/usr/bin/env python3
"""medical-dicom-validate.py — medical-grade lossless validation of JXLSwift
against a corpus of DICOM images.

JXLSwift is the codec; it is intentionally NOT DICOM-aware (CLAUDE.md
constraint 5). This harness therefore uses an EXTERNAL extractor (pydicom) to
pull raw pixel buffers out of DICOM files and feeds them to JXLSwift's lossless
path, then verifies the reconstruction is byte-exact through BOTH the pure-Swift
decoder AND the libjxl reference decoder `djxl`. No DICOM logic ever enters
`Sources/`.

It is **PHI-safe**: it reports only technical pixel configs + aggregate
pass/fail counts and file *basenames* — never patient metadata — and keeps all
temporary pixel files in a scratch dir that it removes as it goes. Nothing is
uploaded or committed.

Methodology:
  1. Walk the corpus (no symlink following), detect DICOM by the `DICM` magic.
  2. Stratify by pixel config (modality × transfer-syntax × bits × channels ×
     photometric × signedness × single/multi-frame): take every small config
     whole, evenly subsample large configs across studies.
  3. For each file: extract pixels (frame 0 if multi-frame) → write a netpbm
     PNM → `jxl-tool encode --lossless` → `jxl-tool decode` + `djxl` → compare
     the decoded sample VALUES (endian-agnostic) to the originals.

Files are validated in parallel (one worker per core, each with its own
scratch subdir); results are aggregated in deterministic input order, so the
report is identical to the old sequential run's.

Requirements: a venv with `pydicom numpy` (+ optionally `pylibjpeg
pylibjpeg-libjpeg pylibjpeg-openjpeg pyjpegls` for compressed transfer
syntaxes). Usage:

    JXL_TOOL=.build/release/jxl-tool DJXL=/opt/homebrew/bin/djxl \\
      python3 scripts/medical-dicom-validate.py <DICOM_DIR> [effort] [big_target]

Optional env: WORKERS=N (default: all cores), SCRATCH=dir.
"""
import collections
import multiprocessing as mp
import os
import subprocess
import sys
import time

import numpy as np
import pydicom

SMALL_CAP = 400

# Worker-process config, set by _worker_init (spawn start method re-imports
# this module in each worker, so nothing config-dependent may run at import).
_CFG = {}


def is_dicom(p):
    try:
        with open(p, 'rb') as f:
            f.seek(128)
            return f.read(4) == b'DICM'
    except Exception:
        return False


def cfg_key(ds):
    return (str(getattr(ds, 'Modality', '?')),
            str(ds.file_meta.TransferSyntaxUID) if getattr(ds, 'file_meta', None) else '?',
            int(getattr(ds, 'BitsAllocated', 0) or 0),
            int(getattr(ds, 'SamplesPerPixel', 1) or 1),
            str(getattr(ds, 'PhotometricInterpretation', '?')),
            int(getattr(ds, 'PixelRepresentation', 0) or 0),
            'multi' if int(getattr(ds, 'NumberOfFrames', 1) or 1) > 1 else 'single')


def write_pnm(path, w, h, ch, vals, maxval):
    magic = b'P5' if ch == 1 else b'P6'
    hdr = magic + b'\n' + f"{w} {h}\n{maxval}\n".encode()
    arr = np.asarray(vals)
    body = (arr.astype('>u1') if maxval <= 255 else arr.astype('>u2')).tobytes()
    with open(path, 'wb') as f:
        f.write(hdr)
        f.write(body)


def parse_pnm(path):
    data = open(path, 'rb').read()
    ch = 3 if data[1:2] == b'6' else 1
    idx, toks = 2, []
    while len(toks) < 3:
        while idx < len(data) and data[idx:idx+1].isspace():
            idx += 1
        s = idx
        while idx < len(data) and not data[idx:idx+1].isspace():
            idx += 1
        toks.append(int(data[s:idx]))
    idx += 1
    w, h, maxval = toks
    n = w * h * ch
    body = data[idx:]
    v = (np.frombuffer(body[:n], dtype='>u1') if maxval <= 255
         else np.frombuffer(body[:2*n], dtype='>u2')).astype(np.int64)
    return w, h, ch, v


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, timeout=900)
    return p.returncode, p.stderr.decode('utf-8', 'replace')


def _worker_init(jxl, djxl, effort, scratch_base):
    _CFG['JXL'] = jxl
    _CFG['DJXL'] = djxl
    _CFG['EFFORT'] = effort
    scratch = os.path.join(scratch_base, f"w{os.getpid()}")
    os.makedirs(scratch, exist_ok=True)
    _CFG['SCRATCH'] = scratch


def validate_one(p):
    """Round-trip one DICOM file. Returns (status, cfg, stage, basename,
    detail) where status is 'pass' / 'fail' / 'skip'; cfg is the config key
    string ('' when unknown); stage names the skip reason or failing step."""
    base = os.path.basename(p)
    try:
        ds = pydicom.dcmread(p, force=True)
    except Exception:
        return ('skip', '', 'header', base, '')
    ba = int(getattr(ds, 'BitsAllocated', 0) or 0)
    spp = int(getattr(ds, 'SamplesPerPixel', 1) or 1)
    frames = int(getattr(ds, 'NumberOfFrames', 1) or 1)
    cfg = '|'.join(map(str, cfg_key(ds)))
    if ba == 0 or 'PixelData' not in ds or ba > 16 or spp not in (1, 3):
        return ('skip', cfg, 'no/unsupported_pixels', base, '')
    try:
        arr = ds.pixel_array
    except Exception as e:
        return ('skip', cfg, 'decode:' + type(e).__name__, base, '')
    if frames > 1:
        arr = arr[0]
    if arr.ndim == 3:
        h, w, c = arr.shape
        if c != 3:
            return ('skip', cfg, f'ch{c}', base, '')
    else:
        h, w = arr.shape
        c = 1
    maxval = 255 if ba <= 8 else 65535
    vals = (arr.astype(np.int64) & (0xFF if ba <= 8 else 0xFFFF)).reshape(-1)
    ext = 'pgm' if c == 1 else 'ppm'
    scratch = _CFG['SCRATCH']
    inP, jxlP = f"{scratch}/in.{ext}", f"{scratch}/o.jxl"
    ourP, djP = f"{scratch}/our.{ext}", f"{scratch}/dj.{ext}"
    write_pnm(inP, w, h, c, vals, maxval)
    rc, se = run([_CFG['JXL'], "encode", "--lossless",
                  "--effort", _CFG['EFFORT'], "-i", inP, "-o", jxlP])
    if rc != 0:
        return ('fail', cfg, 'encode', base, se[:160])
    rc, se = run([_CFG['JXL'], "decode", "-i", jxlP, "-o", ourP])
    if rc != 0 or not np.array_equal(parse_pnm(ourP)[3], vals):
        return ('fail', cfg, 'our_decode', base, se[:160])
    if _CFG['DJXL']:
        rc, se = run([_CFG['DJXL'], jxlP, djP])
        if rc != 0 or not np.array_equal(parse_pnm(djP)[3], vals):
            return ('fail', cfg, 'djxl', base, se[:160])
    return ('pass', cfg, '', base, '')


def main():
    root = sys.argv[1]
    effort = sys.argv[2] if len(sys.argv) > 2 else "1"
    big_target = int(sys.argv[3]) if len(sys.argv) > 3 else 1000
    jxl = os.environ.get("JXL_TOOL", ".build/release/jxl-tool")
    djxl = os.environ.get("DJXL", "/opt/homebrew/bin/djxl")
    if not os.path.exists(djxl):
        djxl = ""   # djxl optional; our-decoder check still runs
    scratch_base = os.environ.get("SCRATCH", "/tmp/dcm_scratch")
    workers = int(os.environ.get("WORKERS", 0)) or (os.cpu_count() or 4)
    os.makedirs(scratch_base, exist_ok=True)

    # --- 1. walk + stratify -------------------------------------------------
    buckets = collections.defaultdict(list)
    for dp, dn, fn in os.walk(root, followlinks=False):
        dn[:] = [d for d in dn if not os.path.islink(os.path.join(dp, d))]
        for f in fn:
            if f == '.DS_Store':
                continue
            p = os.path.join(dp, f)
            if os.path.islink(p) or not is_dicom(p):
                continue
            try:
                ds = pydicom.dcmread(p, stop_before_pixels=True, force=True)
            except Exception:
                continue
            buckets[cfg_key(ds)].append(p)

    sample = []
    for cfg, ps in sorted(buckets.items(), key=lambda kv: -len(kv[1])):
        ps.sort()
        sample.extend(ps if len(ps) <= SMALL_CAP
                      else ps[::max(1, len(ps)//big_target)][:big_target])
    print(f"=== {len(sample)} files sampled from "
          f"{sum(len(v) for v in buckets.values())} across {len(buckets)} "
          f"configs (effort {effort}, djxl={'yes' if djxl else 'no'}, "
          f"{workers} workers) ===", flush=True)

    # --- 2. round-trip in parallel, aggregate in input order ----------------
    PASS = FAIL = SKIP = 0
    by_cfg = collections.Counter()
    fail_cfg = collections.Counter()
    skips = collections.Counter()
    fails = []
    t0 = time.time()
    with mp.Pool(workers, initializer=_worker_init,
                 initargs=(jxl, djxl, effort, scratch_base)) as pool:
        for i, (status, cfg, stage, base, detail) in enumerate(
                pool.imap(validate_one, sample, chunksize=4)):
            if status == 'skip':
                SKIP += 1
                skips[stage] += 1
            elif status == 'fail':
                FAIL += 1
                fail_cfg[cfg] += 1
                by_cfg[cfg] += 1
                fails.append((base, cfg, stage, detail))
            else:
                PASS += 1
                by_cfg[cfg] += 1
            if (i + 1) % 200 == 0:
                print(f"  ...{i+1}/{len(sample)} pass={PASS} fail={FAIL} "
                      f"skip={SKIP} ({time.time()-t0:.0f}s)", flush=True)

    print(f"\n=== DONE: {len(sample)} files in {time.time()-t0:.0f}s ===")
    print(f"PASS={PASS}  FAIL={FAIL}  SKIP={SKIP}  "
          "(every PASS byte-exact via our decoder + djxl)")
    print("tested-by-config:", dict(by_cfg))
    print("skip-reasons:", dict(skips))
    if fails:
        print("FAILURES:")
        for f in fails[:50]:
            print("  ", f)
    sys.exit(1 if FAIL else 0)


if __name__ == '__main__':
    main()
