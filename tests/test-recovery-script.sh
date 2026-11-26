#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$VFS491_SYSTEMCTL_LOG"
if [[ "$1" == is-enabled ]]; then
    echo "${VFS491_TEST_FPRINTD_STATE:-enabled}"
    exit 0
fi
if [[ "${VFS491_FAIL_START:-0}" == 1 && "$1" == start && "$2" == vfs491d.service ]]; then
    exit 1
fi
exit 0
MOCK
chmod +x "$TMP/bin/systemctl"
export VFS491_SYSTEMCTL_LOG="$TMP/systemctl.log"

# Exercise the implementation using mocked systemctl; no root privileges required.
# The executable entry point separately retains the production root check.
source "$ROOT/scripts/vfs491-recover.sh"
PATH="$TMP/bin:$PATH" vfs491_recover_impl >/dev/null
python3 - "$VFS491_SYSTEMCTL_LOG" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
expected = [
    "mask --runtime --now fprintd.service",
    "stop vfs491d.service",
    "start vfs491d.service",
    "is-active --quiet vfs491d.service",
    "unmask --runtime fprintd.service",
]
positions = [lines.index(x) for x in expected]
assert positions == sorted(positions), lines
print("PASS: recovery masks/stops fprintd before vendor restart and unmasks afterward")
PY

: > "$VFS491_SYSTEMCTL_LOG"
set +e
VFS491_FAIL_START=1 PATH="$TMP/bin:$PATH" vfs491_recover_impl >/dev/null 2>&1
status=$?
set -e
[[ $status -ne 0 ]]
grep -qx 'unmask --runtime fprintd.service' "$VFS491_SYSTEMCTL_LOG"
echo "PASS: recovery always unmasks fprintd after a failed vendor restart"

: > "$VFS491_SYSTEMCTL_LOG"
VFS491_TEST_FPRINTD_STATE=masked PATH="$TMP/bin:$PATH" vfs491_recover_impl >/dev/null
! grep -q '^unmask --runtime fprintd.service$' "$VFS491_SYSTEMCTL_LOG"
grep -qx 'stop fprintd.service' "$VFS491_SYSTEMCTL_LOG"
echo "PASS: recovery preserves an administrator's pre-existing fprintd mask"
