#!/usr/bin/env python3
"""Measure how exposed each run was to the hand-over interrupt race.

The race the paper fixes needs two things to coincide: a transfer has to
complete while the interrupter still holds the *departing* VMM's interrupt line,
and the new line has to be installed afterwards. The window is:

    [destination registers its line]  ... [the worker installs it and kicks]

Everything signalled in that window has its completion event in the guest ring
but its interrupt delivered to an event descriptor that belongs to a VMM which
is about to exit; the kick is what makes the guest look at the ring again.

The vfio-user server log records all three ingredients with microsecond
timestamps, so the exposure can be counted per run instead of inferred:

  * "set IRQs: ... #fds: 1"                 - a client installs its line
  * "interrupt line installed: re-raising"  - the worker has installed it
  * "Sent event: ..."                       - a completion was signalled

Usage: analyze-handover-exposure.py <usbvfiod.log> [...]
       (or a directory of runs: pass the run directory and it reads usbvfiod.log)
"""
from __future__ import annotations

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


def parse(path: str) -> tuple[int, int, float] | None:
    """Return (exposed_events, total_events, window_ms) for one run."""
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
    # the *second* registration/installation is the hand-over (the first is the
    # source registering at start-up)
    if len(connects) < 2 or len(installs) < 2:
        return None
    # The dangerous window starts when the destination VMM has connected - from
    # then on its hand-over is under way and the guest on the source side is
    # paused - and ends when the worker actually installs the new line. Every
    # completion signalled in between is written to the guest event ring but its
    # interrupt goes to the departing VMM's descriptor.
    # The window starts when the migration is requested: the source VMM pauses
    # immediately afterwards and never resumes, so any completion signalled from
    # then on has its interrupt delivered to a descriptor nobody will service.
    # migration.epoch (host wall clock) is recorded by the harness next to the
    # log; fall back to the destination's connect if it is missing.
    rundir = os.path.dirname(path)
    epoch_file = os.path.join(rundir, "migration.epoch")
    t_start = connects[1]
    if os.path.exists(epoch_file):
        try:
            txt = open(epoch_file).read().strip()
            if txt:
                e = float(txt)
                t_start = datetime.fromtimestamp(e, timezone.utc).replace(tzinfo=None)
        except (OSError, ValueError):
            pass
    t_install = installs[1]
    exposed = sum(1 for t in sent if t_start <= t < t_install)
    window_ms = (t_install - t_start).total_seconds() * 1000.0
    return exposed, len(sent), window_ms


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    paths: list[str] = []
    for a in args:
        if os.path.isdir(a):
            found = os.path.join(a, "usbvfiod.log")
            paths.append(found if os.path.exists(found) else "")
        else:
            paths.extend(sorted(glob.glob(a)))
    paths = [p for p in paths if p]

    exposed_runs = 0
    total_exposed = 0
    rows = []
    for p in paths:
        r = parse(p)
        if r is None:
            rows.append((os.path.basename(os.path.dirname(p)), None, None, None))
            continue
        exposed, total, window = r
        if exposed:
            exposed_runs += 1
            total_exposed += exposed
        rows.append((os.path.basename(os.path.dirname(p)), exposed, total, window))

    print(f"{'run':<18}{'exposed':>9}{'events':>9}{'window_ms':>11}")
    for name, exposed, total, window in rows:
        if exposed is None:
            print(f"{name:<18}{'n/a':>9}{'n/a':>9}{'n/a':>11}")
        else:
            print(f"{name:<18}{exposed:>9}{total:>9}{window:>11.2f}")

    measured = [r for r in rows if r[1] is not None]
    if measured:
        print()
        print(f"runs measured               : {len(measured)}")
        print(f"runs with exposure > 0      : {exposed_runs} "
              f"({exposed_runs / len(measured):.0%})")
        print(f"total exposed completions   : {total_exposed}")
        worst = max(r[1] for r in measured)
        print(f"worst-case exposed per run  : {worst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
