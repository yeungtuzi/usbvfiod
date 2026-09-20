# PR: serve several vfio-user clients so a device survives a live migration

Target: `cyberus-technology/usbvfiod` (main)
Branch: `yeungtuzi:pr/multi-client`

## Problem

A same-host Cloud Hypervisor live migration of a VM with `--user-device
socket=usbvfiod.sock` deadlocks today. The destination VMM connects while the
source VMM is still connected, but `Server::run()` accepts exactly one
connection, so the destination blocks forever in the vfio-user version
handshake and the migration never completes.

Measured with usbvfiod `4d2c5af` and Cloud Hypervisor `v53.0-520`:

- destination log stops at `device_manager.rs:4749 Restoring virtio-pci
  _vfio_user0 resources`, then 199.9 s of zero progress
- usbvfiod receives exactly one client version handshake
- `ss -x` shows `RecvQ=1` on the listening socket: the destination's
  connection is established but never accepted

## Change

The vfio-user handshake commands (`Version`, `DeviceGetInfo`,
`DeviceGetRegionInfo`, `GetIrqInfo`) never reach the backend, while the data
path commands (`RegionRead`, `RegionWrite`, `DmaMap`, `DmaUnmap`, `SetIrqs`,
`DeviceReset`) do. So a second client can complete its handshake as long as the
backend lock is taken **per command** instead of per connection.

- new `src/shared_backend.rs`: `SharedBackendState` owns the backend and hands
  out one `SharedBackend` handle per connection; every `ServerBackend` method
  takes the lock for the duration of that single call
- `--max-clients N` (default 1, preserving today's behaviour exactly): with
  `N > 1`, N threads each run `Server::run()` against a per-connection handle.
  Unlike the single-client path the process stays alive when the last client
  disconnects
- **stale clients must not tear the device down**: after a successful migration
  the *source* VMM shuts its device down and sends `SetIrqs` without fds
  (disable) plus `DmaUnmap` for the regions it owns. Both would land on the
  shared backend after the destination already registered its own interrupts
  and DMA mappings. The wrapper tracks which connection most recently
  registered interrupts and ignores those destructive commands from any other
  connection
- `DynamicBus::add` is now idempotent for the same start address (the
  destination re-maps the same guest memory range), still rejects overlapping
  mappings at a different address, and no longer corrupts the bus when an
  insert fails
- implement `DynamicBus::remove_range` and wire up `dma_unmap`, which Cloud
  Hypervisor calls when it drops a device (was `todo!()`)
- `reset()` answers with an explicit error instead of `todo!()`, and the
  server advertises `resettable = false` so a reconnect never resets the device

## Testing

`cargo test`: 112 passed (3 new `DynamicBus` tests).
`cargo clippy --all-targets -- --deny warnings`: clean.

End-to-end with a real 32 GB USB stick passed through to an Ubuntu 22.04 guest
that copies a 128 MiB file while the VM is live-migrated:

```
migration line       : Migration completed after 0.0s with a downtime of 4ms
COPY_START           : 1789880056.772
COPY_DONE            : 1789880069.733   rc=0
spans migration      : YES (start before, end after)
MD5 VERDICT          : MATCH
enumerations >30s    : 0 (expected: 0 = no re-enumeration after boot)
```

The guest stays alive, the copied file's md5 matches the stick exactly, and
there is no re-enumeration, no reset and no I/O error after the migration.

## Known limitations

- `--max-clients > 1` deliberately keeps the process running after the last
  client disconnects; the historical exit-on-disconnect behaviour is preserved
  for the default `--max-clients 1`
- concurrent clients share one backend, so two VMMs issuing data path commands
  at the same instant would interleave. During a migration the source is paused
  before the destination starts, so the overlap window is empty in practice
- this is a same-host mechanism. Cross-host migration additionally needs a
  vfio-user device-state region and a state import/export path

## Related

The reset semantics above rely on the client parsing
`VFIO_DEVICE_FLAGS_RESET` correctly. The published `vfio_user` 0.1.5 inverts
it; a fix is proposed separately (see the `rust-vmm/vfio` PR).
