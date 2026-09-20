#!/usr/bin/env python3
"""Run commands inside the demo guest through Cloud Hypervisor's serial socket.

The guest image enables root autologin on ttyS0, so a shell is already
running on the serial console. This helper connects to CH's serial **socket**
(not `file=`), sends commands one by one and waits for a per-command sentinel
so output can be attributed reliably.

Usage:
  guest-exec.py --sock /run/guest-serial.sock --cmd 'lsblk' --cmd 'mount'
  guest-exec.py --sock /run/guest-serial.sock --cmd-file cmds.txt --log guest.log
  echo 'dmesg | tail' | guest-exec.py --sock ... --stdin

Exit status is 0 if every command's sentinel was observed.
"""
from __future__ import annotations

import argparse
import re
import socket
import sys
import time

ANSI = re.compile(rb"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[=>]|\r")


class Tee:
    """Write bytes to stdout and optionally to a log file."""

    def __init__(self, path: str | None, strip_ansi: bool):
        self.fh = open(path, "ab") if path else None
        self.strip = strip_ansi

    def write(self, data: bytes) -> None:
        if self.fh:
            self.fh.write(data)
            self.fh.flush()
        out = ANSI.sub(b"", data) if self.strip else data
        sys.stdout.buffer.write(out)
        sys.stdout.buffer.flush()

    def close(self) -> None:
        if self.fh:
            self.fh.close()


def recv_until(sock: socket.socket, sentinel: bytes, timeout: float, tee: Tee) -> bool:
    """Read from the console until `sentinel` is seen or the timeout expires."""
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        sock.settimeout(max(0.05, deadline - time.time()))
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
        tee.write(chunk)
        if sentinel in buf:
            return True
    return False


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--sock", required=True, help="CH serial socket path")
    p.add_argument("--cmd", action="append", default=[], help="command to run (repeatable)")
    p.add_argument("--cmd-file", help="file with one command per line (# comments ignored)")
    p.add_argument("--stdin", action="store_true", help="read commands from stdin")
    p.add_argument("--log", help="append raw console bytes to this file")
    p.add_argument("--timeout", type=float, default=60.0, help="per-command timeout in seconds")
    p.add_argument("--keep-ansi", action="store_true", help="do not strip ANSI escapes on stdout")
    args = p.parse_args()

    cmds: list[str] = list(args.cmd)
    if args.cmd_file:
        with open(args.cmd_file) as fh:
            cmds += [ln.rstrip("\n") for ln in fh if ln.strip() and not ln.startswith("#")]
    if args.stdin:
        cmds += [ln.rstrip("\n") for ln in sys.stdin if ln.strip() and not ln.startswith("#")]
    if not cmds:
        p.error("no commands given (use --cmd, --cmd-file or --stdin)")

    tee = Tee(args.log, strip_ansi=not args.keep_ansi)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(args.sock)
    except OSError as exc:
        print(f"ERROR: cannot connect to serial socket {args.sock}: {exc}", file=sys.stderr)
        return 2

    # wake up the idle shell and wait for a prompt
    sock.sendall(b"\n")
    recv_until(sock, b"#", 10.0, tee)

    ok = True
    for i, cmd in enumerate(cmds):
        # The sentinel must not appear literally in the echoed command line,
        # otherwise we would match the echo instead of the command's output.
        # Assembling it from quoted fragments keeps the echo distinct while the
        # executed output is the plain "__RC<i>__<exit-code>".
        out_marker = f"__RC{i}__"
        shell = f'{cmd}; echo "__RC""{i}""__$?"\n'
        sock.sendall(shell.encode())
        if not recv_until(sock, out_marker.encode(), args.timeout, tee):
            print(f"\nERROR: command {i} timed out: {cmd}", file=sys.stderr)
            ok = False
            break

    sock.close()
    tee.close()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
