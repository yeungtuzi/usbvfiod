#!/usr/bin/env bash
# Copy every round-3 raw log into artifacts/ with checksums and a manifest.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
A="${A:-$(cd "$DIR/.." && pwd)/artifacts}"
"$DIR/collect-artifacts.sh" /root/usb-runs       campaign-B-acceptance
"$DIR/collect-artifacts.sh" /root/usb-inject     injection-round3
"$DIR/collect-artifacts.sh" /root/usb-replug     replug-baseline
"$DIR/collect-artifacts.sh" /root/usb-runs-accidental-trigger accidental-trigger
cp -f /root/usb-runs-accidental-trigger/README.md "$A/accidental-trigger/README.md" 2>/dev/null
python3 "$DIR/summarize-injection.py" /root/usb-inject > "$A/injection-round3/injection-summary.csv" 2>&1
cp -f /root/usb-replug/replug.csv "$A/replug-baseline/replug.csv" 2>/dev/null
# re-derive the per-run replug and injection summaries into the archives
python3 "$DIR/summarize-replug.py" /root/usb-replug > "$A/replug-baseline/replug-recomputed.csv" 2>&1
du -sh "$A"/* | sort -h
echo ARCHIVE-DONE
