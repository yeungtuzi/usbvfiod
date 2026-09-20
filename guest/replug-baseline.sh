#!/usr/bin/env bash
# Baseline for comparison: what the guest sees when the device is detached and
# re-attached with the hotplug interface, i.e. the "naive" alternative to
# preserving the host-side session across a migration.
#
#   ./replug-baseline.sh
#
# The workload is the same 128 MiB copy as the migration demo; instead of
# migrating, the device is detached and re-attached while the copy runs. The
# guest's own log then shows the cost of that approach: re-enumeration and I/O
# errors, and a copy that does not complete.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
CH="${CH:-/root/lvllm/cloud-hypervisor/target/release/cloud-hypervisor}"
CHR="${CHR:-$(dirname "$CH")/ch-remote}"
USBVF="${USBVF:-$REPO/target/debug/usbvfiod}"
REMOTE="${REMOTE:-$REPO/target/debug/remote}"
DEVICE="${DEVICE:-/dev/bus/usb/001/007}"
RUN="${RUN:-/run/usb-replug}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
COPY_TIMEOUT="${COPY_TIMEOUT:-120}"

pids=()
stop_all() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; sleep 2; }
trap stop_all EXIT

rm -rf "$RUN"; mkdir -p "$RUN"
mkfifo "$RUN/console.fifo"
python3 "$DIR/fifo-capture.py" "$RUN/console.fifo" "$RUN/console.log" &
pids+=($!)
sleep 0.5
log() { printf '[replug] %s\n' "$*"; }

wait_for() {
  local pat="$1" file="$2" tmo="$3" i=0
  while [ "$i" -lt "$tmo" ]; do grep -q "$pat" "$file" 2>/dev/null && return 0; sleep 1; i=$((i+1)); done
  return 1
}

"$USBVF" --socket-path "$RUN/usbvfiod.sock" \
  --hotplug-socket-path "$RUN/hotplug.sock" \
  --device "$DEVICE" --max-clients 4 -v > "$RUN/usbvfiod.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 40); do [ -S "$RUN/usbvfiod.sock" ] && [ -S "$RUN/hotplug.sock" ] && break; sleep 0.25; done
log "usbvfiod up (device attached at startup)"

"$CH" -v --api-socket "$RUN/ch.sock" \
  --memory size=2G,shared=on --cpus boot=1 \
  --kernel "$DIR/casper/vmlinuz" --initramfs "$DIR/initrd-custom.gz" \
  --disk "path=$DIR/rootfs.img,image_type=raw" \
  --user-device "socket=$RUN/usbvfiod.sock" \
  --serial "file=$RUN/console.fifo" --console off \
  --cmdline "root=/dev/vda rw console=ttyS0" > "$RUN/ch.log" 2>&1 &
# $! must be captured here: $CH_PID was never assigned, and under `set -u` the
# script aborted on the next line before the guest had even booted.
pids+=($!)
for _ in $(seq 1 60); do "$CHR" --api-socket "$RUN/ch.sock" ping >/dev/null 2>&1 && break; sleep 1; done
log "guest booted; waiting for the copy to start"
wait_for "DEMO-COPY: COPY_START" "$RUN/console.log" "$BOOT_TIMEOUT" || { log "copy never started"; exit 1; }
sleep 4

log "detaching the device (naive alternative to a migration)"
"$REMOTE" --socket "$RUN/hotplug.sock" --detach 1 7 > "$RUN/detach.log" 2>&1 || log "detach returned non-zero"
sleep 5
log "re-attaching the device"
"$REMOTE" --socket "$RUN/hotplug.sock" --attach "$DEVICE" > "$RUN/attach.log" 2>&1 || log "attach returned non-zero"

wait_for "DEMO-COPY: MD5_DONE" "$RUN/console.log" "$COPY_TIMEOUT" || log "note: copy did not report completion"

stop_all
MNT="$RUN/guestfs"; mkdir -p "$MNT"
mount -o loop "$DIR/rootfs.img" "$MNT" 2>/dev/null && {
  cp "$MNT/root/demo.log" "$RUN/guest-demo.log" 2>/dev/null || true
  umount "$MNT"
}

echo
echo "================ REPLUG BASELINE RESULT ================"
GLOG="$RUN/guest-demo.log"
if [ -s "$GLOG" ]; then
  grep -aoE 'DEMO-COPY: (COPY_START|COPY_DONE|MD5_DONE) [0-9.]*( rc=[0-9]+)?' "$GLOG" | tail -3
  echo "--- guest kernel events (from the guest's own dmesg) ---"
  awk '/DMESG_BEGIN/{f=1;next} /DMESG_END/{f=0} f' "$GLOG" \
    | grep -aiE 'new (high|full)-speed USB device|usb [0-9-]+: reset|device descriptor read|I/O error|blk_update_request|usb-storage' \
    | head -12
  echo "--- md5 ---"
  grep -aoE '^[0-9a-f]{32}  /root/testfile.copy' "$GLOG" | tail -1
  echo "expected: $(awk '{print $1}' "$DIR/testfile.md5")"
else
  echo "guest log not available"
fi
echo "======================================================="
echo "artifacts: $RUN"
