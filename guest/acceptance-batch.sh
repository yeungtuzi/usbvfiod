#!/usr/bin/env bash
# Run a batch of demo iterations and record the raw outcome per run.
#
#   ./acceptance-batch.sh [N] [control|migrate]
#
#   N        number of iterations (default 20)
#   mode     migrate (default) runs the full demo; control skips the migration
#
# Environment:
#   USBVF        override the server binary (e.g. the release build)
#   TAG          label for this batch (defaults to the mode)
#   RUNROOT      directory for the per-run artefacts (default /run/usb-batch)
#   EXTRA_ENV    extra VAR=VALUE pairs exported into every run, for example
#                "USBVFIOD_DISABLE_IRQ_KICK=1" for the negative control arm
#
# This script only drives the runs and writes raw fields. All aggregation
# (pass rate, Clopper-Pearson interval, Fisher comparison, median intervals) is
# done by summarize-batch.py, which re-derives every number from the saved logs
# so that the aggregation cannot disagree with the evidence.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
N="${1:-20}"
MODE="${2:-migrate}"
TAG="${TAG:-$MODE}"
RUNROOT="${RUNROOT:-/run/usb-batch}"
EXTRA_ENV="${EXTRA_ENV:-}"
CSV="$RUNROOT/results-$TAG.csv"
mkdir -p "$RUNROOT"

# APPEND=1 extends an existing batch instead of starting a new one: the CSV is
# kept and the run indices continue after the last one. Used to grow an arm to a
# pre-registered size after a first look at the data, without re-running it.
APPEND="${APPEND:-0}"
if [ "$APPEND" = "1" ] && [ -s "$CSV" ]; then
  FIRST=$(( $(awk 'NR>1' "$CSV" | wc -l) + 1 ))
else
  echo "run,downtime_ms,copy_s,spans,md5,late_enum,late_err,kicks,stale,verdict,rc" > "$CSV"
  FIRST=1
fi
LAST=$((FIRST + N - 1))

pass=0
for i in $(seq "$FIRST" "$LAST"); do
  out="$RUNROOT/$TAG-$i.log"
  (
    cd "$DIR" || exit 1
    export RUN="$RUNROOT/$TAG-$i"
    if [ "$MODE" = control ]; then export SKIP_MIGRATION=1; fi
    [ -n "${USBVF:-}" ] && export USBVF
    for kv in $EXTRA_ENV; do export "$kv"; done
    timeout 400 ./usb-migration-demo.sh
  ) > "$out" 2>&1
  rc=$?

  dt=$(grep -aoE 'downtime of [0-9]+ms' "$out" | grep -aoE '[0-9]+' | head -1)
  copy=$(grep -aE '^copy duration' "$out" | awk -F: '{print $2}' | tr -d ' s')
  spans=$(grep -aE '^spans migration' "$out" | awk -F: '{print $2}' | tr -d ' ')
  md5=$(grep -aE '^md5 verdict' "$out" | awk -F: '{print $2}' | tr -d ' ')
  le=$(grep -aE '^enumerations after migration' "$out" | awk -F: '{print $2}' | tr -d ' ')
  lr=$(grep -aE '^reset/error lines after migr' "$out" | awk -F: '{print $2}' | tr -d ' ')
  kicks=$(grep -aE '^interrupt kicks issued' "$out" | awk -F: '{print $2}' | tr -d ' ')
  stale=$(grep -aE '^stale teardowns ignored' "$out" | awk -F: '{print $2}' | tr -d ' ')
  verdict=$(grep -aE '^VERDICT' "$out" | awk -F: '{print $2}' | tr -d ' ')

  if [ "$MODE" = control ]; then
    c=$(grep -aE '^md5 \(copy\)' "$out" | awk -F: '{print $2}' | tr -d ' ')
    e=$(grep -aE '^expected' "$out" | awk -F: '{print $2}' | tr -d ' ')
    if [ -n "$c" ] && [ "$c" = "$e" ]; then verdict="PASS"; rc=0; else verdict="FAIL"; rc=1; fi
    spans="n/a"
  fi

  echo "$i,${dt:-},${copy:-},${spans:-},${md5:-},${le:-},${lr:-},${kicks:-},${stale:-},${verdict:-},$rc" >> "$CSV"
  [ "$rc" = 0 ] && pass=$((pass+1))
  echo "  run $i/$N rc=$rc verdict=${verdict:-?} downtime=${dt:-?}ms copy=${copy:-?}s spans=${spans:-?} md5=${md5:-?} late_enum=${le:-?} late_err=${lr:-?} kicks=${kicks:-?} stale=${stale:-?}"
done

echo
echo "=== $TAG: $pass / $N runs passed (raw csv: $CSV) ==="
python3 "$DIR/summarize-batch.py" "$RUNROOT" "$TAG-*.log"
