# VFS491 V2.0.0 — Engineering Record

## Purpose

V2.0.0 addresses the failure mode observed in Transaction 13: the proprietary capture helper can terminate from its 30-second no-swipe alarm without running the normal vendor wrapper cleanup path. Reusing the same long-lived vendor IPC session after that event is unsafe.

The implementation remains a Linux `libfprint` TOD integration for USB `138a:003d`. It is not a kernel module and does not claim to implement the undocumented USB protocol independently of HP's vendor stack.

## Capture outcomes

The bridge and broker distinguish three classes of result:

- **Successful frame:** helper exits normally; bridge validates helper metadata and pixels; broker validates the versioned frame again; TOD passes it to the libfprint image pipeline.
- **Recoverable acquisition error (broker status 11):** the preserved helper emits `Could not capture fingerprint`, exits with status 1, and follows its normal cleanup label. The TOD backend applies a bounded retry budget without restarting the vendor service.
- **Tainted session (broker status 10, 12 or 14):** a no-swipe timeout, abnormal helper termination, cancellation during capture, malformed frame, unexpected helper result or failed vendor-process health check is terminal for the current claim. The broker reports an error and marks itself degraded. It never automatically restarts USB/vendor state from a TOD close callback.

## Lifecycle and supervision

- The HP service remains resident between successful swipe requests.
- Each swipe uses a fresh reference helper process, preserving the established 0.3.2 success path.
- The launcher records the exact vendor PID and `/proc` start time, then monitors both vendor process identity and broker liveness. Loss of vendor health is logged; the broker refuses new captures.
- Vendor diagnostics are retained in journald.
- systemd uses `Restart=no`; an unexpected supervisor exit does not automatically restart a potentially claimed USB device.
- The broker socket is root-only and the broker authenticates its peer with `SO_PEERCRED`.
- A broker socket `QUIT` or EOF is not treated as proof that fprintd's D-Bus `Release` method has returned. Therefore no automatic service restart occurs after a poisoned capture.
- `vfs491-recover` runtime-masks/stops `fprintd.service`, stops and starts `vfs491d.service`, then unmasks fprintd. This is an explicit administrative recovery, not automatic crash recovery.

## Recognition baseline

- Enrollment is restored to one stage, matching the archived Validity source declaration. The Transaction 12 five-stage experiment is not treated as proven more accurate.
- The Bozorth3 threshold remains 40.
- The existing inversion and vertical-flip image flags are preserved.
- No speculative crop, resize, rotate, normalization or automatic quality rejection is introduced.
- Runtime telemetry records derived image statistics, not fingerprint pixels, templates or minutiae.

## Software validation performed

`make check` passes, including shell syntax, Python compilation, TOD C syntax against the bundled 1.94.7 headers, bridge C syntax, image metrics C syntax and static architecture checks.

The component test programs pass when run individually:

- bridge frame protocol, no-swipe timeout classification, acquisition-error classification and helper reaping;
- transaction static checks;
- CH_EVENT read aggregation and helper prompt flushing;
- persistent broker across multiple claims;
- broker timeout, cancellation, bounded drain and acquisition retry behavior;
- systemd readiness success and timeout behavior;
- image frame/metrics diagnostics;
- image-metrics C tests;
- boot ordering and diagnostic coverage;
- PAM configuration validation and password-fallback preservation.

The test programs were run individually in the development container. The combined Make target was not completed in one uninterrupted invocation. This record does not claim target-runtime ABI linking or hardware validation.

## Build and hardware limits

The development container does not have the target `libfprint-2-2` and `libfprint-2-tod1` runtime packages installed. Therefore, it cannot perform the final target-ABI link or produce the release `.deb`. `scripts/build.sh` and `scripts/build-system-deb.sh` intentionally refuse to substitute another ABI.

The TOD backend, bridge, broker, launcher, diagnostics and tests are source-built. The HP `vcsFPService`, Validity wrapper, firmware and known-good 0.3.2 capture helper remain binary vendor/reference components. The bundled legacy helper source is incomplete and is not claimed to be a reproducible build of that binary.

No physical VFS491 sensor was attached to the development container. No claim of hardware reliability, successful enrollment, match rate, wrong-finger rejection, suspend/resume behavior or multi-day stability is made until the target HP laptop passes the hardware acceptance matrix in `DEVELOPMENT.md`.

## Build on the HP EliteBook 8470p

Run from the extracted project root on the target laptop:

```bash
make bootstrap
make check
make test
make isolation-test
make build
make package
```

Inspect package metadata before installation:

```bash
dpkg-deb -f debs/vfs491-fprintd-tod_2.0.0-1_amd64.deb \
  Package Version Architecture Depends
```

Then install:

```bash
sudo apt install ./debs/vfs491-fprintd-tod_2.0.0-1_amd64.deb
```

PAM is not modified by package installation. The optional PAM configurator is documented separately. Keep password authentication available during initial validation.

## Existing stale udev rule

The previously observed `/etc/udev/rules.d/100-Validity_FingerPrint_Sensor.rules` references `/usr/sbin/UsbPlugged` and `/usr/bin/test.sh`, which were absent during the V2.0.0 audit. V2.0.0 does not use those hooks. Disable that stale rule manually before hardware testing, preserving it as a `.disabled` file if desired:

```bash
sudo mv /etc/udev/rules.d/100-Validity_FingerPrint_Sensor.rules \
        /etc/udev/rules.d/100-Validity_FingerPrint_Sensor.rules.disabled
sudo udevadm control --reload-rules
```
