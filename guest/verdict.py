#!/usr/bin/env python3
"""Compute the USB live-migration demo verdict from the guest's own log.

Everything is derived from evidence the guest produced, so the result does not
depend on the serial console. That matters because a migration re-creates the
destination's serial device, which resets the guest TTY: console output can be
lost exactly around the event under test.

Criteria (all must hold):

1. the copy window strictly contains the migration instant;
2. the md5 of the copied file equals the expected digest, and so does the digest
   the guest computed for the source file on the stick;
3. no USB enumeration after the guest uptime at which the migration happened;
4. no disconnect / reset / timeout / I/O error after that uptime;
5. the downtime reported by the VMM is within the acceptance budget.

The guest uptime at the migration is interpolated from the heartbeat lines,
which carry both the wall-clock epoch and /proc/uptime. The comparison of guest
copy timestamps against the host epoch assumes the two clocks agree; the
heartbeat pairs let that offset be checked, and it is smaller than the 1 s
resolution of the guest timestamps in every run we took.

Heartbeats and the guest dmesg section are MANDATORY. Without them the cutoff
cannot be established and "nothing happened after the migration" would be
vacuously true, so the verdict fails closed instead of reporting a pass.

Usage:
  verdict.py --guest-log LOG --expected-md5 MD5 --migration-epoch EPOCH
             --downtime-ms N --max-downtime-ms N

Exit status: 0 if every criterion passes, 1 otherwise.
"""
from __future__ import annotations

import argparse
import re
import sys

# Kernel messages that mean the guest noticed the device. Both the classic
# "-speed" forms and the SuperSpeed forms must be covered, otherwise a
# re-enumeration at a different link speed would be missed.
ENUM = re.compile(
    r"new (?:low|full|high)-speed USB device"
    r"|new SuperSpeed(?: Plus)? USB device"
)
BAD = [
    ("disconnect", re.compile(r"USB disconnect")),
    ("reset", re.compile(r"usb \S+: reset")),
    ("descriptor-read-error", re.compile(r"device descriptor read")),
    ("address-error", re.compile(r"device not accepting address")),
    ("controller-not-responding", re.compile(r"xhci_hcd.*not responding")),
    ("usb-storage-error", re.compile(r"usb-storage.*error")),
    ("io-error", re.compile(r"I/O error")),
    ("blk-error", re.compile(r"blk_update_request")),
]
KTS = re.compile(r"^\[\s*([0-9]+\.[0-9]+)\]")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--guest-log", required=True)
    ap.add_argument("--expected-md5", required=True)
    ap.add_argument("--migration-epoch", required=True, type=float)
    ap.add_argument("--downtime-ms", type=float, default=None,
                    help="downtime reported by the VMM for this run")
    ap.add_argument("--max-downtime-ms", type=float, default=None,
                    help="acceptance budget; enforced when given")
    args = ap.parse_args()

    try:
        text = open(args.guest_log, "r", errors="replace").read()
    except OSError as exc:
        print(f"guest log            : UNREADABLE ({exc})")
        print("VERDICT              : FAIL")
        return 1

    failures: list[str] = []

    # --- 1. copy window ------------------------------------------------------
    starts = re.findall(r"DEMO-COPY: COPY_START ([0-9.]+)", text)
    dones = re.findall(r"DEMO-COPY: COPY_DONE ([0-9.]+) rc=(\d+)", text)
    start = float(starts[-1]) if starts else None
    done, rc = (float(dones[-1][0]), int(dones[-1][1])) if dones else (None, None)
    finished = "DEMO-COPY: MD5_DONE" in text

    print(f"COPY_START           : {start if start is not None else '<missing>'}")
    print(f"COPY_DONE            : {done if done is not None else '<missing>'} (rc={rc})")
    print(f"MD5_DONE marker      : {'present' if finished else 'MISSING'}")

    spans = start is not None and done is not None and start < args.migration_epoch < done
    if start is not None and done is not None:
        print(f"copy duration        : {done - start:.1f} s")
    print(f"migration epoch      : {args.migration_epoch:.3f} (host clock)")
    print(f"spans migration      : {'YES' if spans else 'NO'}")
    if not spans:
        failures.append("copy-window-does-not-span-migration")
    if not finished:
        failures.append("missing-md5-done-marker")
    if rc not in (0, None):
        failures.append(f"copy-exit-status-{rc}")

    # --- 2. md5 --------------------------------------------------------------
    src = re.findall(r"^([0-9a-f]{32})  /mnt/usb/testfile\.bin", text, re.M)
    copy = re.findall(r"^([0-9a-f]{32})  /root/testfile\.copy", text, re.M)
    expected = args.expected_md5.strip().lower()
    print(f"expected             : {expected}")
    print(f"read back from stick : {src[-1] if src else '<missing>'}")
    print(f"copied file          : {copy[-1] if copy else '<missing>'}")
    md5_ok = bool(copy) and copy[-1] == expected and bool(src) and src[-1] == expected
    print(f"md5 verdict          : {'MATCH' if md5_ok else 'MISMATCH / missing'}")
    if not md5_ok:
        failures.append("md5-mismatch-or-missing")

    # --- 3/4. cutoff from the heartbeat pairs --------------------------------
    beats = [(float(e), float(u)) for _, e, u in
             re.findall(r"DEMO-HEARTBEAT (\d+) ([0-9.]+) uptime=([0-9.]+)", text)]
    mig_uptime = None
    if beats:
        beats.sort()
        for (e0, u0), (e1, u1) in zip(beats, beats[1:]):
            if e0 <= args.migration_epoch <= e1 and e1 > e0:
                mig_uptime = u0 + (args.migration_epoch - e0) * (u1 - u0) / (e1 - e0)
                break
        if mig_uptime is None:
            e0, u0 = beats[0] if args.migration_epoch < beats[0][0] else beats[-1]
            mig_uptime = u0 + (args.migration_epoch - e0)
    print(f"heartbeats           : {len(beats)}")
    if mig_uptime is None:
        print("guest uptime @migr.  : <unavailable>")
        failures.append("no-heartbeats-cutoff-unavailable")
    else:
        print(f"guest uptime @migr.  : {mig_uptime:.2f} s")

    dmesg = []
    in_dmesg = False
    for line in text.splitlines():
        if line.startswith("DEMO-COPY: DMESG_BEGIN"):
            in_dmesg = True
            continue
        if line.startswith("DEMO-COPY: DMESG_END"):
            in_dmesg = False
            continue
        if in_dmesg:
            dmesg.append(line)

    if not dmesg:
        print("guest dmesg section  : MISSING")
        failures.append("no-guest-dmesg-section")
    elif mig_uptime is None:
        print("guest dmesg section  : present, but no cutoff to apply")
    else:
        late_enum = 0
        late_bad = 0
        seen_enum: list[str] = []
        seen_bad: list[str] = []
        for line in dmesg:
            m = KTS.match(line)
            if not m:
                continue
            ts = float(m.group(1))
            if ts <= mig_uptime:
                continue
            if ENUM.search(line):
                late_enum += 1
                seen_enum.append(f"[{ts:.3f}] {line.split(']', 1)[-1].strip()[:70]}")
            for name, pat in BAD:
                if pat.search(line):
                    late_bad += 1
                    seen_bad.append(f"[{ts:.3f}] ({name}) {line.split(']', 1)[-1].strip()[:60]}")
                    break
        print(f"enumerations after migration : {late_enum}")
        for line in seen_enum[:3]:
            print(f"    {line}")
        print(f"reset/error lines after migr.: {late_bad}")
        for line in seen_bad[:5]:
            print(f"    {line}")
        if late_enum:
            failures.append(f"{late_enum}-enumerations-after-migration")
        if late_bad:
            failures.append(f"{late_bad}-reset-or-io-errors-after-migration")

    # --- 5. downtime budget --------------------------------------------------
    dt = args.downtime_ms
    print(f"downtime             : {dt if dt is not None else '<unknown>'} ms"
          + (f" (budget {args.max_downtime_ms:.0f} ms)" if args.max_downtime_ms else ""))
    if args.max_downtime_ms is not None and (dt is None or dt > args.max_downtime_ms):
        failures.append("downtime-over-budget-or-unknown")

    if failures:
        print(f"failed criteria      : {', '.join(failures)}")
    print(f"VERDICT              : {'PASS' if not failures else 'FAIL'}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
