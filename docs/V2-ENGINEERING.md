# VFS491 Driver 2.0.1 — engineering record

## Purpose and scope

This is a VFS491-only Linux userspace integration for USB ID `138a:003d`, intended for the HP EliteBook 8470p and Linux Mint 22.x / Ubuntu 24.04 x86_64. It is a native libfprint TOD module plus an isolated HP SP84530 service/capture stack. It is not a kernel module and does not implement a reverse-engineered USB protocol.

## What this release changes relative to T13–T15

- Makes build prerequisites explicit and fails before package staging if the exact target runtime, private headers, vendor payload, helper, or generated binaries are absent.
- `make package` is a deterministic build graph: bootstrap is separate, the target TOD module is built once, and the package step validates every staged source path before creating the package.
- The TOD integration keeps the vendor service outside the active fprintd claim. Each fprintd device open creates a client proxy; the proxy does not own or restart the vendor service.
- A no-swipe timeout is classified as a poisoned vendor session because the preserved vendor helper's timeout path exits before its normal wrapper cleanup. The backend reports a terminal session error. It does not loop indefinitely against the same vendor IPC.
- Recovery is explicit. `vfs491-recover` runtime-masks/stops fprintd before stopping and restarting the vendor service. A socket EOF/QUIT from the TOD close callback is not treated as proof that D-Bus Release has completed.
- The proprietary helper remains process-isolated. The project does not claim it can safely interrupt a vendor call that blocks inside the proprietary library.
- Enrollment is one stage, matching the archived original proprietary driver declaration. Threshold 40 and the original image flags are retained as a test baseline, not asserted as optimal recognition parameters.
- Package installation does not modify PAM. PAM integration remains an explicit, separately invoked operation.
- Package scripts do not delete fprintd enrollment data.

## Important distinction: recoverable versus poisoned

The broker distinguishes:
- successful, validated image frame;
- recoverable vendor acquisition error that follows the helper's normal cleanup path;
- no-swipe timeout that exits the helper without vendor API cleanup;
- helper termination/cancellation;
- malformed or truncated frame;
- vendor process identity loss.

Only the recoverable acquisition path is retried, and it has a finite budget. Poisoned states fail closed. Automatic service restart is deliberately not performed from the TOD close callback because it can execute before fprintd's D-Bus Release call has fully returned.

## Build and package

The build requires the exact target system's matching `libfprint-2-2` and `libfprint-2-tod1` 1.94.7+tod1 packages and their matching TOD ABI. It refuses a version mismatch. The private sysroot contains build headers only; it does not substitute a target runtime. The project must be built on the target Mint/Ubuntu machine to produce an installable package.

Commands:

```sh
make preflight
make bootstrap
make check
make test
make isolation-test
make build
make package
```

The package is not considered installable until `dpkg-deb -I` succeeds and the installed module is confirmed to load under the target fprintd/libfprint stack.

## Vendor payload and licensing

`vendor/compat`, `vendor/original`, the firmware, and `reference/working-prototype/vfs_proprietary-capture-helper.reference` are proprietary/reference artifacts supplied in the user's prior project. The archive preserves them for local reproducibility. Their redistribution rights have not been established. Do not publish these binaries/firmware as LGPL source or distribute them publicly without permission. The open integration source license does not relicense vendor artifacts.

## Validation status

Offline unit and protocol tests can validate framing, state transitions, bounded retries, process cleanup, and packaging preflight. They cannot prove the vendor service remains responsive on the physical laptop. No claim of hardware certification is made until the target laptop passes the acceptance plan in `docs/HARDWARE-ACCEPTANCE.md`.

## Hardware acceptance gate

1. Cold boot, 10 independent device claims.
2. 20 consecutive successful swipes, record capture times and frame dimensions.
3. 20 genuine-finger verification attempts; report matches and retry statuses.
4. At least 10 different-finger attempts; confirm no false acceptance.
5. No-swipe timeout, cancellation during capture, and malformed-frame fault injection.
6. Explicit recovery while fprintd is masked/stopped; confirm the previous mask state is restored.
7. USB unplug/replug, suspend/resume, lock-screen, LightDM and password fallback.
8. Four-hour idle/active soak test, with journal and process RSS/FD monitoring.
9. Confirm package removal leaves user enrollment data intact and restores service state.

Raw fingerprint images/templates must not be included in diagnostic bundles or public bug reports.


## 2.0.1 corrective update

The 2.0.0 build log supplied by the target laptop demonstrated that compilation and dynamic dependency validation completed, but package staging failed because `build-system-deb.sh` omitted the `build/package-root/usr/sbin` directory from its `mkdir -p` list. Version 2.0.1 creates that directory before installing the recovery executable. The recovery test now sources the implementation function and uses a mocked `systemctl`, allowing `make test` to run as an ordinary user while preserving the root-only production entry point.

## 2.0.1 corrective update

The 2.0.0 laptop build demonstrated that the native module linked against the installed 1.94.7+tod1 runtime and that source checks and namespace isolation passed. Package staging then failed because `usr/sbin` was absent from the staging directory list. Version 2.0.1 creates that directory before installing `vfs491-recover`. The recovery test now exercises the same implementation through a sourceable function with mocked `systemctl`, while the installed command retains the root-only check. No TOD C logic, matcher threshold, enrollment stage count or image transforms changed in this corrective version.
