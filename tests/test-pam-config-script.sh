#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/dpkg-query" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_PAM_VERSION:-1.94.3-1}"
MOCK
chmod +x "$TMP/bin/dpkg-query"
export PATH="$TMP/bin:$PATH"
export VFS491_PAM_TEST_MODE=1
export VFS491_PAM_FILE="$TMP/common-auth"

cat >"$VFS491_PAM_FILE" <<'PAM'
# generated PAM stack
 auth [authinfo_unavail=1 default=ignore] pam_fingwit.so # debug
 auth [success=2 default=ignore] pam_fprintd.so max-tries=1 timeout=15 # debug
 auth [success=1 default=ignore] pam_unix.so nullok try_first_pass
 auth requisite pam_deny.so
PAM

MOCK_PAM_VERSION=1.94.3-1 "$ROOT/scripts/configure-mint-pam-auth.sh" >/dev/null
grep -Eq 'pam_fprintd\.so max-tries=4 timeout=30 # debug' "$VFS491_PAM_FILE"
compgen -G "$VFS491_PAM_FILE.vfs491-pre-t14.*" >/dev/null
grep -Eq 'pam_fprintd\.so max-tries=1 timeout=15' "$VFS491_PAM_FILE.vfs491-pre-t14."* 
awk '/pam_fprintd\.so/ { found=1; next } found && /pam_unix\.so/ { ok=1; exit } END { exit !ok }' "$VFS491_PAM_FILE"
echo "PASS: pre-1.94.5 PAM gets bounded timeout and preserves password fallback"

cat >"$VFS491_PAM_FILE" <<'PAM'
auth [authinfo_unavail=1 default=ignore] pam_fingwit.so # debug
auth [success=2 default=ignore] pam_fprintd.so max-tries=1 timeout=15 # debug
auth [success=1 default=ignore] pam_unix.so nullok try_first_pass
PAM
MOCK_PAM_VERSION=1.94.5-2 "$ROOT/scripts/configure-mint-pam-auth.sh" >/dev/null
grep -Eq 'pam_fprintd\.so max-tries=4 timeout=30 # debug' "$VFS491_PAM_FILE"
echo "PASS: newer PAM also uses the driver's bounded capture timeout"

cat >"$VFS491_PAM_FILE" <<'PAM'
auth required pam_fprintd.so max-tries=1 timeout=15
auth required pam_unix.so
PAM
cp "$VFS491_PAM_FILE" "$TMP/before"
if MOCK_PAM_VERSION=1.94.5-2 "$ROOT/scripts/configure-mint-pam-auth.sh" >/dev/null 2>&1; then
    echo "PAM script accepted an unexpected control expression" >&2
    exit 1
fi
cmp -s "$TMP/before" "$VFS491_PAM_FILE"
echo "PASS: PAM script refuses unrecognized control flow without modifying the file"
