#!/usr/bin/env python3
"""
Recursive FTP fetch of the DICOM WG26 2017 demo dataset, with proper resume.

- Uses ftplib (REST command) for true byte-offset resume on FTP.
- Reconnects on every transient error; retries each file ~indefinitely.
- Idempotent: re-running skips files whose size already matches the server's.
- Designed for unattended overnight runs against NEMA's slow / flaky FTP.

Output: writes to ../TestFixtures/WG26Demo2017/ relative to this script.
Logs:   stdout (line-buffered). Run via `python3 -u` and redirect to a file.
"""

from __future__ import annotations

import ftplib
import os
import re
import socket
import sys
import time
from pathlib import Path

HOST = "medical.nema.org"
BASE_PATH = "/medical/dicom/DataSets/WG26/WG26Demo2017"
DEST = Path(__file__).resolve().parent.parent / "TestFixtures" / "WG26Demo2017"

CONNECT_TIMEOUT = 60        # initial connect/login deadline
SOCKET_TIMEOUT = 600        # data-channel idle deadline (per chunk gap)
RETRY_DELAY = 30            # backoff between failed attempts
MAX_RETRIES_PER_FILE = 1000 # effectively unlimited for overnight runs
PROGRESS_EVERY = 60         # seconds between in-file progress lines


def log(msg: str) -> None:
    print(f"[wg26 {time.strftime('%H:%M:%S')}] {msg}", flush=True)


# IIS-style LIST line:
#   MM-DD-YY  HH:MMAM/PM       <DIR>          NAME
#   MM-DD-YY  HH:MMAM/PM               12345  NAME
LIST_RE = re.compile(r"^\S+\s+\S+\s+(\S+)\s+(.+)$")


class FtpClient:
    def __init__(self) -> None:
        self.ftp: ftplib.FTP | None = None
        self._connect()

    def _connect(self) -> None:
        while True:
            try:
                log(f"connecting to {HOST}…")
                self.ftp = ftplib.FTP(HOST, timeout=CONNECT_TIMEOUT)
                self.ftp.login()  # anonymous
                self.ftp.set_pasv(True)
                # Bigger socket buffer on the data channel helps with the slow link.
                self.ftp.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
                log("connected")
                return
            except Exception as e:
                log(f"connect failed: {type(e).__name__}: {e}; retry in {RETRY_DELAY}s")
                time.sleep(RETRY_DELAY)

    def reconnect(self) -> None:
        try:
            if self.ftp is not None:
                self.ftp.close()
        except Exception:
            pass
        time.sleep(RETRY_DELAY)
        self._connect()

    def list_dir(self, path: str):
        """Return [(name, is_dir, size_or_None), …] for an FTP directory."""
        while True:
            try:
                lines: list[str] = []
                self.ftp.cwd(path)
                self.ftp.retrlines("LIST", lines.append)
                entries = []
                for line in lines:
                    m = LIST_RE.match(line)
                    if not m:
                        continue
                    third, name = m.group(1), m.group(2).rstrip("\r")
                    if third == "<DIR>":
                        entries.append((name, True, None))
                    else:
                        try:
                            entries.append((name, False, int(third)))
                        except ValueError:
                            continue
                return entries
            except Exception as e:
                log(f"  list_dir({path}) failed: {type(e).__name__}: {e}; reconnecting")
                self.reconnect()

    def download(self, remote_path: str, local_path: Path, expected_size: int) -> bool:
        local_path.parent.mkdir(parents=True, exist_ok=True)
        part = local_path.with_suffix(local_path.suffix + ".part")

        if local_path.exists() and local_path.stat().st_size == expected_size:
            return True

        # Drop a too-large or zero-expected partial; otherwise resume from its size.
        if part.exists() and expected_size > 0 and part.stat().st_size > expected_size:
            log(f"  partial larger than remote ({part.stat().st_size} > {expected_size}); restarting")
            part.unlink()

        for attempt in range(1, MAX_RETRIES_PER_FILE + 1):
            offset = part.stat().st_size if part.exists() else 0
            if expected_size > 0 and offset == expected_size:
                part.rename(local_path)
                log(f"[OK  ] {remote_path} ({expected_size} bytes)")
                return True

            pct = (100.0 * offset / expected_size) if expected_size else 0.0
            log(f"[GET ] try {attempt} from {offset}/{expected_size} ({pct:.1f}%): {remote_path}")

            t0 = time.time()
            bytes_at_start = offset
            try:
                with open(part, "ab") as f:
                    state = {"last_t": time.time(), "last_n": f.tell()}

                    def cb(chunk: bytes) -> None:
                        f.write(chunk)
                        now = time.time()
                        if now - state["last_t"] >= PROGRESS_EVERY:
                            n = f.tell()
                            kbps = (n - state["last_n"]) / (now - state["last_t"]) / 1024.0
                            cur_pct = (100.0 * n / expected_size) if expected_size else 0.0
                            log(f"  … {n}/{expected_size} ({cur_pct:.1f}%, {kbps:.1f} KB/s)")
                            state["last_t"] = now
                            state["last_n"] = n

                    rest = offset if offset > 0 else None
                    # Set per-data-socket idle timeout so a stalled transfer aborts.
                    self.ftp.sock.settimeout(SOCKET_TIMEOUT)
                    self.ftp.retrbinary(f"RETR {remote_path}", cb, blocksize=65536, rest=rest)

                actual = part.stat().st_size
                elapsed = time.time() - t0
                rate = (actual - bytes_at_start) / elapsed / 1024.0 if elapsed > 0 else 0.0
                if expected_size and actual == expected_size:
                    part.rename(local_path)
                    log(f"[OK  ] {remote_path} ({expected_size} bytes, {rate:.1f} KB/s avg this run)")
                    return True
                if expected_size and actual > expected_size:
                    log(f"  overshot ({actual}>{expected_size}), discarding and restarting")
                    part.unlink()
                else:
                    log(f"  short read: {actual}/{expected_size}; will resume next attempt")
            except Exception as e:
                log(f"  attempt {attempt} failed: {type(e).__name__}: {e}")
                self.reconnect()

            time.sleep(RETRY_DELAY if attempt > 1 else 5)

        log(f"[FAIL] {remote_path} after {MAX_RETRIES_PER_FILE} attempts")
        return False


def walk(client: FtpClient, remote_dir: str, local_dir: Path) -> None:
    log(f"[DIR ] {remote_dir}")
    local_dir.mkdir(parents=True, exist_ok=True)
    entries = client.list_dir(remote_dir)
    for name, is_dir, size in entries:
        if name in (".", ".."):
            continue
        if is_dir:
            walk(client, f"{remote_dir}/{name}", local_dir / name)
        else:
            target = local_dir / name
            if target.exists() and size is not None and target.stat().st_size == size:
                log(f"[SKIP] {remote_dir}/{name}")
                continue
            if size is None:
                log(f"  unknown size for {remote_dir}/{name}, skipping")
                continue
            client.download(f"{remote_dir}/{name}", target, size)


def main() -> int:
    DEST.mkdir(parents=True, exist_ok=True)
    log(f"destination: {DEST}")

    client = FtpClient()
    try:
        walk(client, BASE_PATH, DEST)
    except KeyboardInterrupt:
        log("interrupted by SIGINT")
        return 130
    finally:
        try:
            if client.ftp is not None:
                client.ftp.close()
        except Exception:
            pass

    log("ALL DONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
