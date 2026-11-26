#!/usr/bin/env python3
from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PARENT = ROOT / "tests" / "bridge-parent.py"
HELPER = ROOT / "tests" / "fake-hanging-helper.py"

with tempfile.TemporaryDirectory(prefix="vfs491-parent-death-") as tmp:
    bridge = Path(tmp) / "vfs491-bridge"
    subprocess.run(
        ["gcc", "-std=gnu11", "-O2", "-g", "-Wall", "-Wextra", "-Werror",
         "-I", str(ROOT / "include"), str(ROOT / "src" / "vfs491-bridge.c"),
         "-o", str(bridge)],
        check=True,
    )
    bridge_pid_file = Path(tmp) / "bridge.pid"
    child_pid_file = Path(tmp) / "helper.pid"
    parent = subprocess.Popen(
        [sys.executable, str(PARENT), str(bridge), str(HELPER),
         str(bridge_pid_file), str(child_pid_file)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env=os.environ.copy(),
    )
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline and not child_pid_file.exists():
        if parent.poll() is not None:
            raise RuntimeError(f"bridge parent exited early: {parent.returncode}")
        time.sleep(0.025)
    assert bridge_pid_file.exists() and child_pid_file.exists(), "bridge/helper did not start"
    bridge_pid = int(bridge_pid_file.read_text())
    helper_pid = int(child_pid_file.read_text())
    os.kill(parent.pid, signal.SIGKILL)
    parent.wait(timeout=3)

    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        bridge_alive = Path(f"/proc/{bridge_pid}").exists()
        helper_alive = Path(f"/proc/{helper_pid}").exists()
        if not bridge_alive and not helper_alive:
            break
        time.sleep(0.05)
    assert not Path(f"/proc/{bridge_pid}").exists(), "bridge survived broker-parent death"
    assert not Path(f"/proc/{helper_pid}").exists(), "helper survived broker-parent death"
    print("PASS: broker-parent death terminates bridge and reaps proprietary helper")
