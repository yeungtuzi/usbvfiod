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
# When to request the migration. A fixed wall-clock lead is not robust: the
# release build copies the same file three to five times faster than the debug
# build, so a lead tuned for one build lets the copy finish before the
# migration is even requested (the run then fails the "spans" criterion for a
# reason that has nothing to do with the device). Instead the harness watches
# the guest's own dd progress output on the console and requests the migration
# once the copy has passed COPY_TRIGGER_BYTES, i.e. at a fixed *fraction* of the
# copy, whatever the build. COPY_LEAD_SECONDS is kept only as a lower bound and
# as the fallback when no progress line appears.
COPY_TRIGGER_BYTES="${COPY_TRIGGER_BYTES:-16777216}"   # 16 MiB of 128 MiB
COPY_TRIGGER_TIMEOUT="${COPY_TRIGGER_TIMEOUT:-90}"
COPY_LEAD_SECONDS="${COPY_LEAD_SECONDS:-0}"

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

# Milestone marker. With PAUSE=1 the demo waits for Enter so it can be narrated
# live; the default stays fully automatic.
step() {
  printf '\n[demo] ==== %s ====\n' "$*"
  if [ "${PAUSE:-0}" = "1" ]; then
    printf '        (press Enter to continue / 按 Enter 继续) '
    read -r _ || true
  fi
}

wait_for() { # wait_for <pattern> <file> <timeout-seconds>
  local pat="$1" file="$2" tmo="$3" i=0
  while [ "$i" -lt "$tmo" ]; do
    grep -q "$pat" "$file" 2>/dev/null && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

# Highest byte count reported by the guest so far. The guest heartbeat carries
# the size of the in-progress copy ("DEMO-HEARTBEAT n <epoch> uptime=U
# copied=B"), which is build-speed independent; dd's own progress line (which
# only goes to the guest log, not the console) is accepted as a fallback.
#
# Only heartbeats *after* COPY_START count. A heartbeat from before the copy can
# still report the size of the previous boot's output file, which would let the
# migration be requested immediately - exactly the failure this guards against.
copy_bytes_seen() {
  {
    awk '/DEMO-COPY: COPY_START/{f=1} f' "$RUN/console.log" 2>/dev/null \
      | grep -aoE 'copied=[0-9]+' | grep -aoE '[0-9]+'
    awk '/DEMO-COPY: COPY_START/{f=1} f' "$RUN/console.log" 2>/dev/null \
      | grep -aoE '[0-9]+ bytes \([0-9.]+ [kMG]?B' | grep -aoE '^[0-9]+'
  } | sort -n | tail -1
}

wait_copy_progress() { # wait_copy_progress <target-bytes> <timeout-seconds>
  local target="$1" tmo="$2" i=0 b
  while [ "$i" -lt "$tmo" ]; do
    b="$(copy_bytes_seen)"
    if [ -n "$b" ] && [ "$b" -ge "$target" ]; then
      log "guest has copied ${b} bytes (>= ${target}); triggering the migration"
      return 0
    fi
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
  step "1/6 usbvfiod claimed $DEVICE (host driver switched to usbfs)"
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
step "2/6 source VM booted; guest will mount the stick and start copying"
wait_for "DEMO-COPY: COPY_START" "$RUN/console.log" "$BOOT_TIMEOUT" || {
  log "ERROR: the guest never started copying"; tail -40 "$RUN/console.log"; exit 1
}
step "3/6 copy in flight; starting the destination"
[ "${COPY_LEAD_SECONDS}" != "0" ] && sleep "$COPY_LEAD_SECONDS"

# --- 3. destination VM + live migration -------------------------------------
"$CH" -v --api-socket "$RUN/dst.sock" > "$RUN/dst.log" 2>&1 &
DST_PID=$!; pids+=($DST_PID)
wait_api "$RUN/dst.sock" destination || exit 1
"$CHR" --api-socket "$RUN/dst.sock" receive-migration receiver_url=unix:"$RUN/mig.sock" \
  > "$RUN/receive.log" 2>&1 &
pids+=($!)
sleep 2

if [ "${SKIP_MIGRATION:-0}" = "1" ]; then
  step "4/6 CONTROL RUN: no migration; the copy runs to completion"
  MIGRATION_EPOCH=""
  echo "" > "$RUN/migration.epoch"
  wait_for "DEMO-COPY: MD5_DONE" "$RUN/console.log" "$COPY_TIMEOUT" || true
  stop_vms
  MNT="$RUN/guestfs"; mkdir -p "$MNT"
  mount -o loop "$DIR/rootfs.img" "$MNT" 2>/dev/null && {
    cp "$MNT/root/demo.log" "$RUN/guest-demo.log" 2>/dev/null || true; umount "$MNT"; }
  GLOG="$RUN/guest-demo.log"
  echo
  echo "================ CONTROL RESULT (no migration) ================"
  grep -aoE 'DEMO-COPY: COPY_(START|DONE) [0-9.]+( rc=[0-9]+)?' "$GLOG" | tail -2
  awk '/COPY_START/{s=$3} /COPY_DONE/{d=$3} END{if(s&&d) printf "copy duration        : %.1f s\n", d-s}' "$GLOG"
  echo "md5 (copy)           : $(grep -aoE '^[0-9a-f]{32}  /root/testfile.copy' "$GLOG" | awk '{print $1}' | tail -1)"
  echo "expected             : $(awk '{print $1}' "$DIR/testfile.md5")"
  echo "interrupt lines inst.: $(grep -ac 'interrupt line installed' "$RUN/usbvfiod.log")"
  echo "=============================================================="
  exit 0
fi

step "3b/6 waiting for the guest to pass ${COPY_TRIGGER_BYTES} bytes of the copy"
if ! wait_copy_progress "$COPY_TRIGGER_BYTES" "$COPY_TRIGGER_TIMEOUT"; then
  log "WARNING: no copy progress within ${COPY_TRIGGER_TIMEOUT}s (highest seen: '$(copy_bytes_seen)'); migrating anyway"
  sleep "$COPY_LEAD_SECONDS"
fi

step "4/6 starting the live migration"
MIGRATION_EPOCH=$(date +%s.%N)
"$CHR" --api-socket "$RUN/src.sock" \
  send-migration destination_url=unix:"$RUN/mig.sock",memory_mode=memfds,downtime_ms=300,timeout_strategy=cancel \
  > "$RUN/send.log" 2>&1
log "send-migration exit=$?"
# send-migration returns when the switchover has completed. Recording that
# instant as well lets the verdict require the *whole* migration, not just the
# request, to fall inside the copy window - otherwise a run could "span" the
# migration while the guest finished copying before the switchover happened.
MIGRATION_DONE=$(date +%s.%N)
step "5/6 migration issued; the copy must continue on the destination"
echo "$MIGRATION_EPOCH" > "$RUN/migration.epoch"
echo "$MIGRATION_DONE" > "$RUN/migration.done"

# --- 4. wait for the copy to report completion (console is best effort) -----
wait_for "DEMO-COPY: MD5_DONE" "$RUN/console.log" "$COPY_TIMEOUT" \
  || log "note: MD5_DONE not seen on the (best-effort) console; falling back to the guest log"

# --- 5. post-mortem: read the guest's own log from the disk image -----------
step "6/6 stopping the VMs and verifying from the guest log"
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
GLOG="$RUN/guest-demo.log"

echo "--- hand-over path evidence (server log) ---"
echo "client handshakes         : $(grep -ac 'Received client version' "$RUN/usbvfiod.log")"
echo "interrupt lines installed : $(grep -ac 'interrupt line installed' "$RUN/usbvfiod.log")"
echo "interrupt kicks issued    : $(grep -ac 're-raising one interrupt' "$RUN/usbvfiod.log")"
echo "stale teardowns ignored   : $(grep -ac 'ignoring IRQ disable from stale' "$RUN/usbvfiod.log")"

echo "================ DEMO RESULT ================"
echo "source process alive : $(kill -0 "$SRC_PID" 2>/dev/null && echo yes || echo no) (expected: no)"
echo "migration line       : $(grep -o 'Migration completed.*' "$RUN/src.log" | head -1)"
echo "guest log            : $GLOG"
echo "console (best effort): $RUN/console.log"
echo
# The verdict is computed from the guest's own log (see verdict.py): the serial
# console can lose output exactly around the migration, because the destination
# re-creates the serial device and resets the guest TTY.
chmod +x "$DIR/verdict.py"
DOWNTIME_MS=$(grep -aoE 'downtime of [0-9]+ms' "$RUN/src.log" | grep -aoE '[0-9]+' | head -1)
"$DIR/verdict.py" --guest-log "$GLOG" \
  --expected-md5 "$(awk '{print $1}' "$DIR/testfile.md5")" \
  --migration-epoch "$MIGRATION_EPOCH" \
  --migration-done "${MIGRATION_DONE:-}" \
  --downtime-ms "${DOWNTIME_MS:-0}" \
  --max-downtime-ms "${MAX_DOWNTIME_MS:-2000}"
RC=$?
echo "============================================"
echo "artifacts: $RUN/{console.log,guest-demo.log,src.log,dst.log,usbvfiod.log,usb.pcap}"
exit $RC
