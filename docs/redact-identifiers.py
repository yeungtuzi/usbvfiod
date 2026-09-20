#!/usr/bin/env python3
"""Redact author-identifying strings from the tracked documentation.

The manuscript is prepared for double-blind review and claims that the harness
and the development log accompany the submission, so those files must not
identify the authors. Three kinds of string leaked:

  * the filesystem label of the USB stick (it embeds a person's name), which had
    been copied into guest/testfile.md5 as part of a mount path;
  * the fork owner's GitHub handle, in repository/PR/branch references;
  * a host-specific proxy address.

This rewrites only those strings, leaves every technical detail intact, and
refuses to run twice. It is checked into the repository so the redaction is
auditable rather than invisible.

Usage: redact-identifiers.py [--check]
"""
from __future__ import annotations

import re
import sys

FILES = [
    "docs/DEVLOG_cn.md",
    "docs/demo-usb-storage-live-migration-plan_cn.md",
    "docs/pr/usbvfiod-multi-client.md",
    "docs/pr/vfio-resettable-fix.md",
    "paper/README.md",
    "paper/main.tex",
    "artifacts/README.md",
]

MD5_PATH = "guest/testfile.md5"

# (pattern, replacement, why)
SUBS = [
    (r"刘湛渊-U盘-32GB", "<stick-volume-label>", "USB volume label embeds a personal name"),
    (r"yeungtuzi", "<fork-owner>", "GitHub handle identifies the authors"),
    (r"socks5h://192\.168\.100\.4:1080", "socks5h://<proxy-host>:1080", "host-specific proxy"),
    (r"192\.168\.100\.4", "<proxy-host>", "host-specific address"),
    (r"pve\.tuzi", "<host>", "host-specific domain"),
]


def main() -> int:
    check = "--check" in sys.argv
    hits = 0
    for path in FILES:
        try:
            text = open(path).read()
        except OSError:
            continue
        new = text
        for pat, rep, why in SUBS:
            n = len(re.findall(pat, new))
            if n:
                print(f"{path}: {n}x {why}: {pat!r} -> {rep!r}")
                hits += n
                new = re.sub(pat, rep, new)
        if new != text and not check:
            open(path, "w").write(new)
    # the checksum file: keep the digest, drop the mount path that carries the label
    try:
        line = open(MD5_PATH).read().strip()
        digest = line.split()[0]
        if not check and line != f"{digest}  testfile.bin":
            print(f"{MD5_PATH}: replaced the mount path with a bare file name")
            open(MD5_PATH, "w").write(f"{digest}  testfile.bin\n")
            hits += 1
    except OSError:
        pass
    print(f"{'would redact' if check else 'redacted'} {hits} occurrence(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
