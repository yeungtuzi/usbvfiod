#!/usr/bin/env bash
# Controlled A/B for the hand-over interrupt fix.
#
# Arm "on"  : default behaviour (the interrupter re-raises one interrupt when it
#             installs a new line).
# Arm "off" : USBVFIOD_DISABLE_IRQ_KICK=1, a debug-only test hook that suppresses
#             exactly that kick. Everything else is identical, so any difference
#             in outcome is attributable to the kick.
#
#   ./irq-kick-ab.sh [N]        # N runs per arm (default 8)
#
# This is the negative control the methodology review asked for: it shows the
# defect can be reproduced on demand rather than only by waiting for a
# naturally occurring race.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
N="${1:-8}"
ROOT="${ROOT:-/run/usb-ab}"
mkdir -p "$ROOT"

for arm in on off; do
  echo "############ ARM: kick $arm ############"
  for i in $(seq 1 "$N"); do
    pkill -x cloud-hypervisor 2>/dev/null; pkill -x usbvfiod 2>/dev/null; sleep 1
    shopt -s nullglob
    for f in /media/root/*/; do umount "$f" 2>/dev/null; done
    out="$ROOT/$arm-$i.log"
    (
      export RUN="$ROOT/$arm-$i"
      if [ "$arm" = off ]; then export USBVFIOD_DISABLE_IRQ_KICK=1; fi
      timeout 400 ./usb-migration-demo.sh
    ) > "$out" 2>&1
    rc=$?
    v=$(grep -aE '^VERDICT' "$out" | awk '{print $3}')
    dt=$(grep -aoE 'downtime of [0-9]+ms' "$out" | head -1)
    le=$(grep -aE '^enumerations after migration' "$out" | awk '{print $5}')
    echo "  kick=$arm run $i: rc=$rc verdict=${v:-?} $dt late_enum=${le:-?}"
  done
done

echo
echo "=== summary ==="
python3 "$DIR/summarize-batch.py" "$ROOT" 'on-*.log' 2>/dev/null | sed 's/^/[kick on ] /'
python3 "$DIR/summarize-batch.py" "$ROOT" 'off-*.log' 2>/dev/null | sed 's/^/[kick off] /'
