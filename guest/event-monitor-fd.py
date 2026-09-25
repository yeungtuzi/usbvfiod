#!/usr/bin/env python3
"""Subscribe to Cloud Hypervisor's event stream without a file and without logs.

Cloud Hypervisor's `--event-monitor` accepts `fd=<n>`: it takes ownership of an
already-open descriptor (`File::from_raw_fd`, see
`cloud-hypervisor/src/main.rs`) and writes each event to it as pretty JSON
followed by a blank line (`event_monitor/src/lib.rs`, and the writer loop in
`vmm/src/lib.rs::start_event_monitor_thread`).

That means the launcher can keep the other end of a socketpair and *read events
as they happen*: no log parsing, no polling, no path on the filesystem. This
script demonstrates exactly that, and it is also the tool we would use in the
hand-over controller.

What it does not give you: losslessness. The monitor thread writes with
`write_all(...).ok()` on a non-blocking descriptor, so a reader that stalls can
lose an event (and because the JSON and its separator are two separate writes, a
full socket can even split one). An event consumer must therefore drain
promptly; there is no backpressure and no sequence number.

Usage:
    ./event-monitor-fd.py [seconds] [cloud-hypervisor args...]

With no extra arguments it boots a minimal VM with the guest image this
repository already has, which is enough to see `virtio-device activated` and the
VM lifecycle events arriving live.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import threading
import time

DIR = os.path.dirname(os.path.abspath(__file__))
CH = os.environ.get("CH", "/root/lvllm/cloud-hypervisor/target/release/cloud-hypervisor")
RUN = os.environ.get("RUN", "/root/.dsh-tmp/event-monitor-fd")


def default_vm_args(run: str) -> list[str]:
    return [
        "--memory", "size=512M",
        "--cpus", "boot=1",
        "--kernel", os.path.join(DIR, "casper/vmlinuz"),
        "--initramfs", os.path.join(DIR, "initrd-custom.gz"),
        "--disk", f"path={os.path.join(DIR, 'rootfs.img')},image_type=raw",
        "--serial", f"file={run}/console.log",
        "--console", "off",
        "--cmdline", "root=/dev/vda rw console=ttyS0",
    ]


def main() -> int:
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].replace(".", "", 1).isdigit() else 20.0
    extra = sys.argv[2:] if len(sys.argv) > 1 else []

    os.makedirs(RUN, exist_ok=True)
    api = f"{RUN}/api.sock"
    if os.path.exists(api):
        os.unlink(api)

    # Our end stays here; CH's end is inherited across exec (pass_fds clears
    # CLOEXEC for exactly that descriptor).
    ours, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)

    argv = [CH, "--api-socket", api, "--event-monitor", f"fd={theirs.fileno()}"]
    argv += extra if extra else default_vm_args(RUN)
    print(f"launching: {' '.join(argv)}", flush=True)
    child = subprocess.Popen(argv, pass_fds=(theirs.fileno(),))
    theirs.close()  # CH owns its end now; keeping ours open would hide EOF

    events: list[tuple[float, dict]] = []
    started = time.monotonic()
    stop = threading.Event()

    def reader() -> None:
        buf = b""
        while not stop.is_set():
            try:
                chunk = ours.recv(65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            # One event per pretty-printed JSON object, separated by a blank line.
            while b"\n\n" in buf:
                raw, buf = buf.split(b"\n\n", 1)
                if not raw.strip():
                    continue
                try:
                    event = json.loads(raw.decode("utf-8", "replace"))
                except json.JSONDecodeError:
                    print(f"  (unparsable fragment: {raw[:60]!r})", flush=True)
                    continue
                events.append((time.monotonic() - started, event))
                print(
                    f"  +{events[-1][0]:6.3f}s  {event.get('source'):>14} / "
                    f"{event.get('event')}  {event.get('properties') or ''}",
                    flush=True,
                )

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    print(f"reading events for {seconds:.0f}s (they arrive as CH emits them)", flush=True)
    time.sleep(seconds)
    stop.set()
    child.terminate()
    try:
        child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        child.kill()
    ours.close()
    thread.join(timeout=2)
    if os.path.exists(api):
        os.unlink(api)

    print()
    counts: dict[str, int] = {}
    for _, event in events:
        key = f"{event.get('source')}/{event.get('event')}"
        counts[key] = counts.get(key, 0) + 1
    print(f"events received: {len(events)}")
    for key, count in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {count:4d}  {key}")
    return 0 if events else 1


if __name__ == "__main__":
    sys.exit(main())
