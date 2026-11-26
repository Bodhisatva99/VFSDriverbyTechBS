# PAM authentication policy for Linux Mint 22.x

PAM configuration is separate from the VFS491 driver package. The driver does not edit `/etc/pam.d`, LightDM, Fingwit, Cinnamon or GNOME Keyring settings during installation.

## Bounded fingerprint attempt and password fallback

The bundled proprietary capture helper has a fixed 30-second no-swipe deadline. A longer `pam_fprintd.so timeout` cannot extend that underlying capture operation. V2.0.0 treats that timeout as a poisoned vendor session and fails the current fingerprint operation. It does not automatically restart the vendor service from inside the TOD close path. Run `sudo vfs491-recover` to stop/mask fprintd before restarting the vendor stack. Therefore the helper sets a 30-second PAM timeout rather than recommending an unlimited or five-minute wait.

To configure four fingerprint mismatch attempts with the existing Mint password fallback, run:

```sh
sudo ./scripts/configure-mint-pam-auth.sh
```

After package installation, the helper is also available at `/usr/share/doc/vfs491-fprintd-tod/configure-mint-pam-auth.sh`.

The script backs up `common-auth`, preserves the existing `[success=2 default=ignore] pam_fprintd.so` control flow and the following `pam_unix.so` password fallback, and sets `max-tries=4 timeout=30`. It refuses to edit an unrecognized PAM stack. `common-auth` is shared, so the change can affect every PAM service that includes it, including `sudo`.

The `max-tries` option applies to fingerprint mismatches; it does not turn a hardware/session failure into another match attempt. When the sensor session fails, the PAM stack should continue to its configured password fallback.

## GNOME Keyring

Fingerprint authentication returns an authentication verdict, not the account password. A fingerprint-only cold-boot login therefore cannot provide the password needed to unlock a password-encrypted GNOME Login keyring. This is independent of VFS491 capture reliability. The normal Mint workflow is to use the account password for the first login after reboot and fingerprint for later screen unlocks in the active session.
