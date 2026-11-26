#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT="$ROOT/systemd/vfs491d.service"
DROPIN="$ROOT/systemd/fprintd.service.d/50-vfs491.conf"
BUILDER="$ROOT/scripts/build-system-deb.sh"
DIAG="$ROOT/scripts/vfs491-diagnose.sh"

bash -n "$DIAG" "$BUILDER"

python3 - "$UNIT" "$DROPIN" "$BUILDER" "$DIAG" <<'PY'
from pathlib import Path
import sys
unit, dropin, builder, diag = map(lambda p: Path(p).read_text(), sys.argv[1:])
checks = [
    ("VFS491 service is ordered before fprintd without blocking display-manager boot", "Before=fprintd.service" in unit and "display-manager.service" not in unit),
    ("D-Bus-activated fprintd pulls in VFS491 service without hard-failing password fallback", "Wants=vfs491d.service" in dropin),
    ("fprintd starts only after VFS491 startup ordering", "After=vfs491d.service" in dropin),
    ("package installs fprintd ordering drop-in", "fprintd.service.d/50-vfs491.conf" in builder),
    ("package does not interrupt an active fprintd claim during installation", "systemctl try-restart fprintd.service" not in builder),
    ("package masks/stops fprintd before stopping vendor service on upgrade/removal", "systemctl mask --runtime --now fprintd.service" in builder and "systemctl stop vfs491d.service" in builder),
    ("package installs support diagnostic utility", "vfs491-diagnose" in builder),
    ("diagnostic reports auth/PAM and LightDM evidence", "pam_fprintd" in diag and "lightdm-autologin" in diag and "lightdm" in diag.lower()),
    ("diagnostic detects stale VFS491 service units", "vcsfpservice-vfs491.service" in diag and "list-unit-files" in diag),
    ("diagnostic includes boot journal and USB state", 'journalctl -b' in diag and 'lsusb -d 138a:003d' in diag),
    ("diagnostic does not invoke image capture or save image data", '--save-images' not in diag and 'vfs491-image-diagnostics' not in diag),
]
for label, ok in checks:
    print(("PASS" if ok else "FAIL") + ": " + label)
if not all(ok for _, ok in checks):
    raise SystemExit(1)
PY
