#!/usr/bin/env python3
"""Send one command to a QEMU monitor Unix socket.

Usage:
  qemu-monitor.py --socket /tmp/vm-mon.sock --command "savevm baseline"
  qemu-monitor.py --socket /tmp/vm-mon.sock --command "info status" --quiet

The default timeout is 30 s because savevm of a multi-GB guest can take longer
than a few seconds; quick commands still return as soon as the (qemu) prompt
comes back.
"""
import argparse
import re
import socket
import sys
import time


def read_until_prompt(sock, timeout):
    sock.settimeout(timeout)
    data = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        data += chunk
        if b"(qemu)" in data:
            break
    return data.decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--command", required=True)
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(args.timeout)
    try:
        s.connect(args.socket)
    except OSError as exc:
        print(f"connect failed: {exc}", file=sys.stderr)
        return 2
    try:
        read_until_prompt(s, args.timeout)  # banner
        s.sendall((args.command + "\n").encode())
        out = read_until_prompt(s, args.timeout)
    finally:
        s.close()

    # QEMU monitor echoes the command before the response; drop that segment.
    if "\r\n" in out:
        out = out.split("\r\n", 1)[1]
    # Strip ANSI cursor controls from the remaining response.
    out = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", out).replace("\r", "")
    if not args.quiet:
        lines = [ln for ln in out.split("\n")
                 if ln.strip() and ln.strip() != args.command and ln.strip() != "(qemu)"]
        # Drop the monitor's character-by-character echo of the command.
        if len(lines) >= 2 and lines[0].startswith(args.command.split()[0]):
            lines = lines[1:]
        print("\n".join(lines))

    low = out.lower()
    if "error" in low or "unknown command" in low or "invalid" in low:
        return 1
    if "(qemu)" not in out:
        print("warning: monitor prompt not seen before timeout; "
              "command may still be running (raise --timeout)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
