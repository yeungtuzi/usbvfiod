#!/usr/bin/env bash
# Start/stop the demo guest: usbvfiod (+ optional physical USB device) + Cloud
# Hypervisor with the prebuilt Ubuntu image, exposing the serial console as a
# UNIX socket so it can be driven by guest-exec.py.
#
#   ./demo-guest.sh start [--device /dev/bus/usb/BBB/DDD]
#   ./demo-guest.sh stop
#   ./demo-guest.sh status
#
# Runtime files live in $RUN (default /run/usbvfiod-demo).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
CH="${CH:-/root/lvllm/cloud-hypervisor/target/release/cloud-hypervisor}"
USBVF="${USBVF:-$REPO/target/debug/usbvfiod}"
RUN="${RUN:-/run/usbvfiod-demo}"
MEM="${MEM:-2G}"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

stop_all() {
  for name in ch usbvfiod; do
    if [ -f "$RUN/$name.pid" ]; then
      pid="$(cat "$RUN/$name.pid")"
      if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
      rm -f "$RUN/$name.pid"
    fi
  done
}

case "${1:-}" in
  start)
    shift
    DEVICE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; usage ;;
      esac
    done

    mkdir -p "$RUN"
    stop_all
    rm -f "$RUN"/*.sock

    usb_args=(--socket-path "$RUN/usbvfiod.sock" -v)
    [ -n "$DEVICE" ] && usb_args+=(--device "$DEVICE")
    "$USBVF" "${usb_args[@]}" > "$RUN/usbvfiod.log" 2>&1 &
    echo $! > "$RUN/usbvfiod.pid"
    for _ in $(seq 1 60); do [ -S "$RUN/usbvfiod.sock" ] && break; sleep 0.25; done
    if ! kill -0 "$(cat "$RUN/usbvfiod.pid")" 2>/dev/null; then
      echo "ERROR: usbvfiod exited; see $RUN/usbvfiod.log" >&2
      tail -5 "$RUN/usbvfiod.log" >&2 || true
      exit 1
    fi

    "$CH" --api-socket "$RUN/ch.sock" \
      --memory "size=$MEM,shared=on" --cpus boot=1 \
      --kernel "$DIR/casper/vmlinuz" --initramfs "$DIR/initrd-custom.gz" \
      --disk "path=$DIR/rootfs.img,image_type=raw" \
      --user-device "socket=$RUN/usbvfiod.sock" \
      --serial "socket=$RUN/serial.sock" --console off \
      --cmdline "root=/dev/vda rw console=ttyS0" > "$RUN/ch.log" 2>&1 &
    echo $! > "$RUN/ch.pid"

    for _ in $(seq 1 120); do [ -S "$RUN/serial.sock" ] && break; sleep 0.5; done

    echo "usbvfiod socket : $RUN/usbvfiod.sock"
    echo "ch api socket   : $RUN/ch.sock"
    echo "serial socket   : $RUN/serial.sock"
    [ -n "$DEVICE" ] && echo "passthrough dev : $DEVICE"
    ;;

  stop)
    stop_all
    echo "stopped"
    ;;

  status)
    for name in usbvfiod ch; do
      if [ -f "$RUN/$name.pid" ] && kill -0 "$(cat "$RUN/$name.pid")" 2>/dev/null; then
        echo "$name: running (pid $(cat "$RUN/$name.pid"))"
      else
        echo "$name: not running"
      fi
    done
    ;;

  *) usage ;;
esac
