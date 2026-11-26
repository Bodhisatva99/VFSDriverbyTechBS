# VFS491 Linux Fingerprint Driver 2.0.3

Linux fingerprint support for the **Validity VFS491** USB sensor (`138a:003d`) used in the HP EliteBook 8470p, integrated through the standard `libfprint` TOD and `fprintd` stack.

The implementation targets the HP EliteBook 8470p first. Other Validity VFS models are not hardware-certified.

## Hardware support

| Sensor | USB ID | Status |
|---|---|---|
| Validity VFS491 | `138a:003d` | Previously exercised on HP EliteBook 8470p; Transaction 15 requires fresh hardware validation |
| Validity VFS495 | Not confirmed | Firmware/reference material only |
| Validity VFS471 | Not confirmed | Firmware/reference material only |

Firmware presence does not establish support for another sensor.

## Architecture

- Native `libfprint` 1.94.7 TOD backend and standard `fprintd` interface.
- Systemd-managed HP vendor service, activated on demand through fprintd ordering and isolated in private mount, IPC and temporary-file namespaces.
- Root-only Unix-socket broker and per-claim capture proxy.
- A fresh reference capture-helper process for each swipe, retaining the 0.3.2 known-good successful-capture lifecycle.
- Continuous observation of the exact vendor process identity and broker process.
- Fail-closed poisoned-session handling: a no-swipe timeout, helper termination, active-capture cancellation or malformed frame marks the broker degraded. It rejects subsequent captures rather than reusing potentially damaged vendor IPC state.
- No automatic vendor/USB restart from a TOD close callback. The libfprint close callback can run before fprintd's D-Bus Release method has returned; a socket QUIT or EOF is not proof that the claim has been relinquished.
- Explicit `vfs491-recover` operation masks/stops fprintd before stopping and restarting the isolated vendor service. This trades automatic recovery for claim-safe recovery.
- Image telemetry records dimensions and derived quality metrics only. It does not write fingerprint pixels, templates or minutiae to the journal.
- One-stage enrollment is restored as the archived Validity driver baseline. The earlier five-stage experiment is not treated as proven more accurate.

## Platform

The build target is Linux Mint 22.x / Ubuntu 24.04 base, x86_64, with the matching installed `libfprint 1.94.7+tod1` runtime ABI. The build refuses a mismatched core/TOD ABI and does not replace system libfprint packages.

## Build and test on the target laptop

```bash
make bootstrap
make check
make build
make test
make isolation-test
make package
```

The generated package is placed in `debs/`:

```bash
sudo apt install ./debs/vfs491-fprintd-tod_2.0.3-1_amd64.deb
```

Package installation does not enable or start `vfs491d.service`. The fprintd systemd drop-in starts it on demand before fprintd accesses the TOD device. PAM policy remains separate from driver installation. If the broker marks the vendor session degraded, inspect its journal and run `sudo vfs491-recover`; this temporarily masks/stops fprintd before restarting the vendor service.

## Enroll and verify

```bash
fprintd-enroll "$USER"
fprintd-verify -f right-index-finger "$USER"
fprintd-list "$USER"
```

Do not enroll multiple times while diagnosing the transport layer. First establish stable frame capture and then measure repeated same-finger and different-finger results.

## Diagnostics and recognition study

```bash
sudo /usr/libexec/vfs491/vfs491-diagnose
sudo journalctl -fu vfs491d.service -u fprintd.service
vfs491-verify-study --finger right-index-finger --class genuine
```

The verification-study utility runs one ordinary `fprintd-verify` attempt and correlates only journal events whose timestamps fall inside that command interval. Study runs are serialized, and the JSONL file is created with permissions `0600`. The study file contains derived metrics and outcomes only, not fingerprint pixels or templates. See `docs/2.0.3-ENGINEERING.md` for the controlled test procedure.

## Reliability status

2.0.3 hardens attempt-level verification correlation by filtering journal events to the exact process interval and serializing study runs. The underlying matcher and capture behavior remain unchanged. It retains the Transaction 15 process supervision and fail-closed vendor-session handling. Software protocol tests cannot prove the HP vendor service is stable on physical hardware, and the observability additions do not establish improved recognition. The transaction is a development candidate until cold boot, repeated capture, enrol/verify, wrong-finger rejection, cancellation, no-swipe timeout, claim close/reopen, recovery, suspend/resume, USB replug, LightDM and `sudo` are exercised on the target machine.

The proprietary HP service, wrapper library, firmware and known-good helper are binary vendor/reference dependencies. This project provides the Linux TOD integration and service lifecycle around them; it is not a kernel module and does not claim to have reverse-engineered the complete USB protocol.

## License

The open-source integration is provided under the GNU Lesser General Public License, version 2.1 or (at your option) any later version. Vendor binaries and firmware retain their respective provenance and licensing; see `vendor/README.md` and `docs/vendor-audit.md`.

## Engineering record

See [`docs/2.0.3-ENGINEERING.md`](docs/2.0.3-ENGINEERING.md) for the recognition-study design, [`docs/PROJECT-HANDOFF.md`](docs/PROJECT-HANDOFF.md) for the complete current engineering state and historical decisions, and [`docs/TRANSACTION15-ENGINEERING.md`](docs/TRANSACTION15-ENGINEERING.md) for the fail-closed lifecycle decisions.
