#!/usr/bin/env python3
"""Run Cloud Hypervisor with the event stream delivered to us over a socketpair.

Cloud Hypervisor's `--event-monitor fd=<n>` takes ownership of an already-open
descriptor and writes every event to it (`File::from_raw_fd` in
`cloud-hypervisor/src/main.rs`). That lets the launcher keep the other end of a
socketpair and receive events as they are emitted, instead of pointing CH at a
file and tailing it.

This wrapper is the drop-in for the harness: it spawns the VMM with `fd=` wired
to a socketpair it owns, and republishes the stream as

  * `<events>`      - the raw pretty JSON, one object per blank-line-separated
                      block, i.e. byte-for-byte what `path=` would have written,
                      so existing analysis keeps working; and
  * `<events>.lines` - `<uptime> <source>/<event> [properties]`, one line per
                      event, flushed immediately, so a shell harness can grep it
                      without racing a block buffer; and
  * `<events>.pid`  - the VMM's pid, because the wrapper is what the shell sees
                      as its child while the interesting process is the VMM.

Usage:
    ch-with-events.py --events PATH -- CLOUD_HYPERVISOR [ARGS...]

Signals (TERM/INT) are forwarded to the VMM, and the wrapper exits with the
VMM's exit status so `wait` keeps meaning what it used to.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--events", required=True, help="raw JSON stream output path")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("no command given; use -- CLOUD_HYPERVISOR [ARGS...]")

    ours, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    raw = open(args.events, "wb", buffering=0)
    lines = open(f"{args.events}.lines", "w", buffering=1)

    argv = [command[0], *command[1:], "--event-monitor", f"fd={theirs.fileno()}"]
    # pass_fds clears CLOEXEC for exactly the descriptor the VMM has to inherit
    child = subprocess.Popen(argv, pass_fds=(theirs.fileno(),))
    theirs.close()
    with open(f"{args.events}.pid", "w") as fh:
        fh.write(f"{child.pid}\n")

    started = time.monotonic()

    def forward(signum: int, _frame: object) -> None:
        try:
            child.send_signal(signum)
        except ProcessLookupError:
            pass

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, forward)

    def reader() -> None:
        buf = b""
        while True:
            try:
                chunk = ours.recv(65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while b"\n\n" in buf:
                block, buf = buf.split(b"\n\n", 1)
                if not block.strip():
                    continue
                raw.write(block + b"\n\n")
                try:
                    event = json.loads(block.decode("utf-8", "replace"))
                except json.JSONDecodeError:
                    lines.write(f"{time.monotonic() - started:9.3f} <unparsable>\n")
                    continue
                props = event.get("properties") or {}
                props = " ".join(f"{k}={v}" for k, v in props.items())
                lines.write(
                    f"{time.monotonic() - started:9.3f} "
                    f"{event.get('source')}/{event.get('event')} {props}\n"
                )
        raw.close()
        lines.close()

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    status = child.wait()
    thread.join(timeout=2)
    return status


if __name__ == "__main__":
    sys.exit(main())
