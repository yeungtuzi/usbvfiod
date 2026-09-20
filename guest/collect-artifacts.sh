#!/usr/bin/env bash
# Archive a batch's raw run artefacts, with a manifest and per-file checksums.
#
#   ./collect-artifacts.sh <source-dir> <archive-name>
#
# Every run directory produced by usb-migration-demo.sh is copied verbatim:
# the guest's own log, the serial console capture, both VMM logs, the vfio-user
# server log with per-transfer tracing, the USB packet capture and the migration
# bookkeeping. Nothing is filtered, so a reviewer can re-derive every number in
# the paper from these files.
set -uo pipefail

SRC="${1:?usage: collect-artifacts.sh <source-dir> <archive-name>}"
NAME="${2:?usage: collect-artifacts.sh <source-dir> <archive-name>}"
DEST="${DEST:-/root/lvllm/usbvfiod/artifacts}/$NAME"

mkdir -p "$DEST"
echo "collecting $SRC -> $DEST"

n=0
for d in "$SRC"/*/; do
  [ -d "$d" ] || continue
  run="$(basename "$d")"
  mkdir -p "$DEST/$run"
  # copy everything except the FIFO and the (empty) lock files
  find "$d" -maxdepth 1 -type f \
       ! -name '*.fifo' ! -name '*.sock' ! -name '*.lock' \
       -exec cp -f {} "$DEST/$run/" \; 2>/dev/null
  n=$((n+1))
done
echo "copied $n run directories"

# per-file checksums of the text evidence (pcaps are checksummed too, but the
# manifest keeps the sizes so a reader can see what is large)
(
  cd "$DEST" || exit 1
  find . -type f ! -name 'SHA256SUMS' ! -name 'MANIFEST.md' -print0 \
    | sort -z | xargs -0 sha256sum > SHA256SUMS 2>/dev/null
)
echo "wrote SHA256SUMS ($(wc -l < "$DEST/SHA256SUMS") files)"

# manifest: metrics from verdict.py plus the artefact inventory
python3 - "$DEST" <<'PY'
import os, re, sys, glob, hashlib
dest = sys.argv[1]
rows = []
for d in sorted(glob.glob(os.path.join(dest, "*/"))):
    run = os.path.basename(d.rstrip("/"))
    g = os.path.join(d, "guest-demo.log")
    text = open(g, errors="replace").read() if os.path.exists(g) else ""
    c = os.path.join(d, "console.log")
    ctext = open(c, errors="replace").read() if os.path.exists(c) else ""
    def find(pat, t=text, g=1):
        m = re.search(pat, t, re.M)
        return m.group(g) if m else ""
    size = sum(os.path.getsize(f) for f in glob.glob(os.path.join(d, "*")) if os.path.isfile(f))
    rows.append({
        "run": run,
        "verdict": find(r"^VERDICT\s+:\s+(\w+)"),
        "down_ms": (re.search(r"downtime of (\d+)ms", ctext) or [None, ""])[1] if re.search(r"downtime of (\d+)ms", ctext) else "",
        "copy_s": find(r"^copy duration\s+:\s+([\d.]+)"),
        "spans": find(r"^spans migration\s+:\s+(\w+)"),
        "md5": find(r"^md5 verdict\s+:\s+(\S+)"),
        "late_enum": find(r"^enumerations after migration\s+:\s+(-?\d+)"),
        "late_err": find(r"^reset/error lines after migr\.\s*:\s+(-?\d+)"),
        "kicks": find(r"^interrupt lines installed\s+:\s+(\d+)"),
        "stale": find(r"^stale teardowns ignored\s+:\s+(\d+)"),
        "size_kb": f"{size//1024}",
    })

with open(os.path.join(dest, "MANIFEST.md"), "w") as fh:
    fh.write("# Raw run artefacts\n\n")
    fh.write(f"{len(rows)} runs, copied verbatim from the harness. Every file is listed in\n")
    fh.write("`SHA256SUMS`; the metrics below are re-derived here from the guest log and\n")
    fh.write("the CH log so they can be cross-checked against the paper.\n\n")
    cols = ["run", "verdict", "down_ms", "copy_s", "spans", "md5", "late_enum",
            "late_err", "kicks", "stale", "size_kb"]
    fh.write("| " + " | ".join(cols) + " |\n")
    fh.write("|" + "---|" * len(cols) + "\n")
    for r in rows:
        fh.write("| " + " | ".join(str(r[c]) for c in cols) + " |\n")
    fh.write("\n## Files per run\n\n")
    fh.write("| file | what it is |\n|---|---|\n")
    for f, desc in [
        ("guest-demo.log", "the guest's own log: copy markers, md5 of source and copy, heartbeats, and a dmesg/lsusb dump taken after the copy"),
        ("console.log", "serial console capture through a FIFO (best effort; the destination resets the guest TTY)"),
        ("console.clean", "the same, with ANSI escapes stripped and CR turned into LF"),
        ("src.log", "source Cloud Hypervisor log (`-v`), incl. the `Migration completed ... downtime` line"),
        ("dst.log", "destination Cloud Hypervisor log (`-v`)"),
        ("usbvfiod.log", "vfio-user server log (`-v`): handshakes, DMA maps, IRQ registrations, stale-teardown decisions"),
        ("usb.pcap", "USB packet capture at the server (Linux USB link type); ~130 MB per 128 MiB copy"),
        ("migration.epoch", "wall-clock epoch at which send-migration was issued"),
        ("send.log / receive.log", "ch-remote output"),
        ("guest-copy.stat", "size of the copied file as seen in the guest"),
    ]:
        fh.write(f"| `{f}` | {desc} |\n")
    fh.write("\n## Reproducing the verdict\n\n")
    fh.write("```console\n$ guest/verdict.py --guest-log <run>/guest-demo.log \\\n")
    fh.write("      --expected-md5 $(cat guest/testfile.md5 | cut -d' ' -f1) --migration-epoch <run>/migration.epoch\n```\n")
print("wrote MANIFEST.md")
PY
du -sh "$DEST"
