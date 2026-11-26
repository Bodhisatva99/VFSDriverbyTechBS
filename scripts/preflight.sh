#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'VFS491 preflight: ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is missing"; }
for cmd in bash gcc make python3 dpkg-query dpkg-architecture dpkg-deb ldd nm readelf install; do need_cmd "$cmd"; done
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
printf 'VFS491 %s build preflight\n' "$VERSION"
printf 'Architecture: '; dpkg-architecture -qDEB_HOST_ARCH
printf 'Multiarch: '; dpkg-architecture -qDEB_HOST_MULTIARCH
for pkg in libfprint-2-2 libfprint-2-tod1; do
    status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
    [[ "$status" == "install ok installed" ]] || fail "target runtime package $pkg is not installed. Build on the intended Mint/Ubuntu host."
done
core="$(dpkg-query -W -f='${Version}' libfprint-2-2)"
tod="$(dpkg-query -W -f='${Version}' libfprint-2-tod1)"
[[ "$core" == "$tod" ]] || fail "libfprint core ($core) and TOD ($tod) versions differ"
case "$tod" in *1.94.7+tod1*) ;; *) fail "unsupported TOD ABI '$tod'; expected 1.94.7+tod1" ;; esac
for p in \
  reference/libfprint/fpi-image-device.h \
  reference/libfprint/fpi-device.h \
  reference/working-prototype/vfs_proprietary-capture-helper.reference \
  vendor/compat/vcsFPService \
  vendor/compat/libvfsFprintWrapper.so \
  vendor/original/HPUsbVFS491.img \
  systemd/vfs491d.service \
  systemd/fprintd.service.d/50-vfs491.conf \
  docs/ARCHITECTURE-2.0.0.md \
  docs/RECOGNITION-PIPELINE.md \
  docs/2.0.3-ENGINEERING.md \
  docs/PROJECT-HANDOFF.md \
  scripts/vfs491-verify-study.py \
  docs/PAM-AUTHENTICATION.md \
  docs/V2-ENGINEERING.md \
  docs/HARDWARE-ACCEPTANCE.md \
  docs/VALIDATION-RESULTS.md; do
    [[ -e "$ROOT/$p" ]] || fail "required project file is missing: $p"
done
[[ -x "$ROOT/reference/working-prototype/vfs_proprietary-capture-helper.reference" ]] || fail "reference capture helper is not executable"
[[ -d "$ROOT/sysroot/usr/include/glib-2.0" ]] || printf '%s\n' "Private build sysroot is not populated yet; run 'make bootstrap'."
"$ROOT/scripts/verify-vendor.sh"
printf 'Target runtime: %s\n' "$tod"
printf '%s\n' 'Preflight passed.'
