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
#
# The VMM's event stream is delivered to us over a socketpair (`--event-monitor
# fd=`), not through a file we tail: `guest/ch-with-events.py` owns the read end
# and republishes the events as flushed `<source>/<event>` lines, so a decision
# here can react to what the VMM reports without racing a block buffer.
#
# The device hand-over is driven from here, not from the VMM. usbvfiod stages
# the destination's interrupt registration as a *candidate* and only installs it
# when the control socket says so, so the harness is the one that decides when
# the device changes hands:
#
#   candidate seen + source paused  ->  ready  ->  commit
#
# and, if `send-migration` comes back with an error, `reclaim` puts the device
# back in the source's hands. That is what keeps the source usable when a
# migration does not take: the line never moved, or it moved back.
#
# HANDOVER=commit   drive ready+commit (default)
# HANDOVER=none     never commit; for measuring what the staging alone changes
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
CH="${CH:-/root/lvllm/cloud-hypervisor/target/release/cloud-hypervisor}"
CHR="${CHR:-$(dirname "$CH")/ch-remote}"
USBVF="${USBVF:-$REPO/target/debug/usbvfiod}"
DEVICE="${DEVICE:-/dev/bus/usb/001/007}"
REMOTE="${REMOTE:-$REPO/target/debug/remote}"
# Client slots: 1 is the historical single-client mode, which is the regression
# arm (no hand-over is possible there, and the server still exits with the client).
MAX_CLIENTS="${MAX_CLIENTS:-4}"
# How the harness drives the hand-over: commit (default) or none.
HANDOVER="${HANDOVER:-commit}"
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

# --- two-phase hand-over control ---------------------------------------------
# The control protocol is line-oriented and the `remote` tool resolves the role
# keywords (`candidate`, `prev`, `owner`) through a status query, so the harness
# never has to track connection ids itself.
status_field() { # status_field <key>
  "$REMOTE" --socket "$RUN/hotplug.sock" --handover-status 2>/dev/null \
    | grep -aoE "$1=[^ ]*" | head -1 | cut -d= -f2
}

# Wait for the destination's device activation, i.e. for its interrupt
# registration to be staged, then commit it once the source has stopped running.
#
# Committing as early as possible is the whole point: the interval between the
# source's pause and the commit is the window in which the destination can run
# without an interrupt line, so the controller polls fast and acts immediately.
handover_controller() {
  local i=0 cand
  # Watch the server's own log for the staging record: it is written before the
  # destination's registration reply is sent, so it is the earliest observable
  # instant, and reading a file does not compete with the registration for the
  # ownership lock the way a status query does. The candidate is short-lived in
  # practice - Cloud Hypervisor deactivates the source about 7 ms after the
  # destination registers - so the fast path matters.
  while [ "$i" -lt 24000 ]; do
    grep -q 'hand-over candidate: client' "$RUN/usbvfiod.log" 2>/dev/null && break
    sleep 0.005; i=$((i + 1))
  done
  cand="$(status_field candidate)"
  if [ -z "$cand" ] || [ "$cand" = "-" ]; then
    log "hand-over: no candidate appeared; the source keeps the device"
    printf 'none\n' > "$RUN/handover.mode"
    return 1
  fi
  date +%s.%N > "$RUN/handover.candidate"
  log "hand-over: destination staged as candidate $cand ($(status_field epoch) is the current epoch)"
  "$REMOTE" --socket "$RUN/hotplug.sock" --handover-status > "$RUN/handover.staged" 2>&1

  # Injected failure: the destination dies in the window in which the *old*
  # implementation had already stolen the source's line. This is the case the
  # staging exists for, so nothing may be committed here.
  if [ "${KILL_DST_WHEN_STAGED:-0}" = "1" ]; then
    log "hand-over: INJECTED FAILURE: killing the destination while it is only staged"
    kill -9 "$DST_CH_PID" 2>/dev/null
    printf 'destination-died-while-staged\n' > "$RUN/handover.mode"
    return 1
  fi

  # The source must have stopped executing before the device may move: before
  # that it is still the one using the stick. CH pauses the source before the
  # destination activates its devices, so this is normally already true; waiting
  # for the event makes the order explicit instead of assumed.
  local j=0
  while [ "$j" -lt 400 ]; do
    grep -qE ' vm/paused( |$)' "$RUN/src.events.lines" 2>/dev/null && break
    sleep 0.025; j=$((j + 1))
  done

  case "$HANDOVER" in
    none)
      printf 'none\n' > "$RUN/handover.mode"
      log "hand-over: HANDOVER=none, leaving the candidate staged"
      return 0
      ;;
    commit)
      "$REMOTE" --socket "$RUN/hotplug.sock" --handover-ready candidate \
        >> "$RUN/handover.log" 2>&1
      date +%s.%N > "$RUN/handover.commit"
      "$REMOTE" --socket "$RUN/hotplug.sock" --handover-commit candidate \
        >> "$RUN/handover.log" 2>&1
      printf 'commit\n' > "$RUN/handover.mode"
      "$REMOTE" --socket "$RUN/hotplug.sock" --handover-status > "$RUN/handover.committed" 2>&1
      log "hand-over: committed; owner is now $(status_field owner), previous owner $(status_field prev)"
      if [ "${KILL_DST_AFTER_COMMIT:-0}" = "1" ]; then
        log "hand-over: INJECTED FAILURE: killing the destination VMM after the commit"
        kill -9 "$DST_CH_PID" 2>/dev/null
      fi
      ;;
    *)
      log "ERROR: unknown HANDOVER=$HANDOVER"; return 1 ;;
  esac
}

# Trigger for a failure *after* the destination has asked for the device: watch
# the server log, which records the staging before it replies, instead of the
# control socket, whose status query is serialised behind that very registration.
kill_destination_on_registration() {
  local i=0
  while [ "$i" -lt 4000 ]; do
    grep -q 'hand-over candidate: client' "$RUN/usbvfiod.log" 2>/dev/null && break
    sleep 0.025; i=$((i + 1))
  done
  if ! grep -q 'hand-over candidate: client' "$RUN/usbvfiod.log" 2>/dev/null; then
    log "INJECTED FAILURE: the destination never registered; not killing it"
    printf 'destination-never-registered\n' > "$RUN/handover.mode"
    return 1
  fi
  date +%s.%N > "$RUN/handover.candidate"
  log "INJECTED FAILURE: the destination has registered as a candidate; killing it"
  kill -9 "$DST_CH_PID" 2>/dev/null
  printf 'destination-died-after-registering\n' > "$RUN/handover.mode"
  return 1
}

# The outcome of a migration is a *CH event*, not the return code of
# send-migration: the API call can return success while the switchover then fails
# (measured: the source logs `Migration failed` and `Resumed VM successfully` after
# ch-remote already returned 0). Reading the event monitor is the reliable path,
# which is exactly what the design's event-driven controller prescribes.
#
# Order matters: a failed migration also emits `shutdown` later, so a failure
# marker must win over it.
wait_migration_outcome() {
  local i=0 lines="$RUN/src.events.lines"
  while [ "$i" -lt 900 ]; do
    if grep -qE ' vm/migration-failed( |$)' "$lines" 2>/dev/null; then
      printf 'failed\n'; return 0
    fi
    if grep -qE ' vm/resumed( |$)' "$lines" 2>/dev/null; then
      printf 'resumed\n'; return 0
    fi
    if grep -qE ' vm/shutdown( |$)' "$lines" 2>/dev/null; then
      # The source is gone; look once more for a failure marker before calling
      # this a successful migration.
      if grep -qE ' vm/(migration-failed|resumed)( |$)' "$lines" 2>/dev/null; then
        printf 'failed\n'; return 0
      fi
      printf 'shutdown\n'; return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  printf 'unknown\n'
}

# If the migration did not take, the device has to go back to the source. When
# the failure happened before the commit nothing moved and this is a no-op that
# the server refuses with ERECLAIM_NOT_PREVIOUS_OWNER; when it happened after the
# commit the source gets a working line back.
handover_rollback() {
  local reason="$1"
  [ "$(cat "$RUN/handover.mode" 2>/dev/null)" = "commit" ] || {
    log "hand-over: nothing to roll back ($reason)"
    return 0
  }
  log "hand-over: $reason; asking for the device back"
  date +%s.%N > "$RUN/handover.reclaim"
  "$REMOTE" --socket "$RUN/hotplug.sock" --handover-reclaim prev \
    >> "$RUN/handover.log" 2>&1
  local rc=$?
  "$REMOTE" --socket "$RUN/hotplug.sock" --handover-status > "$RUN/handover.reclaimed" 2>&1
  log "hand-over: reclaim exit=$rc; owner is now $(status_field owner)"
  return 0
}

# --- 1. usbvfiod claims the physical stick -----------------------------------
"$USBVF" --socket-path "$RUN/usbvfiod.sock" --max-clients "$MAX_CLIENTS" \
  --hotplug-socket-path "$RUN/hotplug.sock" \
  --device "$DEVICE" --pcap-path "$RUN/usb.pcap" -v > "$RUN/usbvfiod.log" 2>&1 &
USB_PID=$!; pids+=($USB_PID)
for _ in $(seq 1 40); do
  [ -S "$RUN/usbvfiod.sock" ] && [ -S "$RUN/hotplug.sock" ] && break
  sleep 0.25
done
if grep -q 'Attached' "$RUN/usbvfiod.log"; then
  step "1/6 usbvfiod claimed $DEVICE (host driver switched to usbfs)"
else
  log "ERROR: usbvfiod did not attach $DEVICE"; tail -5 "$RUN/usbvfiod.log"; exit 1
fi

# --- 2. source VM: guest boots and starts copying from the stick -------------
python3 "$DIR/ch-with-events.py" --events "$RUN/src.events" -- \
  "$CH" -v --api-socket "$RUN/src.sock" \
  --memory size=2G,shared=on --cpus boot=1 \
  --kernel "$DIR/casper/vmlinuz" --initramfs "$DIR/initrd-custom.gz" \
  --disk "path=$DIR/rootfs.img,image_type=raw" \
  --user-device "socket=$RUN/usbvfiod.sock" \
  --serial "file=$RUN/console.fifo" --console off \
  --cmdline "root=/dev/vda rw console=ttyS0" > "$RUN/src.log" 2>&1 &
SRC_PID=$!; pids+=($SRC_PID)
wait_api "$RUN/src.sock" source || exit 1
SRC_CH_PID="$(cat "$RUN/src.events.pid" 2>/dev/null || echo "$SRC_PID")"
step "2/6 source VM booted; guest will mount the stick and start copying"
wait_for "DEMO-COPY: COPY_START" "$RUN/console.log" "$BOOT_TIMEOUT" || {
  log "ERROR: the guest never started copying"; tail -40 "$RUN/console.log"; exit 1
}
step "3/6 copy in flight; starting the destination"
[ "${COPY_LEAD_SECONDS}" != "0" ] && sleep "$COPY_LEAD_SECONDS"

# --- 3. destination VM + live migration -------------------------------------
python3 "$DIR/ch-with-events.py" --events "$RUN/dst.events" -- \
  "$CH" -v --api-socket "$RUN/dst.sock" > "$RUN/dst.log" 2>&1 &
DST_PID=$!; pids+=($DST_PID)
wait_api "$RUN/dst.sock" destination || exit 1
DST_CH_PID="$(cat "$RUN/dst.events.pid" 2>/dev/null || echo "$DST_PID")"
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

step "4/6 starting the live migration, driven by the hand-over controller"
: > "$RUN/handover.log"
MIGRATION_EPOCH=$(date +%s.%N)
# In the background: the migration only completes once the harness commits the
# hand-over, so the foreground is the controller.
"$CHR" --api-socket "$RUN/src.sock" \
  send-migration destination_url=unix:"$RUN/mig.sock",memory_mode=memfds,downtime_ms=300,timeout_strategy=cancel \
  > "$RUN/send.log" 2>&1 &
SEND_PID=$!
if [ "${KILL_DST_ON_REGISTRATION:-0}" = "1" ]; then
  kill_destination_on_registration
else
  handover_controller
fi
wait "$SEND_PID"; SEND_RC=$?
MIGRATION_OUTCOME="$(wait_migration_outcome)"
printf '%s\n' "$MIGRATION_OUTCOME" > "$RUN/migration.outcome"
log "send-migration exit=$SEND_RC; migration outcome=$MIGRATION_OUTCOME"
case "$MIGRATION_OUTCOME" in
  failed|resumed)
    handover_rollback "the migration failed ($MIGRATION_OUTCOME)" ;;
  shutdown)
    log "hand-over: the migration completed; the destination keeps the device" ;;
  *)
    if [ "$SEND_RC" != "0" ]; then
      handover_rollback "send-migration failed with exit $SEND_RC"
    else
      log "hand-over: no terminal migration event was seen; leaving the ownership as it is"
    fi ;;
esac
# Sample the ownership again once the dust has settled: after a failure the
# source VMM may have reconnected, and the status is what says who owns what.
if [ "${KILL_DST_AFTER_COMMIT:-0}" = "1" ] || [ "${KILL_DST_ON_REGISTRATION:-0}" = "1" ]; then
  sleep 20
  date +%s.%N > "$RUN/handover.aftermath.time"
  "$REMOTE" --socket "$RUN/hotplug.sock" --handover-status > "$RUN/handover.aftermath" 2>&1
  log "hand-over: aftermath: $(cat "$RUN/handover.aftermath" 2>/dev/null)"
fi
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

echo "--- hand-over control (harness) ---"
echo "migration outcome (event) : $(cat "$RUN/migration.outcome" 2>/dev/null || echo '<none>')"
echo "mode                      : $(cat "$RUN/handover.mode" 2>/dev/null || echo '<none>')"
echo "destination staged at     : $(cat "$RUN/handover.candidate" 2>/dev/null || echo '<never>')"
echo "hand-over committed at    : $(cat "$RUN/handover.commit" 2>/dev/null || echo '<never>')"
echo "status after staging      : $(cat "$RUN/handover.staged" 2>/dev/null || echo '<none>')"
echo "status after commit       : $(cat "$RUN/handover.committed" 2>/dev/null || echo '<none>')"
echo "remote log                : $(tr '\n' '|' < "$RUN/handover.log" 2>/dev/null)"
echo "--- hand-over path evidence (server log) ---"
echo "source VMM pid             : $SRC_CH_PID (relay $SRC_PID)"
echo "destination VMM pid        : ${DST_CH_PID:-<not started>} (relay ${DST_PID:-<none>})"
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
# A run in which the migration failed and the source was resumed is judged by
# different criteria (see verdict.py --expect-failure): the device has to survive
# the failure, not migrate. The mode is derived from the VMM log so a caller
# cannot forget to declare it.
EXPECT_FAILURE_ARGS=()
if grep -q 'Resumed VM successfully after failed migration' "$RUN/src.log" 2>/dev/null; then
  log "the source was resumed after a failed migration; judging the run as a recovery run"
  EXPECT_FAILURE_ARGS=(--expect-failure)
fi
DOWNTIME_MS=$(grep -aoE 'downtime of [0-9]+ms' "$RUN/src.log" | grep -aoE '[0-9]+' | head -1)
# Pass the downtime through unchanged (possibly empty). Defaulting it to 0 here
# made a missing "downtime of Nms" line look like a perfect 0 ms run, so the
# budget criterion could never fail for the one reason it exists to catch.
"$DIR/verdict.py" "${EXPECT_FAILURE_ARGS[@]}" --guest-log "$GLOG" \
  --expected-md5 "$(awk '{print $1}' "$DIR/testfile.md5")" \
  --migration-epoch "$MIGRATION_EPOCH" \
  --migration-done "${MIGRATION_DONE:-}" \
  --src-log "$RUN/src.log" \
  --downtime-ms "$DOWNTIME_MS" \
  --max-downtime-ms "${MAX_DOWNTIME_MS:-2000}"
RC=$?
echo "============================================"
echo "artifacts: $RUN/{console.log,guest-demo.log,src.log,dst.log,usbvfiod.log,usb.pcap}"
exit $RC
