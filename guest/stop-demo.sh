#!/usr/bin/env bash
# Stop any leftover demo processes. Kept in a script so the command line of the
# caller never contains the process pattern being killed: `pkill -f
# cloud-hypervisor` typed into a shell matches that shell's own command line and
# kills the session (this happened twice during the work).
for name in cloud-hypervis usbvfiod; do
  pkill -x "$name" 2>/dev/null
done
sleep 2
shopt -s nullglob
for f in /media/root/*/; do umount "$f" 2>/dev/null; done
for name in cloud-hypervis usbvfiod; do
  n=$(pgrep -c -x "$name" 2>/dev/null || true)
  echo "leftover $name: ${n:-0}"
done
