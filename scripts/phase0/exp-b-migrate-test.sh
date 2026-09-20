#!/usr/bin/env bash
# Phase 0 / Experiment B: does Cloud Hypervisor live-migrate a VM that has a
# --user-device (vfio-user, e.g. usbvfiod) attached?
#
# Result (2026-09-20, CH v53.0-520-gc24527002): control passes, userdev hangs
# forever on the destination. See docs/phase0-exp-b-ch-vfio-user-migration_cn.md.
#
# Usage: exp-b-migrate-test.sh <control|userdev>
#
# Overridable environment variables:
#   CH     path to cloud-hypervisor binary
#   CHR    path to ch-remote binary
#   USBVF  path to the usbvfiod binary
#   IMG    directory containing the guest `linux` and `initrd.gz`
set -u

MODE="${1:-control}"
CH="${CH:-/root/lvllm/cloud-hypervisor/target/release/cloud-hypervisor}"
CHR="${CHR:-$(dirname "$CH")/ch-remote}"
USBVF="${USBVF:-/root/lvllm/usbvfiod/target/debug/usbvfiod}"
IMG="${IMG:-/root/lvllm/images}"
D="${D:-/run/ch-mig2-$MODE}"

SRC_PID=""; DST_PID=""; RECV_PID=""; USB_PID=""
cleanup() {
  for p in "$SRC_PID" "$DST_PID" "$RECV_PID" "$USB_PID"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
}
trap cleanup EXIT

rm -rf "$D"; mkdir -p "$D"

wait_api() {
  local sock="$1" name="$2"
  for _ in $(seq 1 60); do
    if "$CHR" --api-socket "$sock" ping >/dev/null 2>&1; then echo "[$name] API ready"; return 0; fi
    sleep 1
  done
  echo "[$name] API NOT ready"; return 1
}

if [ "$MODE" = userdev ]; then
  "$USBVF" --socket-path "$D/usbvfiod.sock" --max-clients 4 -v > "$D/usbvfiod.log" 2>&1 &
  USB_PID=$!
  for _ in $(seq 1 20); do [ -S "$D/usbvfiod.sock" ] && break; sleep 0.5; done
  echo "[usbvfiod] pid=$USB_PID"
fi

EXTRA=()
if [ "$MODE" = userdev ]; then EXTRA=(--user-device "socket=$D/usbvfiod.sock"); fi

"$CH" -v --api-socket "$D/src.sock" \
  --memory size=512M,shared=on --cpus boot=1 \
  --kernel "$IMG/linux" --initramfs "$IMG/initrd.gz" \
  --cmdline "console=ttyS0" --serial "file=$D/src-console.log" --console off \
  "${EXTRA[@]}" > "$D/src.log" 2>&1 &
SRC_PID=$!
wait_api "$D/src.sock" source || { echo "source failed"; tail -20 "$D/src.log"; exit 1; }
sleep 6

"$CH" -v --api-socket "$D/dst.sock" > "$D/dst.log" 2>&1 &
DST_PID=$!
wait_api "$D/dst.sock" destination || { echo "destination failed"; tail -20 "$D/dst.log"; exit 1; }

"$CHR" --api-socket "$D/dst.sock" receive-migration receiver_url=unix:"$D/mig.sock" > "$D/receive.log" 2>&1 &
RECV_PID=$!
sleep 2

echo "=== send-migration ==="
"$CHR" --api-socket "$D/src.sock" \
  send-migration destination_url=unix:"$D/mig.sock",memory_mode=memfds,downtime_ms=300,timeout_strategy=cancel \
  > "$D/send.log" 2>&1
SEND_RC=$?
echo "send-migration exit=$SEND_RC"

echo "=== waiting for outcome (max 80s) ==="
OUTCOME="timeout"
for i in $(seq 1 40); do
  sleep 2
  # ch-remote info itself blocks while the receiver is stuck, hence the timeout
  DSTSTATE=$(timeout 3 "$CHR" --api-socket "$D/dst.sock" info 2>/dev/null | grep -o '"state":"[A-Za-z]*"' | head -1)
  SRCALIVE=no; kill -0 "$SRC_PID" 2>/dev/null && SRCALIVE=yes
  if grep -qE 'Migration aborted|aborting migration|Fatal error' "$D/dst.log" "$D/src.log" 2>/dev/null; then
    OUTCOME="failed"; echo "[t=$((i*2))s] failure in logs"; break
  fi
  if [ "$DSTSTATE" = '"state":"Running"' ] && [ "$SRCALIVE" = no ]; then
    OUTCOME="migrated"; echo "[t=$((i*2))s] migration completed"; break
  fi
  [ $((i % 5)) -eq 0 ] && echo "[t=$((i*2))s] dst=$DSTSTATE src_alive=$SRCALIVE"
done
echo "OUTCOME=$OUTCOME"

echo "=== unix socket connections to usbvfiod ==="
ss -xap 2>/dev/null | grep -E 'usbvfiod|mig.sock' | head -5 || echo "(none)"
echo "=== destination log (error lines) ==="
grep -nE 'ERROR|WARN|migrat|vfio' "$D/dst.log" | tail -25
echo "--- dst tail ---"; tail -8 "$D/dst.log"
echo "=== source log (error lines) ==="
grep -nE 'ERROR|WARN|migrat|vfio|MSI' "$D/src.log" | tail -25
echo "=== receive / send output ==="; cat "$D/receive.log" "$D/send.log"
echo "=== usbvfiod: connection events ==="
grep -inE 'connect|accept|client|disconnect|error' "$D/usbvfiod.log" | tail -15
echo "RESULT: mode=$MODE send_rc=$SEND_RC outcome=$OUTCOME"
