#!/usr/bin/env bash
set -u

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run with: sudo $0" >&2
    exit 1
fi

section() { printf '\n\n===== %s =====\n' "$1"; }
run() {
    printf '\n$'
    printf ' %q' "$@"
    printf '\n'
    "$@" 2>&1 || printf '[command exited %s]\n' "$?"
}

section "TIME AND SYSTEM"
date --iso-8601=seconds
run uname -a
if [[ -r /etc/os-release ]]; then
    sed -n '1,12p' /etc/os-release
fi
run dpkg-query -W -f='${Package} ${Version}\n' \
    vfs491-fprintd-tod fprintd libpam-fprintd libfprint-2-2 libfprint-2-tod1

section "UNIT STATES AND ORDERING"
for unit in vfs491d.service fprintd.service display-manager.service lightdm.service vcsfpservice-vfs491.service; do
    echo "--- $unit ---"
    systemctl show "$unit" \
        -p LoadState -p UnitFileState -p ActiveState -p SubState -p Result \
        -p ExecMainStartTimestamp -p ActiveEnterTimestamp \
        -p Requires -p Wants -p After -p Before 2>&1 || true
    systemctl status "$unit" --no-pager -l 2>&1 || true
done

section "VFS491 AND FPRINTD UNIT DEFINITIONS"
systemctl cat vfs491d.service 2>&1 || true
systemctl cat fprintd.service 2>&1 || true
systemctl list-unit-files --no-pager 2>&1 | grep -Ei 'vfs491|vcsfp|fprintd|lightdm' || true

section "BROKER SOCKET AND PROCESSES"
if [[ -e /var/lib/vfs491/control.sock ]]; then
    stat -c '%A %a %U:%G %n' /var/lib/vfs491/control.sock
else
    echo "Broker socket is absent: /var/lib/vfs491/control.sock"
fi
run ss -xlpn
run pgrep -af 'vcsFPService|vfs491d.py|vfs491-client' || true

section "USB SENSOR STATE"
run lsusb -d 138a:003d
found=0
for dev in /sys/bus/usb/devices/*; do
    [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
    [[ "$(<"$dev/idVendor")" == 138a && "$(<"$dev/idProduct")" == 003d ]] || continue
    found=1
    echo "Device: ${dev##*/}"
    for attr in idVendor idProduct busnum devnum speed authorized power/control power/runtime_status; do
        [[ -r "$dev/$attr" ]] && printf '%s=%s\n' "$attr" "$(<"$dev/$attr")"
    done
done
(( found == 1 )) || echo "No matching USB sysfs node found."

section "CURRENT BOOT: VFS491, FPRINTD AND LIGHTDM JOURNAL"
journalctl -b -o short-monotonic --no-pager \
    -u vfs491d.service -u fprintd.service -u lightdm.service -u display-manager.service 2>&1 || true

section "CURRENT BOOT: FINGERPRINT AND PAM JOURNAL EVENTS"
journalctl -b -o short-monotonic --no-pager 2>&1 \
    | grep -Ei 'pam_fprintd|fprintd|vfs491|vcsfpservice|lightdm.*(auth|greeter)|fingerprint' \
    | tail -n 300 || true

section "CURRENT BOOT: USB KERNEL EVENTS"
journalctl -b -k -o short-monotonic --no-pager 2>&1 \
    | grep -Ei '138a|003d|usb.*(disconnect|reset|new device)|reset.*usb' \
    | tail -n 160 || true

section "AUTH.LOG FINGERPRINT EVENTS"
if [[ -r /var/log/auth.log ]]; then
    grep -Ei 'pam_fprintd|fprintd|lightdm' /var/log/auth.log | tail -n 200 || true
else
    echo "/var/log/auth.log is not present/readable; see journal section above."
fi

section "PAM AUTHENTICATION ROUTING"
for file in /etc/pam.d/lightdm /etc/pam.d/lightdm-greeter \
            /etc/pam.d/lightdm-autologin /etc/pam.d/common-auth /etc/pam.d/sudo \
            /etc/pam.d/cinnamon-screensaver /etc/pam.d/light-locker; do
    [[ -r "$file" ]] || continue
    echo "--- $file ---"
    grep -nE 'pam_fprintd|pam_unix|@include|^[[:space:]]*auth[[:space:]].*(include|substack)' "$file" || true
done

section "LIGHTDM AUTHENTICATION SETTINGS"
for file in /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf; do
    [[ -r "$file" ]] || continue
    echo "--- $file ---"
    grep -nEi 'pam-service|pam-greeter-service|greeter-session|greeter-user' "$file" || true
done

echo
echo "Diagnostic collection complete. No fingerprint image pixels are collected or exported."
echo "Review this report for personal usernames/paths before sharing it."
