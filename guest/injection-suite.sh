#!/usr/bin/env bash
# Deterministic fault-injection suite for the hand-over fixes.
#
#   ./injection-suite.sh [N_PER_ARM]
#
# The acceptance batch measures the *fixed* system and relies on the hand-over
# race happening by chance (in the 20-run campaign the CH-clock-anchored window
# was non-empty in 4/20 runs, 8/20 with the harness-epoch anchor and 11/20 with
# the request anchor). That is enough to show the system works, but it is a weak way to
# show *why* it works: a reviewer cannot tell whether the two hand-over fixes
# carry the weight or whether the runs simply never hit the bad case.
#
# This suite removes the luck. Two compile-time-dormant hooks (enabled only in
# debug builds, and only through the environment) let a run be *exposed by
# construction*:
#
#   USBVFIOD_INJECT_HANDOVER_DELAY_MS=N
#       Sleep N ms inside the SetIrqs handler, before the new interrupt line is
#       handed to the interrupter worker. While the handler sleeps, the worker
#       keeps draining completion events onto the departing client's line - the
#       exact window the kick exists to cover - so every run in the arm is
#       exposed to the race.
#
#   USBVFIOD_DISABLE_OWNER_GUARD=1
#       Make every connection "own" the device, re-introducing the
#       stale-teardown defect that the ownership guard closes. The source VMM's
#       IRQ-disable then lands on the destination's freshly installed line and
#       replaces it with a dummy.
#
# The arms run the same guest workload and the same verdict script as the
# acceptance batch, so their PASS/FAIL is directly comparable.
#
#   arm      delay  kick   guard   expected
#   baseline   0     on     on     PASS   (hooks dormant: sanity that they are inert)
#   window   500     on     on     PASS   (kick recovers an enlarged window)
#   window-loss 500  off    on     FAIL   (window without the kick)
#   guard-off  0     on     off    FAIL   (stale teardown without the guard)
#
# Environment:
#   USBVF     server binary (must be a debug build: the hooks are debug-only)
#   RUNROOT   where the per-run artefacts go (default /run/usb-inject)
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
N="${1:-5}"
RUNROOT="${RUNROOT:-/root/usb-inject}"
mkdir -p "$RUNROOT"

clean() {
  pkill -x cloud-hypervisor 2>/dev/null
  pkill -x usbvfiod 2>/dev/null
  sleep 1
  shopt -s nullglob
  for f in /media/root/*/; do umount "$f" 2>/dev/null; done
}

arm() { # tag, extra env, expected verdict, [runs]
  local tag="$1" env="$2" expect="$3" runs="${4:-$N}"
  echo
  echo "########## ARM $tag (expected $expect, $runs runs) ##########"
  clean
  TAG="$tag" RUNROOT="$RUNROOT" EXTRA_ENV="$env" \
    "$DIR/acceptance-batch.sh" "$runs" migrate
  local csv="$RUNROOT/results-$tag.csv"
  local pass fail
  pass=$(awk -F, 'NR>1 && $10=="PASS"' "$csv" | wc -l)
  fail=$(awk -F, 'NR>1 && $10=="FAIL"' "$csv" | wc -l)
  echo "ARM $tag: PASS=$pass FAIL=$fail expected=$expect"
}

if [ -z "${USBVF:-}" ]; then
  USBVF="$DIR/../target/debug/usbvfiod"
fi
if [ ! -x "$USBVF" ]; then
  echo "no server binary at $USBVF" >&2
  exit 2
fi
export USBVF
echo "server binary: $USBVF"
if ! strings "$USBVF" | grep -q USBVFIOD_INJECT_HANDOVER_DELAY_MS; then
  echo "warning: $USBVF does not contain the injection hooks (release build?)" >&2
fi

arm baseline      ""                                                          PASS 5
arm window        "USBVFIOD_INJECT_HANDOVER_DELAY_MS=500"                    PASS 5
# The 500 ms contrast is deliberately reported as non-deterministic and is given
# more runs than the others so its failure rate is not estimated from a handful.
arm window-loss   "USBVFIOD_INJECT_HANDOVER_DELAY_MS=500 MAX_DOWNTIME_MS=12000 USBVFIOD_DISABLE_IRQ_KICK=1" FAIL 10
arm guard-off     "USBVFIOD_DISABLE_OWNER_GUARD=1"                            FAIL 5
# A 500 ms window is not always enough to make the missing kick fatal: the guest
# can recover if the completion it lost was not the last one outstanding. A 5 s
# window drains the transfer queue, so the lost completion *is* the last one.
# MAX_DOWNTIME_MS has to be raised because the injected delay is what the VMM
# reports as downtime; the acceptance budget does not apply to these arms.
# 8 runs per arm is the pre-registered size. A perfect split is already
# significant at n=4 (two-sided p=0.029); 8 was chosen to keep power against a
# less extreme effect (it gives 0.88 at 5% vs 80%).
arm winlong-on    "USBVFIOD_INJECT_HANDOVER_DELAY_MS=5000 MAX_DOWNTIME_MS=12000" PASS 8
arm winlong-off   "USBVFIOD_INJECT_HANDOVER_DELAY_MS=5000 MAX_DOWNTIME_MS=12000 USBVFIOD_DISABLE_IRQ_KICK=1" FAIL 8

echo
echo "================ INJECTION SUITE SUMMARY ================"
printf '%-14s %6s %6s %8s\n' arm PASS FAIL expected
for a in baseline window window-loss winlong-on winlong-off guard-off; do
  csv="$RUNROOT/results-$a.csv"
  [ -f "$csv" ] || continue
  p=$(awk -F, 'NR>1 && $10=="PASS"' "$csv" | wc -l)
  f=$(awk -F, 'NR>1 && $10=="FAIL"' "$csv" | wc -l)
  printf '%-14s %6s %6s\n' "$a" "$p" "$f"
done
echo "(expected: baseline PASS, window PASS, window-loss FAIL, winlong-on PASS,"
echo " winlong-off FAIL, guard-off FAIL)"
echo "raw evidence: $RUNROOT"
