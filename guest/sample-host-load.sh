#!/usr/bin/env bash
# Sample host load while a batch runs, so that run-to-run variation can be
# attributed. The host also runs four unrelated KVM VMs, and the paper has to
# disclose that; this gives the per-run context rather than a bare statement.
#
#   ./sample-host-load.sh <output-file> [interval-seconds]
set -u
OUT="${1:-<repo>/artifacts/host-load.log}"
INT="${2:-5}"
mkdir -p "$(dirname "$OUT")"
echo "# epoch load1 load5 load15 running/total vms_running usbvfiod_procs ch_procs" > "$OUT"
while true; do
  read -r l1 l5 l15 rest < /proc/loadavg
  run=$(echo "$rest" | awk '{print $1}')
  vms=$(qm list 2>/dev/null | awk '$3=="running"' | wc -l)
  uv=$(pgrep -xc usbvfiod 2>/dev/null); uv=${uv:-0}
  ch=$(pgrep -xc cloud-hypervisor 2>/dev/null); ch=${ch:-0}
  echo "$(date +%s) $l1 $l5 $l15 $run $vms $uv $ch" >> "$OUT"
  sleep "$INT"
done
