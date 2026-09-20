#!/usr/bin/env python3
"""Measure how exposed each run was to the hand-over interrupt race.

The race needs two things to coincide: a transfer completes while the
interrupter still holds the *departing* VMM's interrupt line, and the new line is
installed afterwards. The dangerous window is therefore

    [the source VM stops executing]  ...  [the worker installs the new line]

and *not* from the moment the migration is requested. Cloud Hypervisor does a
pre-copy, so the guest keeps running for a few milliseconds after the request;
counting completions from the request overstates the exposure. The VMM log
records the ``Event: source = vm event = paused`` instant, and its uptime clock
can be tied to the harness's migration epoch through the ``VmSendMigration`` API
request line, so the window is anchored at the pause. Both bounds are printed:
the pause-anchored count is the measurement, the request-anchored count is a
strict upper bound.

  * "set IRQs: ... #fds: 1"                 - a client installs its line
  * "interrupt line installed"              - the worker has installed it
  * "Sent event: ..."                       - a completion was signalled
  * "event = paused" / "VmSendMigration"    - the source stopped / was requested

Usage: analyze-handover-exposure.py <usbvfiod.log|run-dir> [...]
"""
from __future__ import annotations

import datetime as dt
import glob
import os
import re
import sys
from datetime import datetime, timezone

ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
TS = re.compile(r"^\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)Z")
REG = re.compile(r"set IRQs:.*#fds: 1")
INSTALL = re.compile(r"interrupt line installed")
SENT = re.compile(r"Sent event:")
CONNECT = re.compile(r"Received client version")
CH_REL = re.compile(r"^\S+:\s+([\d.]+)s:")


def pause_offset_ms(run_dir: str) -> tuple[float, bool]:
    """Milliseconds between the migration request and the source being paused.

    Returns (offset_ms, measured). measured is False when the VMM log is missing
    or does not contain the event, in which case the offset is 0 and the window
    degenerates to the request-anchored (upper-bound) definition.
    """
    path = os.path.join(run_dir, "src.log")
    if not os.path.exists(path):
        return 0.0, False
    req = paused = None
    for line in open(path, errors="replace"):
        m = CH_REL.match(line)
        if not m:
            continue
        t = float(m.group(1))
        if "API request event: VmSendMigration" in line:
            req = t
        elif "event = paused" in line:
            paused = t
    if req is None or paused is None:
        return 0.0, False
    return (paused - req) * 1000.0, True


def parse(path: str) -> dict | None:
    run_dir = os.path.dirname(path)
    regs: list[datetime] = []
    installs: list[datetime] = []
    sent: list[datetime] = []
    connects: list[datetime] = []
    with open(path, "r", errors="replace") as fh:
        for raw in fh:
            line = ANSI.sub("", raw)
            m = TS.match(line)
            if not m:
                continue
            try:
                t = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S.%f")
            except ValueError:
                continue
            if CONNECT.search(line):
                connects.append(t)
            if REG.search(line):
                regs.append(t)
            elif INSTALL.search(line):
                installs.append(t)
            elif SENT.search(line):
                sent.append(t)

    if len(connects) < 2 or len(installs) < 2:
        return None

    epoch_file = os.path.join(run_dir, "migration.epoch")
    t_req = connects[1]
    if os.path.exists(epoch_file):
        txt = open(epoch_file).read().strip()
        if txt:
            try:
                t_req = datetime.fromtimestamp(float(txt), timezone.utc).replace(tzinfo=None)
            except (OSError, ValueError):
                pass

    offset_ms, measured = pause_offset_ms(run_dir)
    t_pause = t_req + dt.timedelta(milliseconds=offset_ms)
    t_install = installs[1]

    return {
        "exposed": sum(1 for t in sent if t_pause <= t < t_install),
        "exposed_req": sum(1 for t in sent if t_req <= t < t_install),
        "total": len(sent),
        "window_ms": (t_install - t_pause).total_seconds() * 1000.0,
        "window_req_ms": (t_install - t_req).total_seconds() * 1000.0,
        "pause_ms": offset_ms,
        "pause_measured": measured,
    }


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    paths: list[str] = []
    for a in args:
        if os.path.isdir(a) and not a.endswith(".log"):
            found = os.path.join(a, "usbvfiod.log")
            paths.append(found if os.path.exists(found) else "")
        else:
            paths.extend(sorted(glob.glob(a)))
    paths = [p for p in paths if p and os.path.isfile(p)]

    rows = []
    for p in paths:
        rows.append((os.path.basename(os.path.dirname(p)), parse(p)))

    print(f"{'run':<18}{'exposed':>9}{'events':>9}{'window_ms':>11}"
          f"{'pause_ms':>10}{'upper':>7}{'upper_win':>11}")
    for name, r in rows:
        if r is None:
            print(f"{name:<18}{'n/a':>9}{'n/a':>9}{'n/a':>11}{'n/a':>10}{'n/a':>7}{'n/a':>11}")
            continue
        tail = "" if r["pause_measured"] else "   (pause instant unavailable; >req)"
        print(f"{name:<18}{r['exposed']:>9}{r['total']:>9}{r['window_ms']:>11.2f}"
              f"{r['pause_ms']:>10.2f}{r['exposed_req']:>7}{r['window_req_ms']:>11.2f}{tail}")

    measured = [(n, r) for n, r in rows if r]
    if measured:
        n_run = len(measured)
        expos = sum(1 for _, r in measured if r["exposed"] > 0)
        expos_req = sum(1 for _, r in measured if r["exposed_req"] > 0)
        tot = sum(r["exposed"] for _, r in measured)
        tot_req = sum(r["exposed_req"] for _, r in measured)
        windows = [r["window_ms"] for _, r in measured]
        print()
        print(f"runs measured                     : {n_run}")
        print(f"runs with exposure > 0 (pause)    : {expos} ({expos / n_run:.0%})")
        print(f"completions at risk (pause)       : {tot}")
        print(f"worst case per run (pause)        : {max(r['exposed'] for _, r in measured)}")
        print(f"window ms (pause)                 : {min(windows):.2f} .. {max(windows):.2f}")
        print("-- strict upper bounds (window anchored at the migration request) --")
        print(f"runs with exposure > 0 (request)  : {expos_req} ({expos_req / n_run:.0%})")
        print(f"completions at risk (request)     : {tot_req}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
