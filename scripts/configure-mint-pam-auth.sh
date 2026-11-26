#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 && ${VFS491_PAM_TEST_MODE:-0} != 1 ]]; then
    echo "Run with: sudo $0" >&2
    exit 1
fi

PAM_FILE="${VFS491_PAM_FILE:-/etc/pam.d/common-auth}"
[[ -f "$PAM_FILE" ]] || { echo "Missing $PAM_FILE" >&2; exit 1; }

VERSION="$(dpkg-query -W -f='${Version}' libpam-fprintd 2>/dev/null)"
# The vendor helper has a 30-second hard capture deadline. Longer PAM
# timeouts cannot extend that hardware operation and would only hide stalls.
TIMEOUT=30
echo "libpam-fprintd $VERSION: using a 30-second per-capture timeout; vendor-session recovery is handled by the driver."

if ! grep -Eq '^[[:space:]]*auth[[:space:]].*\[success=2[[:space:]]+default=ignore\].*pam_fprintd\.so' "$PAM_FILE"; then
    echo "Expected '[success=2 default=ignore] pam_fprintd.so' control line was not found; refusing to alter PAM." >&2
    exit 1
fi
if ! awk '/pam_fprintd\.so/ { found=1; next } found && /pam_unix\.so/ { ok=1; exit } END { exit !ok }' "$PAM_FILE"; then
    echo "pam_unix.so fallback is not after pam_fprintd.so; refusing to alter PAM." >&2
    exit 1
fi

BACKUP="$(mktemp "${PAM_FILE}.vfs491-pre-t14.XXXXXXXX")"
cp -a -- "$PAM_FILE" "$BACKUP"
python3 - "$PAM_FILE" "$TIMEOUT" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
timeout = sys.argv[2]
lines = path.read_text().splitlines(keepends=True)
found = 0
for i, line in enumerate(lines):
    if not re.match(r"^\s*auth\s+", line) or "pam_fprintd.so" not in line:
        continue
    found += 1
    body, marker, comment = line.partition("#")
    match = re.search(r"pam_fprintd\.so", body)
    if not match:
        continue
    prefix = body[:match.end()]
    options = body[match.end():].split()
    options = [x for x in options if not x.startswith("max-tries=") and not x.startswith("timeout=")]
    replacement = prefix + " " + " ".join(options + ["max-tries=4", f"timeout={timeout}"])
    if marker:
        replacement += " #" + comment.rstrip("\n")
    if line.endswith("\n"):
        replacement += "\n"
    lines[i] = replacement
if found != 1:
    raise SystemExit(f"Expected exactly one auth pam_fprintd.so line; found {found}; no change written")
path.write_text("".join(lines))
PY

if ! grep -Eq '^[[:space:]]*auth[[:space:]].*\[success=2[[:space:]]+default=ignore\].*pam_fprintd\.so.*max-tries=4.*timeout=' "$PAM_FILE"; then
    cp -a "$BACKUP" "$PAM_FILE"
    echo "Post-edit validation failed; restored $BACKUP" >&2
    exit 1
fi

echo "Updated: $PAM_FILE"
echo "Backup:  $BACKUP"
echo "Result:"
grep -nE 'pam_fingwit|pam_fprintd|pam_unix' "$PAM_FILE"
