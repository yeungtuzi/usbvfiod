#!/usr/bin/env bash
# Archive a batch's raw run artefacts, with a manifest and per-file checksums.
#
#   ./collect-artifacts.sh <source-dir> <archive-name>
#
# Every run directory produced by usb-migration-demo.sh is copied verbatim:
# the guest's own log, the serial console capture, both VMM logs, the vfio-user
# server log with per-transfer tracing, the USB packet capture and the migration
# bookkeeping. Nothing is filtered, so a reviewer can re-derive every number in
# the paper from these files.
set -uo pipefail

SRC="${1:?usage: collect-artifacts.sh <source-dir> <archive-name>}"
NAME="${2:?usage: collect-artifacts.sh <source-dir> <archive-name>}"
DEST="${DEST:-/root/lvllm/usbvfiod/artifacts}/$NAME"

mkdir -p "$DEST"
echo "collecting $SRC -> $DEST"

n=0
for d in "$SRC"/*/; do
  [ -d "$d" ] || continue
  run="$(basename "$d")"
  mkdir -p "$DEST/$run"
  # copy everything except the FIFO and the (empty) lock files
  find "$d" -maxdepth 1 -type f \
       ! -name '*.fifo' ! -name '*.sock' ! -name '*.lock' \
       -exec cp -f {} "$DEST/$run/" \; 2>/dev/null
  n=$((n+1))
done
echo "copied $n run directories"

# Batch-level files as well: the per-arm CSVs (results-<tag>.csv, summary.csv),
# the harness stdout logs (<tag>-<n>.log) and any arm-specific CSV. Without these
# the attachment cannot regenerate paper/data/results.tex with update-results.py
# --batch, which is the whole point of shipping it.
m=0
while IFS= read -r f; do
  cp -f "$f" "$DEST/" && m=$((m+1))
done < <(find "$SRC" -maxdepth 1 -type f \
           \( -name 'results-*.csv' -o -name 'summary.csv' -o -name '*.log' \
              -o -name 'replug.csv' \) 2>/dev/null)
echo "copied $m batch-level files (CSVs / harness logs)"

# per-file checksums of the text evidence (pcaps are checksummed too, but the
# manifest keeps the sizes so a reader can see what is large)
(
  cd "$DEST" || exit 1
  find . -type f ! -name 'SHA256SUMS' ! -name 'MANIFEST.md' -print0 \
    | sort -z | xargs -0 sha256sum > SHA256SUMS 2>/dev/null
)
echo "wrote SHA256SUMS ($(wc -l < "$DEST/SHA256SUMS") files)"

# hand-over exposure: how many completions were at risk in each run
python3 "$(dirname "$0")/analyze-handover-exposure.py" "$DEST"/*/usbvfiod.log \
  > "$DEST/handover-exposure.txt" 2>/dev/null || true
echo "wrote handover-exposure.txt"

# manifest: per-run metrics re-derived from the archived run directories
# themselves, using the same verdict code as the paper (guest/make-manifest.py).
python3 "$(dirname "$0")/make-manifest.py" "$DEST"

du -sh "$DEST"
