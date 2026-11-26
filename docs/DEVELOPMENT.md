# VFS491 Driver 2.0.3 — Developer and Validation Notes

## Target environment

- HP EliteBook 8470p
- Validity VFS491, USB `138a:003d`
- Linux Mint 22.x / Ubuntu 24.04 base, x86_64
- Matching installed `libfprint 1.94.7+tod1` core/TOD ABI

## Architecture

- Native libfprint TOD backend.
- On-demand `vfs491d.service` in private mount, IPC and temporary-file namespaces, ordered before fprintd.
- HP vendor service supervised by the launcher, plus a root-only broker.
- Per-claim fprintd proxy and fresh reference capture-helper process per swipe.
- Failed no-swipe/interrupted capture marks the vendor IPC session tainted. The broker fails the current TOD operation and remains degraded; it never treats socket `QUIT`/EOF as proof that fprintd's D-Bus `Release` method has returned.
- CH_EVENT full-read compatibility shim.
- D-Bus-activated `fprintd` ordered after VFS491 service readiness.

## Build

```bash
make bootstrap
make check
make build
make test
make isolation-test
make package
```

The output package is `debs/vfs491-fprintd-tod_2.0.3-1_amd64.deb`.
The build must run on the target laptop or an exact matching Mint/Ubuntu build environment. This source package deliberately refuses to substitute a different libfprint TOD ABI.

### Proprietary build boundary

The TOD backend, bridge, broker, service launcher, diagnostics and test harness are built from this repository. The HP service, Validity wrapper, firmware and known-good 0.3.2 helper are binary components. The legacy helper source snapshot is incomplete (its original support headers/build context are absent), so the build intentionally does not claim to compile that helper. A fully source-built helper requires a complete, redistributable source/build environment for the vendor wrapper API.

## Hardware acceptance matrix

1. Cold boot: service starts, exact vendor PID is monitored, broker socket becomes ready before fprintd use.
2. Successful captures: at least 20 consecutive successful swipes across independent claims; record frame dimensions, PID and USB devnum.
3. Enrollment: confirm the archived one-stage baseline is requested and completes; verify the enrolled finger at least 20 times.
4. Different-finger negative test: at least 10 attempts; all must reject.
5. Cancellation: interrupt a capture; confirm the helper is terminated, the broker enters degraded state, and no vendor/USB restart occurs automatically.
6. No-swipe timeout: leave the sensor untouched for the helper's full timeout; confirm `ERR 14`, broker degraded state, no repeated helper loop, and no automatic vendor PID change. Run `sudo vfs491-recover` with fprintd stopped/masked and confirm readiness returns.
7. Vendor-process failure: terminate the vendor service in a controlled development test; launcher must detect it, broker must reject further capture, and the service must remain degraded until explicit recovery.
8. Broker failure: terminate the broker; its bridge/helper child must exit via parent-death handling, while the launcher leaves the vendor service untouched and keeps the unit unavailable. Use the recovery utility to stop fprintd before restarting the service.
9. Repeated authentication: `sudo`, lock/unlock, LightDM login, warm reboot and cold boot.
10. Lifecycle: fprintd restart, suspend/resume, unplug/replug and USB reset events.
11. Regression: password authentication must remain available when fingerprint hardware is unavailable.

A release is not certified until the target-laptop matrix passes repeatedly, including a multi-hour soak test. A successful compile, unit test, frame capture or enrollment completion is not sufficient evidence of reliable authentication.

## Recognition telemetry workflow

`vfs491-verify-study` runs one interactive verify and joins its result with `VFS491_EVENT` records from `fprintd.service` in the same time window. The JSONL record is private by default (mode `0600`); it excludes the account name, output transcript and raw biometric data. Journal read permission is required for complete correlation. See `2.0.3-ENGINEERING.md`.
