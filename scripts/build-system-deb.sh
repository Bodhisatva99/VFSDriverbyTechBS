#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
STAGE="$BUILD/package-root"
DEBS="$ROOT/debs"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[[ "$VERSION" == "2.0.3" ]] || { echo "Unexpected VERSION file: $VERSION" >&2; exit 1; }
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
CORE_VERSION="$(dpkg-query -W -f='${Version}' libfprint-2-2)"
TOD_VERSION="$(dpkg-query -W -f='${Version}' libfprint-2-tod1)"

[[ "$CORE_VERSION" == "$TOD_VERSION" ]] || {
    echo "Installed libfprint core/TOD versions differ; refusing package build." >&2
    exit 1
}
case "$TOD_VERSION" in
    *1.94.7+tod1*) ;;
    *) echo "Unsupported target TOD ABI: $TOD_VERSION" >&2; exit 1 ;;
esac

bash -n "$ROOT/scripts/vfs491d-launcher.sh" "$ROOT/scripts/vfs491-recover.sh"
python3 -m py_compile "$ROOT/scripts/vfs491d.py" "$ROOT/scripts/vfs491-client.py" \
    "$ROOT/scripts/vfs491-wait-ready.py" "$ROOT/scripts/vfs491-image-diagnostics.py" \
    "$ROOT/scripts/vfs491-verify-study.py"
"$ROOT/scripts/verify-vendor.sh"

for required in \
  "$BUILD/tod/libfprint-tod-vfs491.so" "$BUILD/vfs491-bridge" \
  "$BUILD/libvfs491-readfull.so" "$ROOT/reference/working-prototype/vfs_proprietary-capture-helper.reference" \
  "$ROOT/vendor/compat/vcsFPService" "$ROOT/vendor/compat/libvfsFprintWrapper.so" \
  "$ROOT/vendor/original/HPUsbVFS491.img" "$ROOT/docs/V2-ENGINEERING.md" \
  "$ROOT/docs/2.0.3-ENGINEERING.md" "$ROOT/docs/PROJECT-HANDOFF.md" "$ROOT/docs/HARDWARE-ACCEPTANCE.md" \
  "$ROOT/scripts/vfs491-verify-study.py"; do
    [[ -f "$required" ]] || { echo "Package preflight: required file missing: $required (run make build and inspect its first error)" >&2; exit 1; }
done

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" \
    "$STAGE/usr/lib/$MULTIARCH/libfprint-2/tod-1" \
    "$STAGE/usr/lib/vfs491/vendor/firmware" \
    "$STAGE/usr/libexec/vfs491" \
    "$STAGE/usr/sbin" \
    "$STAGE/usr/bin" \
    "$STAGE/usr/share/doc/vfs491-fprintd-tod" \
    "$STAGE/lib/systemd/system" \
    "$STAGE/usr/lib/systemd/system/fprintd.service.d"

install -m 0644 "$BUILD/tod/libfprint-tod-vfs491.so" \
    "$STAGE/usr/lib/$MULTIARCH/libfprint-2/tod-1/libfprint-tod-vfs491.so"
install -m 0755 "$BUILD/vfs491-bridge" \
    "$STAGE/usr/libexec/vfs491/vfs491-bridge"
install -m 0755 "$ROOT/scripts/vfs491d-launcher.sh" \
    "$STAGE/usr/libexec/vfs491/vfs491d-launcher"
install -m 0755 "$ROOT/scripts/vfs491d.py" \
    "$STAGE/usr/libexec/vfs491/vfs491d.py"
install -m 0755 "$ROOT/scripts/vfs491-client.py" \
    "$STAGE/usr/libexec/vfs491/vfs491-client"
install -m 0755 "$ROOT/scripts/vfs491-wait-ready.py" \
    "$STAGE/usr/libexec/vfs491/vfs491-wait-ready"
install -m 0755 "$ROOT/scripts/vfs491-image-diagnostics.py" \
    "$STAGE/usr/libexec/vfs491/vfs491-image-diagnostics"
install -m 0755 "$ROOT/scripts/vfs491-verify-study.py" \
    "$STAGE/usr/bin/vfs491-verify-study"
install -m 0755 "$ROOT/reference/working-prototype/vfs_proprietary-capture-helper.reference" \
    "$STAGE/usr/libexec/vfs491/vfs_proprietary-capture-helper.real"
install -m 0755 "$ROOT/scripts/vfs491-helper-launcher.sh" \
    "$STAGE/usr/libexec/vfs491/vfs_proprietary-capture-helper"
install -m 0644 "$BUILD/libvfs491-readfull.so" \
    "$STAGE/usr/lib/vfs491/libvfs491-readfull.so"
install -m 0755 "$ROOT/vendor/compat/vcsFPService" \
    "$STAGE/usr/lib/vfs491/vendor/vcsFPService"
install -m 0644 "$ROOT/vendor/compat/libvfsFprintWrapper.so" \
    "$STAGE/usr/lib/vfs491/vendor/libvfsFprintWrapper.so"
install -m 0644 "$ROOT/vendor/original/HPUsbVFS491.img" \
    "$STAGE/usr/lib/vfs491/vendor/firmware/HPUsbVFS491.img"
install -m 0644 "$ROOT/systemd/vfs491d.service" \
    "$STAGE/lib/systemd/system/vfs491d.service"
install -m 0644 "$ROOT/systemd/fprintd.service.d/50-vfs491.conf" \
    "$STAGE/usr/lib/systemd/system/fprintd.service.d/50-vfs491.conf"
install -m 0755 "$ROOT/scripts/vfs491-diagnose.sh" \
    "$STAGE/usr/libexec/vfs491/vfs491-diagnose"
install -m 0755 "$ROOT/scripts/vfs491-recover.sh" \
    "$STAGE/usr/sbin/vfs491-recover"
install -m 0644 "$ROOT/README.md" "$STAGE/usr/share/doc/vfs491-fprintd-tod/README.md"
install -m 0644 "$ROOT/CHANGELOG.md" "$STAGE/usr/share/doc/vfs491-fprintd-tod/CHANGELOG.md"
install -m 0644 "$ROOT/docs/ARCHITECTURE-2.0.0.md" \
    "$STAGE/usr/share/doc/vfs491-fprintd-tod/ARCHITECTURE-2.0.0.md"
install -m 0644 "$ROOT/docs/V2-ENGINEERING.md" \
    "$STAGE/usr/share/doc/vfs491-fprintd-tod/V2-ENGINEERING.md"
install -m 0644 "$ROOT/docs/2.0.3-ENGINEERING.md" \
    "$STAGE/usr/share/doc/vfs491-fprintd-tod/2.0.3-ENGINEERING.md"
install -m 0644 "$ROOT/docs/PROJECT-HANDOFF.md" \
    "$STAGE/usr/share/doc/vfs491-fprintd-tod/PROJECT-HANDOFF.md"
install -m 0644 "$ROOT/docs/HARDWARE-ACCEPTANCE.md" \
    "$STAGE/usr/share/doc/vfs491-fprintd-tod/HARDWARE-ACCEPTANCE.md"
install -m 0644 "$ROOT/docs/RECOGNITION-PIPELINE.md" \
    "$STAGE/usr/share/doc/vfs491-fprintd-tod/RECOGNITION-PIPELINE.md"
install -m 0644 "$ROOT/docs/PAM-AUTHENTICATION.md" \
    "$STAGE/usr/share/doc/vfs491-fprintd-tod/PAM-AUTHENTICATION.md"
install -m 0755 "$ROOT/scripts/configure-mint-pam-auth.sh" \
    "$STAGE/usr/share/doc/vfs491-fprintd-tod/configure-mint-pam-auth.sh"

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: vfs491-fprintd-tod
Version: 2.0.3-1
Section: admin
Priority: optional
Architecture: amd64
Depends: libc6, libglib2.0-0, libusb-0.1-4, libusb-1.0-0, libudev1, libfprint-2-2 (= $CORE_VERSION), libfprint-2-tod1 (= $TOD_VERSION), fprintd, systemd, util-linux, sysvinit-utils, bash, coreutils, python3
Maintainer: VFS491 Linux Driver Project
Description: HP Validity VFS491 fail-closed TOD driver
 Native libfprint TOD backend for the HP EliteBook 8470p Validity VFS491 sensor.
 Starts the isolated HP service on demand for fprintd and exposes a root-only local
 socket to per-claim fprintd clients. Poisoned vendor sessions fail closed; the
 vfs491-recover command masks/stops fprintd before restarting the USB service.
 Includes capture diagnostics and per-attempt verification correlation; PAM authentication policy is not modified.
CONTROL

cat > "$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = configure ] && [ -d /run/systemd/system ]; then
    systemctl daemon-reload
fi
exit 0
POSTINST

cat > "$STAGE/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
case "$1" in
    remove|deconfigure|upgrade|failed-upgrade)
        if [ -d /run/systemd/system ]; then
            original_state=$(systemctl is-enabled fprintd.service 2>/dev/null || true)
            if [ "$original_state" = masked ] || [ "$original_state" = masked-runtime ]; then
                systemctl stop fprintd.service || true
            else
                systemctl mask --runtime --now fprintd.service
                systemctl stop vfs491d.service || true
                systemctl unmask --runtime fprintd.service || true
            fi
            systemctl stop vfs491d.service || true
        fi
        ;;
esac
exit 0
PRERM

cat > "$STAGE/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ "$1" = purge ]; then
    rm -rf /var/lib/vfs491
    rm -f /run/lock/vfs491-capture.lock
fi
systemctl daemon-reload || true
exit 0
POSTRM

chmod 0755 "$STAGE/DEBIAN" "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"
chmod 0644 "$STAGE/DEBIAN/control"
mkdir -p "$DEBS"
DEB="$DEBS/vfs491-fprintd-tod_2.0.3-1_amd64.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB"
echo "Built VFS491 2.0.3 recognition-observability package: $DEB"
dpkg-deb -f "$DEB" Package Version Architecture Depends
