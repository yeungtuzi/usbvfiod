#!/usr/bin/env bash
# Extend the underpowered injection arms to their pre-registered size.
# The earlier runs stay; reverify-batch.py has already re-judged them with the
# corrected verdict, so the whole arm uses one verdict definition.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export USBVF="${USBVF:-$(cd "$DIR/.." && pwd)/target/debug/usbvfiod}"
run_arm() { # tag, env, n
  "$DIR/stop-demo.sh" >/dev/null 2>&1
  echo "########## APPEND $1 (+$3 runs) ##########"
  TAG="$1" APPEND=1 RUNROOT=/root/usb-inject EXTRA_ENV="$2" \
    "$DIR/acceptance-batch.sh" "$3" migrate
}
run_arm window-loss  "USBVFIOD_INJECT_HANDOVER_DELAY_MS=500 MAX_DOWNTIME_MS=12000 USBVFIOD_DISABLE_IRQ_KICK=1" 5
run_arm winlong-on   "USBVFIOD_INJECT_HANDOVER_DELAY_MS=5000 MAX_DOWNTIME_MS=12000" 5
run_arm winlong-off  "USBVFIOD_INJECT_HANDOVER_DELAY_MS=5000 MAX_DOWNTIME_MS=12000 USBVFIOD_DISABLE_IRQ_KICK=1" 5
echo "EXTEND-DONE"
for t in window-loss winlong-on winlong-off; do
  p=$(awk -F, 'NR>1 && $10=="PASS"' /root/usb-inject/results-$t.csv | wc -l)
  n=$(awk -F, 'NR>1' /root/usb-inject/results-$t.csv | wc -l)
  echo "$t $p/$n"
done
