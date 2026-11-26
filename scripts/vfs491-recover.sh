#!/usr/bin/env bash
set -Eeuo pipefail

FPRINTD_UNIT=fprintd.service
VFS_UNIT=vfs491d.service

vfs491_require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo "Run as root: sudo vfs491-recover" >&2
        return 1
    fi
}

vfs491_recover_impl() {
    local masked_by_us=0
    local original_state
    original_state="$(systemctl is-enabled "$FPRINTD_UNIT" 2>/dev/null || true)"

    vfs491_restore_fprintd() {
        if (( masked_by_us )); then
            systemctl unmask --runtime "$FPRINTD_UNIT" >/dev/null 2>&1 || true
        fi
    }

    trap vfs491_restore_fprintd EXIT INT TERM

    # Preserve a pre-existing administrator mask. Otherwise block D-Bus/systemd
    # activation while stopping fprintd and restarting the proprietary USB owner.
    case "$original_state" in
        masked|masked-runtime)
            systemctl stop "$FPRINTD_UNIT"
            ;;
        *)
            systemctl mask --runtime --now "$FPRINTD_UNIT"
            masked_by_us=1
            ;;
    esac

    systemctl reset-failed "$VFS_UNIT" >/dev/null 2>&1 || true
    systemctl stop "$VFS_UNIT"
    local status=0
    if systemctl start "$VFS_UNIT"; then
        :
    else
        status=$?
        vfs491_restore_fprintd
        masked_by_us=0
        trap - EXIT INT TERM
        return "$status"
    fi
    if systemctl is-active --quiet "$VFS_UNIT"; then
        :
    else
        status=$?
        vfs491_restore_fprintd
        masked_by_us=0
        trap - EXIT INT TERM
        return "$status"
    fi
    vfs491_restore_fprintd
    masked_by_us=0
    trap - EXIT INT TERM
    systemctl reset-failed "$VFS_UNIT" "$FPRINTD_UNIT" >/dev/null 2>&1 || true
    printf '%s\n' "VFS491 service recovered. fprintd's previous mask state was preserved."
}

vfs491_main() {
    vfs491_require_root
    vfs491_recover_impl
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    vfs491_main "$@"
fi
