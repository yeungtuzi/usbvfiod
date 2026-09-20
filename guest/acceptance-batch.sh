#!/usr/bin/env bash
# Run a batch of demo iterations and emit a CSV summary plus a pass-rate
# confidence interval.
#
#   ./acceptance-batch.sh [N] [control|migrate]
#
#   N        number of iterations (default 20)
#   mode     migrate (default) runs the full demo; control skips the migration
#
# Environment:
#   USBVF    override the server binary (e.g. the release build)
#   TAG      label written into the CSV (e.g. "debug", "release", "control")
#   RUNROOT  directory for the per-run artefacts (default /run/usb-batch)
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
N="${1:-20}"
MODE="${2:-migrate}"
TAG="${TAG:-$MODE}"
RUNROOT="${RUNROOT:-/run/usb-batch}"
CSV="$RUNROOT/results-$TAG.csv"
mkdir -p "$RUNROOT"

echo "run,downtime_ms,copy_s,spans,md5,late_enum,late_err,kicks,stale_teardown,rc" > "$CSV"

pass=0
for i in $(seq 1 "$N"); do
  out="$RUNROOT/$TAG-$i.log"
  (
    export RUN="$RUNROOT/$TAG-$i"
    if [ "$MODE" = control ]; then SKIP_MIGRATION=1; export SKIP_MIGRATION; fi
    [ -n "${USBVF:-}" ] && export USBVF
    timeout 400 ./usb-migration-demo.sh
  ) > "$out" 2>&1
  rc=$?

  dt=$(grep -aoE 'downtime of [0-9]+ms' "$out" | grep -aoE '[0-9]+' | head -1)
  copy=$(grep -aE '^copy duration' "$out" | awk '{print $3}')
  spans=$(grep -aE '^spans migration' "$out" | awk '{print $3}')
  md5=$(grep -aE '^md5 verdict' "$out" | awk '{print $3}')
  le=$(grep -aE '^enumerations after migration' "$out" | awk '{print $4}')
  lr=$(grep -aE '^reset/error lines after migr' "$out" | awk '{print $5}')
  kicks=$(grep -aE '^interrupt lines installed' "$out" | awk '{print $4}')
  stale=$(grep -aE '^stale teardowns ignored' "$out" | awk '{print $4}')

  if [ "$MODE" = control ]; then
    # a control run has no migration: only the copy result matters
    c=$(grep -aE '^md5 \(copy\)' "$out" | awk '{print $4}')
    e=$(grep -aE '^expected' "$out" | awk '{print $2}')
    [ -n "$c" ] && [ "$c" = "$e" ] && rc=0 || rc=1
    spans="n/a"
  fi

  echo "$i,${dt:-},${copy:-},${spans:-},${md5:-},${le:-},${lr:-},${kicks:-},${stale:-},$rc" >> "$CSV"
  [ "$rc" = 0 ] && pass=$((pass+1))
  echo "  run $i/$N rc=$rc downtime=${dt:-?}ms copy=${copy:-?}s spans=${spans:-?} md5=${md5:-?} late_enum=${le:-?} late_err=${lr:-?} kicks=${kicks:-?} stale=${stale:-?}"
done

echo
echo "=== $TAG: $pass / $N passed ==="
python3 - "$pass" "$N" <<'PY'
import sys
from math import comb
k, n = int(sys.argv[1]), int(sys.argv[2])
# Clopper-Pearson 95% interval via the Beta quantile expressed as a sum.
def beta_cdf(x, a, b):
    # regularised incomplete beta via continued fraction (Lentz), enough here
    if x <= 0: return 0.0
    if x >= 1: return 1.0
    lbeta = __import__('math').lgamma(a)+__import__('math').lgamma(b)-__import__('math').lgamma(a+b)
    front = __import__('math').exp(__import__('math').lgamma(a+b)-__import__('math').lgamma(a)-__import__('math').lgamma(b)+a*__import__('math').log(x)+b*__import__('math').log(1-x))
    f, c, d = 1.0, 1.0, 0.0
    for i in range(0, 200):
        m = i//2
        if i == 0: num = 1.0
        elif i % 2 == 0: num = (m*(b-m)*x)/((a+2*m-1)*(a+2*m))
        else: num = -((a+m)*(a+b+m)*x)/((a+2*m)*(a+2*m+1))
        d = 1.0 + num*d
        if abs(d) < 1e-30: d = 1e-30
        d = 1.0/d
        c = 1.0 + num/c
        if abs(c) < 1e-30: c = 1e-30
        f *= c*d
        if abs(1.0-c*d) < 1e-12: break
    return front*f/a
def bisect(p, a, b, lo=0.0, hi=1.0):
    for _ in range(80):
        mid = (lo+hi)/2
        if beta_cdf(mid, a, b) < p: lo = mid
        else: hi = mid
    return (lo+hi)/2
if n == 0:
    print("no runs"); sys.exit()
lo = 0.0 if k == 0 else bisect(0.025, k, n-k+1)
hi = 1.0 if k == n else bisect(0.975, k+1, n-k)
print(f"pass proportion      : {k}/{n} = {k/n:.3f}")
print(f"95% Clopper-Pearson  : [{lo:.3f}, {hi:.3f}]")
if k == n:
    print(f"upper bound on failure rate (rule of three): <= {3/n:.3f}")
PY
echo "csv: $CSV"
