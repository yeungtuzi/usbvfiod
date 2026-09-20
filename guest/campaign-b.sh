#!/usr/bin/env bash
# Campaign B: the full round-3 measurement set, produced by one harness.
#
#   ./campaign-b.sh <phase>      # a | bcd | e | f | all
#
# Phases (run in this order; split so the paper can be regenerated while the
# injection arms are still running):
#
#   a    20 acceptance runs, debug build, migration
#   bcd  8 no-migration control, 8 release-build migration, 8 kick-disabled
#        negative control
#   e    3 naive detach/re-attach baseline runs
#   f    fault-injection suite (see injection-suite.sh for the per-arm sizes:
#        hooks dormant, 500 ms window with/without kick, 5 s window with/without
#        kick, ownership guard disabled). The extended sizes themselves were
#        produced by extend-injection.sh after the first look at the data, which
#        the paper discloses and labels exploratory.
#
# Everything lands in RUNROOT (on disk: /run is a 6.3 GB tmpfs and one run
# including its packet capture is ~145 MB, so two campaigns do not fit).
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
RUNROOT="${RUNROOT:-/root/usb-runs}"
export PATH=/root/lvllm/.cargo/bin:$PATH CARGO_HOME=/root/lvllm/.cargo RUSTUP_HOME=/root/lvllm/.rustup

mkdir -p "$RUNROOT"
"$DIR/stop-demo.sh" >/dev/null 2>&1

phase="${1:-all}"
do_a=0; do_bcd=0; do_e=0; do_f=0
case "$phase" in
  a) do_a=1 ;;
  bcd) do_bcd=1 ;;
  e) do_e=1 ;;
  f) do_f=1 ;;
  all) do_a=1; do_bcd=1; do_e=1; do_f=1 ;;
  *) echo "unknown phase $phase" >&2; exit 2 ;;
esac

if [ "$do_a" = 1 ]; then
  echo "########## PHASE A: 20 acceptance runs (debug build, migration) ##########"
  TAG=debug RUNROOT="$RUNROOT" "$DIR/acceptance-batch.sh" 20 migrate
fi

if [ "$do_bcd" = 1 ]; then
  echo; echo "########## PHASE B: 8 control runs (no migration) ##########"
  TAG=control RUNROOT="$RUNROOT" "$DIR/acceptance-batch.sh" 8 control

  echo; echo "########## PHASE C: 8 release-build migration runs ##########"
  TAG=release USBVF="$REPO/target/release/usbvfiod" RUNROOT="$RUNROOT" \
    "$DIR/acceptance-batch.sh" 8 migrate

  echo; echo "########## PHASE D: 8 kick-disabled runs (negative control) ##########"
  TAG=kickoff EXTRA_ENV="USBVFIOD_DISABLE_IRQ_KICK=1" RUNROOT="$RUNROOT" \
    "$DIR/acceptance-batch.sh" 8 migrate
fi

if [ "$do_e" = 1 ]; then
  echo; echo "########## PHASE E: 3 naive detach/re-attach baseline runs ##########"
  for i in 1 2 3; do
    "$DIR/stop-demo.sh" >/dev/null 2>&1
    RUN="/root/usb-replug/$i" timeout 500 "$DIR/replug-baseline.sh" > "/root/usb-replug-$i.log" 2>&1
    echo "  baseline run $i rc=$?"
  done
  python3 "$DIR/summarize-replug.py" /root/usb-replug > /root/usb-replug/replug.csv 2>&1
  cat /root/usb-replug/replug.csv
fi

if [ "$do_f" = 1 ]; then
  echo; echo "########## PHASE F: fault-injection suite ##########"
  RUNROOT=/root/usb-inject USBVF="$REPO/target/debug/usbvfiod" \
    "$DIR/injection-suite.sh" 5
fi

echo; echo "########## CAMPAIGN B ($phase) DONE ##########"
for f in "$RUNROOT"/results-*.csv /root/usb-inject/results-*.csv; do
  [ -f "$f" ] && { echo "--- $f"; awk -F, 'NR>1 && $10=="PASS"{p++} NR>1{n++} END{printf "  %d/%d PASS\n", p+0, n+0}' "$f"; }
done
