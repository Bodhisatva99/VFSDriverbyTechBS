# VFS491 2.0.1 validation record

## Evidence from the target HP laptop (user terminal log, 24 November 2026)

The user's 2.0.0 source tree successfully completed `make bootstrap`, `make check`, `make isolation-test`, and `make build`. The build produced the native TOD shared object, bridge and CH_EVENT read shim. `ldd -r` showed the module resolving against the installed `libfprint-2.so.2` and `libfprint-2-tod.so.1` on that laptop. Vendor payload checksums also passed.

Two issues remained in that 2.0.0 run:

- `make test` stopped at `tests/test-recovery-script.sh` because it invoked the root-only production command as an ordinary user. In 2.0.1 the recovery implementation is sourceable for unit testing; the actual installed `vfs491-recover` command still enforces root.
- `make package` failed when `install` attempted to create `build/package-root/usr/sbin/vfs491-recover`; the staging script had not created `usr/sbin`. Version 2.0.1 adds that directory to the staging `mkdir -p` list and bumps the package to `2.0.1-1`.

The log did not contain a successful `.deb` build or installation.

## Offline component tests for 2.0.1 source

Executed individually in the development container:

- `bash -n` over project shell scripts and tests.
- `python3 -m py_compile` over project Python scripts and tests.
- `tests/test-transaction-static.sh`, including the new `/usr/sbin` staging assertion.
- `tests/test-bridge.sh`.
- `tests/test-parent-death.py`.
- `tests/test-readfull.sh`.
- `tests/test-persistent-broker.py`.
- `tests/test-broker-recovery.py`.
- `tests/test-systemd-readiness.py`.
- `tests/test-image-diagnostics.py` (6 tests).
- `tests/test-image-metrics.sh`.
- `tests/test-boot-integration.sh`.
- `tests/test-pam-config-script.sh`.
- `tests/test-recovery-script.sh`.
- Vendor payload SHA-256 manifest check.

All listed component tests passed. One combined test invocation exceeded the container command timeout after the persistent-broker tests had printed their success results; subsequent remaining test programs were executed separately and passed.

## Not yet verified

- `make check` for this exact 2.0.1 archive on the target laptop (the user's 2.0.0 run passed; C sources are unchanged by the 2.0.1 corrective patch).
- `make package` and `.deb` metadata for 2.0.1-1 on the target laptop.
- Package installation/removal and dynamic loading under the laptop's installed fprintd/TOD runtime.
- Any 2.0.1 physical sensor capture, enrollment, verification, USB lifecycle or soak test.

## Release classification

2.0.1 is a source candidate with the observed package-staging and unprivileged-test defects corrected. It is not hardware-certified. A successful package build is the next gate; repeated physical VFS491 captures, enrollment/verification and the hardware acceptance plan are still required before a stable release claim.

# VFS491 2.0.2 validation supplement

## Changes under test

2.0.2 changes only the native TOD telemetry identifiers/log records and adds the `vfs491-verify-study` utility. The matcher threshold, enrollment stage count, image flags, frame transport, broker retry policy and vendor-service recovery policy are unchanged from 2.0.1.

## Checks completed in the development container

- Verified the supplied 2.0.1 source archive checksum before using it as the baseline.
- `bash -n` across project shell scripts and tests.
- `python3 -m py_compile` across project Python scripts and tests.
- Six new verification-study unit tests passed: structured event parsing, capture start/error parsing, malformed-event rejection, fprintd result parsing and mode-0600 JSONL output.
- `tests/test-transaction-static.sh` passed all architecture, security and release-invariant assertions, including the 2.0.2 event IDs and package installation entries.
- Bridge, parent-death, CH_EVENT read shim, persistent broker, broker recovery, systemd readiness, image diagnostics, image metrics, boot integration, PAM fallback and recovery-script tests passed when run as individual commands.

The first combined run exceeded its overall command timeout after the persistent-broker checks completed. The remaining broker-recovery and subsequent component tests were re-run individually and passed. Therefore this record does not claim that a single `make test` invocation completed end-to-end in the container.

## Not verified in the development container

- Native C compilation and linking of the modified TOD module.
- `make bootstrap`, `make check`, `make build`, `make isolation-test` and `make package` against the actual Mint 22.3 / libfprint 1.94.7+tod1 target environment.
- Package install, upgrade or rollback on the HP EliteBook 8470p.
- Physical VFS491 capture, enrollment, verification, different-finger rejection, timeout recovery, suspend/resume, replug or soak test.

The development container does not provide the target libfprint/TOD runtime and private C build sysroot. These checks must run on the target laptop before installing the candidate. The 2.0.2 source is not hardware-certified, and no recognition improvement is claimed.


# VFS491 2.0.3 validation supplement

## Changes under test

2.0.3 fixes a concrete correlation defect in the 2.0.2 study utility: 2.0.2 queried a journal interval padded by two seconds but retained every event in that padded interval. This could associate an adjacent fprintd capture with a different verification result. Version 2.0.3 consumes journal JSON and filters events by `__REALTIME_TIMESTAMP` to the exact verification process interval. It also serializes study runs and refuses symlink/non-regular output targets. The TOD driver code, matching threshold, enrollment count, image flags, broker, helper and vendor service are unchanged from 2.0.2.

## Checks completed in the development container

- Eight dedicated `tests/test-verify-study.py` tests passed, including exact interval boundary tests, a simulated end-to-end match/capture correlation, private file permissions, symlink refusal and lock serialization.
- `tests/test-transaction-static.sh` passes all architecture and release assertions, including the new 2.0.3 study-correlation invariants.
- `tests/test-bridge.sh` passed.
- `tests/test-parent-death.py` passed.
- `tests/test-transaction-static.sh` passed, including 60 architecture/release assertions.
- `tests/test-readfull.sh` passed.
- `tests/test-persistent-broker.py` passed.
- `tests/test-broker-recovery.py` passed when rerun by itself after an aggregate test command stalled at that stage.
- `tests/test-systemd-readiness.py` passed.
- `tests/test-image-diagnostics.py` passed (6 tests).
- `tests/test-image-metrics.sh` passed.
- `tests/test-boot-integration.sh` passed.
- `tests/test-pam-config-script.sh` passed.
- `tests/test-recovery-script.sh` passed.
- All project shell scripts passed `bash -n`; all Python scripts/tests passed `py_compile`.
- GCC `-fanalyzer` syntax/static analysis passed for the bridge, CH_EVENT shim and image-metrics C files.
- Vendor payload hashes passed. The final archive's complete source checksum manifest is verified separately.

The component tests were run individually. One aggregate invocation exceeded the available command window while it was at the broker-recovery test; that test and the remaining tests were rerun individually and passed. This does not claim a single uninterrupted `make test` run.

## Build and hardware status

The container does not have GLib, GIO, GUsb, libusb or the installed libfprint 1.94.7+tod1 runtime/development ABI. `scripts/preflight.sh` therefore correctly refuses to build the target package here because `libfprint-2-2` is not installed. The 2.0.3 native TOD module has not been compiled or dynamically linked in this environment; neither `make check`, `make build`, `make isolation-test` nor `make package` has been completed for this archive. No `.deb` or physical-sensor claim is made. The HP EliteBook 8470p must complete the target build, installation, hardware acceptance and recognition protocol before this is a production-certified release.
