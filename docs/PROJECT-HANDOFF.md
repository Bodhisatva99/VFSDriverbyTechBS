# VFS491 project handoff — state at 2.0.3

This file is the engineering handoff for continuing the VFS491 Linux driver. It records the confirmed target, architecture, historical decisions, measured behavior and outstanding validation gates. Treat source code and test logs as authoritative where this summary differs from older notes.

## 1. Target and scope

- Laptop target: HP EliteBook 8470p.
- Fingerprint sensor: Validity VFS491, USB VID:PID `138a:003d`.
- OS target: Linux Mint 22.x, specifically Mint 22.3 in the latest target plan.
- Runtime target: matching `libfprint-2-2` and `libfprint-2-tod1`, version `1.94.7+tod1`, plus fprintd.
- CPU architecture: x86_64 / amd64.
- The project is a userspace libfprint TOD backend and supporting service stack. It is not a kernel driver and does not claim support for all Validity VFS devices.

The proprietary HP/Validity SP84530 service, wrapper library, firmware and reference capture helper are vendor dependencies. This project integrates and supervises them; it does not claim to have reverse-engineered the complete sensor protocol.

## 2. Runtime architecture

1. fprintd loads the native VFS491 TOD module through libfprint's TOD interface.
2. The TOD backend opens one per-claim client connection to a root-owned local Unix-socket broker.
3. A systemd-managed launcher starts the proprietary `vcsFPService` inside private mount, IPC and temporary-file namespaces, then runs the broker.
4. The broker verifies the vendor process identity/readiness and handles capture requests. It launches the reference capture helper for each swipe.
5. The helper uses the CH_EVENT read-full compatibility shim to aggregate the vendor FIFO's partial reads.
6. A valid frame is returned to the TOD backend, checked for frame magic/version, width, height, exact image length and total size, then passed to libfprint.
7. The device claim stays attached to the broker proxy until TOD close. Normal image deactivation does not tear down the persistent vendor service.

The broker authenticates local peers using Unix peer credentials and accepts the privileged client identity only. Poisoned vendor sessions fail closed. A timeout, helper failure, cancellation during an active capture, invalid framing or vendor-process health loss must not trigger an in-claim USB/service restart. Explicit recovery masks/stops fprintd before stopping/restarting the vendor service, then restores the previous fprintd mask state.

## 3. Historical engineering decisions

- **T13:** explored same-session no-swipe retry. Repeated use of the legacy proprietary stack was later treated as unsafe because timeout can leave IPC state unusable.
- **T14:** moved toward supervised capture, bounded retries for ordinary acquisition errors, and poisoned-session handling.
- **T15:** made failure recovery fail-closed and removed vendor/USB restart from the TOD close callback. A TOD close callback or socket QUIT/EOF is not proof that fprintd's D-Bus Release has completed.
- **2.0.0:** introduced the persistent broker, isolated vendor service, per-claim client and per-swipe helper architecture.
- **2.0.1:** corrected package staging for `/usr/sbin/vfs491-recover` and made recovery logic independently testable while retaining a root-only production entry point.
- **2.0.2:** adds claim/capture telemetry and an attempt-level verification study tool. It does not change the matcher or capture pixels.
- **2.0.3:** hardens study correlation with exact journal timestamp filtering, per-user run serialization, malformed-frame rejection and safer file handling; the TOD capture pipeline is unchanged.

Older transaction notes are historical engineering records, not evidence that every intermediate candidate was production-safe.

## 4. Recognition baseline — do not change without controlled evidence

The archived Validity driver baseline is retained:

- Bozorth3 matcher threshold: `40`.
- Enrollment stages: `1`.
- Image flags: `FPI_IMAGE_COLORS_INVERTED | FPI_IMAGE_V_FLIPPED`.
- No VFS491-specific crop, rotate, mirror, resize, contrast/intensity normalization, adaptive threshold, or raw-pixel rewrite.
- Enrollment and verification share the same frame parse and image-flag path.

The earlier five-stage enrollment experiment was reverted because a recognition improvement was not demonstrated. A low genuine-match rate is not permission to lower the matcher threshold: the false-accept rate must also be measured.

## 5. Observed recognition/acquisition evidence

The latest supplied 24 November verification transcript contains 12 visible verification attempts: 3 `verify-match` and 9 `verify-no-match` results. The visible sample is therefore 3/12 (25%) genuine matches. One accompanying narrative counted 3/11; the terminal outcomes were recounted from the visible command results and total 12. This is a small diagnostic sample, not a stable performance estimate.

Ten diagnostic frame records showed:

- width: 200 pixels throughout;
- height: 177–403 pixels;
- mean intensity: 94.445–175.979;
- bright-pixel proportion: 13.333–59.089%;
- entropy: 2.515–3.749 bits;
- capture duration: 1.635–4.637 seconds.

These measurements establish frame-to-frame variation, not its cause. The statistics were computed from raw frame bytes before libfprint applies the image flags. `bright_pct` is not a post-inversion measurement. No raw image data was saved by that diagnostic run, so the metrics cannot establish ridge completeness, finger placement, sensor contamination, polarity correctness or matcher quality. No threshold, image transform or enrollment change is justified by these data alone.

## 6. 2.0.2 changes

Every TOD device claim receives a random UUID. Each capture request increments a claim-local sequence. The driver logs structured `VFS491_EVENT` records for capture start, completed frame metrics and broker capture errors. The event key is `(claim_id, capture)`.

The original 2.0.2 `vfs491-verify-study` utility ran one ordinary `fprintd-verify` attempt and collected the fprintd journal interval. In 2.0.3, it reads JSON journal entries, filters by each event's exact microsecond timestamp to the actual command interval, stores that timestamp, serializes runs and rejects unsafe output-file types. It appends the parsed result and associated frame events to a JSONL file with mode `0600`. It stores no account name, raw command output, fingerprint pixels, templates or minutiae. The `--class` value is supplied by the test operator; it is not inferred by the driver.

The timing value logged for a completed frame is computed before the capture timer is cleared and is passed explicitly to the frame-delivery routine. Static regression coverage checks that ordering.

## 7. Controlled recognition test plan

Run the study one verification operation at a time and avoid other concurrent fprintd operations during the measurement window.

1. Confirm the device is visible and the installed libfprint core/TOD versions match.
2. Verify the enrolled finger label and baseline enrollment state.
3. Record at least 20 separate genuine attempts with `--class genuine`.
4. Record at least 10 attempts presenting a different finger against the same enrolled-finger template with `--class different-finger`. All must reject.
5. Preserve this first dataset; then perform one fresh enrollment and repeat the same sequence.
6. Analyze capture errors separately from valid frames followed by `no-match` results. Compare per-attempt dimensions, elapsed time and image-statistic distributions.
7. Only after the capture data is stable should any future change to recognition processing be proposed. Any proposed change must improve genuine acceptance while preserving different-finger rejection on the exact target runtime.

If the current user cannot read the fprintd system journal, study records will contain `journal_error` and the capture correlation will be incomplete. Do not interpret a missing frame record as a failed sensor capture until journal access is fixed.

## 8. 2.0.2 validation status

Passed in the development container, as individual commands:

- Python syntax compilation and shell syntax checks.
- The 2.0.2 baseline had six verification-study tests; 2.0.3 adds two more tests covering exact timestamp filtering, end-to-end journal correlation, symlink refusal and study-run serialization (eight tests total).
- Static architecture/release assertions, including the frame-timing regression check.
- Bridge/helper lifecycle, parent-death, CH_EVENT read-full, persistent broker, broker recovery, systemd readiness, image diagnostics, image metrics, boot integration, PAM fallback and recovery-script tests.
- Vendor payload hash verification.

The aggregate test runner exceeded the container command timeout when several timing-sensitive broker tests were chained. Those test programs were rerun individually and passed. This is not a claim that one uninterrupted `make test` invocation completed.

Not verified in the development container:

- Native C compile/link of the modified TOD module.
- `make bootstrap`, `make check`, `make build`, `make isolation-test` or `make package` against the exact target runtime.
- Debian package installation, upgrade, removal or rollback on the laptop.
- Physical sensor capture, enrollment, genuine matching, different-finger rejection, cancellation, no-swipe timeout, recovery, suspend/resume, USB replug, LightDM, or soak testing.

The development container does not have the GLib/libfprint pkg-config development environment or the private target sysroot. The 2.0.2 native TOD C changes were therefore not compiled in this container. The 2.0.2 source is not hardware-certified.

## 9. 2.0.3 validation record

The eight dedicated 2.0.3 verification-study tests passed, including exact timestamp boundary filtering, simulated end-to-end match/capture correlation, malformed frame rejection, output symlink refusal and study-run serialization. Shell syntax checks, Python syntax compilation, all protocol/component tests when run individually, and the source/vendor checksum manifests passed. See `docs/VALIDATION-RESULTS.md` for the exact validation scope.

The 2.0.3 changes are limited to verification-study correlation and local diagnostic-file handling. The native TOD backend itself remains uncompiled in this development container because GLib/GIO/libfprint TOD development headers and the private target sysroot are not present. No native link, Debian package build, installation or physical sensor test has been performed for 2.0.3.

## 10. Target-laptop release gate

From the extracted project directory:

```bash
sha256sum -c SHA256SUMS
make bootstrap
make check
make build
make test
make isolation-test
make package
```

Review the produced TOD module with the target's `ldd -r`, inspect the package metadata and staged file list, then install only after all gates pass. Follow `docs/HARDWARE-ACCEPTANCE.md` for physical testing. Preserve the test JSONL and journal excerpts for the next engineering iteration; do not collect or upload raw fingerprint images/templates.
