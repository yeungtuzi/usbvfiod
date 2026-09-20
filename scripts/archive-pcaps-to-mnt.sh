#!/usr/bin/env bash
# Move the raw USB packet captures onto the big network mount.
#
#   ./archive-pcaps-to-mnt.sh [--clean-tmp] [DEST]
#
# The packet captures are ~145 MB per run and dominate both the repository
# artefact directory and the live batch directories; the text logs next to them
# are what every number in the paper is re-derived from. This keeps exactly one
# copy of every capture on the network share and removes them from the root disk.
#
# The archive tree and the live batch directories contain the *same* captures
# (the archives were copied from them), so a plain move would leave two copies
# and free nothing. Captures under artifacts/ are moved first and indexed by run
# name; a live capture whose run name and size match an indexed one is deleted
# rather than copied, and anything unrecognised is copied to live/ instead of
# being dropped.
#
# Safety:
#   * Every access to DEST is wrapped in `timeout`. The share is served by a VM
#     that can be down or wedged, and a plain stat/cp into a hung CIFS mount
#     sleeps uninterruptibly.
#   * DEST must be a different filesystem from every source.
#   * A source file is removed only after its destination copy exists non-empty.
set -uo pipefail
export TMPDIR="${TMPDIR:-/root/.dsh-tmp}"
mkdir -p "$TMPDIR"

CLEAN_TMP=0
if [ "${1:-}" = "--clean-tmp" ]; then
  CLEAN_TMP=1
  shift
fi
DEST="${1:-/mnt/mt/usbvfiod-artifacts}"
REACH_S="${REACH_S:-10}"
ARCHIVE=/root/lvllm/usbvfiod/artifacts
LIVE=(/root/usb-runs /root/usb-inject /root/usb-replug)

# --- optionally free the tmpfs that DSH needs for its scratch ---------------
if [ "$CLEAN_TMP" = 1 ]; then
  echo "== /tmp before =="; du -xsh /tmp/* 2>/dev/null | sort -h | tail -10
  find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
  sync
  echo "== /tmp after =="; df -h /tmp | tail -1
fi

probe() { timeout "$REACH_S" stat "$1" >/dev/null 2>&1; }
mount_of() { timeout "$REACH_S" df --output=target "$1" 2>/dev/null | tail -1; }

if ! probe "$DEST"; then
  if ! timeout "$REACH_S" mkdir -p "$DEST" 2>/dev/null; then
    echo "ERROR: cannot create $DEST (share down or unwritable); nothing done." >&2
    exit 3
  fi
  probe "$DEST" || { echo "ERROR: $DEST unreachable within ${REACH_S}s; nothing done." >&2; exit 3; }
fi

dest_mnt="$(mount_of "$DEST")"
[ -n "$dest_mnt" ] || { echo "ERROR: cannot determine the mount of $DEST" >&2; exit 3; }
for src in "$ARCHIVE" "${LIVE[@]}"; do
  [ -d "$src" ] || continue
  if [ "$(mount_of "$src")" = "$dest_mnt" ]; then
    echo "ERROR: $src and $DEST are both on $dest_mnt; moving would not free space." >&2
    case "$DEST" in
      /mnt/*)
        parent="/mnt/$(echo "${DEST#/mnt/}" | cut -d/ -f1)"
        if grep -q " $parent " /proc/mounts; then
          echo "       $parent is mounted, but $DEST still resolves to $dest_mnt." >&2
        else
          echo "       $parent is not in /proc/mounts, i.e. the share is not mounted" >&2
          echo "       and $DEST is a plain directory on the root filesystem." >&2
          echo "       Mount the share first, then re-run." >&2
        fi
        ;;
    esac
    exit 3
  fi
done

# --- phase 1: the canonical archive tree ------------------------------------
declare -A SIZE_OF_RUN=()
declare -A HASH_OF_RUN=()
copied=0; bytes=0
while IFS= read -r pcap; do
  rel="${pcap#"$ARCHIVE"/}"            # <batch>/<run>/usb.pcap
  run="${rel%%/*}"; rest="${rel#*/}"; run="${rest%%/*}"
  out="$DEST/$rel"
  timeout "$REACH_S" mkdir -p "$(dirname "$out")"
  if [ ! -s "$out" ]; then
    if ! timeout 900 cp -f "$pcap" "$out" || [ ! -s "$out" ]; then
      echo "  ! copy failed, keeping source: $pcap" >&2; continue
    fi
    bytes=$((bytes + $(stat -c %s "$pcap")))
  fi
  SIZE_OF_RUN["$run"]="$(stat -c %s "$pcap")"
  HASH_OF_RUN["$run"]="$(sha256sum "$pcap" | cut -d' ' -f1)"
  rm -f "$pcap"
  copied=$((copied + 1)); printf '.'
done < <(find "$ARCHIVE" -type f -name '*.pcap' 2>/dev/null)
echo; echo "archive captures moved: $copied (${bytes} bytes)"

# --- phase 2: live dirs, de-duplicated against phase 1 ----------------------
dedup=0; extra=0
for src in "${LIVE[@]}"; do
  [ -d "$src" ] || continue
  tag="$(basename "$src")"
  while IFS= read -r pcap; do
    run="$(basename "$(dirname "$pcap")")"
    sz="$(stat -c %s "$pcap")"
    if [ "${SIZE_OF_RUN[$run]:-}" = "$sz" ] && [ -n "${HASH_OF_RUN[$run]:-}" ]; then
      # same run name and size as an archived capture: verify the digest before
      # deleting, so a name collision or a re-run cannot lose unique data
      if [ "$(sha256sum "$pcap" | cut -d' ' -f1)" = "${HASH_OF_RUN[$run]}" ]; then
        rm -f "$pcap"; dedup=$((dedup + 1)); printf 'd'; continue
      fi
    fi
    out="$DEST/live/$tag/$run/usb.pcap"
    timeout "$REACH_S" mkdir -p "$(dirname "$out")"
    if [ ! -s "$out" ] && { ! timeout 900 cp -f "$pcap" "$out" || [ ! -s "$out" ]; }; then
      echo "  ! copy failed, keeping source: $pcap" >&2; continue
    fi
    HASH_OF_RUN["$run"]="$(sha256sum "$pcap" | cut -d' ' -f1)"
    rm -f "$pcap"; extra=$((extra + 1)); printf '+'
  done < <(find "$src" -type f -name '*.pcap' 2>/dev/null)
done
echo; echo "live captures de-duplicated: $dedup, unique copies added: $extra"

# --- checksums at the destination ------------------------------------------
if probe "$DEST" && timeout 60 bash -c "cd '$DEST'" 2>/dev/null; then
  ( cd "$DEST" && find . -type f -name '*.pcap' -print0 | sort -z \
      | xargs -0 sha256sum > SHA256SUMS-pcap 2>/dev/null )
  echo "wrote $DEST/SHA256SUMS-pcap ($(wc -l < "$DEST/SHA256SUMS-pcap") files)"
fi

# --- regenerate per-batch checksums, drop a pointer to the captures ---------
regen() {
  local d="$1"
  [ -f "$d/SHA256SUMS" ] || return 0
  ( cd "$d" && find . -type f ! -name 'SHA256SUMS' ! -name 'MANIFEST.md' -print0 \
      | sort -z | xargs -0 sha256sum > SHA256SUMS 2>/dev/null )
  echo "regenerated $d/SHA256SUMS"
}
for batch in "$ARCHIVE"/*/; do
  [ -d "$batch" ] || continue
  regen "$batch"
  cat > "$batch/PCAPS.md" <<EOF
# Packet captures

The USB packet captures (\`usb.pcap\`, ~145 MB per run) for this batch are stored
on the network share, not here:

    $DEST/$(basename "$batch")/

Their checksums are in \`$DEST/SHA256SUMS-pcap\`. Everything else here — the
guest log, the console capture, both VMM logs, the vfio-user server log and the
migration bookkeeping — is unchanged, and those text files are what the paper's
numbers are re-derived from.
EOF
done
echo "wrote PCAPS.md into each batch directory"

echo
timeout 60 du -xsh "$DEST" 2>/dev/null
df -h / /tmp 2>/dev/null | sed -n '1p;/\/$/p;/tmp/p'
