# VFS491 1.0.0 — V2.0.0 architecture

## Target

- HP EliteBook 8470p, Validity VFS491 USB `138a:003d`
- Linux Mint 22.x / Ubuntu 24.04 base, x86_64
- Installed `libfprint 1.94.7+tod1` core and TOD runtime must match exactly
- No other VFS model is enabled or hardware-certified

## Process ownership

1. `vfs491d.service` starts `vfs491d-launcher` inside private mount, IPC and temporary-file namespaces.
2. The launcher verifies USB stability and obtains the host-visible exclusive VFS491 lock.
3. The launcher starts `vcsFPService`, records its PID, verifies the vendor readiness marker, and waits for USB stability again.
4. The launcher starts the Unix-socket broker as a supervised child and monitors both broker liveness and the exact vendor-service PID.
5. If the vendor process exits or changes PID, the launcher terminates the broker and fails the systemd unit. If the broker exits unexpectedly, the launcher also fails the unit.
6. Systemd restarts failed units with a bounded start rate (30 starts per 300 seconds). This accommodates repeated user-triggered 30-second no-swipe recoveries without immediately exhausting the default five-start burst, while still bounding startup crash loops. Vendor stdout/stderr and broker/helper diagnostics go to the journal.
7. `ExecStartPost` opens the actual broker socket, checks `READY`, and sends `QUIT` before systemd considers startup complete.

## Capture protocol

- A per-claim client proxy connects to `/var/lib/vfs491/control.sock`.
- `CAPTURE` starts a fresh bridge and preserved reference helper process.
- The helper receives three inherited pipe descriptors for ready, metadata and image data.
- The bridge validates metadata and the exact payload length, then emits a versioned `VFS1` frame.
- The broker validates the frame again before forwarding it to the TOD backend.
- The TOD backend retains the archived Validity image flags `FPI_IMAGE_COLORS_INVERTED | FPI_IMAGE_V_FLIPPED`.
- Successful captures leave the persistent service running and can be followed by another capture in the same device claim.

## Poisoned-session recovery

The original helper has a hard 30-second alarm while waiting inside `vfs_capture()`. Its signal handler calls `exit(ETIMEDOUT)` directly; that bypasses `vfs_free_img_data()`, `vfs_clean_handles()` and `vfs_dev_exit()`. The original source also warns that killing an application while it is waiting in `vfs_capture()` can lock the vendor IPC path.

Therefore, V2.0.0 does not interpret this timeout as an idle retry. It treats the vendor session as tainted:

1. Bridge status 10 (vendor no-swipe timeout), status 12 (abnormal helper termination) or active-capture cancellation causes the broker to mark the service for reset.
2. The broker sends `ERR 14` to the TOD backend. The backend reports a session error instead of requesting another capture from the same vendor session.
3. The broker waits for the fprintd/TOD client to send `QUIT` or disconnect, up to a bounded drain timeout. This allows the active `FpDevice` claim to close before service teardown.
4. The broker exits with status 75. The launcher then stops the exact vendor process and exits with the same non-zero status.
5. Systemd restarts the service, waits for vendor and broker readiness, and reopens the socket.

Status 11 is reserved for `VFSW_CAPTURE_ERROR`, where the preserved helper logs `Could not capture fingerprint`, exits with status 1 and reaches its normal cleanup path. The bridge recognizes that exact helper diagnostic instead of assuming an undocumented exit code. The TOD backend applies a small bounded retry budget to this condition only.

The drain timeout is a final liveness bound, not proof that fprintd always closes the claim within that time. Hardware logs must confirm the expected `QUIT`/disconnect sequence. If the timeout expires, service restart still proceeds to prevent a permanently wedged machine, and the journal records the forced recovery.

## Enrollment and matcher baseline

- Enrollment count is one stage, matching `VFS_PROPRIETARY_NR_ENROLL 1` in the archived Validity source.
- Matcher threshold remains explicitly 40, the bundled libfprint 1.94.7 default.
- No image rotation, mirroring, resizing, crop, intensity normalization or automatic quality rejection is added.
- Image telemetry is observational only.

## Package boundary

- Installs the TOD module, broker, client, bridge, helper launcher, vendor stack, firmware, systemd unit, fprintd ordering drop-in and diagnostics.
- Pins the exact installed libfprint core/TOD versions.
- Does not edit PAM, LightDM, Fingwit, Cinnamon or GNOME Keyring configuration.
- On purge, removes `/var/lib/vfs491` and the VFS491 runtime lock. User fingerprint enrollment data under `/var/lib/fprint` is not removed by the package.

## Hardware acceptance

A successful build is not hardware acceptance. Validate cold boot, repeated frame captures, same-finger matching, different-finger rejection, enrollment, close/reopen, no-swipe timeout, cancellation, vendor crash recovery, broker crash recovery, fprintd restart, suspend/resume, unplug/replug, LightDM, lock screen and `sudo`. Record PID changes, USB bus/device number, frame metrics and service restart timestamps.
