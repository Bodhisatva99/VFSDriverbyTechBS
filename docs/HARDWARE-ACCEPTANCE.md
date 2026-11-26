# VFS491 2.0.0 hardware acceptance plan

Run on the target HP EliteBook 8470p only after the package is built and installed.

## Baseline
```sh
uname -a
dpkg-query -W libfprint-2-2 libfprint-2-tod1 fprintd
lsusb -d 138a:003d
systemctl status vfs491d.service fprintd.service --no-pager
```

## Capture and verification
- Run 20 independent captures, recording only dimensions, elapsed time, and status.
- Run 20 same-finger verification attempts.
- Run at least 10 different-finger attempts.
- Do not tune Bozorth3 threshold based only on genuine match rate; record false accepts/rejects separately.

## Failure handling
- Leave the finger off the reader for the helper timeout interval.
- Cancel during an active capture.
- Close/reopen fprintd claims repeatedly.
- Verify that poisoned sessions reject new capture requests and do not restart USB while fprintd is active.
- Run `sudo vfs491-recover` and confirm fprintd's previous runtime-mask state is preserved.

## Platform integration
- Cold boot; suspend/resume; USB unplug/replug; LightDM lock/unlock; password fallback.
- Soak for at least four hours and inspect journal, process count, RSS, file descriptors and coredumps.

## Evidence
Collect `sudo /usr/libexec/vfs491/vfs491-diagnose` and the relevant journal. Do not collect or upload raw biometric images or templates.
