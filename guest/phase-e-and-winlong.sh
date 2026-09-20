#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export CARGO_HOME="${CARGO_HOME:-/root/lvllm/.cargo}" RUSTUP_HOME="${RUSTUP_HOME:-/root/lvllm/.rustup}"
export PATH="$CARGO_HOME/bin:$PATH"
echo "########## PHASE E: replug baseline (3 runs) ##########"
REPLUG_ROOT="${REPLUG_ROOT:-/root/usb-replug}"
rm -rf "$REPLUG_ROOT"; mkdir -p "$REPLUG_ROOT"
for i in 1 2 3; do
  "$DIR/stop-demo.sh" >/dev/null 2>&1
  RUN="$REPLUG_ROOT/$i" timeout 500 "$DIR/replug-baseline.sh" > "$REPLUG_ROOT-$i.log" 2>&1
  echo "  baseline run $i rc=$?"
done
python3 "$DIR/summarize-replug.py" "$REPLUG_ROOT" > $REPLUG_ROOT/replug.csv 2>&1
cat $REPLUG_ROOT/replug.csv

echo; echo "########## long-window A/B: 5000 ms delay ##########"
for arm in on off; do
  "$DIR/stop-demo.sh" >/dev/null 2>&1
  if [ "$arm" = off ]; then KICK="USBVFIOD_DISABLE_IRQ_KICK=1"; else KICK=""; fi
  TAG="winlong-$arm" RUNROOT=/root/usb-inject \
    EXTRA_ENV="USBVFIOD_INJECT_HANDOVER_DELAY_MS=5000 MAX_DOWNTIME_MS=12000 $KICK" \
    "$DIR/acceptance-batch.sh" 3 migrate
done
echo "DONE-PHASE-E-WINLONG"
