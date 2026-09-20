# PR: vfio-user: fix inverted RESET capability parsing

Target: `rust-vmm/vfio` (main)
Branch: `<fork-owner>:fix/resettable-flag-parsing`

## Problem

`VFIO_DEVICE_FLAGS_RESET` is set by the server when the device supports reset,
so the client has to test the masked value for equality:

```rust
// vfio-user/src/lib.rs, Client::get_regions()
self.resettable = reply.flags & VFIO_DEVICE_FLAGS_RESET != VFIO_DEVICE_FLAGS_RESET;
```

`!=` inverts the result. A device that advertises reset support is reported as
*not* resettable, and a device that does **not** support reset is reported as
resettable.

## Impact

Observable with usbvfiod, which advertises `resettable = false` (it deliberately
never resets the device, so that a guest does not re-enumerate across a live
migration). Cloud Hypervisor therefore concluded the device *was* resettable and
issued `VFIO_USER_DEVICE_RESET` on every (re)connect - including once per
connection during a live migration:

```
04:32:43.164  destination registers IRQs (#fds: 1)
04:32:43.169  Error handling command: 13: Error from backend:
              Custom { kind: Other, error: "device reset is not supported" }
```

Conversely, a backend that *does* support reset is never asked to reset.

## Change

```rust
self.resettable = reply.flags & VFIO_DEVICE_FLAGS_RESET == VFIO_DEVICE_FLAGS_RESET;
```

## Testing

`cargo test -p vfio_user`: 3 passed.

Verified end-to-end with Cloud Hypervisor `v53.0-520` and usbvfiod: with the
fix, `VFIO_USER_DEVICE_RESET` is no longer sent on connect, and a same-host live
migration of a VM with a passed-through USB stick completes with a 4 ms
downtime and no device reset.

## Note on the repository

`rust-vmm/vfio-user` was archived on 2025-05-19 and its contents moved to
`rust-vmm/vfio`; the crate lives in `vfio-user/` of this repository and is the
`vfio_user 0.1.5` published on crates.io.
