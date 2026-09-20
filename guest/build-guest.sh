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
IMG_MB="${IMG_MB:-4096}"

cd "$WORK"
mkdir -p casper

echo "[1/7] extracting casper files from ISO"
if [ ! -f casper/vmlinuz ] || [ ! -f casper/initrd ] || [ ! -f casper/ubuntu-server-minimal.squashfs ]; then
  7z x -y -o. "$ISO" casper/vmlinuz casper/initrd \
    casper/ubuntu-server-minimal.squashfs casper/ubuntu-server-minimal.manifest >/dev/null
fi
ls -lh casper/

echo "[2/7] unpacking rootfs squashfs"
rm -rf rootfs
unsquashfs -q -d rootfs casper/ubuntu-server-minimal.squashfs >/dev/null

echo "[3/7] grafting kernel modules from initrd"
rm -rf /tmp/ird-graft
unmkinitramfs casper/initrd /tmp/ird-graft >/dev/null 2>&1 || true
SRC="/tmp/ird-graft/main/usr/lib/modules/$KVER"
[ -d "$SRC" ] || { echo "ERROR: module tree $SRC not found"; exit 1; }
mkdir -p "rootfs/usr/lib/modules"
cp -a "$SRC" "rootfs/usr/lib/modules/"
echo "      modules: $(find "rootfs/usr/lib/modules/$KVER" -name '*.ko' | wc -l) .ko files"

echo "[4/7] rebuilding initramfs without the casper hooks"
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

echo "[5/7] guest configuration"
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

# keep the live-only casper unit from failing the boot
rm -f rootfs/etc/systemd/system/multi-user.target.wants/casper-md5check.service 2>/dev/null || true

echo "[6/7] creating ${IMG_MB}MB ext4 image"
rm -f rootfs.img
truncate -s "${IMG_MB}M" rootfs.img
mke2fs -q -t ext4 -F -d rootfs rootfs.img

echo "[7/7] done"
ls -lh rootfs.img initrd-custom.gz
