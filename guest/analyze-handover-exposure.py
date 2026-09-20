#!/usr/bin/env python3
"""Measure how exposed each run was to the hand-over interrupt race.

The race needs a transfer to complete while the interrupter still holds the
departing VMM's interrupt line, and before the new line is installed. The
dangerous window therefore starts when the source VM *stops executing*, and the
migration *request* is the wrong proxy for that instant: Cloud Hypervisor
pre-copies, and the harness records `migration.epoch` before it even launches
ch-remote, so the actual request is 0.9-4.6 ms later than that epoch.

Two anchors are computed and both are printed:

  * CH-clock anchor. Cloud Hypervisor logs device IRQ events with its own uptime
    ("Enabling IRQ", "Disabling IRQ") and usbvfiod logs the matching `set IRQs` /
    `ignoring IRQ disable` events with wall-clock timestamps, so the two clocks
    are tied together within the run from causally adjacent pairs. The pause is
    then read on CH's own clock. Because CH logs `Enabling IRQ` just before it
    sends the command, this anchor is marginally late and yields a lower bound.
  * harness-epoch anchor: `migration.epoch` plus CH's own request-to-pause delta.
    It is early by the same skew and yields an upper bound.
  * the raw harness epoch (recorded before ch-remote is launched) is printed as
    a strict upper bound.

Output columns (space separated, parsed by paper/update-results.py):
    run lower epoch upper events win_lower_ms win_epoch_ms win_req_ms anchor

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
STALE = re.compile(r"ignoring IRQ disable from stale")
CH_REL = re.compile(r"^\S+:\s+([\d.]+)s:")


def ch_events(run_dir: str) -> dict:
    """Relative (uptime) instants from the VMM log."""
    path = os.path.join(run_dir, "src.log")
    out: dict[str, float] = {}
    if not os.path.exists(path):
        return out
    for line in open(path, errors="replace"):
        m = CH_REL.match(line)
        if not m:
            continue
        t = float(m.group(1))
        if "API request event: VmSendMigration" in line:
            out["req"] = t
        elif "event = paused" in line:
            out["paused"] = t
        elif "Migration completed after" in line:
            out["completed"] = t
        elif "Enabling IRQ" in line:
            out.setdefault("enabling", t)
        elif "Disabling IRQ" in line:
            out["disabling"] = t
    return out


def parse(path: str) -> dict | None:
    run_dir = os.path.dirname(path)
    installs: list[datetime] = []
    sent: list[datetime] = []
    connects: list[datetime] = []
    setirqs: list[datetime] = []
    stale_wall: datetime | None = None
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
                setirqs.append(t)
            elif INSTALL.search(line):
                installs.append(t)
            elif SENT.search(line):
                sent.append(t)
            if STALE.search(line):
                stale_wall = t

    if len(connects) < 2 or len(installs) < 2:
        return None

    ch = ch_events(run_dir)
    epoch_file = os.path.join(run_dir, "migration.epoch")
    t_req_epoch = connects[1]
    if os.path.exists(epoch_file):
        txt = open(epoch_file).read().strip()
        if txt:
            try:
                t_req_epoch = datetime.fromtimestamp(float(txt), timezone.utc).replace(tzinfo=None)
            except (OSError, ValueError):
                pass

    # tie CH's uptime clock to wall clock using causally adjacent event pairs
    offsets = []
    if setirqs and "enabling" in ch:
        offsets.append((setirqs[0].replace(tzinfo=timezone.utc) - dt.timedelta(seconds=ch["enabling"])).timestamp())
    if stale_wall is not None and "disabling" in ch:
        offsets.append((stale_wall.replace(tzinfo=timezone.utc) - dt.timedelta(seconds=ch["disabling"])).timestamp())
    anchored = bool(offsets)
    if anchored:
        off = sum(offsets) / len(offsets)
        spread_ms = (max(offsets) - min(offsets)) * 1000.0 if len(offsets) > 1 else 0.0
    else:
        off = t_req_epoch.replace(tzinfo=timezone.utc).timestamp() - ch.get("req", 0.0)
        spread_ms = 0.0
    t_pause = datetime.fromtimestamp(off + ch.get("paused", ch.get("req", 0.0)), timezone.utc).replace(tzinfo=None)
    t_completed = (datetime.fromtimestamp(off + ch["completed"], timezone.utc).replace(tzinfo=None)
                   if "completed" in ch else None)

    # harness-epoch anchor (early -> upper bound)
    d_pause = ch.get("paused", ch.get("req", 0.0)) - ch.get("req", 0.0) if "req" in ch else 0.0
    t_pause_epoch = t_req_epoch + dt.timedelta(seconds=d_pause)

    t_install = installs[1]
    margin_s = None
    gpath = os.path.join(run_dir, "guest-demo.log")
    if t_completed is not None and os.path.exists(gpath):
        m = re.search(r"DEMO-COPY: COPY_DONE\s+([\d.]+)", open(gpath, errors="replace").read())
        if m:
            margin_s = float(m.group(1)) - t_completed.replace(tzinfo=timezone.utc).timestamp()

    return {
        "lower": sum(1 for t in sent if t_pause <= t < t_install),
        "epoch": sum(1 for t in sent if t_pause_epoch <= t < t_install),
        "upper": sum(1 for t in sent if t_req_epoch <= t < t_install),
        "events": len(sent),
        "win_lower_ms": (t_install - t_pause).total_seconds() * 1000.0,
        "win_epoch_ms": (t_install - t_pause_epoch).total_seconds() * 1000.0,
        "win_req_ms": (t_install - t_req_epoch).total_seconds() * 1000.0,
        "anchor": "CH-clock" if anchored else "harness-epoch",
        "spread_ms": spread_ms,
        "margin_s": margin_s,
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
    rows = [(os.path.basename(os.path.dirname(p)), parse(p)) for p in paths]

    print(f"{'run':<18}{'lower':>7}{'epoch':>7}{'upper':>7}{'events':>8}"
          f"{'win_lo':>9}{'win_ep':>9}{'win_up':>9}  anchor")
    for name, r in rows:
        if r is None:
            print(f"{name:<18}{'n/a':>7}{'n/a':>7}{'n/a':>7}{'n/a':>8}"
                  f"{'n/a':>9}{'n/a':>9}{'n/a':>9}  n/a")
            continue
        print(f"{name:<18}{r['lower']:>7}{r['epoch']:>7}{r['upper']:>7}{r['events']:>8}"
              f"{r['win_lower_ms']:>9.2f}{r['win_epoch_ms']:>9.2f}{r['win_req_ms']:>9.2f}  {r['anchor']}")

    m = [(n, r) for n, r in rows if r]
    if m:
        n_run = len(m)

        def cnt(key: str) -> tuple[int, int]:
            return (sum(1 for _, r in m if r[key] > 0), sum(r[key] for _, r in m))

        lo = cnt("lower")
        ep = cnt("epoch")
        up = cnt("upper")
        wins = [r["win_lower_ms"] for _, r in m]
        print()
        print(f"runs measured                       : {n_run}")
        print(f"CH-clock anchor (lower bound)       : {lo[0]} runs ({lo[0] / n_run:.0%}), {lo[1]} completions, window {min(wins):.2f}..{max(wins):.2f} ms")
        print(f"harness-epoch anchor (upper bound)  : {ep[0]} runs ({ep[0] / n_run:.0%}), {ep[1]} completions")
        print(f"raw harness epoch (strict upper)    : {up[0]} runs ({up[0] / n_run:.0%}), {up[1]} completions")
        margins = [r["margin_s"] for _, r in m if r.get("margin_s") is not None]
        if margins:
            print(f"min copy margin after switchover    : {min(margins):.2f} s")
        print(f"runs with a CH-clock anchor         : {sum(1 for _, r in m if r['anchor'] == 'CH-clock')}/{n_run}")
        print(f"max spread between the two CH-anchor pairs: "
              f"{max((r['spread_ms'] for _, r in m), default=0.0):.2f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
