# VFS491 Driver 1.0.0 — V2.0.0 engineering record

## Scope and supported hardware

- Target: HP EliteBook 8470p, Validity VFS491 USB `138a:003d`.
- OS target: Linux Mint 22.x / Ubuntu 24.04 base, x86_64.
- TOD target: installed matching `libfprint-2-2` and `libfprint-2-tod1` 1.94.7+tod1 packages.
- This is a userspace libfprint TOD integration, not a kernel module and not a reverse-engineered USB protocol implementation.
- VFS495/VFS471 are not supported. Firmware files for other models do not establish support.

## Why V2.0.0 changes recovery

The Transaction 14 candidate treated socket `QUIT` or EOF as sufficient evidence that the fprintd claim had closed, then allowed the broker/launcher/systemd chain to restart the vendor service. That is too strong an assumption: the libfprint device close callback can be running inside the D-Bus `Release` method, before fprintd has necessarily returned from the method and relinquished its claim. A timeout-based restart is even less defensible.

V2.0.0 therefore chooses fail-closed behavior over speculative automatic recovery:

1. Successful captures continue to use the resident HP vendor service and a fresh isolated capture helper per swipe.
2. The preserved helper's no-swipe timeout (status 10), abnormal helper failure (status 12), cancellation during capture, malformed frame, unexpected bridge result, or vendor-process health loss marks the broker degraded.
3. The active TOD operation receives terminal broker status 14. The TOD backend reports a session error; it does not retry against a potentially poisoned vendor IPC session.
4. The broker remains alive but rejects later clients with status 14. If the broker itself exits, the launcher leaves the vendor daemon running and keeps the systemd unit alive but unavailable; the bridge has a parent-death signal so any in-flight helper is terminated and reaped.
5. The launcher stops the broker before the vendor daemon on an intentional service stop. systemd uses `Restart=no`, preventing an unexpected launcher exit from automatically restarting the vendor service while fprintd might still hold a claim.
6. An administrator runs `sudo vfs491-recover`. The utility runtime-masks/stops `fprintd.service`, stops and starts `vfs491d.service`, then restores fprintd's prior mask state. This is explicit recovery, not automatic recovery.

This policy deliberately does not claim that socket close proves D-Bus claim release. The explicit recovery script uses service-level fprintd shutdown to close outstanding claims before the vendor service is restarted.

## Capture outcome classification

- Status 0: validated grayscale frame with width 200, height 1..1023 and exact payload length.
- Status 11: the preserved helper's `VFSW_CAPTURE_ERROR` / `Could not capture fingerprint` path, which exits through its normal cleanup path; TOD applies a bounded retry budget.
- Status 10: helper no-swipe alarm. The legacy signal handler calls `exit(ETIMEDOUT)` before the normal wrapper cleanup label; session is poisoned.
- Status 12: helper/bridge abnormal termination or interruption; session is poisoned.
- Status 14: poisoned vendor session / terminal device-session failure.

The binary helper remains a vendor/reference artifact. The source snapshot does not contain a complete build context sufficient to claim a source-reproducible replacement helper.

## Process and IPC boundaries

- `vcsFPService` runs in the private mount, IPC and temporary-file namespaces created by the systemd service.
- The launcher records the exact vendor PID and `/proc` start time. It monitors the vendor process and broker process.
- The broker socket is root-only (`0600`) inside a root-owned state directory and authenticates peers using Linux `SO_PEERCRED`.
- Each fprintd claim has its own client proxy; each swipe gets a fresh bridge/helper process. The bridge uses `PR_SET_PDEATHSIG` so broker death terminates the bridge, which in turn terminates and reaps its helper.
- Broker frame validation is repeated before data reaches TOD: magic/version, width, height, image length and exact total frame length.
- Runtime image telemetry records derived statistics only; it does not log raw fingerprint pixels or templates.

## Enrollment and matching baseline

- Enrollment stage count is one, matching the archived Validity proprietary source declaration.
- Bozorth3 threshold remains 40, matching the bundled libfprint 1.94.7 default used by the prior integration.
- Original image flags are retained: `FPI_IMAGE_COLORS_INVERTED | FPI_IMAGE_V_FLIPPED`.
- No speculative resize, crop, rotation, normalization or automatic rejection threshold is introduced.
- The previous T12 five-stage experiment is not treated as evidence of better recognition.

## Package behavior

- The package installs the TOD module, broker, client proxy, bridge, reference helper launcher, vendor payload, systemd unit, diagnostics and `vfs491-recover`.
- The package pins the exact installed core/TOD versions and refuses a mismatched ABI.
- Package installation does not modify PAM or restart an already-running fprintd instance.
- Package removal/upgrade runtime-masks/stops fprintd before stopping the vendor service.
- Purge removes VFS491 runtime state but deliberately does not delete user enrollment data under `/var/lib/fprint`.
- Proprietary HP binaries/firmware are retained for the user's local build. Their redistribution rights have not been established; do not publish those files as LGPL source.

## Offline validation results in the development container

The container is Debian 13, not the target Mint/Ubuntu runtime, and has no installed `libfprint-2-2` or `libfprint-2-tod1` target packages. A private build sysroot was reused from the user's T13 archive for syntax checking only.

Passed individually:

- shell/Python/C syntax and static architecture checks (`scripts/check-source.sh`);
- bridge frame, timeout, acquisition-error, malformed-ready and child-reaping tests;
- persistent broker multi-claim tests;
- broker poisoned-timeout, cancellation, bounded-drain, acquisition-retry and vendor-health-loss tests;
- recovery-script tests for fprintd mask ordering, failure cleanup and preservation of an administrator's pre-existing mask;
- systemd readiness probe tests;
- image diagnostics (6 tests) and C image-metrics tests;
- boot ordering/diagnostic tests;
- PAM configuration parser tests;
- CH_EVENT full-read shim tests.

Not passed or not run:

- target TOD link/package build: `scripts/build.sh` refuses because the development container lacks installed `libfprint-2-2`; this is intentional ABI protection, not a successful build.
- systemd isolation runtime test: skipped/failed in this container because PID 1 is not systemd and no system D-Bus is available.
- `.deb` build/install on Mint 22.3: not performed.
- physical VFS491 capture, enrollment, verification, wrong-finger rejection, suspend/resume, USB replug, LightDM/PAM and soak tests: not performed.

## Hardware release gate

Do not call the release hardware-validated until the HP laptop completes: cold boot; 20 consecutive successful swipes; 20 genuine verification attempts; at least 10 different-finger rejections; cancellation; 30-second no-swipe; explicit `vfs491-recover`; fprintd claim/release cycles; suspend/resume; USB replug; LightDM lock/unlock; password fallback; and a multi-hour soak test. Preserve journal logs and image metrics but do not publish raw biometric data.

## Upstream and community references

- libfprint project overview and driver purpose: https://fprint.freedesktop.org/
- fprintd D-Bus Device API, including `Claim`, `Release`, `VerifyStatus`, `EnrollStatus` and terminal/retry status meanings: https://fprint.freedesktop.org/fprintd-dev/Device.html
- libfprint driver-development API reference: https://fprint.freedesktop.org/libfprint-stable/
- Linux USB sysfs ABI (`busnum`, `devnum` and descriptors): https://github.com/torvalds/linux/blob/master/Documentation/ABI/stable/sysfs-bus-usb
- systemd service restart semantics: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- Community VFS proprietary driver architecture and its documented proprietary-daemon/library dependency and lockup history: https://github.com/rindeal/libfprint-vfs_proprietary-driver
- Current libfprint development supported-device list: https://fprint.freedesktop.org/supported-devices.html

The community project is historical evidence of the VFS proprietary architecture, not proof that its old code is compatible with the installed 1.94.7+tod1 ABI. The VFS491 implementation here uses the user's locally supplied SP84530 payload and a separately compiled TOD module. The USB protocol remains undocumented in the available sources; no independent protocol implementation is claimed.
