#!/usr/bin/env bash
# Build the double-blind submission snapshot.
#
# `git archive` exports the tracked tree and nothing else, so the tarball has no
# .git directory: the repository's own metadata (origin URL, commit authorship,
# and the pre-redaction history of the files whose contents were scrubbed) would
# otherwise identify the authors even though every tracked file is clean.
#
#   ./make-anonymous-snapshot.sh [output.tar.gz]
#
# The script verifies with docs/redact-identifiers.py before writing anything,
# so a snapshot cannot be produced from a tree that still leaks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/usbvfiod-anonymous.tar.gz}"

echo "checking tracked files for identifying strings"
python3 "$ROOT/docs/redact-identifiers.py"

echo "exporting the tracked tree (no .git)"
git -C "$ROOT" archive --format=tar.gz --prefix=usbvfiod/ -o "$OUT" HEAD

echo "wrote $OUT"
sha256sum "$OUT"
echo
echo "This snapshot contains no .git directory. It also does not contain the raw"
echo "run artefacts (they are large binary logs delivered separately) nor the"
echo "gitignored guest image; see paper/README.md for what a reproducer must"
echo "supply."
