# VFS491 Linux Fingerprint Driver

A Linux userspace driver integration for the **Validity VFS491** fingerprint sensor (`138a:003d`), developed for the **HP EliteBook 8470p**. It connects the HP/Validity vendor stack to the `libfprint` TOD and `fprintd` interfaces.

> **Status:** Version 2.0.3 is an audited source candidate, not a hardware-certified release. The native backend has not yet been built against the target runtime, and the current source still needs physical-laptop acceptance testing. Review [validation status](#validation-status) before installing.

## Hardware and support status

| Sensor | USB ID | Status |
|---|---|---|
| Validity VFS491 | `138a:003d` | Project target: HP EliteBook 8470p. The current 2.0.3 source still needs fresh build and hardware validation. |
| Validity VFS495 | Not confirmed | Not certified or claimed as supported. |
| Validity VFS471 | Not confirmed | Not certified or claimed as supported. |

This is a userspace `libfprint` TOD backend and service integration, not a kernel driver. The VFS491 is not listed as an upstream-supported device by [libfprint](https://fprint.freedesktop.org/supported-devices.html); this repository is an out-of-tree integration for its specific target. Files or references for other sensors do not establish support for them.

## Target platform and requirements

- HP EliteBook 8470p with a Validity VFS491 (`138a:003d`)
- Linux Mint 22.x / Ubuntu 24.04 base, x86_64 (amd64)
- Matching installed `libfprint-2-2` and `libfprint-2-tod1` packages with the expected `1.94.7+tod1` ABI
- Build utilities used by the project, including GCC, Make, Python 3, and Debian packaging tools
- HP/Validity vendor service, wrapper library, firmware, and reference capture helper; these components retain their own provenance and license terms

The build intentionally refuses an unexpected or mismatched `libfprint` core/TOD ABI. Build on the target laptop or a matching environment; do not substitute a different ABI.

## Build and test

Run from the repository root on the intended target or a matching build host:

```bash
make bootstrap
make check
make build
make test
make isolation-test
make package
```

The bootstrap prepares the private build sysroot. The package step validates the installed runtime and vendor payload before creating the Debian package under `debs/`.

For a physical-device capture test after installation:

```bash
make hardware-test
```

This test starts `vfs491d.service` and performs two captures across two claims. It is not a substitute for the full acceptance plan in [`docs/HARDWARE-ACCEPTANCE.md`](docs/HARDWARE-ACCEPTANCE.md).

## Install and use

After `make package` succeeds, install the generated package (the current package version is `2.0.3-1`):

```bash
sudo apt install ./debs/vfs491-fprintd-tod_2.0.3-1_amd64.deb
```

The package does **not** modify PAM policy. Configure fingerprint authentication separately if desired, and keep password authentication available as a fallback; see [`docs/PAM-AUTHENTICATION.md`](docs/PAM-AUTHENTICATION.md).

Enroll and verify with the normal fprintd tools:

```bash
fprintd-enroll "$USER"
fprintd-verify "$USER"
fprintd-list "$USER"
```

For attempt-level study, run one verification at a time and check the available options first:

```bash
vfs491-verify-study --help
```

The study tool writes private JSONL diagnostic records and correlates verification with capture telemetry. It does not record raw fingerprint pixels, templates, or minutiae. See [`docs/2.0.3-ENGINEERING.md`](docs/2.0.3-ENGINEERING.md).

## Architecture and safety

- Native `libfprint` TOD backend using the standard fprintd interface.
- Systemd-managed, isolated HP vendor service and root-only local broker.
- Per-claim client connection and a fresh reference capture-helper process for each swipe.
- Frame validation and structured capture telemetry; diagnostics report derived image metrics, not biometric pixels.
- A timed-out, interrupted, or malformed capture can poison the vendor session. The broker fails closed rather than continuing to reuse a potentially damaged session.
- Recovery is explicit: `sudo vfs491-recover` coordinates fprintd and the vendor service. A TOD close callback or socket EOF is not treated as proof that fprintd has released the device.
- The archived recognition baseline is retained: one-stage enrollment, matcher threshold `40`, and the original Validity image flags. No recognition improvement is claimed without controlled evidence.

More detail: [`docs/ARCHITECTURE-2.0.0.md`](docs/ARCHITECTURE-2.0.0.md), [`docs/RECOGNITION-PIPELINE.md`](docs/RECOGNITION-PIPELINE.md), and [`docs/PROJECT-HANDOFF.md`](docs/PROJECT-HANDOFF.md).

## Diagnostics and recovery

```bash
sudo /usr/libexec/vfs491/vfs491-diagnose
sudo journalctl -fu vfs491d.service -u fprintd.service
sudo vfs491-recover
```

Do not collect, publish, or upload raw fingerprint images or templates. See [`docs/HARDWARE-ACCEPTANCE.md`](docs/HARDWARE-ACCEPTANCE.md) for capture, cancellation, recovery, boot, suspend/resume, and soak-test checks.

## Validation status

Software and static checks cover the service/broker lifecycle, frame handling, recovery, and verification-study tooling. Passing software tests does not establish hardware support or release readiness. The current 2.0.3 source still requires validation on the target laptop, including:

- Native build/link against the exact installed `libfprint 1.94.7+tod1` core/TOD ABI and package inspection
- Package installation, upgrade, removal, and rollback
- Physical capture, enrollment, repeated genuine verification, and different-finger rejection
- Cancellation, no-swipe timeout, explicit recovery, suspend/resume, USB replug, login/lock flows, and a multi-hour soak test

See [`docs/PROJECT-HANDOFF.md`](docs/PROJECT-HANDOFF.md), [`docs/VALIDATION-RESULTS.md`](docs/VALIDATION-RESULTS.md), and [`CHANGELOG.md`](CHANGELOG.md) for the detailed engineering and release record. Do not describe 2.0.3 as hardware-certified until those gates pass and the evidence is recorded.

## License and vendor components

The integration is licensed under the GNU Lesser General Public License, version 2.1 or (at your option) any later version; see [`LICENSE`](LICENSE). Proprietary vendor binaries, firmware, and reference materials retain their own provenance and license terms and are not relicensed by this project.
