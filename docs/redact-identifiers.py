#!/usr/bin/env python3
"""Check that the tracked tree does not identify the authors.

The manuscript is prepared for double-blind review and says the harness and the
development log accompany the submission, so those files must not name the
authors, their hosts or their accounts. This checker stores only SHA-256 digests
of the strings that were removed, plus generic detectors; it never contains one
of those strings, so it can verify their absence without publishing them. The
digests are of low-entropy identifiers and are therefore reversible in
principle; the mitigation is that this repository must not be public while the
submission is under double-blind review.

Usage:
    redact-identifiers.py            report anything identifying; exit 1 if found
    redact-identifiers.py --selftest additionally prove the detector still works
    redact-identifiers.py --patterns FILE   also search for one literal per line
                                     from FILE (kept out of git), for re-runs

Design notes, because earlier versions of this file failed in three ways:
  * it reported OK while containing the very strings it removes, because it
    exempted itself from the scan. Nothing is exempt now, and the file passes
    only because it genuinely holds no literal;
  * it used `git ls-files` from the caller's working directory, so the same tree
    could pass from the repository root and fail from a subdirectory, and outside
    a repository it scanned the caller's directory instead and still said OK.
    It now chdirs to its own repository root; when there is no .git (an exported
    snapshot) it walks that root rather than failing, so the artefact itself can
    be verified;
  * it scanned only file contents, so the hyphenated *file name* that started
    this whole thread would have slipped through. Paths are scanned too.
"""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

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
    "024acf1c513884e8f8f5ee6966b3e81c3cc6ed61734826a21b0f4c3711a04ac4":
        "a personal name, lower case",
    "55bb0d0b2489601db0397f363f29e8a7a265e0ab0d0d38cb5df47202e66e4686":
        "a personal name, hyphenated",
    "2721a1000324033b3f6d9dfcea6127962677b7e513a111720e00c678753251e4":
        "a personal name, run together",
    "579dac7228d7ead91ee9fb0b35401b0d6730cbeb5eee4ef96546a2804c672f42":
        "a personal name, first token",
    "4243718ce7098065effba94758430ce7d229b2dbeeea34fce6a6e9ce26d7fc4e":
        "a personal name, bare",
}

# Generic categories: reported for file contents and paths. Only the digest table
# and --patterns decide the exit status, because upstream project URLs, private
# lab addresses in vendor documentation and toolchain paths are legitimate and
# treating them as failures would train the reader to ignore the check.
#
# These are deliberately also run over file *text*: an earlier version applied
# them only to paths, so a line containing a proxy URL or a host name produced no
# note at all.
GENERIC = [
    ("a GitHub URL", r"github\.com/[A-Za-z0-9_.-]+"),
    ("a private IPv4 address", r"\b(?:10|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b"),
    ("a host-specific path", r"/(?:home|root)/[A-Za-z0-9_.-]+/"),
]

SPLIT = r"[\s\"'`()\[\]{}<>,;.=:/@+]+"
JOINS = (" ", "-", "", ".", ":", "/", "@")


def candidates(text: str) -> list[str]:
    """Every token and 1-6 token window under the plausible joins.

    A secret can appear spaced, hyphenated, run together, dotted, colon- or
    slash-separated (an address, a proxy URL, a host name), and a file name can
    carry it in a different case, so all joins and both cases are produced. An
    earlier version only joined with space, hyphen and the empty string, which
    meant dotted addresses and host names were never formed and could not match
    their own digests.
    """
    words = [w for w in re.split(SPLIT, text.replace("-", " ").replace("_", " ")) if w]
    out: list[str] = []
    for n in (1, 2, 3, 4, 5, 6):
        for i in range(len(words) - n + 1):
            window = words[i:i + n]
            for sep in JOINS:
                out.append(sep.join(window))
    out.append(text)
    out.extend([t for t in re.split(SPLIT, text) if t])
    # A secret can mix separators within one token (a proxy URL, a qualified
    # host name with a port), which no single-join window can reconstruct, so
    # the whitespace-delimited tokens themselves are candidates too.
    out.extend(text.split())
    return out


def hits_in(text: str, extra: list[str]) -> list[str]:
    found = []
    for cand in candidates(text):
        for form in ({cand, cand.lower()}):
            d = hashlib.sha256(form.encode()).hexdigest()
            if d in KNOWN_BAD_SHA256:
                found.append(KNOWN_BAD_SHA256[d])
        if cand in extra:
            found.append("matches a supplied pattern")
    return found


def tracked_files() -> list[str]:
    """Paths to scan, always relative to ROOT.

    In a checkout this is `git ls-files`, so ignored build products are skipped.
    In an exported snapshot there is no .git, and the right fallback is to walk
    ROOT - never the caller's directory, which is what an earlier version did.
    """
    try:
        out = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True,
                             text=True, check=True).stdout
        if out.strip():
            return [p for p in out.splitlines() if p]
    except (OSError, subprocess.CalledProcessError):
        pass
    found = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in (".git", "target", "__pycache__")]
        for f in filenames:
            found.append(os.path.relpath(os.path.join(dirpath, f), ROOT))
    return sorted(found)


def scan(paths: list[str], extra: list[str]) -> int:
    hits = 0
    for rel in paths:
        for h in hits_in(rel, extra):
            print(f"{rel}: path: {h}")
            hits += 1
        p = os.path.join(ROOT, rel)
        try:
            with open(p, "rb") as fh:
                raw = fh.read()
        except OSError:
            continue
        text = raw.decode("utf-8", "replace")
        # Generic detectors run over contents as well as paths; an earlier
        # version only looked at the path, so a line carrying a proxy URL or a
        # host name produced no note at all.
        for label, pat in GENERIC:
            for _ in list(re.finditer(pat, rel)) + list(re.finditer(pat, text))[:5]:
                print(f"note: {rel}: matches {label}")
        for h in hits_in(text, extra):
            print(f"{rel}: {h}")
            hits += 1
    return hits


def selftest() -> int:
    """Prove the detector works, without containing any real secret.

    Synthetic strings and their digests stand in for real ones, so the test can
    exercise contents, paths, several join forms and the absence of false
    positives with no leaking literal. The fixtures cover a hyphenated word, a
    dotted name and a colon-separated token, because an earlier version tested
    only the hyphenated form - exactly the one the generator already supported -
    and therefore could not reveal that dotted addresses and host names were
    never formed.
    """
    fixtures = ["synthetic-identifier-do-not-ship", "synthetic.example",
                "synthetic:1080"]
    added = []
    try:
        for s in fixtures:
            d = hashlib.sha256(s.encode()).hexdigest()
            KNOWN_BAD_SHA256[d] = "test fixture"
            added.append(d)
        return _selftest_body(fixtures)
    finally:
        # The synthetic digests must not leak into the subsequent scan: the
        # fixture strings are in this file, so leaving them in would make the
        # checker report itself.
        for d in added:
            KNOWN_BAD_SHA256.pop(d, None)


def _selftest_body(fixtures: list[str]) -> int:
    ok = True
    hyphenated, dotted, colon = fixtures
    if not hits_in(f"prefix {hyphenated} suffix", []):
        print("selftest FAIL: hyphenated body text not detected")
        ok = False
    if not hits_in(f"docs/{hyphenated}-note.md", []):
        print("selftest FAIL: file path not detected")
        ok = False
    if not hits_in(f"proxy is at {dotted} today", []):
        print("selftest FAIL: dotted address inside a sentence not detected")
        ok = False
    if not hits_in(f"listening on {colon}", []):
        print("selftest FAIL: colon-separated token inside a sentence not detected")
        ok = False
    if hits_in("a perfectly ordinary sentence", []):
        print("selftest FAIL: false positive on clean text")
        ok = False
    print(f"selftest {'OK' if ok else 'FAILED'}")
    return 0 if ok else 1


def main() -> int:
    if "--selftest" in sys.argv:
        rc = selftest()
        if rc:
            return rc
    extra: list[str] = []
    if "--patterns" in sys.argv:
        pf = sys.argv[sys.argv.index("--patterns") + 1]
        extra = [l.rstrip("\n") for l in open(pf) if l.strip()]

    os.chdir(ROOT)
    files = tracked_files()
    hits = scan(files, extra)
    print(f"{'FAIL' if hits else 'OK'}: {hits} identifying match(es) in "
          f"{len(files)} files under {ROOT}")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
