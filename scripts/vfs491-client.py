#!/usr/bin/python3
"""Bridge a fprintd TOD stdio protocol to the systemd-managed VFS491 broker."""

from __future__ import annotations

import os
import selectors
import socket
import subprocess
import sys

SOCKET_PATH = "/var/lib/vfs491/control.sock"
SYSTEMCTL = "/usr/bin/systemctl"
UNIT = "vfs491d.service"


def start_service() -> None:
    if os.environ.get("VFS491_CLIENT_TEST_MODE") == "1":
        return
    result = subprocess.run(
        [SYSTEMCTL, "start", UNIT],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=sys.stderr,
        timeout=170,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"systemctl start {UNIT} failed with status {result.returncode}")


def connect_service() -> socket.socket:
    path = os.environ.get("VFS491D_SOCKET", SOCKET_PATH)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect(path)
    sock.settimeout(None)
    return sock


def write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def proxy(sock: socket.socket) -> int:
    selector = selectors.DefaultSelector()
    stdin_fd = sys.stdin.fileno()
    selector.register(stdin_fd, selectors.EVENT_READ, "stdin")
    selector.register(sock, selectors.EVENT_READ, "socket")
    stdin_open = True
    try:
        while True:
            for key, _mask in selector.select():
                if key.data == "stdin":
                    chunk = os.read(stdin_fd, 65536)
                    if not chunk:
                        selector.unregister(stdin_fd)
                        stdin_open = False
                        try:
                            sock.shutdown(socket.SHUT_WR)
                        except OSError:
                            pass
                    else:
                        sock.sendall(chunk)
                else:
                    chunk = sock.recv(65536)
                    if not chunk:
                        return 0
                    write_all(sys.stdout.fileno(), chunk)
    finally:
        selector.close()
        if stdin_open:
            try:
                selector.unregister(stdin_fd)
            except Exception:
                pass


def main() -> int:
    try:
        start_service()
        with connect_service() as sock:
            return proxy(sock)
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"VFS491 client: {exc}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
