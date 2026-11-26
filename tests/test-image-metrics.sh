#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror \
    -I"$ROOT/include" \
    "$ROOT/src/vfs491-image-metrics.c" \
    "$ROOT/tests/test-image-metrics.c" -lm -o "$TMP/test-image-metrics"
"$TMP/test-image-metrics"
