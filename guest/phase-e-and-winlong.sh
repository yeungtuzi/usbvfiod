#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH=/root/lvllm/.cargo/bin:$PATH CARGO_HOME=/root/lvllm/.cargo RUSTUP_HOME=/root/lvllm/.rustup
echo "########## PHASE E: replug baseline (3 runs) ##########"
rm -rf /root/usb-replug; mkdir -p /root/usb-replug
for i in 1 2 3; do
  "$DIR/stop-demo.sh" >/dev/null 2>&1
  RUN="/root/usb-replug/$i" timeout 500 "$DIR/replug-baseline.sh" > "/root/usb-replug-$i.log" 2>&1
  echo "  baseline run $i rc=$?"
done
python3 "$DIR/summarize-replug.py" /root/usb-replug > /root/usb-replug/replug.csv 2>&1
cat /root/usb-replug/replug.csv

echo; echo "########## long-window A/B: 5000 ms delay ##########"
for arm in on off; do
  "$DIR/stop-demo.sh" >/dev/null 2>&1
  if [ "$arm" = off ]; then KICK="USBVFIOD_DISABLE_IRQ_KICK=1"; else KICK=""; fi
  TAG="winlong-$arm" RUNROOT=/root/usb-inject \
    EXTRA_ENV="USBVFIOD_INJECT_HANDOVER_DELAY_MS=5000 MAX_DOWNTIME_MS=12000 $KICK" \
    "$DIR/acceptance-batch.sh" 3 migrate
done
echo "DONE-PHASE-E-WINLONG"
