#!/usr/bin/env python3
"""Check that the tracked documentation does not identify the authors.

The manuscript is prepared for double-blind review and says the harness and the
development log accompany the submission, so those files must not name the
authors, their hosts or their accounts. An earlier version of this script
contained the offending strings verbatim as the patterns to search for, which
re-published exactly what it was removing; this version stores only SHA-256
digests of the known strings plus generic detectors, so it can verify absence
without containing a secret.

  --check (default)  report any tracked file that still matches
  --patterns FILE    additionally search for one literal per line from FILE,
                     which lets a maintainer re-run a redaction without
                     committing the literals

Exit status is 0 when nothing matches.
"""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys

# sha256 -> what it is, in words that do not give the string away
KNOWN_BAD_SHA256 = {
    "996c362ad206e2818e604a80da911c2aa47e8fca7db5bbb393780522dd769790":
        "the USB stick's exFAT volume label, which embedded a personal name",
    "a515b48580a51001375ec57303bdc8bff4bd21888b6b3f831ff143e0f193cf17":
        "the fork owner's GitHub handle",
    "b2d13b93950c30a1cca417b9580fe6584f1e663d14e1fb3af3ecaba3361cc1cc":
        "a host-specific proxy URL",
    "439e7e60f30be6f7dd96676bcb80d9aaf53b5035954b6a2b08b075ee2d0feb99":
        "a host-specific proxy address",
    "70ea3310c6fa21f8358d344f42cab2803c7bb9ec551ec4184795908223e83375":
        "a host-specific domain",
    "cfd6728aee11815ac32d941ed745c3035ddea4c1e2b67f8eb5d6363ae95847d6":
        "a personal name",
    "3830e8c40db6ae4143881b9028ab676b5cb17f6fcfc97fb4710e73874d2812f5":
        "a personal account name",
}

# Generic categories that should never appear in a double-blind artefact.
GENERIC = [
    ("a GitHub URL naming an account", re.compile(r"github\.com/[A-Za-z0-9_.-]+")),
    ("a private IPv4 address", re.compile(r"\b(?:10|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b")),
    ("a host-specific path", re.compile(r"/(?:home|root)/[A-Za-z0-9_.-]+/")),
]

# Paths that are allowed to contain the generic patterns because they document
# them (this file) or because they are the placeholder list itself.
ALLOW = {"docs/redact-identifiers.py"}


def tracked_files() -> list[str]:
    try:
        out = subprocess.run(["git", "ls-files"], capture_output=True, text=True,
                             check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        out = "\n".join(
            os.path.join(root, f)
            for root, _, files in os.walk(".")
            for f in files
        )
    return [p for p in out.splitlines() if p and not p.startswith(".git/")]


def main() -> int:
    extra: list[str] = []
    if "--patterns" in sys.argv:
        path = sys.argv[sys.argv.index("--patterns") + 1]
        extra = [l.rstrip("\n") for l in open(path) if l.strip()]

    hits = 0
    for path in tracked_files():
        if path in ALLOW:
            continue
        try:
            text = open(path, errors="replace").read()
        except OSError:
            continue
        for token in re.split(r"[\s\"'`()\[\]{}<>,;]+", text):
            digest = hashlib.sha256(token.encode()).hexdigest()
            if digest in KNOWN_BAD_SHA256:
                print(f"{path}: known-bad token ({KNOWN_BAD_SHA256[digest]})")
                hits += 1
        for lit in extra:
            if lit and lit in text:
                print(f"{path}: matches a supplied pattern")
                hits += 1
        # Generic host-path fingerprints are only meaningful in prose; scripts
        # legitimately carry the interpreter/toolchain paths they run under.
        # Generic categories are reported as notes only: upstream project URLs,
        # private lab addresses in vendor documentation and toolchain paths are
        # legitimate, and flagging them as failures would train the reader to
        # ignore this check. The digest list and --patterns drive the verdict.
        if path.endswith((".md", ".tex")) or path.startswith(("docs/", "paper/")):
            for label, pat in GENERIC:
                for m in pat.finditer(text):
                    print(f"note: {path}: {label}: {m.group(0)}")
    print(f"{'FAIL' if hits else 'OK'}: {hits} identifying match(es)")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
