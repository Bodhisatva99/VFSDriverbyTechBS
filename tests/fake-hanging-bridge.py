#!/usr/bin/env python3
import os
import time
from pathlib import Path

pid_file = os.environ.get("VFS491_TEST_BRIDGE_PID_FILE")
if pid_file:
    Path(pid_file).write_text(str(os.getpid()), encoding="ascii")
time.sleep(60)
