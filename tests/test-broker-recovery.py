#!/usr/bin/env python3
from __future__ import annotations

import os
import select
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DAEMON = ROOT / "scripts/vfs491d.py"
POISON_BRIDGE = ROOT / "tests/fake-poison-bridge.py"
HANGING_BRIDGE = ROOT / "tests/fake-hanging-bridge.py"
SEQUENCE_BRIDGE = ROOT / "tests/fake-sequence-bridge.py"


def recv_line(sock: socket.socket, timeout: float = 5) -> bytes:
    sock.settimeout(timeout)
    data = bytearray()
    while not data.endswith(b"\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise RuntimeError("socket closed before protocol line completed")
        data.extend(chunk)
    return bytes(data)


def recv_exact(sock: socket.socket, length: int, timeout: float = 5) -> bytes:
    sock.settimeout(timeout)
    data = bytearray()
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise RuntimeError(f"socket closed during frame ({len(data)}/{length})")
        data.extend(chunk)
    return bytes(data)


def start_daemon(tmp: str, bridge: Path, extra_env: dict[str, str] | None = None):
    socket_path = Path(tmp) / "control.sock"
    env = os.environ.copy()
    env.update({
        "VFS491D_TEST_MODE": "1",
        "VFS491D_SOCKET": str(socket_path),
        "VFS491_BRIDGE_BIN": str(bridge),
        "VFS491_HELPER_BIN": "/dev/null",
    })
    if extra_env:
        env.update(extra_env)
    proc = subprocess.Popen([sys.executable, str(DAEMON), "--socket", str(socket_path)],
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            detail = proc.stderr.read().decode(errors="replace") if proc.stderr else ""
            raise RuntimeError(f"broker exited early ({proc.returncode}): {detail}")
        if socket_path.exists():
            return socket_path, proc
        time.sleep(0.025)
    raise TimeoutError("broker socket was not created")


def connect_ready(path: Path) -> socket.socket:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect(str(path))
    assert recv_line(client) == b"READY\n"
    return client


def assert_degraded(path: Path, daemon: subprocess.Popen[bytes]) -> None:
    assert daemon.poll() is None, "broker exited and could restart vendor USB state"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(str(path))
        assert recv_line(client) == b"ERR 14\n"
    assert daemon.poll() is None, "broker exited after rejecting a degraded session"


def stop(daemon: subprocess.Popen[bytes]) -> None:
    if daemon.poll() is None:
        daemon.terminate()
        try:
            daemon.wait(timeout=3)
        except subprocess.TimeoutExpired:
            daemon.kill()
            daemon.wait(timeout=3)
    if daemon.stderr:
        daemon.stderr.close()


def test_timeout_marks_degraded_without_restart() -> None:
    with tempfile.TemporaryDirectory(prefix="vfs491-recovery-") as tmp:
        path, daemon = start_daemon(tmp, POISON_BRIDGE)
        try:
            with connect_ready(path) as client:
                client.sendall(b"CAPTURE\n")
                assert recv_line(client) == b"ERR 14\n"
                client.sendall(b"QUIT\n")
            time.sleep(0.1)
            assert_degraded(path, daemon)
            print("PASS: poisoned timeout fails closed; broker never auto-restarts vendor service")
        finally:
            stop(daemon)


def test_client_cancellation_marks_degraded_without_restart() -> None:
    with tempfile.TemporaryDirectory(prefix="vfs491-cancel-") as tmp:
        pid_file = str(Path(tmp) / "bridge.pid")
        path, daemon = start_daemon(tmp, HANGING_BRIDGE,
                                    {"VFS491_TEST_BRIDGE_PID_FILE": pid_file})
        try:
            client = connect_ready(path)
            client.sendall(b"CAPTURE\n")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not Path(pid_file).exists():
                time.sleep(0.025)
            assert Path(pid_file).exists(), "fake bridge did not enter capture wait"
            bridge_pid = int(Path(pid_file).read_text())
            client.close()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and Path(f"/proc/{bridge_pid}").exists():
                time.sleep(0.025)
            assert not Path(f"/proc/{bridge_pid}").exists(), "broker failed to terminate cancelled bridge"
            assert_degraded(path, daemon)
            print("PASS: cancellation terminates helper and leaves vendor reset to explicit recovery")
        finally:
            stop(daemon)


def test_drain_timeout_is_bounded_and_does_not_restart() -> None:
    with tempfile.TemporaryDirectory(prefix="vfs491-drain-timeout-") as tmp:
        path, daemon = start_daemon(tmp, POISON_BRIDGE,
                                    {"VFS491_RESET_DRAIN_TIMEOUT": "0.25"})
        try:
            client = connect_ready(path)
            client.sendall(b"CAPTURE\n")
            assert recv_line(client) == b"ERR 14\n"
            time.sleep(0.4)
            assert daemon.poll() is None, "bounded drain timeout restarted vendor service"
            client.close()
            assert_degraded(path, daemon)
            print("PASS: drain deadline is bounded and never triggers an in-claim USB reset")
        finally:
            stop(daemon)


def test_acquisition_error_retries_without_degrading() -> None:
    with tempfile.TemporaryDirectory(prefix="vfs491-acquisition-") as tmp:
        sequence_file = str(Path(tmp) / "sequence")
        path, daemon = start_daemon(tmp, SEQUENCE_BRIDGE,
                                    {"VFS491_TEST_SEQUENCE_FILE": sequence_file})
        try:
            with connect_ready(path) as client:
                client.sendall(b"CAPTURE\n")
                assert recv_line(client) == b"ERR 11\n"
                client.sendall(b"CAPTURE\n")
                header = recv_line(client)
                assert header == b"OK 420\n"
                assert len(recv_exact(client, 420)) == 420
                client.sendall(b"QUIT\n")
            time.sleep(0.1)
            assert daemon.poll() is None
            assert Path(sequence_file).read_text() == "2"
            print("PASS: recoverable acquisition error retries without degrading or restarting")
        finally:
            stop(daemon)


def test_vendor_health_loss_marks_degraded_without_restart() -> None:
    with tempfile.TemporaryDirectory(prefix="vfs491-health-loss-") as tmp:
        health_file = Path(tmp) / "vendor-health"
        health_file.write_text("ok")
        path, daemon = start_daemon(
            tmp, SEQUENCE_BRIDGE,
            {"VFS491_TEST_VENDOR_HEALTH_FILE": str(health_file)},
        )
        try:
            with connect_ready(path) as client:
                client.sendall(b"QUIT\n")
            health_file.write_text("dead")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(5)
                client.connect(str(path))
                assert recv_line(client) == b"ERR 14\n"
            assert daemon.poll() is None, "vendor health loss caused automatic service restart"
            print("PASS: vendor PID health loss marks broker degraded without automatic restart")
        finally:
            stop(daemon)


if __name__ == "__main__":
    test_timeout_marks_degraded_without_restart()
    test_client_cancellation_marks_degraded_without_restart()
    test_drain_timeout_is_bounded_and_does_not_restart()
    test_acquisition_error_retries_without_degrading()
    test_vendor_health_loss_marks_degraded_without_restart()
