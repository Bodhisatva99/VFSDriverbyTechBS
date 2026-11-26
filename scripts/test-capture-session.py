#!/usr/bin/env python3
"""Exercise the broker across repeated captures and client claims."""

import argparse
import os
import socket
import struct
import sys
import time
from pathlib import Path

SOCKET_PATH = "/var/lib/vfs491/control.sock"
MAGIC = 0x31534656
VERSION = 1
WIDTH = 200
HEADER_SIZE = 20
MAX_HEIGHT = 1023


def read_line(sock, timeout, label):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for {label} after {timeout}s")
        sock.settimeout(remaining)
        byte = sock.recv(1)
        if not byte:
            raise RuntimeError(f"broker closed while waiting for {label}")
        if byte == b"\n":
            return data.decode("ascii", "replace").rstrip("\r")
        data.extend(byte)
        if len(data) > 128:
            raise RuntimeError("broker sent an oversized protocol line")


def read_exact(sock, length, timeout):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while len(data) < length:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out reading frame ({len(data)}/{length} bytes)")
        sock.settimeout(remaining)
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise RuntimeError(f"broker closed during frame ({len(data)}/{length} bytes)")
        data.extend(chunk)
    return bytes(data)


def one_capture(sock, number, timeout):
    started = time.monotonic()
    print(f"Capture {number}: swipe one finger when prompted", flush=True)
    sock.sendall(b"CAPTURE\n")
    response = read_line(sock, timeout + 20, "capture response")
    if response.startswith("ERR "):
        raise RuntimeError(f"capture failed with bridge status {response.split()[1]}")
    if not response.startswith("OK "):
        raise RuntimeError(f"unexpected capture response: {response!r}")
    frame_size = int(response.split()[1])
    if frame_size < HEADER_SIZE or frame_size > HEADER_SIZE + WIDTH * MAX_HEIGHT:
        raise RuntimeError(f"invalid frame size: {frame_size}")
    frame = read_exact(sock, frame_size, 15)
    magic, version, width, height, image_len = struct.unpack("<IIIII", frame[:HEADER_SIZE])
    if magic != MAGIC or version != VERSION or width != WIDTH or not (1 <= height <= MAX_HEIGHT):
        raise RuntimeError(f"invalid VFS491 frame header: {width}x{height}, version={version}")
    if image_len != width * height or len(frame) != HEADER_SIZE + image_len:
        raise RuntimeError(f"invalid grayscale payload length: {image_len}, frame={len(frame)}")
    print(f"PASS: {width}x{height}, {image_len} grayscale bytes in {time.monotonic() - started:.3f}s")



def sensor_identity():
    """Return (USB port path, device number) for the physical VFS491."""
    matches = []
    for path in Path("/sys/bus/usb/devices").glob("*"):
        try:
            vendor = (path / "idVendor").read_text().strip().lower()
            product = (path / "idProduct").read_text().strip().lower()
            if vendor == "138a" and product == "003d":
                devnum = (path / "devnum").read_text().strip()
                matches.append((path.name, devnum))
        except (FileNotFoundError, PermissionError, OSError):
            continue
    if len(matches) != 1:
        raise RuntimeError(f"expected exactly one USB VFS491 (138a:003d), found {matches!r}")
    return matches[0]


def vendor_service_pid():
    """Find exactly one vendor service PID and verify it is namespace-isolated."""
    matches = []
    init_mnt = os.readlink("/proc/1/ns/mnt")
    init_ipc = os.readlink("/proc/1/ns/ipc")
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            exe = os.readlink(entry / "exe")
            comm = (entry / "comm").read_text().strip()
            if Path(exe).name != "vcsFPService" and comm != "vcsFPService":
                continue
            mnt = os.readlink(entry / "ns/mnt")
            ipc = os.readlink(entry / "ns/ipc")
            if mnt == init_mnt or ipc == init_ipc:
                raise RuntimeError(f"vcsFPService PID {entry.name} is not isolated from PID 1")
            matches.append(int(entry.name))
        except (FileNotFoundError, ProcessLookupError, PermissionError, OSError):
            continue
    if len(matches) != 1:
        raise RuntimeError(f"expected exactly one isolated vcsFPService, found PIDs {matches!r}")
    return matches[0]


def invariants(expected_pid=None, expected_usb=None):
    pid = vendor_service_pid()
    usb = sensor_identity()
    if expected_pid is not None and pid != expected_pid:
        raise RuntimeError(f"vcsFPService PID changed: {expected_pid} -> {pid}")
    if expected_usb is not None and usb != expected_usb:
        raise RuntimeError(f"VFS491 USB identity changed (disconnect/re-enumeration suspected): {expected_usb} -> {usb}")
    return pid, usb


def main():
    parser = argparse.ArgumentParser(description="Capture swipes using the persistent VFS491 daemon")
    parser.add_argument("--captures", type=int, default=2, choices=range(1, 6))
    parser.add_argument("--claims", type=int, default=2, choices=range(1, 6))
    parser.add_argument("--capture-timeout", type=int, default=110)
    args = parser.parse_args()
    if __import__("os").geteuid() != 0:
        raise SystemExit("Run with sudo: sudo ./scripts/test-capture-session.py --captures 2 --claims 2")

    expected_pid, expected_usb = invariants()
    print(f"PASS: one isolated vcsFPService PID {expected_pid}; VFS491 USB {expected_usb[0]} devnum={expected_usb[1]}", flush=True)

    for claim in range(1, args.claims + 1):
        started = time.monotonic()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.connect(SOCKET_PATH)
            ready = read_line(sock, 15, "persistent service READY")
            if ready != "READY":
                raise RuntimeError(f"unexpected READY response: {ready!r}")
            print(f"PASS: broker ready for client claim {claim} in {time.monotonic() - started:.3f}s")
            for index in range(1, args.captures + 1):
                invariants(expected_pid, expected_usb)
                one_capture(sock, index, args.capture_timeout)
                invariants(expected_pid, expected_usb)
            sock.sendall(b"QUIT\n")
        invariants(expected_pid, expected_usb)
        print(f"PASS: client claim {claim} closed; same vendor PID and USB identity remain", flush=True)
    print("PASS: persistent VFS491 service handled independent client claims without PID/USB re-enumeration")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
