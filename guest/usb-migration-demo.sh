#!/usr/bin/env bash
# End-to-end demo: a USB stick passed through to a Linux guest keeps working
# across a same-host Cloud Hypervisor live migration while the guest is copying
# a large file from that stick.
#
#   ./usb-migration-demo.sh
#
# Prerequisites:
#   - rootfs.img / initrd-custom.gz / casper/vmlinuz built by build-guest.sh
#   - a USB stick with a `testfile.bin` (its md5 goes into guest/testfile.md5)
#   - DEVICE pointing at its /dev/bus/usb/BBB/DDD node
#
# The live view comes from the guest console (captured through a FIFO so the
# destination VMM cannot truncate the pre-migration output). The migration
# nevertheless re-creates the destination's serial device, which resets the
# guest tty, so the *authoritative* result is read from the guest's own
# /root/demo.log after stopping the VMs and mounting the disk image.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
CH="${CH:-/root/lvllm/cloud-hypervisor/target/release/cloud-hypervisor}"
CHR="${CHR:-$(dirname "$CH")/ch-remote}"
USBVF="${USBVF:-$REPO/target/debug/usbvfiod}"
DEVICE="${DEVICE:-/dev/bus/usb/001/007}"
RUN="${RUN:-/run/usb-demo}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
COPY_TIMEOUT="${COPY_TIMEOUT:-120}"
COPY_LEAD_SECONDS="${COPY_LEAD_SECONDS:-4}"

pids=()
stop_vms() {
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done
  sleep 2
}
cleanup() { stop_vms; }
trap cleanup EXIT

rm -rf "$RUN"; mkdir -p "$RUN"
mkfifo "$RUN/console.fifo"
python3 "$DIR/fifo-capture.py" "$RUN/console.fifo" "$RUN/console.log" &
pids+=($!)
sleep 0.5

log() { printf '[demo] %s\n' "$*"; }

wait_for() { # wait_for <pattern> <file> <timeout-seconds>
  local pat="$1" file="$2" tmo="$3" i=0
  while [ "$i" -lt "$tmo" ]; do
    grep -q "$pat" "$file" 2>/dev/null && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

wait_api() { # wait_api <socket> <name>
  local sock="$1" name="$2" i=0
  while [ "$i" -lt 60 ]; do
    "$CHR" --api-socket "$sock" ping >/dev/null 2>&1 && return 0
    sleep 1; i=$((i + 1))
  done
  log "ERROR: $name API never became ready"
  return 1
}

# --- 1. usbvfiod claims the physical stick -----------------------------------
"$USBVF" --socket-path "$RUN/usbvfiod.sock" --max-clients 4 \
  --device "$DEVICE" --pcap-path "$RUN/usb.pcap" -v > "$RUN/usbvfiod.log" 2>&1 &
USB_PID=$!; pids+=($USB_PID)
for _ in $(seq 1 40); do [ -S "$RUN/usbvfiod.sock" ] && break; sleep 0.25; done
if grep -q 'Attached' "$RUN/usbvfiod.log"; then
  log "usbvfiod attached $DEVICE"
else
  log "ERROR: usbvfiod did not attach $DEVICE"; tail -5 "$RUN/usbvfiod.log"; exit 1
fi

# --- 2. source VM: guest boots and starts copying from the stick -------------
"$CH" -v --api-socket "$RUN/src.sock" \
  --memory size=2G,shared=on --cpus boot=1 \
  --kernel "$DIR/casper/vmlinuz" --initramfs "$DIR/initrd-custom.gz" \
  --disk "path=$DIR/rootfs.img,image_type=raw" \
  --user-device "socket=$RUN/usbvfiod.sock" \
  --serial "file=$RUN/console.fifo" --console off \
  --cmdline "root=/dev/vda rw console=ttyS0" > "$RUN/src.log" 2>&1 &
SRC_PID=$!; pids+=($SRC_PID)
wait_api "$RUN/src.sock" source || exit 1
log "source VM booted; waiting for the guest to start copying"
wait_for "DEMO-COPY: COPY_START" "$RUN/console.log" "$BOOT_TIMEOUT" || {
  log "ERROR: the guest never started copying"; tail -40 "$RUN/console.log"; exit 1
}
log "copy is running; letting it get in flight for ${COPY_LEAD_SECONDS}s"
sleep "$COPY_LEAD_SECONDS"

# --- 3. destination VM + live migration -------------------------------------
"$CH" -v --api-socket "$RUN/dst.sock" > "$RUN/dst.log" 2>&1 &
DST_PID=$!; pids+=($DST_PID)
wait_api "$RUN/dst.sock" destination || exit 1
"$CHR" --api-socket "$RUN/dst.sock" receive-migration receiver_url=unix:"$RUN/mig.sock" \
  > "$RUN/receive.log" 2>&1 &
pids+=($!)
sleep 2

log "sending migration"
MIGRATION_EPOCH=$(date +%s.%N)
"$CHR" --api-socket "$RUN/src.sock" \
  send-migration destination_url=unix:"$RUN/mig.sock",memory_mode=memfds,downtime_ms=300,timeout_strategy=cancel \
  > "$RUN/send.log" 2>&1
log "send-migration exit=$?"
echo "$MIGRATION_EPOCH" > "$RUN/migration.epoch"

# --- 4. wait for the copy to report completion (console is best effort) -----
wait_for "DEMO-COPY: MD5_DONE" "$RUN/console.log" "$COPY_TIMEOUT" \
  || log "note: MD5_DONE not seen on the (best-effort) console; falling back to the guest log"

# --- 5. post-mortem: read the guest's own log from the disk image -----------
log "stopping VMs and reading the guest log from rootfs.img"
stop_vms
MNT="$RUN/guestfs"; mkdir -p "$MNT"
# Mount read-write: ext4 has to replay its journal after the VM was killed,
# otherwise the most recent guest writes (the md5 result) are invisible.
if mount -o loop "$DIR/rootfs.img" "$MNT" 2>/dev/null; then
  cp "$MNT/root/demo.log" "$RUN/guest-demo.log" 2>/dev/null || true
  ls -l "$MNT/root/testfile.copy" > "$RUN/guest-copy.stat" 2>/dev/null || true
  umount "$MNT"
else
  log "WARNING: could not mount rootfs.img"
fi

CLEAN="$RUN/console.clean"
sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r/\n/g' "$RUN/console.log" > "$CLEAN"

echo
echo "================ DEMO RESULT ================"
echo "source process alive : $(kill -0 "$SRC_PID" 2>/dev/null && echo yes || echo no) (expected: no)"
echo "destination state    : $(timeout 5 "$CHR" --api-socket "$RUN/dst.sock" info 2>/dev/null | grep -o '"state":"[A-Za-z]*"' | head -1 || echo '<already stopped>')"
echo "migration line       : $(grep -o 'Migration completed.*' "$RUN/src.log" | head -1)"
echo "migration epoch      : $MIGRATION_EPOCH"

GLOG="$RUN/guest-demo.log"
if [ -s "$GLOG" ]; then
  echo "--- guest log markers (authoritative) ---"
  grep -aE 'DEMO-COPY: (COPY_START|COPY_DONE|MD5_DONE|ERROR)' "$GLOG" || echo "(none)"
  START=$(grep -aoE 'COPY_START [0-9.]+' "$GLOG" | awk '{print $2}' | tail -1)
  DONE=$(grep -aoE 'COPY_DONE [0-9.]+' "$GLOG" | awk '{print $2}' | tail -1)
  echo "--- copy continuity ---"
  echo "COPY_START epoch     : ${START:-<missing>}"
  echo "COPY_DONE  epoch     : ${DONE:-<missing>}"
  if [ -n "$START" ] && [ -n "$DONE" ]; then
    awk -v s="$START" -v m="$MIGRATION_EPOCH" -v d="$DONE" 'BEGIN {
      printf "copy duration        : %.1f s\n", d - s;
      printf "spans migration      : %s (start before, end after)\n", (s < m && d > m) ? "YES" : "NO"
    }'
  fi
  echo "--- heartbeat around the migration ---"
  grep -a 'DEMO-HEARTBEAT' "$GLOG" | head -1
  grep -a 'DEMO-HEARTBEAT' "$GLOG" | tail -1
  echo "heartbeat lines      : $(grep -ac 'DEMO-HEARTBEAT' "$GLOG")"

  echo "--- md5 verification ---"
  EXPECTED=$(awk '{print $1}' "$DIR/testfile.md5" 2>/dev/null)
  SRC_MD5=$(grep -aoE '^[0-9a-f]{32}  /mnt/usb/testfile.bin' "$GLOG" | awk '{print $1}' | tail -1)
  COPY_MD5=$(grep -aoE '^[0-9a-f]{32}  /root/testfile.copy' "$GLOG" | awk '{print $1}' | tail -1)
  echo "expected (host)      : ${EXPECTED:-<unknown>}"
  echo "read back from stick : ${SRC_MD5:-<missing>}"
  echo "copied file          : ${COPY_MD5:-<missing>}"
  if [ -n "$COPY_MD5" ] && [ "$COPY_MD5" = "$EXPECTED" ]; then
    echo "MD5 VERDICT          : MATCH"
  else
    echo "MD5 VERDICT          : MISMATCH / missing"
  fi
  echo "--- dd tail ---"; grep -aE 'bytes .* copied|Input/output|error reading' "$GLOG" | tail -3
else
  echo "guest log            : NOT AVAILABLE"
fi

echo "--- guest-side USB disturbances (console) ---"
ENUM=$(grep -ac 'new high-speed USB device\|new full-speed USB device' "$CLEAN")
echo "enumeration events   : $ENUM (expected: 1)"
grep -aiE 'xhci_hcd.*not responding|usb [0-9-]+: reset|device descriptor read|device not accepting|usb-storage.*error|Input/output error' \
  "$CLEAN" | head -5 || echo "(no resets / no I/O errors)"
echo "============================================"
echo "artifacts: $RUN/{console.log,guest-demo.log,src.log,dst.log,usbvfiod.log,usb.pcap}"
