#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

VENDOR_DIR=/usr/lib/vfs491/vendor
FIRMWARE="$VENDOR_DIR/firmware/HPUsbVFS491.img"
BRIDGE=/usr/libexec/vfs491/vfs491-bridge
HELPER=/usr/libexec/vfs491/vfs_proprietary-capture-helper
READFULL=/usr/lib/vfs491/libvfs491-readfull.so
DAEMON=/usr/libexec/vfs491/vfs491d.py
SOCKET=/var/lib/vfs491/control.sock
READY_MARKER=/tmp/vcsSemKey_ServiceReady
SERVICE_ID=/tmp/vcsSemKey_ServiceId
SERVICE_PID=""
SERVICE_STARTTIME=""
PIDOF_STAGED=""
FRAME_FILE=""
LAUNCHER_PID=""
BROKER_PID=""
NAMESPACE_ISOLATED=0
PRIVATE_MOUNTS_ACTIVE=0
SERVICE_LAUNCHED=0
CLEANING=0

log() { printf 'vfs491d: %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit "${2:-20}"; }

same_namespace() {
    local kind="$1" self_ns init_ns
    self_ns="$(readlink "/proc/self/ns/$kind")" || return 0
    init_ns="$(readlink "/proc/1/ns/$kind")" || return 0
    [[ "$self_ns" == "$init_ns" ]]
}

find_vendor_pids() {
    local proc state exe base comm proc_mnt self_mnt proc_ipc self_ipc
    for proc in /proc/[0-9]*; do
        [[ -d "$proc" ]] || continue
        state="$(awk '{print $3}' "$proc/stat" 2>/dev/null || true)"
        [[ "$state" != Z && "$state" != X && -n "$state" ]] || continue
        exe="$(readlink -f "$proc/exe" 2>/dev/null || true)"
        base="${exe##*/}"
        proc_mnt="$(readlink "$proc/ns/mnt" 2>/dev/null || true)"
        self_mnt="$(readlink /proc/self/ns/mnt 2>/dev/null || true)"
        proc_ipc="$(readlink "$proc/ns/ipc" 2>/dev/null || true)"
        self_ipc="$(readlink /proc/self/ns/ipc 2>/dev/null || true)"
        [[ "$proc_mnt" == "$self_mnt" && "$proc_ipc" == "$self_ipc" ]] || continue
        if [[ "$base" == vcsFPService ]]; then
            printf '%s\n' "${proc##*/}"
            continue
        fi
        comm="$(cat "$proc/comm" 2>/dev/null || true)"
        [[ "$comm" == vcsFPService ]] && printf '%s\n' "${proc##*/}"
    done
}

find_any_vendor_service() {
    local pids
    pids="$(find_vendor_pids || true)"
    [[ -z "$pids" ]] || { printf '%s\n' "${pids%%$'\n'*}"; return 0; }
    return 1
}

wait_sensor_stable() {
    local required="${1:-8}" deadline=$((SECONDS + 25))
    local current="" previous="" stable=0 path vendor product devnum
    while (( SECONDS < deadline )); do
        current=""
        for path in /sys/bus/usb/devices/*; do
            [[ -r "$path/idVendor" && -r "$path/idProduct" && -r "$path/devnum" ]] || continue
            vendor="$(<"$path/idVendor")"
            product="$(<"$path/idProduct")"
            [[ "$vendor" == 138a && "$product" == 003d ]] || continue
            devnum="$(<"$path/devnum")"
            current="${path##*/}:$devnum"
            break
        done
        if [[ -n "$current" && "$current" == "$previous" ]]; then
            stable=$((stable + 1))
            (( stable >= required )) && { log "VFS491 USB stable: $current"; return 0; }
        else
            previous="$current"
            stable=0
        fi
        sleep 0.1
    done
    return 1
}

proc_identity() {
    local pid="$1" stat_text
    stat_text="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    awk '{ sub(/^.*\) /, ""); print $1, $20 }' <<< "$stat_text"
}

stop_vendor_service() {
    local pid="${SERVICE_PID:-}" identity state starttime exe="" comm=""
    [[ -n "$pid" && -n "$SERVICE_STARTTIME" ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    identity="$(proc_identity "$pid" 2>/dev/null || true)"
    read -r state starttime <<< "$identity"
    if [[ "$starttime" != "$SERVICE_STARTTIME" ]]; then
        log "service PID $pid identity changed; refusing to signal a reused PID"
        return 0
    fi
    [[ "$state" != Z && "$state" != X ]] || return 0
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    if [[ "${exe##*/}" != vcsFPService && "$comm" != vcsFPService ]]; then
        log "service PID $pid no longer identifies vcsFPService; leaving it untouched"
        return 0
    fi
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
        identity="$(proc_identity "$pid" 2>/dev/null || true)"
        read -r state starttime <<< "$identity"
        [[ "$starttime" == "$SERVICE_STARTTIME" ]] || return 0
        [[ "$state" != Z && "$state" != X ]] || return 0
        sleep 0.1
    done
    identity="$(proc_identity "$pid" 2>/dev/null || true)"
    read -r state starttime <<< "$identity"
    if [[ "$starttime" == "$SERVICE_STARTTIME" && "$state" != Z && "$state" != X ]]; then
        exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        if [[ "${exe##*/}" == vcsFPService || "$comm" == vcsFPService ]]; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
}

cleanup() {
    local rc=$?
    (( CLEANING == 1 )) && return 0
    CLEANING=1
    trap - EXIT TERM INT HUP
    [[ -z "$FRAME_FILE" ]] || rm -f "$FRAME_FILE" || true
    # Never touch host service processes or host marker paths if isolation
    # validation failed or private mounts were not established.
    if (( NAMESPACE_ISOLATED == 1 )); then
        # On an intentional service stop, shut down broker/bridge/helper first.
        # This keeps the vendor IPC owner alive until its capture children exit.
        if [[ -n "$BROKER_PID" ]]; then
            if pid_is_running "$BROKER_PID"; then
                kill -TERM "$BROKER_PID" 2>/dev/null || true
                for _ in $(seq 1 50); do
                    pid_is_running "$BROKER_PID" || break
                    sleep 0.1
                done
                pid_is_running "$BROKER_PID" && kill -KILL "$BROKER_PID" 2>/dev/null || true
            fi
            wait "$BROKER_PID" 2>/dev/null || true
            BROKER_PID=""
        fi
        if (( SERVICE_LAUNCHED == 1 )); then
            # Stop only the exact vendor process captured at startup.
            stop_vendor_service
            # The service is launched as a direct child (the subshell execs it).
            # Reap it so controlled resets do not leave zombies.
            if [[ -n "$LAUNCHER_PID" ]]; then
                wait "$LAUNCHER_PID" 2>/dev/null || true
                LAUNCHER_PID=""
            fi
        fi
        [[ -z "$PIDOF_STAGED" ]] || rm -f "$PIDOF_STAGED" || true
        if (( PRIVATE_MOUNTS_ACTIVE == 1 )); then
            rm -f "$READY_MARKER" "$SERVICE_ID" /run/ValidityService.pid
        fi
        rm -f "$SOCKET" || true
        log "persistent daemon stopped; private IPC namespace will be destroyed"
    fi
    return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

[[ $EUID -eq 0 ]] || fail "must run as root through fprintd"
if same_namespace mnt; then
    fail "mount namespace is not private; refusing to mount over host paths"
fi
if same_namespace ipc; then
    fail "IPC namespace is not private; refusing to start the vendor daemon"
fi
NAMESPACE_ISOLATED=1

for item in "$VENDOR_DIR/vcsFPService" "$VENDOR_DIR/libvfsFprintWrapper.so" \
            "$FIRMWARE" "$BRIDGE" "$HELPER" "$READFULL" "$DAEMON" \
            /usr/bin/stdbuf /usr/sbin/killall5; do
    [[ -e "$item" ]] || fail "required runtime file missing: $item"
done
[[ -x "$VENDOR_DIR/vcsFPService" && -x "$BRIDGE" && -x "$HELPER" && -x "$DAEMON" ]] || fail "runtime executable mode is invalid"
[[ -d /run/lock ]] || fail "/run/lock is unavailable before private /run setup"

# Hold the host-visible device lock for the entire systemd service lifetime.
exec 9>/run/lock/vfs491-capture.lock
flock -n 9 || fail "another VFS491 session is active" 21

if existing="$(find_any_vendor_service || true)" && [[ -n "$existing" ]]; then
    fail "another vcsFPService already exists (PID $existing); refusing to kill or reuse it"
fi

wait_sensor_stable 8 || fail "USB 138a:003d did not remain stable before service startup" 22

PIDOF_TARGET="$(readlink -f "$(command -v pidof || true)" 2>/dev/null || true)"
[[ "$PIDOF_TARGET" == /usr/sbin/* && -x "$PIDOF_TARGET" ]] || fail "pidof executable target is unavailable"
PIDOF_STAGED="$(mktemp /tmp/vfs491-pidof.XXXXXX)"
install -m 0755 "$PIDOF_TARGET" "$PIDOF_STAGED"

mount --make-rprivate /
mount -t tmpfs -o mode=0755,nosuid,nodev,size=1m tmpfs /run
mount -t tmpfs -o mode=0755,nosuid,nodev,size=2m tmpfs /usr/sbin
PRIVATE_MOUNTS_ACTIVE=1
mkdir -p -m 0755 /run/lock
install -m 0755 "$PIDOF_STAGED" /usr/sbin/killall5
rm -f "$PIDOF_STAGED"
PIDOF_STAGED=""
install -m 0644 "$FIRMWARE" /usr/sbin/HPUsbVFS491.img
rm -f "$READY_MARKER" "$SERVICE_ID"

log "starting persistent HP VFS491 service for the system lifetime"
SERVICE_LAUNCHED=1
(
    cd /
    export LD_LIBRARY_PATH="$VENDOR_DIR"
    exec "$VENDOR_DIR/vcsFPService"
) &
LAUNCHER_PID=$!

service_ready=0
for _ in $(seq 1 120); do
    mapfile -t pids < <(find_vendor_pids || true)
    if (( ${#pids[@]} > 0 )) && [[ -e "$READY_MARKER" ]]; then
        SERVICE_PID="${pids[0]}"
        service_ready=1
        break
    fi
    sleep 0.25
done
(( service_ready == 1 )) || fail "vcsFPService did not publish readiness within 30 seconds (launcher PID $LAUNCHER_PID)"
SERVICE_STARTTIME="$(proc_identity "$SERVICE_PID" | awk '{print $2}')"
[[ "$SERVICE_STARTTIME" =~ ^[0-9]+$ ]] || fail "could not record vcsFPService process start time"
wait_sensor_stable 8 || fail "VFS491 USB did not stabilize after HP service startup" 22

export VFS491_HP_LIBDIR="$VENDOR_DIR"
export VFS491_READFULL_SHIM="$READFULL"
export VFS491_READY_MARKER="$READY_MARKER"
export VFS491_VENDOR_PID="$SERVICE_PID"
export VFS491_VENDOR_STARTTIME="$SERVICE_STARTTIME"
export VFS491_SERVICE_START_WAIT_MS=1000
export VFS491_BRIDGE_TIMEOUT_MS=90000

pid_is_running() {
    local pid="$1" state
    [[ -r "/proc/$pid/stat" ]] || return 1
    state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)"
    [[ -n "$state" && "$state" != Z && "$state" != X ]]
}

vendor_pid_is_healthy() {
    local pid="$SERVICE_PID" identity state starttime exe comm
    [[ -r "/proc/$pid/stat" ]] || return 1
    identity="$(proc_identity "$pid" 2>/dev/null || true)"
    read -r state starttime <<< "$identity"
    [[ -n "$state" && "$state" != Z && "$state" != X ]] || return 1
    [[ "$starttime" == "$SERVICE_STARTTIME" ]] || return 1
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    [[ "${exe##*/}" == vcsFPService || "$comm" == vcsFPService ]]
}

log "HP service ready (PID $SERVICE_PID); starting supervised socket broker"
python3 "$DAEMON" --socket "$SOCKET" &
BROKER_PID=$!

while true; do
    if [[ -n "$BROKER_PID" ]] && ! pid_is_running "$BROKER_PID"; then
        set +e
        wait "$BROKER_PID"
        broker_status=$?
        set -e
        BROKER_PID=""
        log "capture broker exited unexpectedly with status $broker_status; vendor service is left untouched and VFS491 remains unavailable until sudo vfs491-recover"
    fi

    if ! vendor_pid_is_healthy; then
        if [[ "${VENDOR_LOST_LOGGED:-0}" != 1 ]]; then
            log "vendor service health lost (expected vcsFPService PID $SERVICE_PID); broker remains alive and will reject new captures; use vfs491-recover after fprintd is stopped"
            VENDOR_LOST_LOGGED=1
        fi
    else
        VENDOR_LOST_LOGGED=0
    fi

    sleep 1
done
