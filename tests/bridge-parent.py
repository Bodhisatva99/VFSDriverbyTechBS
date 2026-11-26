#!/usr/bin/env python3
import os
import subprocess
import sys
from pathlib import Path

bridge, helper, bridge_pid_file, child_pid_file = sys.argv[1:]
env = os.environ.copy()
env.update({
    "VFS491_TEST_SKIP_SERVICE_CHECK": "1",
    "VFS491_TEST_CHILD_PID_FILE": child_pid_file,
})
proc = subprocess.Popen([bridge, helper], env=env,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        start_new_session=True)
Path(bridge_pid_file).write_text(str(proc.pid), encoding="ascii")
raise SystemExit(proc.wait())
