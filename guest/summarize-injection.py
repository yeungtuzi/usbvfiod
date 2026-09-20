#!/usr/bin/env python3
"""Summarise a fault-injection arm from its own logs.

For each run the interesting question is not only pass/fail but *where the copy
stopped*: a lost completion leaves the guest's dd stuck at a fixed byte count,
which is direct evidence for the mechanism rather than for "something went
wrong". This reads the guest heartbeat (which carries copied=B), the run's
verdict lines, and the server log's hand-over markers.

Usage: summarize-injection.py <run-root>
"""
from __future__ import annotations

import glob
import os
import re
import sys

HB = re.compile(r"DEMO-HEARTBEAT\s+\d+\s+[\d.]+\s+uptime=[\d.]+\s+copied=(\d+)")
COPY_DONE = re.compile(r"DEMO-COPY: COPY_DONE\s+[\d.]+\s+rc=(-?\d+)")
INSTALL = re.compile(r"interrupt line installed")
KICK = re.compile(r"re-raising one interrupt")
STALE = re.compile(r"ignoring IRQ disable from stale")


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else "/root/usb-inject"
    rows = []
    for log in sorted(glob.glob(os.path.join(root, "*.log"))):
        tag = os.path.basename(log).rsplit("-", 1)[0]
        text = open(log, errors="replace").read()
        verdict = re.search(r"^VERDICT\s*:\s*(\w+)", text, re.M)
        rundir = os.path.join(root, os.path.basename(log)[:-4])
        copied = []
        g = os.path.join(rundir, "guest-demo.log")
        if os.path.exists(g):
            gtext = open(g, errors="replace").read()
            copied = [int(x) for x in HB.findall(gtext)]
        srv = os.path.join(rundir, "usbvfiod.log")
        stext = open(srv, errors="replace").read() if os.path.exists(srv) else ""
        gtext = open(g, errors="replace").read() if os.path.exists(g) else ""
        rows.append({
            "run": os.path.basename(rundir),
            "arm": tag,
            "verdict": verdict.group(1) if verdict else "?",
            "copy_done": "yes" if COPY_DONE.search(gtext) else "no",
            "stall_at_MiB": f"{copied[-1] / 1048576:.1f}" if copied else "?",
            "beat": len(copied),
            "installs": len(INSTALL.findall(stext)),
            "kicks": len(KICK.findall(stext)),
            "stale": len(STALE.findall(stext)),
        })
    cols = ["run", "arm", "verdict", "copy_done", "stall_at_MiB", "beat",
            "installs", "kicks", "stale"]
    print(",".join(cols))
    for r in rows:
        print(",".join(str(r[c]) for c in cols))
    # per-arm summary
    print()
    for arm in sorted({r["arm"] for r in rows}):
        sub = [r for r in rows if r["arm"] == arm]
        p = sum(1 for r in sub if r["verdict"] == "PASS")
        stalls = sum(1 for r in sub if r["copy_done"] == "no")
        print(f"{arm:<14} PASS {p}/{len(sub)}   copy never finished: {stalls}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
