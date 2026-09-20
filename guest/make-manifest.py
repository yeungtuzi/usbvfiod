#!/usr/bin/env python3
"""Re-derive a batch's per-run metrics from the run directories themselves.

The earlier manifest read the harness's stdout, which is not part of a run
directory, so every metric column came out blank in the archive. This reads what
is actually stored next to the run: the guest's own log, the migration
bookkeeping files, the VMM logs and the server log.

Verdicts are produced by guest/verdict.py (the same code the paper's numbers come
from) rather than by a second, independent parser, so the archive cannot disagree
with the paper. Control runs have no migration and are judged on the digest
alone, exactly as acceptance-batch.sh does.

Usage: make-manifest.py <batch-dir>
"""
from __future__ import annotations

import glob
import os
import re
import subprocess
import sys

DIR = os.path.dirname(os.path.abspath(__file__))
VERDICT = os.path.join(DIR, "verdict.py")
EXPECTED = ""
_MD5_FILE = os.path.join(DIR, "testfile.md5")
if os.path.exists(_MD5_FILE):
    EXPECTED = open(_MD5_FILE).read().split()[0]

COPY_DONE = re.compile(r"DEMO-COPY: COPY_DONE ([\d.]+) rc=(-?\d+)")
COPY_START = re.compile(r"DEMO-COPY: COPY_START ([\d.]+)")
MD5LINE = re.compile(r"^([0-9a-f]{32})\s+(\S+)", re.M)
KICK = re.compile(r"re-raising one interrupt")
INSTALL = re.compile(r"interrupt line installed")
STALE = re.compile(r"ignoring IRQ disable from stale")
DOWN = re.compile(r"downtime of (\d+)ms")


def field(text: str, name: str) -> str:
    m = re.search(rf"^{re.escape(name)}\s*:\s*(.+?)\s*$", text, re.M)
    return m.group(1) if m else ""


def one(run_dir: str) -> dict:
    run = os.path.basename(run_dir.rstrip("/"))
    gpath = os.path.join(run_dir, "guest-demo.log")
    gtext = open(gpath, errors="replace").read() if os.path.exists(gpath) else ""

    def read(name: str) -> str:
        p = os.path.join(run_dir, name)
        return open(p, errors="replace").read().strip() if os.path.exists(p) else ""

    epoch = read("migration.epoch")
    done = read("migration.done")
    src = read("src.log")
    srv = read("usbvfiod.log")

    down = (DOWN.search(src) or [None, ""])[1] if DOWN.search(src) else ""

    start = COPY_START.search(gtext)
    copydone = COPY_DONE.search(gtext)
    copy_s = ""
    if start and copydone:
        copy_s = f"{float(copydone.group(1)) - float(start.group(1)):.1f}"

    digests = {p: h for h, p in MD5LINE.findall(gtext)}
    src_digest = next((h for p, h in digests.items() if "testfile.bin" in p), "")
    dst_digest = next((h for p, h in digests.items() if "testfile.copy" in p), "")

    if epoch and float(epoch) > 0:
        # Pass the downtime through unchanged (empty -> fail closed) and let
        # verdict.py take the completion instant from CH's own log, exactly as
        # the harness does. Passing "0" here made a run whose CH log had no
        # "downtime of Nms" line look like a perfect 0 ms run.
        budget = "12000" if run.startswith(("winlong", "window-loss")) else "2000"
        cmd = [sys.executable, VERDICT, "--guest-log", gpath,
               "--expected-md5", EXPECTED, "--migration-epoch", epoch,
               "--src-log", os.path.join(run_dir, "src.log"),
               "--downtime-ms", down, "--max-downtime-ms", budget]
        if done:
            cmd += ["--migration-done", done]
        out = subprocess.run(cmd, capture_output=True, text=True).stdout
        verdict = field(out, "VERDICT")
        spans = field(out, "spans migration")
        late_enum = field(out, "enumerations after migration")
        late_err = field(out, "reset/error lines after migr.")
        md5 = field(out, "md5 verdict")
        kind = "migrate"
    else:
        # control run: no migration, judged on the digest alone
        ok = bool(src_digest and dst_digest and src_digest == dst_digest)
        verdict = "PASS" if ok else "FAIL"
        spans, late_enum, late_err = "n/a", "n/a", "n/a"
        md5 = "MATCH" if ok else "MISMATCH"
        kind = "control"

    size = sum(os.path.getsize(f) for f in glob.glob(os.path.join(run_dir, "*"))
               if os.path.isfile(f))
    return {
        "run": run, "kind": kind, "verdict": verdict, "down_ms": down,
        "copy_s": copy_s, "spans": spans, "md5": md5, "late_enum": late_enum,
        "late_err": late_err, "installs": str(len(INSTALL.findall(srv))),
        "kicks": str(len(KICK.findall(srv))), "stale": str(len(STALE.findall(srv))),
        "rc": copydone.group(2) if copydone else "",
        "size_kb": str(size // 1024),
    }


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    dest = sys.argv[1]
    dirs = sorted(d for d in glob.glob(os.path.join(dest, "*/")) if os.path.isdir(d))
    rows = [one(d) for d in dirs]
    cols = ["run", "kind", "verdict", "down_ms", "copy_s", "spans", "md5",
            "late_enum", "late_err", "installs", "kicks", "stale", "rc", "size_kb"]
    with open(os.path.join(dest, "MANIFEST.md"), "w") as fh:
        fh.write("# Raw run artefacts\n\n")
        fh.write(f"{len(rows)} runs, copied verbatim from the harness. Every file is listed\n")
        fh.write("in `SHA256SUMS`. The metrics below are re-derived from the guest's own log,\n")
        fh.write("the migration bookkeeping and the VMM logs (verdicts via `guest/verdict.py`,\n")
        fh.write("the same code the paper uses), so they can be cross-checked against it.\n\n")
        fh.write("| " + " | ".join(cols) + " |\n")
        fh.write("|" + "---|" * len(cols) + "\n")
        for r in rows:
            fh.write("| " + " | ".join(r[c] for c in cols) + " |\n")
        npass = sum(1 for r in rows if r["verdict"] == "PASS")
        fh.write(f"\n**{npass}/{len(rows)} PASS**\n\n")
        fh.write("## Files per run\n\n| file | what it is |\n|---|---|\n")
        for f, desc in [
            ("guest-demo.log", "the guest's own log: copy markers, md5 of source and copy, heartbeats with the in-progress copy size, and a dmesg/lsusb dump taken after the copy"),
            ("console.log", "serial console capture through a FIFO (best effort; the destination resets the guest TTY)"),
            ("console.clean", "the same, with ANSI escapes stripped and CR turned into LF"),
            ("src.log", "source Cloud Hypervisor log (`-v`), incl. the `Migration completed ... downtime` line"),
            ("dst.log", "destination Cloud Hypervisor log (`-v`)"),
            ("usbvfiod.log", "vfio-user server log (`-v`): handshakes, DMA maps, IRQ registrations, stale-teardown decisions, injected-hook warnings"),
            ("usb.pcap", "USB packet capture at the server (Linux USB link type); ~130 MB per 128 MiB copy"),
            ("migration.epoch", "wall-clock epoch at which send-migration was issued"),
            ("migration.done", "wall-clock epoch at which send-migration returned; it is a few ms before CH logs the switchover as complete, so verdict.py prefers the completion instant it parses from src.log"),
            ("send.log / receive.log", "ch-remote output"),
            ("guest-copy.stat", "size of the copied file as seen in the guest"),
        ]:
            fh.write(f"| `{f}` | {desc} |\n")
        fh.write("\n## Reproducing a verdict\n\n```console\n")
        fh.write("$ guest/verdict.py --guest-log <run>/guest-demo.log \\\n")
        fh.write("    --expected-md5 \"$(cut -d' ' -f1 guest/testfile.md5)\" \\\n")
        fh.write("    --migration-epoch \"$(cat <run>/migration.epoch)\" \\\n")
        fh.write("    --src-log <run>/src.log \\\n")
        fh.write("    --downtime-ms \"$(grep -aoE 'downtime of [0-9]+ms' <run>/src.log | grep -aoE '[0-9]+')\" \\\n")
        fh.write("    --max-downtime-ms 2000\n```\n")
    print(f"wrote {os.path.join(dest, 'MANIFEST.md')}: "
          f"{sum(1 for r in rows if r['verdict'] == 'PASS')}/{len(rows)} PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
