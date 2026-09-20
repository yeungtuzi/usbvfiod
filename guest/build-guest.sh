#!/usr/bin/env bash
# Build a bootable Ubuntu 22.04 demo guest disk from the live-server ISO.
#
# The live-server ISO cannot be used as-is with CH direct kernel boot: its
# casper initrd insists on finding a "live file system" medium and ignores
# root=. We therefore:
#   1. extract casper/vmlinuz + casper/initrd + ubuntu-server-minimal.squashfs
#   2. unpack the squashfs into a rootfs
#   3. graft the kernel module tree (it lives in the initrd, NOT in the
#      squashfs — the minimal layer ships an empty /lib/modules)
#   4. rebuild the initrd with the casper hooks removed, so the stock
#      initramfs-tools init honours root=/dev/vda
#   5. configure serial root autologin + a boot report, then pack an ext4 image
#
# Boot with:
#   cloud-hypervisor --kernel casper/vmlinuz --initramfs initrd-custom.gz \
#     --disk path=rootfs.img,image_type=raw --cmdline "root=/dev/vda rw console=ttyS0" \
#     [--user-device socket=/run/usbvfiod.sock]
#
# All artifacts are written next to this script (see .gitignore); only this
# script is tracked in git.
set -euo pipefail

WORK="${WORK:-$(cd "$(dirname "$0")" && pwd)}"
ISO="${ISO:-/var/lib/vz/template/iso/ubuntu-22.04.4-live-server-amd64.iso}"
KVER="${KVER:-5.15.0-94-generic}"
KMOD_VER="${KMOD_VER:-5.15.0-94.104}"
EXTRA_DEB_URL="${EXTRA_DEB_URL:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu/pool/main/l/linux/linux-modules-extra-${KVER}_${KMOD_VER}_amd64.deb}"
IMG_MB="${IMG_MB:-4096}"

cd "$WORK"
mkdir -p casper

echo "[1/8] extracting casper files from ISO"
if [ ! -f casper/vmlinuz ] || [ ! -f casper/initrd ] || [ ! -f casper/ubuntu-server-minimal.squashfs ]; then
  7z x -y -o. "$ISO" casper/vmlinuz casper/initrd \
    casper/ubuntu-server-minimal.squashfs casper/ubuntu-server-minimal.manifest >/dev/null
fi
ls -lh casper/

echo "[2/8] unpacking rootfs squashfs"
rm -rf rootfs
unsquashfs -q -d rootfs casper/ubuntu-server-minimal.squashfs >/dev/null

echo "[3/8] grafting kernel modules from initrd"
rm -rf /tmp/ird-graft
unmkinitramfs casper/initrd /tmp/ird-graft >/dev/null 2>&1 || true
SRC="/tmp/ird-graft/main/usr/lib/modules/$KVER"
[ -d "$SRC" ] || { echo "ERROR: module tree $SRC not found"; exit 1; }
mkdir -p "rootfs/usr/lib/modules"
cp -a "$SRC" "rootfs/usr/lib/modules/"
echo "      modules: $(find "rootfs/usr/lib/modules/$KVER" -name '*.ko' | wc -l) .ko files"

echo "[4/8] merging linux-modules-extra (exfat and other filesystems)"
# The initrd only carries boot-critical modules; USB sticks are usually exfat,
# which lives in linux-modules-extra. Fetch it once and merge it in.
CACHE="$WORK/.cache"
DEB="$CACHE/$(basename "$EXTRA_DEB_URL")"
EXDIR="$CACHE/extra-extract"
mkdir -p "$CACHE"
if [ ! -f "$DEB" ]; then
  curl -sSL --max-time 600 -o "$DEB" "$EXTRA_DEB_URL" || echo "WARNING: could not fetch $EXTRA_DEB_URL"
fi
if [ -f "$DEB" ]; then
  rm -rf "$EXDIR"; mkdir -p "$EXDIR"
  dpkg-deb -x "$DEB" "$EXDIR"
  src="$EXDIR/usr/lib/modules/$KVER"
  [ -d "$src" ] || src="$EXDIR/lib/modules/$KVER"
  cp -a "$src/." "rootfs/usr/lib/modules/$KVER/" 2>/dev/null || true
  depmod -b "$WORK/rootfs" "$KVER" 2>/dev/null || true
  echo "      modules after merge: $(find "rootfs/usr/lib/modules/$KVER" -name '*.ko' | wc -l) .ko files"
else
  echo "      WARNING: linux-modules-extra unavailable; exfat will not mount"
fi

echo "[5/8] rebuilding initramfs without the casper hooks"
rm -rf /tmp/ird-custom
cp -a /tmp/ird-graft/main /tmp/ird-custom
rm -f /tmp/ird-custom/conf/conf.d/casperize.conf \
      /tmp/ird-custom/conf/conf.d/default-boot-to-casper.conf
rm -rf /tmp/ird-custom/scripts/casper \
       /tmp/ird-custom/scripts/casper-bottom \
       /tmp/ird-custom/scripts/casper-premount \
       /tmp/ird-custom/scripts/casper-functions \
       /tmp/ird-custom/scripts/casper-helpers
( cd /tmp/ird-custom && find . -print0 | cpio --null -o -H newc --quiet | gzip -1 ) > initrd-custom.gz
ls -lh initrd-custom.gz

echo "[6/8] guest configuration"
echo demo-guest > rootfs/etc/hostname
mkdir -p rootfs/etc/cloud && touch rootfs/etc/cloud/cloud-init.disabled

# root autologin on the serial console so the demo needs no login
mkdir -p 'rootfs/etc/systemd/system/serial-getty@ttyS0.service.d'
cat > 'rootfs/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf' <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 %I $TERM
Type=idle
EOF

# one-shot boot report to the serial console (harness diagnostics)
mkdir -p rootfs/usr/local/bin
cat > rootfs/usr/local/bin/demo-info.sh <<'EOF'
#!/bin/sh
{
  echo "=== DEMO-INFO BEGIN ==="
  uname -a
  cat /proc/cmdline
  echo "--- modules dir ---"; ls /lib/modules 2>/dev/null
  modprobe usb-storage 2>&1 && echo "modprobe usb-storage: OK" || echo "modprobe usb-storage: FAILED"
  modprobe uas 2>&1 && echo "modprobe uas: OK" || echo "modprobe uas: FAILED (may be absent)"
  echo "--- lsblk ---"; lsblk 2>/dev/null
  echo "--- lspci (usb) ---"; lspci 2>/dev/null | grep -i usb
  echo "--- lsusb ---"; lsusb 2>&1
  echo "--- /dev/sd* ---"; ls -l /dev/sd* 2>/dev/null || echo "(none yet)"
  echo "--- dmesg usb/xhci/sd ---"; dmesg 2>/dev/null | grep -iE 'usb|xhci| sd ' | tail -30
  echo "=== DEMO-INFO END ==="
} > /dev/ttyS0 2>&1
EOF
chmod +x rootfs/usr/local/bin/demo-info.sh
cat > rootfs/etc/systemd/system/demo-info.service <<'EOF'
[Unit]
Description=Demo boot information report
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/demo-info.sh
[Install]
WantedBy=multi-user.target
EOF
mkdir -p rootfs/etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/demo-info.service rootfs/etc/systemd/system/multi-user.target.wants/demo-info.service

# Live-migration demo: copy a large file from the passthrough USB stick to the
# guest disk, so the copy spans the migration.
#
# Everything is written to /root/demo.log first; the serial console is only a
# best-effort mirror. A live migration re-creates the destination's serial
# device, which resets the guest tty - writing progress exclusively to
# /dev/ttyS0 makes the copy appear to stop even though it is still running.
cat > rootfs/usr/local/bin/demo-copy.sh <<'EOF'
#!/bin/sh
LOG=/root/demo.log
: > "$LOG"
say() {
  echo "$*" >> "$LOG"
  echo "$*" > /dev/ttyS0 2>/dev/null || true
}
say "DEMO-COPY: waiting for the USB device"
for _ in $(seq 1 120); do [ -b /dev/sda1 ] && break; sleep 1; done
if [ ! -b /dev/sda1 ]; then say "DEMO-COPY: ERROR no /dev/sda1"; exit 1; fi
mkdir -p /mnt/usb
if ! mount -t exfat -o ro /dev/sda1 /mnt/usb; then
  say "DEMO-COPY: ERROR mount failed"; exit 1
fi
say "DEMO-COPY: SOURCE_READY $(date +%s.%N)"
ls -l /mnt/usb/testfile.bin >> "$LOG" 2>&1 || { say "DEMO-COPY: ERROR no testfile"; exit 1; }
say "DEMO-COPY: COPY_START $(date +%s.%N)"
dd if=/mnt/usb/testfile.bin of=/root/testfile.copy bs=1M status=progress 2>> "$LOG"
say "DEMO-COPY: COPY_DONE $(date +%s.%N) rc=$?"
sync
md5sum /mnt/usb/testfile.bin /root/testfile.copy >> "$LOG" 2>&1
# Kernel view, so that the enumeration/reset verdict can be derived from the
# guest's own log instead of from the (unreliable) serial console.
echo "DEMO-COPY: DMESG_BEGIN" >> "$LOG"
dmesg >> "$LOG" 2>&1
lsusb >> "$LOG" 2>&1
echo "DEMO-COPY: DMESG_END" >> "$LOG"
# Marker last, and synced, so that killing the VM cannot drop the verdict.
echo "DEMO-COPY: MD5_DONE $(date +%s.%N)" >> "$LOG"
sync
echo "DEMO-COPY: MD5_DONE $(date +%s.%N)" > /dev/ttyS0 2>/dev/null || true
EOF
chmod +x rootfs/usr/local/bin/demo-copy.sh
cat > rootfs/etc/systemd/system/demo-copy.service <<'EOF'
[Unit]
Description=USB live-migration copy demo
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/demo-copy.sh
[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/demo-copy.service rootfs/etc/systemd/system/multi-user.target.wants/demo-copy.service

# Heartbeat: proves whether the guest is actually executing after the migration.
# Without it a stalled copy is indistinguishable from a frozen VM.
cat > rootfs/usr/local/bin/demo-heartbeat.sh <<'EOF'
#!/bin/sh
LOG=/root/demo.log
i=0
while true; do
  i=$((i + 1))
  MSG="DEMO-HEARTBEAT $i $(date +%s) uptime=$(cut -d' ' -f1 /proc/uptime)"
  echo "$MSG" >> "$LOG"
  echo "$MSG" > /dev/ttyS0 2>/dev/null || true
  sleep 2
done
EOF
chmod +x rootfs/usr/local/bin/demo-heartbeat.sh
cat > rootfs/etc/systemd/system/demo-heartbeat.service <<'EOF'
[Unit]
Description=Demo heartbeat
After=multi-user.target
[Service]
ExecStart=/usr/local/bin/demo-heartbeat.sh
[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/demo-heartbeat.service rootfs/etc/systemd/system/multi-user.target.wants/demo-heartbeat.service

# keep the live-only casper unit from failing the boot
rm -f rootfs/etc/systemd/system/multi-user.target.wants/casper-md5check.service 2>/dev/null || true

echo "[7/8] creating ${IMG_MB}MB ext4 image"
rm -f rootfs.img
truncate -s "${IMG_MB}M" rootfs.img
mke2fs -q -t ext4 -F -d rootfs rootfs.img

echo "[8/8] done"
ls -lh rootfs.img initrd-custom.gz
