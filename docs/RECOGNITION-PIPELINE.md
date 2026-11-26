# VFS491 recognition pipeline and evidence boundaries

## Fixed baseline

The archived Validity proprietary driver source defines `VFS_PROPRIETARY_NR_ENROLL` as `1` and assigns `FP_IMG_COLORS_INVERTED | FP_IMG_V_FLIPPED` to captured images. V2.0.0 restores the one-stage enrollment contract rather than carrying forward the unproven five-stage experiment. The TOD backend keeps the matcher threshold at 40, the documented libfprint 1.94.7 default.

No rotation, mirroring, resizing, crop, intensity normalization, contrast adjustment or VFS491-specific frame rejection threshold is applied. Enrollment and verification use the same frame parser and image flags.

## Capture metrics

The runtime records dimensions, payload size, min/max, p05/p50/p95, mean, standard deviation, histogram entropy, dark/bright saturation percentages, row/column variation and horizontal/vertical gradients. Each capture-start, completed-frame and broker-error event is keyed by a random per-claim UUID plus a capture sequence. Pixel bytes, templates and minutiae are not logged by this telemetry path.

`vfs491-verify-study` runs one normal `fprintd-verify` attempt and correlates its result with those journal events. It stores derived statistics and outcomes in a local mode-0600 JSONL file, not images or templates. Metrics indicate acquisition characteristics; they do not identify the cause of a false reject by themselves. The supplied logs showed substantial brightness, entropy, gradient and frame-height variation, but they cannot establish sensor contamination, swipe technique, ridge-extraction failure or matcher quality without controlled local image analysis.

## Enrollment validation

The initial V2.0.0 baseline requests one accepted swipe, matching the archived Validity source. This avoids treating the earlier five-stage Linux experiment as proven. To change enrollment stages later, measure repeat genuine-match rate and wrong-finger rejection across multiple fresh enrollments; do not infer accuracy from successful stage progression.

## Recognition validation protocol

1. Enroll a single finger once.
2. Verify the enrolled finger in at least 20 independent attempts, lifting fully and using normal swipe variation. Record matches, no-matches, retry-scan events and session errors.
3. Test at least 10 attempts with a different finger. All must reject.
4. Repeat with a fresh enrollment and compare results.
5. Use `vfs491-verify-study --finger right-index-finger` for each attempt so capture metrics and verification outcomes are correlated. Keep raw biometric images and templates local; they are not needed for the initial statistical comparison.

A threshold change is not an acceptable substitute for diagnosing inconsistent frames or template extraction. Any future matcher adjustment must be assessed against both genuine-match improvement and false-accept risk.

## V2.0.0 acquisition failure policy

The preserved vendor helper has a fixed no-swipe alarm. Its timeout handler exits without running the wrapper's normal resource cleanup. Because the legacy source warns that terminating a process while blocked in `vfs_capture()` can leave the vendor IPC path locked, V2.0.0 marks timed-out or interrupted sessions as poisoned. The TOD backend reports a session error; the broker waits for claim close; systemd then restarts the isolated vendor stack. It does not launch unlimited retries against the same potentially damaged session.

This is a conservative recovery policy, not proof that every vendor failure is repaired. The target laptop must confirm that claim-close, service-stop and service-readiness transitions complete in the expected order.


The reference helper's recoverable `VFSW_CAPTURE_ERROR` path is identified by its `Could not capture fingerprint` diagnostic: the helper returns exit status 1 through its normal cleanup label. The bridge must not assume an undocumented numeric exit code for this condition.
