#!/usr/bin/env python3
"""Recompute a batch's verdicts from the archived run directories.

Note: this normalises the md5 column to MATCH/MISMATCH, so re-deriving a CSV that
acceptance-batch.sh wrote can differ in that one string (it emits
"MISMATCH/missing" when the guest log has no digest). Verdicts and all numeric
fields are identical.

The verdict logic in guest/verdict.py changed after the round-3 campaign: the
copy must now contain CH's own completion instant (parsed from src.log) rather
than the instant send-migration returned, and a missing downtime line is a
failure rather than a 0 ms run. Every ingredient of the new verdict is in the
archived logs, so the campaign does not have to be re-run on the VMs; it has to
be *re-judged*, which is cheaper and leaves the evidence untouched.

Rewrites results-<tag>.csv in exactly the format acceptance-batch.sh produces,
so paper/update-results.py cannot tell the difference.

Usage: reverify-batch.py <batch-dir> <tag> [<tag> ...]
"""
from __future__ import annotations

import glob
import os
import re
import subprocess
import sys

DIR = os.path.dirname(os.path.abspath(__file__))
VERDICT = os.path.join(DIR, "verdict.py")
EXPECTED = open(os.path.join(DIR, "testfile.md5")).read().split()[0]
HEADER = "run,downtime_ms,copy_s,spans,md5,late_enum,late_err,kicks,stale,verdict,rc"

KICK = re.compile(r"re-raising one interrupt")
STALE = re.compile(r"ignoring IRQ disable from stale")


def field(text: str, name: str) -> str:
    m = re.search(rf"^{re.escape(name)}\s*:\s*(.+?)\s*$", text, re.M)
    return m.group(1).strip() if m else ""


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    batch = sys.argv[1]
    for tag in sys.argv[2:]:
        runs = []
        for d in glob.glob(os.path.join(batch, f"{tag}-*")):
            if not os.path.isdir(d):
                continue
            suf = os.path.basename(d)[len(tag) + 1:]
            if suf.isdigit():
                runs.append((int(suf), d))
        runs.sort()
        if not runs:
            print(f"{tag}: no run directories")
            continue
        out = [HEADER]
        summary = []
        for i, d in runs:
            g = os.path.join(d, "guest-demo.log")
            gtext = open(g, errors="replace").read() if os.path.exists(g) else ""
            srv = os.path.join(d, "usbvfiod.log")
            stext = open(srv, errors="replace").read() if os.path.exists(srv) else ""
            epoch = ""
            ep = os.path.join(d, "migration.epoch")
            if os.path.exists(ep):
                epoch = open(ep).read().strip()
            if not epoch or float(epoch) <= 0:
                # control run: no migration, digest-only verdict
                digests = {p: h for h, p in re.findall(r"^([0-9a-f]{32})\s+(\S+)", gtext, re.M)}
                src = next((h for p, h in digests.items() if "testfile.bin" in p), "")
                dst = next((h for p, h in digests.items() if "testfile.copy" in p), "")
                ok = bool(src) and src == dst
                out.append(f"{i},,{opts_copy(gtext)},n/a,{'MATCH' if ok else 'MISMATCH'},,,"
                           f"{len(KICK.findall(stext))},{len(STALE.findall(stext))},"
                           f"{'PASS' if ok else 'FAIL'},0")
                summary.append((i, "PASS" if ok else "FAIL"))
                continue
            cmd = [sys.executable, VERDICT, "--guest-log", g,
                   "--expected-md5", EXPECTED, "--migration-epoch", epoch,
                   "--src-log", os.path.join(d, "src.log")]
            dn = os.path.join(d, "migration.done")
            if os.path.exists(dn) and open(dn).read().strip():
                cmd += ["--migration-done", open(dn).read().strip()]
            down = ""
            s = os.path.join(d, "src.log")
            if os.path.exists(s):
                m = re.search(r"downtime of (\d+)ms", open(s, errors="replace").read())
                down = m.group(1) if m else ""
            # The enlarged-window arms deliberately exceed the acceptance
            # downtime budget; the injected delay *is* the downtime there.
            budget = "12000" if tag.startswith("winlong") or tag == "window-loss" \
                else "2000"
            cmd += ["--downtime-ms", down, "--max-downtime-ms", budget]
            o = subprocess.run(cmd, capture_output=True, text=True).stdout
            verdict = field(o, "VERDICT") or "FAIL"
            spans = field(o, "spans migration") or "NO"
            md5 = "MATCH" if field(o, "md5 verdict").startswith("MATCH") else "MISMATCH"
            le = field(o, "enumerations after migration") or ""
            lr = field(o, "reset/error lines after migr.") or ""
            copy_s = field(o, "copy duration").replace(" s", "")
            rc = "0" if verdict == "PASS" else "1"
            out.append(f"{i},{down},{copy_s},{spans},{md5},{le},{lr},"
                       f"{len(KICK.findall(stext))},{len(STALE.findall(stext))},{verdict},{rc}")
            summary.append((i, verdict))
        path = os.path.join(batch, f"results-{tag}.csv")
        open(path, "w").write("\n".join(out) + "\n")
        p = sum(1 for _, v in summary if v == "PASS")
        print(f"{tag}: {p}/{len(summary)} PASS -> {path}")
    return 0


def opts_copy(gtext: str) -> str:
    st = re.search(r"DEMO-COPY: COPY_START ([\d.]+)", gtext)
    dn = re.search(r"DEMO-COPY: COPY_DONE ([\d.]+) rc=", gtext)
    if st and dn:
        return f"{float(dn.group(1)) - float(st.group(1)):.1f}"
    return ""


if __name__ == "__main__":
    sys.exit(main())
