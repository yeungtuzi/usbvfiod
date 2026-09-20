#!/usr/bin/env bash
# Add the batch-level files to an existing archive and regenerate its derived
# files. collect-artifacts.sh copies run directories; the per-arm CSVs and the
# harness stdout logs live in the batch root, and without them the attachment
# cannot regenerate paper/data/results.tex with update-results.py --batch.
#
#   ./finalize-archive.sh <source-batch-dir> <archive-dir>
set -uo pipefail
SRC="${1:?usage: finalize-archive.sh <src> <archive>}"
DEST="${2:?usage: finalize-archive.sh <src> <archive>}"
DIR="$(cd "$(dirname "$0")" && pwd)"

[ -d "$DEST" ] || { echo "no archive at $DEST" >&2; exit 1; }

n=0
while IFS= read -r f; do
  cp -f "$f" "$DEST/" && n=$((n + 1))
done < <(find "$SRC" -maxdepth 1 -type f \
           \( -name 'results-*.csv' -o -name 'summary.csv' -o -name '*.log' \
              -o -name 'replug.csv' \) 2>/dev/null)
echo "added $n batch-level file(s) to $DEST"

python3 "$DIR/make-manifest.py" "$DEST"
python3 "$DIR/analyze-handover-exposure.py" "$DEST"/*/usbvfiod.log \
  > "$DEST/handover-exposure.txt" 2>/dev/null || true
(
  cd "$DEST" || exit 1
  find . -type f ! -name 'SHA256SUMS' ! -name 'MANIFEST.md' -print0 \
    | sort -z | xargs -0 sha256sum > SHA256SUMS 2>/dev/null
)
echo "regenerated SHA256SUMS ($(wc -l < "$DEST/SHA256SUMS") files)"
