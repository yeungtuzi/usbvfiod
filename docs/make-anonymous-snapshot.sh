#!/usr/bin/env bash
# Build the double-blind submission snapshot.
#
#   ./make-anonymous-snapshot.sh [output.tar.gz]
#
# The snapshot must not identify the authors in any layer. Three layers matter:
#
#   1. tracked file contents and paths - checked by redact-identifiers.py;
#   2. repository metadata (origins, commit authors) - excluded by exporting the
#      tracked tree with no .git;
#   3. archive metadata. `git archive` writes a pax_global_header containing
#      `comment=<commit id>`, and that commit id resolves to the public fork
#      through any hosting site, i.e. it links the artefact to the account. The
#      tree is therefore re-packed as an ordinary gnu tar with a fixed mtime and
#      numeric ownership, and the commit id is asserted to be gone.
#
# The checker is run on the *extracted archive*, not only on the worktree, so a
# mismatch between the worktree and what was shipped cannot slip through.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/usbvfiod-anonymous.tar.gz}"
WORK="$(mktemp -d "$ROOT/.anon-snapshot.XXXXXX")"
EXTRACT=""
cleanup() { rm -rf "$WORK" "$EXTRACT"; }
trap cleanup EXIT

# Refuse to ship a tree that differs from HEAD: otherwise the checker would
# inspect the worktree while the archive carries HEAD.
if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
  echo "ERROR: the working tree has uncommitted changes; commit or stash first," >&2
  echo "       so that what is checked is what is archived." >&2
  exit 1
fi

echo "checking tracked files for identifying strings"
python3 "$ROOT/docs/redact-identifiers.py" --selftest

echo "exporting the tracked tree"
git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$WORK"

echo "re-packing without the commit id or host metadata"
tar --format=gnu --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime='@0' -C "$WORK" -cf - . | gzip -n > "$OUT"

commit_id="$(gzip -dc "$OUT" | git get-tar-commit-id 2>/dev/null || true)"
if [ -n "$commit_id" ]; then
  echo "ERROR: the archive still carries a commit id ($commit_id); refusing to finish" >&2
  rm -f "$OUT"
  exit 1
fi

# Verify the shipped artefact itself, from both cwds
EXTRACT="$(mktemp -d "$ROOT/.anon-extract.XXXXXX")"
tar -xzf "$OUT" -C "$EXTRACT"
( cd "$EXTRACT" && python3 docs/redact-identifiers.py --selftest )
( cd "$EXTRACT/docs" && python3 redact-identifiers.py )

echo "wrote $OUT"
sha256sum "$OUT"
echo
echo "No .git and no commit id. This still does not contain the raw run artefacts"
echo "(large binary logs delivered separately) nor the gitignored guest image;"
echo "see paper/README.md for what a reproducer must supply."
