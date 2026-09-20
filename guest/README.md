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

## Live-migration demo

`usb-migration-demo.sh` runs the whole scenario: usbvfiod claims the stick, the
guest copies `testfile.bin` from it, the VM is live-migrated mid-copy, and the
copied file is verified against the source.

```console
$ dd if=/dev/urandom of=<stick>/testfile.bin bs=1M count=128   # once
$ md5sum <stick>/testfile.bin > testfile.md5                    # once
$ DEVICE=/dev/bus/usb/001/007 ./usb-migration-demo.sh
```

A successful run ends with:

```
migration line       : Migration completed after 0.0s with a downtime of 4ms
spans migration      : YES (start before, end after)
MD5 VERDICT          : MATCH
enumerations >30s    : 0 (expected: 0 = no re-enumeration after boot)
(no resets / no I/O errors)
```

### How the result is measured

The guest writes everything to `/root/demo.log` and only mirrors it to the
serial console, because a migration re-creates the destination's serial device
and therefore resets the guest tty. The authoritative check is done by mounting
`rootfs.img` and reading that log; the mount has to be read-write so ext4 can
replay its journal, otherwise the newest guest writes are invisible. The console
is captured through a FIFO (`fifo-capture.py`), because CH opens
`--serial file=` with `File::create()`, which would truncate the pre-migration
output when the destination VMM starts.

## Verified

- 2026-09-20 — boots to a root shell (kernel `5.15.0-94-generic`).
- With usbvfiod attached via `--user-device`, the guest enumerates the virtual
  controller (`xhci_hcd 0000:00:03.0`) and `lsusb` lists both root hubs
  (`1d6b:0002` Bus 001 / `1d6b:0003` Bus 002).
- Real hardware passthrough: a 32 GB exfat USB stick on `/dev/bus/usb/001/007`
  is claimed by usbvfiod, appears in the guest as `/dev/sda`, and mounts:
  `mount -t exfat -o ro /dev/sda1 /mnt/usb` → `MOUNT_OK` (29.7 GB visible).
- **Live migration, 4/4 runs**: 128 MiB copied from the stick while the VM was
  migrated; the copy spans the migration, `md5` matches the source exactly, the
  guest stays alive, and there are no resets, no I/O errors and no
  re-enumeration after boot. Measured downtime 4–16 ms.

### exfat note

The initrd only ships boot-critical modules, so the minimal rootfs had **no
`exfat`** and the stick could not be mounted. `build-guest.sh` now fetches
`linux-modules-extra-<kver>` and merges it (1561 → 5394 modules), which also
brings ntfs/f2fs/btrfs and friends.

### Known remaining guest-visible disturbance

The migration makes the guest reprint its login banner: the destination
re-creates the serial device, which resets the guest tty. That is a Cloud
Hypervisor serial-device behaviour, unrelated to the USB path; a fully
zero-perception demo would need CH to preserve the serial device instance.

## Files

| file | tracked | purpose |
|---|---|---|
| `build-guest.sh` | yes | build `rootfs.img` + `initrd-custom.gz` from the ISO |
| `demo-guest.sh` | yes | start/stop usbvfiod + CH, expose the serial socket |
| `guest-exec.py` | yes | run commands in the guest over the serial socket |
| `usb-migration-demo.sh` | yes | end-to-end USB live-migration demo + verdict |
| `fifo-capture.py` | yes | FIFO console capture that survives the hand-over |
| `testfile.md5` | yes | expected md5 of the stick's `testfile.bin` |
| `README.md`, `.gitignore` | yes | this file / ignore rules |
| `casper/`, `rootfs/`, `rootfs.img`, `initrd-custom.gz`, `.cache/` | no | artifacts (multi-GB) |
