#!/usr/bin/env bash
# E1: what does Cloud Hypervisor report when a migration fails or is cancelled?
#
# The two-phase design wants to drive abort/reclaim from CH's own events rather
# than from the return value of send-migration. This experiment captures the real
# event stream for two failure modes:
#
#   s1  the migration is cancelled by a one-second timeout (pre-copy phase)
#   s2  the destination is killed while the hand-over is held open by the
#       USBVFIOD_INJECT_HANDOVER_DELAY_MS hook, i.e. after the source was paused
#
# For each it writes the CH event streams (--event-monitor), both CH logs, the
# console capture and a short summary: which events appeared, and whether the
# guest's copy kept making progress after the failure.
#
#   ./exp-cancel-events.sh [s1|s2|all]
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
CH="${CH:-/root/lvllm/cloud-hypervisor/target/release/cloud-hypervisor}"
CHR="${CHR:-$(dirname "$CH")/ch-remote}"
USBVF="${USBVF:-$REPO/target/debug/usbvfiod}"
DEVICE="${DEVICE:-/dev/bus/usb/001/007}"
ROOT="${ROOT:-/root/usb-e1}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"

pids=()
stop_all() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; sleep 2; }
trap stop_all EXIT
log() { printf '[e1] %s\n' "$*"; }

wait_for() { local p="$1" f="$2" t="${3:-60}" i=0; while [ "$i" -lt "$t" ]; do grep -q "$p" "$f" 2>/dev/null && return 0; sleep 1; i=$((i+1)); done; return 1; }
wait_api() { local s="$1" i=0; while [ "$i" -lt 60 ]; do "$CHR" --api-socket "$s" ping >/dev/null 2>&1 && return 0; sleep 1; i=$((i+1)); done; return 1; }
copied_bytes() { grep -aoE 'copied=[0-9]+' "$1" 2>/dev/null | grep -aoE '[0-9]+' | tail -1; }

start_stack() { # run-dir, usbvfiod-extra-env
  local run="$1"; shift
  rm -rf "$run"; mkdir -p "$run"
  mkfifo "$run/console.fifo"
  python3 "$DIR/fifo-capture.py" "$run/console.fifo" "$run/console.log" &
  pids+=($!); sleep 0.5
  env "$@" "$USBVF" --socket-path "$run/usbvfiod.sock" --max-clients 4 \
      --device "$DEVICE" -v > "$run/usbvfiod.log" 2>&1 &
  pids+=($!)
  for _ in $(seq 1 40); do [ -S "$run/usbvfiod.sock" ] && break; sleep 0.25; done
  grep -q 'Attached' "$run/usbvfiod.log" || { log "ERROR: usbvfiod did not attach"; tail -5 "$run/usbvfiod.log"; return 1; }

  "$CH" -v --api-socket "$run/src.sock" --event-monitor "path=$run/src.events" \
    --memory size=2G,shared=on --cpus boot=1 \
    --kernel "$DIR/casper/vmlinuz" --initramfs "$DIR/initrd-custom.gz" \
    --disk "path=$DIR/rootfs.img,image_type=raw" \
    --user-device "socket=$run/usbvfiod.sock" \
    --serial "file=$run/console.fifo" --console off \
    --cmdline "root=/dev/vda rw console=ttyS0" > "$run/src.log" 2>&1 &
  SRC_PID=$!; pids+=($SRC_PID)
  wait_api "$run/src.sock" || { log "ERROR: source API"; return 1; }
  wait_for "DEMO-COPY: COPY_START" "$run/console.log" "$BOOT_TIMEOUT" || { log "ERROR: copy never started"; return 1; }
  log "guest is copying; stack is up in $run"
}

start_dst() { # run-dir
  local run="$1"
  "$CH" -v --api-socket "$run/dst.sock" --event-monitor "path=$run/dst.events" > "$run/dst.log" 2>&1 &
  DST_PID=$!; pids+=($DST_PID)
  wait_api "$run/dst.sock" || return 1
  "$CHR" --api-socket "$run/dst.sock" receive-migration receiver_url=unix:"$run/mig.sock" \
    > "$run/receive.log" 2>&1 &
  pids+=($!)
  sleep 2
}

summarise() { # run-dir, label
  local run="$1" label="$2"
  echo
  echo "================ E1 $label : $run ================"
  echo "--- source events ($run/src.events) ---"
  grep -oE '"event": *"[^"]+"' "$run/src.events" 2>/dev/null | sed 's/.*"event": *"//;s/"//' | uniq -c || echo "(no src events)"
  echo "--- destination events ($run/dst.events) ---"
  grep -oE '"event": *"[^"]+"' "$run/dst.events" 2>/dev/null | sed 's/.*"event": *"//;s/"//' | uniq -c || echo "(no dst events)"
  echo "--- source log: outcome lines ---"
  grep -aoE 'Migration (completed|failed|aborted)[^"]*|Resumed VM successfully[^"]*' "$run/src.log" | tail -3
  echo "--- usbvfiod: hand-over evidence ---"
  echo "interrupt lines installed: $(grep -ac 'interrupt line installed' "$run/usbvfiod.log")"
  echo "kicks issued             : $(grep -ac 're-raising one interrupt' "$run/usbvfiod.log")"
  echo "stale teardowns ignored  : $(grep -ac 'ignoring IRQ disable from stale' "$run/usbvfiod.log")"
  echo "--- did the guest copy keep going? ---"
  echo "last copied= seen        : $(copied_bytes "$run/console.log") bytes"
  echo "heartbeats after failure : $(grep -ac 'DEMO-HEARTBEAT' "$run/console.log")"
  echo "======================================================"
}

scenario_s1() { # cancelled by timeout during pre-copy
  local run="$ROOT/s1"
  start_stack "$run" USBVFIOD_INJECT_HANDOVER_DELAY_MS=8000 || return 1
  start_dst "$run" || return 1
  local before; before="$(copied_bytes "$run/console.log")"
  log "s1: sending migration with an 8 s hand-over delay and timeout_s=2 (cancel while the source is paused)"
  "$CHR" --api-socket "$run/src.sock" \
    send-migration destination_url=unix:"$run/mig.sock",memory_mode=memfds,downtime_ms=300,timeout_s=2,timeout_strategy=cancel \
    > "$run/send.log" 2>&1
  log "s1: send-migration exit=$?"
  sleep 25
  summarise "$run" "s1 timeout-cancel (copy before=$before)"
}

scenario_s2() { # destination killed inside the held-open hand-over window
  local run="$ROOT/s2"
  start_stack "$run" USBVFIOD_INJECT_HANDOVER_DELAY_MS=8000 || return 1
  start_dst "$run" || return 1
  local before; before="$(copied_bytes "$run/console.log")"
  log "s2: sending migration with an 8 s hand-over delay, then killing the destination"
  "$CHR" --api-socket "$run/src.sock" \
    send-migration destination_url=unix:"$run/mig.sock",memory_mode=memfds,downtime_ms=300,timeout_s=60,timeout_strategy=cancel \
    > "$run/send.log" 2>&1 &
  local send_pid=$!
  # wait until the hook announces the delayed hand-over, then kill the destination
  # Wait for the SOURCE to be paused (the switchover has begun and the 8 s
  # hand-over delay keeps it paused), not merely for the hook line: the hook also
  # fires during the source's own boot-time registration.
  local i=0
  while [ "$i" -lt 120 ]; do grep -q '"event": "paused"' "$run/src.events" 2>/dev/null && break; sleep 0.25; i=$((i+1)); done
  log "s2: source paused (i=$i quarter-seconds); killing destination pid $DST_PID"
  kill -9 "$DST_PID" 2>/dev/null
  wait "$send_pid"; log "s2: send-migration exit=$?"
  sleep 25
  summarise "$run" "s2 destination killed in the hand-over window (copy before=$before)"
}

case "${1:-all}" in
  s1) scenario_s1 ;;
  s2) scenario_s2 ;;
  all) scenario_s1; stop_all; pids=(); scenario_s2 ;;
  *) echo "usage: $0 [s1|s2|all]" >&2; exit 2 ;;
esac
echo "E1 DONE"
