#!/usr/bin/env python3
"""serial-expect.py — minimal expect over a QEMU unix-socket serial console.

Stdlib only. QEMU is started with:
  -chardev socket,id=ser0,path=SOCK,server=on,wait=off,logfile=LOG
  -serial chardev:ser0
so the FULL console transcript is always in LOG; this tool attaches for the
live tail. Because output printed before we connect is only in LOG, `wait`
pre-scans the logfile first.

usage:
  serial-expect.py SOCK wait     PATTERN [--timeout S] [--logfile F]
  serial-expect.py SOCK send     LINE
  serial-expect.py SOCK sendwait LINE PATTERN [--timeout S] [--logfile F] [--retry N]

everything received is mirrored to stdout. exit 0 on match, 1 on timeout.
"""
import argparse
import os
import re
import socket
import sys
import time


def pre_scan(logfile: str, rx: "re.Pattern[str]") -> bool:
    try:
        with open(logfile, "r", errors="replace") as fh:
            return any(rx.search(line) for line in fh)
    except OSError:
        return False


def wait_for(rx: "re.Pattern[str]", timeout: float, conn, logfile, first_deadline=None) -> int:
    if logfile and pre_scan(logfile, rx):
        print(f"[serial-expect] '{rx.pattern}' already present in {logfile}", file=sys.stderr)
        return 0
    deadline = time.monotonic() + timeout
    buf = ""
    conn.settimeout(0.5)
    while time.monotonic() < deadline:
        try:
            data = conn.recv(4096)
            if not data:
                time.sleep(0.1)
                continue
        except socket.timeout:
            continue
        text = data.decode("utf-8", "replace")
        sys.stdout.write(text)
        sys.stdout.flush()
        buf += text
        buf = buf[-65536:]
        if rx.search(buf):
            return 0
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sock")
    ap.add_argument("cmd", choices=["wait", "send", "sendwait"])
    ap.add_argument("args", nargs="+")
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--logfile", default=None)
    ap.add_argument("--retry", type=int, default=1, help="sendwait: resend LINE up to N times")
    ns = ap.parse_args()

    rx = None
    if ns.cmd in ("wait", "sendwait"):
        pattern = ns.args[0] if ns.cmd == "wait" else ns.args[1]
        rx = re.compile(pattern)

    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    deadline = time.monotonic() + ns.timeout
    while True:
        try:
            conn.connect(ns.sock)
            break
        except OSError:
            if time.monotonic() > deadline:
                print(f"[serial-expect] cannot connect to {ns.sock}", file=sys.stderr)
                return 1
            time.sleep(0.2)

    if ns.cmd == "wait":
        return wait_for(rx, ns.timeout, conn, ns.logfile)

    line = ns.args[0]
    attempts = max(1, ns.retry) if ns.cmd == "sendwait" else 1
    for attempt in range(attempts):
        conn.sendall(line.encode() + b"\n")
        if ns.cmd == "send":
            return 0
        # give the guest a slice of the remaining budget per attempt
        rc = wait_for(rx, ns.timeout / attempts, conn, ns.logfile)
        if rc == 0:
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
