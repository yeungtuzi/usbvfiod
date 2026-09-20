#!/usr/bin/env python3
"""Capture a FIFO to a log file without ever hitting EOF.

Cloud Hypervisor opens its `--serial file=<path>` target with `File::create()`,
which truncates a regular file. During a live migration the destination VMM
therefore wipes the console output produced before the migration, so a plain
file cannot be used to prove continuity.

A FIFO is not truncated (O_TRUNC has no effect on it), but a plain `cat` exits
as soon as the last writer closes - and there is a window during the hand-over
where the source has exited and the destination has not opened the file yet.
Opening the FIFO with O_RDWR keeps a write end open inside this process, so the
reader never observes EOF and no writer ever blocks on open().

Usage: fifo-capture.py <fifo> <logfile>
"""
from __future__ import annotations

import os
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    fifo, logfile = sys.argv[1], sys.argv[2]
    fd = os.open(fifo, os.O_RDWR)

    with open(logfile, "ab", buffering=0) as out:
        while True:
            data = os.read(fd, 65536)
            if data:
                out.write(data)


if __name__ == "__main__":
    sys.exit(main())
