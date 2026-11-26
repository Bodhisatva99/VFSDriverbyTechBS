# Changelog

## 2.0.3-1 — verification correlation hardening

- Correct the 2.0.2 study-window flaw: journal entries are now individually filtered by `__REALTIME_TIMESTAMP` to the exact `fprintd-verify` process interval, instead of keeping every event in a padded journal query window.
- Include the journal timestamp on every retained capture event so a study record can be independently audited.
- Serialize study runs per user to prevent overlapping `vfs491-verify-study` processes.
- Reject malformed frame dimensions, inconsistent pixel byte counts and non-finite metric values.
- Harden study output and lock files against symlink following and non-regular-file targets; retain `0600` output permissions.
- Preserve all 2.0.2 recognition, image, broker, vendor-service and recovery invariants.

## 2.0.2-1 — recognition observability and verification correlation

- Add a unique claim UUID and monotonically increasing capture number to every TOD claim.
- Emit machine-readable `VFS491_EVENT` journal records for capture start, returned frame metrics and broker acquisition errors.
- Keep all measurements derived from grayscale pixels; no fingerprint pixels, templates or minutiae are written to the journal.
- Add `vfs491-verify-study` to run one standard `fprintd-verify` attempt and correlate its result with the frame events in the corresponding fprintd journal time window.
- Store study data as private JSONL with mode `0600`; do not record the account name or raw verification output.
- Preserve the recognition baseline: matcher threshold 40, one-stage enrollment, and the archived Validity polarity/orientation flags.
- Add unit tests for event parsing, result parsing and private study-file creation.
- Preserve the complete architecture/history, observed diagnostics and target validation gates in `docs/PROJECT-HANDOFF.md`.

## 2.0.1-1 — package staging and test-runner correction

- Create `build/package-root/usr/sbin` before installing `vfs491-recover`, fixing the exact package-build failure reported from the HP laptop.
- Refactor the recovery command into a root-checked CLI entry point and separately testable recovery function. The production command remains root-only.
- Update the recovery test to use mocked systemctl, allowing ordinary-user tests.
- Bump the Debian package version to `2.0.1-1` so the corrected package cannot be confused with the failed `2.0.0-1` attempt.

## Historical Transactions 10–15

The following entries record earlier development stages. They are retained for traceability and are not claims that those intermediate versions were production releases.

### 1.0.0~transaction10-1 — boot and authentication readiness candidate

- Add fprintd boot ordering and diagnostics without forcing password authentication to depend on fingerprint hardware.
- Keep PAM policy separate from package installation.

### 1.0.0~transaction11-1 — recognition diagnostics candidate

- Add image metrics and capture telemetry without storing fingerprint pixels.
- Preserve the original image orientation and threshold baseline.

### 1.0.0~transaction12-1 — multi-image enrollment experiment

- Experiment with five-stage enrollment. This was later reverted to the archived one-stage Validity baseline because improved recognition was not demonstrated.

### 1.0.0~transaction13-1 — idle wait and retry candidate

- Repeated same-session no-swipe retries were introduced. Subsequent logs showed this was not a safe recovery policy for the proprietary stack.

### 1.0.0~transaction14-1 — supervised capture candidate

- Classify the legacy helper timeout as a poisoned session rather than reusing potentially damaged vendor IPC.
- Add process monitoring, bounded retries for normal acquisition errors and explicit recovery work.

### 1.0.0~transaction15-1 — fail-closed recovery candidate

- Remove automatic vendor/USB restart from the TOD close callback because socket QUIT/EOF is not proof that fprintd's D-Bus Release has completed.
- Add an explicit recovery utility that masks/stops fprintd before restarting the vendor service.

## Release status

VFS491 2.0.3 is an audited source candidate. It has not yet been natively built against the target Mint 22.3 `libfprint 1.94.7+tod1` ABI or validated on the physical HP EliteBook 8470p. It does not claim improved recognition accuracy or hardware certification. Complete the build, package, install and physical acceptance gates before treating it as a stable production driver.
