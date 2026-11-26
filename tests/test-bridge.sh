#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$(mktemp /tmp/vfs491-bridge-test.XXXXXX)"
HELPER="$ROOT/tests/fake-capture-helper.py"
OUT="$(mktemp)"
LOG="$(mktemp)"
trap 'rm -f "$OUT" "$LOG" "$BRIDGE"' EXIT

gcc -std=gnu11 -O2 -g -Wall -Wextra -Wformat=2 -Werror \
    -I"$ROOT/include" "$ROOT/src/vfs491-bridge.c" -o "$BRIDGE"
VFS491_TEST_SKIP_SERVICE_CHECK=1 "$BRIDGE" "$HELPER" >"$OUT" 2>"$LOG"
python3 - "$OUT" <<'PY'
import struct
import sys
raw = open(sys.argv[1], "rb").read()
assert len(raw) >= 20, f"short frame: {len(raw)} bytes"
magic, version, width, height, image_len = struct.unpack("<IIIII", raw[:20])
assert magic == 0x31534656, hex(magic)
assert version == 1, version
assert width == 200, width
assert height == 73, height
assert image_len == width * height, image_len
assert len(raw) == 20 + image_len, len(raw)
print(f"PASS: VFS491 bridge frame {width}x{height}, {image_len} grayscale bytes")
PY

# A vendor helper no-swipe timeout taints the session; the broker resets it after claim close.
set +e
VFS491_TEST_SKIP_SERVICE_CHECK=1 "$BRIDGE" "$ROOT/tests/fake-timeout-helper.py" >"$OUT" 2>"$LOG"
status=$?
set -e
[[ "$status" -eq 10 ]] || { echo "Expected retry status 10, got $status" >&2; cat "$LOG" >&2; exit 1; }
echo "PASS: no-swipe vendor timeout maps to session-reset status 10"

# An outer helper deadline also taints the session and requires recovery.
set +e
VFS491_BRIDGE_TIMEOUT_MS=1000 VFS491_TEST_SKIP_SERVICE_CHECK=1 \
  "$BRIDGE" "$ROOT/tests/fake-hanging-helper.py" >"$OUT" 2>"$LOG"
status=$?
set -e
[[ "$status" -eq 10 ]] || { echo "Expected outer no-swipe deadline status 10, got $status" >&2; cat "$LOG" >&2; exit 1; }
echo "PASS: outer vendor capture deadline maps to session-reset status 10"

# The known helper exits 1 for VFSW_CAPTURE_ERROR, but logs this message and
# reaches its normal cleanup path. That is safe for a bounded in-claim retry.
set +e
VFS491_TEST_SKIP_SERVICE_CHECK=1 "$BRIDGE" "$ROOT/tests/fake-capture-error-helper.py" >"$OUT" 2>"$LOG"
status=$?
set -e
[[ "$status" -eq 11 ]] || { echo "Expected acquisition status 11, got $status" >&2; cat "$LOG" >&2; exit 1; }
grep -q 'bounded retry is safe' "$LOG"
echo "PASS: normal VFSW_CAPTURE_ERROR cleanup maps to bounded-retry status 11"

# A successful helper exit must not make malformed ready metadata acceptable.
set +e
VFS491_TEST_SKIP_SERVICE_CHECK=1 "$BRIDGE" "$ROOT/tests/fake-invalid-ready-helper.py" >"$OUT" 2>"$LOG"
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo "Malformed ready status was accepted" >&2; exit 1; }
[[ ! -s "$OUT" ]] || { echo "Malformed helper unexpectedly returned an image frame" >&2; exit 1; }
echo "PASS: malformed helper-ready status is rejected"

# Verify SIGTERM to the bridge is forwarded into bounded child cleanup.
PIDFILE="$(mktemp)"
rm -f "$PIDFILE"
VFS491_TEST_CHILD_PID_FILE="$PIDFILE" VFS491_TEST_SKIP_SERVICE_CHECK=1 \
  "$BRIDGE" "$ROOT/tests/fake-hanging-helper.py" >"$OUT" 2>"$LOG" &
bridge_pid=$!
for _ in $(seq 1 40); do
  [[ -s "$PIDFILE" ]] && break
  sleep 0.05
done
[[ -s "$PIDFILE" ]] || { echo "Hanging helper did not start" >&2; kill "$bridge_pid" 2>/dev/null || true; exit 1; }
helper_pid="$(cat "$PIDFILE")"
kill -TERM "$bridge_pid"
set +e
wait "$bridge_pid"
bridge_status=$?
set -e
rm -f "$PIDFILE"
if kill -0 "$helper_pid" 2>/dev/null; then
  echo "Bridge left its vendor helper running (pid $helper_pid)" >&2
  kill -KILL "$helper_pid" 2>/dev/null || true
  exit 1
fi
[[ "$bridge_status" -ne 0 ]] || { echo "Expected terminated bridge to return nonzero" >&2; exit 1; }
echo "PASS: bridge termination reaps the capture helper"

# If the bridge is forcibly killed, PR_SET_PDEATHSIG must still stop its child.
PIDFILE="$(mktemp)"
rm -f "$PIDFILE"
VFS491_TEST_CHILD_PID_FILE="$PIDFILE" VFS491_TEST_SKIP_SERVICE_CHECK=1 \
  "$BRIDGE" "$ROOT/tests/fake-hanging-helper.py" >"$OUT" 2>"$LOG" &
bridge_pid=$!
for _ in $(seq 1 40); do
  [[ -s "$PIDFILE" ]] && break
  sleep 0.05
done
[[ -s "$PIDFILE" ]] || { echo "Second hanging helper did not start" >&2; kill -KILL "$bridge_pid" 2>/dev/null || true; exit 1; }
helper_pid="$(cat "$PIDFILE")"
kill -KILL "$bridge_pid"
set +e
wait "$bridge_pid"
set -e
for _ in $(seq 1 40); do
  if ! kill -0 "$helper_pid" 2>/dev/null; then break; fi
  sleep 0.05
done
rm -f "$PIDFILE"
if kill -0 "$helper_pid" 2>/dev/null; then
  echo "Parent-death signal did not stop vendor helper $helper_pid" >&2
  kill -KILL "$helper_pid" 2>/dev/null || true
  exit 1
fi
echo "PASS: vendor helper is stopped if the bridge is forcibly killed"
