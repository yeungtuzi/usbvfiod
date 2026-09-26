#!/usr/bin/env bash
# Print (or apply) the GitHub attribution this project uses everywhere.
#
#   scripts/git-identity.sh                 # print the two trailers
#   scripts/git-identity.sh --trailers      # same, explicitly
#   scripts/git-identity.sh --configure     # set user.name/user.email in this repo
#   scripts/git-identity.sh --check [REV]   # verify REV (default HEAD) carries them
#
# The rule, and the reasoning behind it, live in docs/github-attribution_cn.md:
# every external GitHub signature uses the same two lines, whether or not the
# target project asks for them.
set -euo pipefail

NAME="BigHippo"
EMAIL="dahema@me.com"
ASSISTED="DeepSeek:deepseek-flash"

case "${1:---trailers}" in
  --trailers|"")
    printf 'Signed-off-by: %s <%s>\n' "$NAME" "$EMAIL"
    printf 'Assisted-by: %s\n' "$ASSISTED"
    ;;
  --configure)
    repo="${2:-.}"
    git -C "$repo" config user.name "$NAME"
    git -C "$repo" config user.email "$EMAIL"
    printf 'configured %s: user.name=%s user.email=%s\n' \
      "$(git -C "$repo" rev-parse --show-toplevel)" "$NAME" "$EMAIL"
    ;;
  --check)
    rev="${2:-HEAD}"
    message="$(git log -1 --format=%B "$rev")"
    rc=0
    if ! grep -qF "Signed-off-by: $NAME <$EMAIL>" <<<"$message"; then
      printf 'missing: Signed-off-by: %s <%s>\n' "$NAME" "$EMAIL" >&2
      rc=1
    fi
    if ! grep -qF "Assisted-by: $ASSISTED" <<<"$message"; then
      printf 'missing: Assisted-by: %s\n' "$ASSISTED" >&2
      rc=1
    fi
    if [ "$rc" = 0 ]; then
      printf '%s: attribution OK\n' "$(git rev-parse --short "$rev")"
    fi
    exit "$rc"
    ;;
  *)
    printf 'usage: %s [--trailers|--configure [REPO]|--check [REV]]\n' "$0" >&2
    exit 2
    ;;
esac
