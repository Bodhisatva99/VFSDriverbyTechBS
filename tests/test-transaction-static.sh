#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT/scripts/vfs491d-launcher.sh"
DAEMON="$ROOT/scripts/vfs491d.py"
CLIENT="$ROOT/scripts/vfs491-client.py"
UNIT="$ROOT/systemd/vfs491d.service"
TOD="$ROOT/src/vfs491-tod.c"
BRIDGE="$ROOT/src/vfs491-bridge.c"
HELPER_LAUNCHER="$ROOT/scripts/vfs491-helper-launcher.sh"
READFULL="$ROOT/src/vfs491-readfull.c"
BUILDER="$ROOT/scripts/build-system-deb.sh"
WAIT_READY="$ROOT/scripts/vfs491-wait-ready.py"
PREFLIGHT="$ROOT/scripts/preflight.sh"
METRICS="$ROOT/src/vfs491-image-metrics.c"
METRICS_HEADER="$ROOT/include/vfs491-image-metrics.h"

bash -n "$LAUNCHER" "$HELPER_LAUNCHER" "$ROOT/scripts/vfs491-recover.sh" "$ROOT/tests/test-recovery-script.sh"
python3 -m py_compile "$DAEMON" "$CLIENT" "$WAIT_READY" "$ROOT/scripts/vfs491-verify-study.py"
python3 - "$LAUNCHER" "$DAEMON" "$CLIENT" "$UNIT" "$TOD" "$BRIDGE" "$HELPER_LAUNCHER" "$READFULL" "$BUILDER" "$WAIT_READY" "$METRICS" "$METRICS_HEADER" "$ROOT/scripts/vfs491-recover.sh" "$ROOT/scripts/vfs491-verify-study.py" "$PREFLIGHT" <<'PY'
from pathlib import Path
import sys
launcher, daemon, client, unit, tod, bridge, helper_launcher, readfull, builder, wait_ready, metrics, metrics_header, recover, verify_study, preflight = [Path(x).read_text() for x in sys.argv[1:]]
open_fn = tod[tod.index('vfs491_img_open (FpImageDevice *device)'):tod.index('vfs491_img_close (FpImageDevice *device)')]
close_fn = tod[tod.index('vfs491_img_close (FpImageDevice *device)'):tod.index('vfs491_activate (FpImageDevice *device)')]
deactivate_fn = tod[tod.index('vfs491_deactivate (FpImageDevice *device)'):tod.index('vfs491_change_state (FpImageDevice *device,')]
frame_read_fn = tod[tod.index('vfs491_frame_read_done (GObject *source_object,'):tod.index('vfs491_response_line_done (GObject *source_object,')]
checks = [
    ("mount and IPC namespace guards precede mount operations", launcher.index('same_namespace ipc') < launcher.index('mount --make-rprivate /')),
    ("launcher verifies private mount and IPC namespaces", 'same_namespace mnt' in launcher and 'same_namespace ipc' in launcher),
    ("vendor service starts before persistent broker", launcher.index('exec "$VENDOR_DIR/vcsFPService"') < launcher.index('python3 "$DAEMON"')),
    ("vendor service is not tied to client QUIT", 'received session close request' not in launcher and 'python3 "$DAEMON"' in launcher),
    ("systemd vendor service is on-demand and avoids boot-time hardware blocking", 'Restart=no' in unit and 'WantedBy=multi-user.target' not in unit),
    ("systemd keeps service namespaces isolated", 'PrivateMounts=yes' in unit and 'PrivateIPC=yes' in unit and 'PrivateTmp=yes' in unit),
    ("systemd does not restart a possibly claimed USB device automatically", 'Restart=no' in unit and 'D-Bus Release method' in unit),
    ("systemd waits for real broker protocol readiness", 'Type=exec' in unit and 'ExecStartPost=/usr/libexec/vfs491/vfs491-wait-ready' in unit and 'TimeoutStartSec=150s' in unit and 'Type=notify' not in unit),
    ("readiness probe verifies READY and closes only its temporary client", 'READY' in wait_ready and 'QUIT\\n' in wait_ready and 'time.monotonic()' in wait_ready),
    ("broker no longer relies on NOTIFY_SOCKET inside private /run", 'notify_systemd' not in daemon and 'NOTIFY_SOCKET' not in daemon),
    ("daemon exposes a persistent Unix socket", 'SOCKET_PATH' in daemon and 'server.listen' in daemon and '/var/lib/vfs491/control.sock' in daemon),
    ("daemon authenticates local peer as root", 'SO_PEERCRED' in daemon and 'uid == 0' in daemon),
    ("daemon launches the reference bridge per capture", 'subprocess.Popen' in daemon and '[BRIDGE, HELPER]' in daemon),
    ("broker validates the exact vendor PID, process start time and readiness marker before captures", 'VFS491_VENDOR_PID' in daemon and 'VFS491_VENDOR_STARTTIME' in daemon and 'vendor_service_health' in daemon and 'READY_MARKER' in daemon),
    ("launcher records and continuously checks vendor PID start time", 'SERVICE_STARTTIME=' in launcher and '[[ "$starttime" == "$SERVICE_STARTTIME" ]]' in launcher),
    ("poisoned captures fail closed with status 14", 'SESSION_RESET_STATUS = 14' in daemon and 'ERR {SESSION_RESET_STATUS}' in daemon and 'DEGRADED = True' in daemon),
    ("broker never restarts vendor USB state from a TOD close callback", 'D-Bus Release method' in daemon and 'automatic reset disabled' in daemon and 'request_service_reset' not in daemon and 'RESTART_REQUESTED' not in daemon),
    ("capture cancellation poisons the session without automatic restart", 'capture was cancelled while proprietary helper was active' in daemon and 'DEGRADED = True' in daemon),
    ("launcher leaves failed vendor service isolated for explicit recovery", 'pid_is_running' in launcher and 'find_any_vendor_service' in launcher and 'vendor service is left untouched' in launcher and 'fail "capture broker exited' not in launcher),
    ("intentional launcher shutdown stops broker before vendor service", 'shut down broker/bridge/helper first' in launcher and 'kill -TERM "$BROKER_PID"' in launcher),
    ("explicit recovery masks and stops fprintd before vendor restart", 'systemctl mask --runtime --now' in recover and 'systemctl stop "$VFS_UNIT"' in recover),
    ("vendor service diagnostics are retained in the system journal", ') >/dev/null 2>&1 &' not in launcher),
    ("daemon validates image framing before forwarding", 'def validate_frame' in daemon and 'validate_frame(bytes(frame))' in daemon),
    ("client starts service and allows full bounded startup window", 'systemctl' in client and 'start_service()' in client and 'timeout=170' in client),
    ("client uses Unix socket and byte-transparent proxy", 'AF_UNIX' in client and 'sock.sendall(chunk)' in client),
    ("TOD uses per-claim proxy rather than transient systemd unit", 'VFS491_DEFAULT_CLIENT' in tod and 'systemd-run' not in tod and 'systemctl' not in tod),
    ("TOD opens client during fprintd claim", 'vfs491_start_session (self);' in open_fn),
    ("TOD sends QUIT only to client connection on close", 'QUIT\\n' in close_fn and 'g_output_stream_close' in close_fn),
    ("normal deactivation does not close persistent broker", 'fpi_image_device_deactivate_complete (device, NULL)' in deactivate_fn and 'QUIT' not in deactivate_fn.split('/* Cancellation')[0]),
    ("reference CH_EVENT read shim retained without IPC keepalive", 'LD_PRELOAD' in helper_launcher and 'READFULL' in helper_launcher and 'keepalive' not in helper_launcher.lower()),
    ("read shim targets only CH_EVENT FIFO", 'strstr(target, "/tmp/CH_EVENT") != NULL' in readfull),
    ("bridge does not inject SysV IPC keepalive", 'VFS491_IPC_KEEPALIVE_SO' not in bridge and 'libvfs491-ipc-keepalive' not in bridge),
    ("bridge terminates if its broker parent dies", 'PR_SET_PDEATHSIG' in bridge and 'getppid() != broker_pid' in bridge),
    ("preflight uses the project version and requires 2.0.3 engineering records", 'VERSION=' in preflight and '2.0.3-ENGINEERING.md' in preflight and 'PROJECT-HANDOFF.md' in preflight and 'vfs491-verify-study.py' in preflight),
    ("package version is V2.0.3", 'Version: 2.0.3-1' in builder),
    ("package installs explicit recovery utility", 'vfs491-recover.sh' in builder and 'vfs491-recover' in builder),
    ("package staging creates /usr/sbin before installing recovery utility", '"$STAGE/usr/sbin"' in builder),
    ("production matcher threshold is explicit and unchanged at libfprint default 40", 'image_class->bz3_threshold = 40;' in tod),
    ("VFS491 enrollment uses the archived Validity one-stage baseline", 'device_class->nr_enroll_stages = VFS491_ENROLL_STAGES;' in tod and '#define VFS491_ENROLL_STAGES 1' in tod),
    ("poisoned vendor timeout is terminal for the current claim", all(token in tod for token in ('status == VFS491_BROKER_ERR_NO_SWIPE_SESSION_RESET',
                                                'status == VFS491_BROKER_ERR_HELPER_FAILURE',
                                                'status == VFS491_BROKER_ERR_SESSION_RESET')) and 'vfs491_retry_no_swipe' not in tod),
    ("each enrollment stage submits a captured image to libfprint", 'fpi_image_device_image_captured (FP_IMAGE_DEVICE (self), image);' in tod),
    ("image-device deactivation keeps the per-claim broker proxy until close", 'Keep the per-claim broker proxy open until img_close().' in tod and 'self->session_job' in tod[tod.index('vfs491_activate (FpImageDevice *device)'):tod.index('vfs491_deactivate (FpImageDevice *device)')]),
    ("capture telemetry uses per-claim IDs and logs derived metrics only", 'VFS491_EVENT type=frame' in tod and 'claim_id=%s capture=%u' in tod and 'vfs491_image_metrics_compute' in tod),
    ("frame elapsed time is captured before its timer is cleared", frame_read_fn.index('const gdouble capture_ms =') < frame_read_fn.index('self->capture_started_us = 0;') < frame_read_fn.index('vfs491_deliver_frame (self, bytes, capture_ms);')),
    ("image metrics implementation is separately unit-tested", 'percentile_value' in metrics and 'entropy' in metrics and 'horizontal_gradient_mean' in metrics_header),
    ("original Validity polarity and vertical orientation are preserved", 'FPI_IMAGE_COLORS_INVERTED | FPI_IMAGE_V_FLIPPED' in tod),
    ("diagnostic capture tool is installed", 'vfs491-image-diagnostics.py' in builder),
    ("verification study utility is installed", 'vfs491-verify-study.py' in builder and 'vfs491-verify-study' in builder),
    ("project handoff is installed with package documentation", 'PROJECT-HANDOFF.md' in builder and 'docs/PROJECT-HANDOFF.md' in preflight),
    ("verification study records derived telemetry but not raw biometric payloads", 'extract_events' in verify_study and 'capture_events' in verify_study and 'fingerprint pixels' in verify_study and 'command transcript' in verify_study),
    ("claim UUID is generated per device claim", 'g_uuid_string_random' in tod and 'self->capture_sequence = 0;' in open_fn),
    ("package installs bounded readiness probe", 'vfs491-wait-ready.py' in builder and 'vfs491-wait-ready' in builder),
    ("package does not auto-start hardware service during installation", 'systemctl start vfs491d.service' not in builder and 'systemctl daemon-reload' in builder),
    ("package does not restart fprintd during installation", 'systemctl try-restart fprintd.service' not in builder),
    ("PAM and LightDM are not modified by driver package", 'libpam-fprintd' not in builder and 'pam-auth-update' not in builder),
    ("verification study requests structured journal JSON", "--output=json" in verify_study),
    ("verification study filters journal events to the exact verify interval", "__REALTIME_TIMESTAMP" in verify_study and "start_realtime_us" in verify_study and "end_realtime_us" in verify_study),
    ("verification study preserves an auditable journal timestamp", "journal_realtime_us" in verify_study),
    ("verification study prevents concurrent study windows", "flock" in verify_study and "LOCK_NB" in verify_study),
    ("verification study refuses output symlinks and non-regular files", "O_NOFOLLOW" in verify_study and "S_ISREG" in verify_study),
]
for label, ok in checks:
    print(("PASS" if ok else "FAIL") + ": " + label)
if not all(ok for _, ok in checks):
    raise SystemExit(1)
PY
