# Demo guest image (Ubuntu 22.04.4 LTS)

Builds a bootable ext4 disk + a custom initramfs from the Ubuntu
live-server ISO so Cloud Hypervisor can boot it with **direct kernel boot**.

## Why not boot the ISO as-is

CH direct kernel boot of `casper/vmlinuz` + `casper/initrd` fails with
`Unable to find a medium containing a live file system`: casper hijacks the
boot via `conf/conf.d/casperize.conf` and `conf/conf.d/default-boot-to-casper.conf`
and ignores `root=`. Also, the minimal squashfs ships an **empty
`/lib/modules`** — the module tree lives in the initrd, so `usb-storage`/`uas`
cannot be loaded after switching root.

`build-guest.sh` addresses both: it grafts the initrd's module tree into the
rootfs and rebuilds the initrd with the casper hooks removed.

## Build

Dependencies: `7z`, `unsquashfs` (`squashfs-tools`), `unmkinitramfs`
(`initramfs-tools-core`).

```console
$ ISO=/var/lib/vz/template/iso/ubuntu-22.04.4-live-server-amd64.iso ./build-guest.sh
```

Artifacts (all gitignored, see `.gitignore`): `casper/`, `rootfs/`,
`rootfs.img`, `initrd-custom.gz`.

## Boot

```console
$ cloud-hypervisor --api-socket /run/guest.sock \
    --memory size=2G,shared=on --cpus boot=1 \
    --kernel casper/vmlinuz --initramfs initrd-custom.gz \
    --disk path=$PWD/rootfs.img,image_type=raw \
    [--user-device socket=/run/usbvfiod.sock] \
    --serial file=$PWD/console.log --console off \
    --cmdline "root=/dev/vda rw console=ttyS0"
```

`shared=on` is mandatory when `--user-device` is used
(`UserDevicesRequireSharedMemory`), and it is also the precondition for
`memory_mode=memfds` migration.

The guest gives root autologin on `ttyS0`; `dmesg`, `lsusb`, `mount`,
`md5sum` are available and `usb-storage`/`uas` load.

## Driving the guest

`demo-guest.sh` starts/stops usbvfiod + CH and exposes the serial console as a
UNIX socket; `guest-exec.py` sends commands to it and waits for a per-command
sentinel, so results can be scripted instead of typed.

```console
$ ./demo-guest.sh start --device /dev/bus/usb/001/007
$ ./guest-exec.py --sock /run/usbvfiod-demo/serial.sock \
    --cmd 'lsblk' --cmd 'mount -t exfat -o ro /dev/sda1 /mnt/usb && ls /mnt/usb'
$ ./demo-guest.sh stop
```

## Verified

- 2026-09-20 — boots to a root shell (kernel `5.15.0-94-generic`).
- With usbvfiod attached via `--user-device`, the guest enumerates the virtual
  controller (`xhci_hcd 0000:00:03.0`) and `lsusb` lists both root hubs
  (`1d6b:0002` Bus 001 / `1d6b:0003` Bus 002).
- Real hardware passthrough: a 32 GB exfat USB stick on `/dev/bus/usb/001/007`
  is claimed by usbvfiod, appears in the guest as `/dev/sda`, and mounts:
  `mount -t exfat -o ro /dev/sda1 /mnt/usb` → `MOUNT_OK` (29.7 GB visible).
- A 1 GiB `testfile.bin` (md5 `0fc3e7df554fcfd9165d70586ef45bb6`) is written to
  the stick from the guest and is the copy source for the migration demo.

### exfat note

The initrd only ships boot-critical modules, so the minimal rootfs had **no
`exfat`** and the stick could not be mounted. `build-guest.sh` now fetches
`linux-modules-extra-<kver>` and merges it (1561 → 5394 modules), which also
brings ntfs/f2fs/btrfs and friends.

## Files

| file | tracked | purpose |
|---|---|---|
| `build-guest.sh` | yes | build `rootfs.img` + `initrd-custom.gz` from the ISO |
| `demo-guest.sh` | yes | start/stop usbvfiod + CH, expose the serial socket |
| `guest-exec.py` | yes | run commands in the guest over the serial socket |
| `README.md`, `.gitignore` | yes | this file / ignore rules |
| `casper/`, `rootfs/`, `rootfs.img`, `initrd-custom.gz`, `.cache/` | no | artifacts (multi-GB) |
