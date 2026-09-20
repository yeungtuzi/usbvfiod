#!/usr/bin/env python3
"""Summarise the naive detach/re-attach baseline the same way the migration runs
are judged: from the guest's own log, with the events counted relative to the
guest's uptime at the moment the device was disturbed.

replug-baseline.sh starts the identical 128 MiB copy, then detaches the device
four seconds after COPY_START and re-attaches it five seconds later. The guest
log therefore contains the same heartbeats, the same copy markers and the same
dmesg dump as an acceptance run, so the same criteria apply:

  * enumerations, resets and I/O errors are counted only after the detach moment,
    which is derived from COPY_START plus REPLUG_LEAD seconds and interpolated
    through the heartbeat (epoch, uptime) pairs;
  * a missing heartbeat, dmesg or copy marker is a failure, not a pass.

Usage: summarize-replug.py <run-dir> [<run-dir> ...]
       summarize-replug.py /run/usb-replug          # all numeric subdirs
"""
from __future__ import annotations

import os
import re
import sys

LEAD = float(os.environ.get("REPLUG_LEAD", "4"))  # must match replug-baseline.sh

HEARTBEAT = re.compile(r"DEMO-HEARTBEAT\s+\d+\s+(\d+)\s+uptime=([\d.]+)")
COPY_START = re.compile(r"DEMO-COPY: COPY_START\s+([\d.]+)")
COPY_DONE = re.compile(r"DEMO-COPY: COPY_DONE\s+([\d.]+)\s+rc=(-?\d+)")
MD5 = re.compile(r"^([0-9a-f]{32})\s+(\S+)", re.M)
KTIME = re.compile(r"^\[\s*(\d+\.\d+)\]")

ENUM = re.compile(r"new (?:high|full|SuperSpeed|low)-speed USB device", re.I)
RESET = re.compile(r"usb [0-9.:-]+: reset|device descriptor read|device not accepting address", re.I)
IOERR = re.compile(r"I/O error|blk_update_request|usb-storage.*(error|fail)", re.I)


def read_run(run: str) -> dict | None:
    path = os.path.join(run, "guest-demo.log")
    if not os.path.exists(path):
        return None
    text = open(path, errors="replace").read()
    hb = [(float(e), float(u)) for e, u in HEARTBEAT.findall(text)]
    start = COPY_START.search(text)
    if not hb or not start:
        return {"run": run, "complete": False, "reason": "no heartbeat or COPY_START"}
    t0 = float(start.group(1))
    t_detach = t0 + LEAD
    # interpolate the guest uptime at the detach moment
    hb.sort(key=lambda p: p[0])
    up = None
    for i in range(len(hb) - 1):
        e0, u0 = hb[i]
        e1, u1 = hb[i + 1]
        if e0 <= t_detach <= e1 and e1 > e0:
            up = u0 + (u1 - u0) * (t_detach - e0) / (e1 - e0)
            break
    if up is None:
        if t_detach <= hb[0][0]:
            up = hb[0][1]
        elif t_detach >= hb[-1][0]:
            up = hb[-1][1]
    if up is None:
        return {"run": run, "complete": False, "reason": "detach moment outside the heartbeats"}

    dmesg = ""
    m = re.search(r"DEMO-COPY: DMESG_BEGIN(.*?)DEMO-COPY: DMESG_END", text, re.S)
    if m:
        dmesg = m.group(1)
        source = "guest-log"
    else:
        # The guest only dumps dmesg once dd has returned. If the detach makes
        # the copy hang forever the dump never happens, so fall back to the
        # serial console, which carries the same kernel messages because the
        # kernel was booted with console=ttyS0.
        source = ""
        for name in ("console.clean", "console.log"):
            cpath = os.path.join(run, name)
            if os.path.exists(cpath):
                dmesg = open(cpath, errors="replace").read()
                source = name
                break
        if not source:
            return {"run": run, "complete": False, "reason": "no dmesg and no console log"}

    after = 0
    enum = reset = ioerr = 0
    for line in dmesg.splitlines():
        km = KTIME.match(line)
        if not km or float(km.group(1)) < up:
            continue
        after += 1
        if ENUM.search(line):
            enum += 1
        if RESET.search(line):
            reset += 1
        if IOERR.search(line):
            ioerr += 1

    done = COPY_DONE.search(text)
    digests = {p: h for h, p in MD5.findall(text)}
    src = next((h for p, h in digests.items() if "testfile.bin" in p), None)
    dst = next((h for p, h in digests.items() if "testfile.copy" in p), None)
    return {
        "run": os.path.basename(run.rstrip("/")),
        "complete": True,
        "copy_done": bool(done),
        "rc": done.group(2) if done else "",
        "md5_match": bool(src and dst and src == dst),
        "uptime_at_detach": round(up, 2),
        "source": source,
        "reenum": enum,
        "resets": reset,
        "io_errors": ioerr,
        "dmesg_lines_after": after,
    }


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    dirs: list[str] = []
    for a in args:
        if os.path.isdir(a) and not os.path.exists(os.path.join(a, "guest-demo.log")):
            dirs += [os.path.join(a, d) for d in sorted(os.listdir(a)) if d.isdigit()]
        else:
            dirs.append(a)
    cols = ["run", "complete", "copy_done", "rc", "md5_match",
            "uptime_at_detach", "source", "reenum", "resets", "io_errors",
            "dmesg_lines_after"]
    print(",".join(cols))
    rows = []
    for d in dirs:
        r = read_run(d)
        if r is None:
            print(f"{os.path.basename(d)},no-guest-log")
            continue
        rows.append(r)
        print(",".join(str(r.get(c, "")) for c in cols))
    return 0


if __name__ == "__main__":
    sys.exit(main())
