#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do
    bash -n "$f"
done
python3 -m py_compile "$ROOT"/scripts/*.py "$ROOT"/tests/*.py
"$ROOT/tests/test-transaction-static.sh"

SYSROOT="$ROOT/sysroot"
if [[ ! -d "$SYSROOT/usr/include/glib-2.0" ]]; then
    echo "Private build sysroot is missing. Run 'make bootstrap' before 'make check'." >&2
    exit 2
fi
GLIBCONFIG="$(find "$SYSROOT/usr" -type f -name glibconfig.h -print -quit | xargs -r dirname)"
GUSB="$(find "$SYSROOT/usr/include" -type f -name gusb.h -print -quit | xargs -r dirname)"
LIBUSB="$(find "$SYSROOT/usr/include" -type f -name libusb.h -print -quit | xargs -r dirname)"
JSON_HEADER="$(find "$SYSROOT/usr/include" -type f -path '*/json-glib/json-glib.h' -print -quit)"
JSON_INC="${JSON_HEADER%/json-glib/json-glib.h}"
mkdir -p "$ROOT/build/tod-headers"
printf '#pragma once\n' > "$ROOT/build/tod-headers/fp-enums.h"
printf '#pragma once\n' > "$ROOT/build/tod-headers/fpi-enums.h"
gcc -std=gnu11 -Wall -Wextra -Werror=implicit-function-declaration -fsyntax-only \
    -I"$ROOT/build/tod-headers" -I"$ROOT/reference/libfprint" \
    -I"$ROOT/reference/libfprint/tod" -I"$SYSROOT/usr/include/glib-2.0" \
    -I"$GLIBCONFIG" -I"$GUSB" -I"$LIBUSB" -I"$JSON_INC" \
    -I"$ROOT/include" "$ROOT/src/vfs491-tod.c"
gcc -std=c11 -Wall -Wextra -Werror -fsyntax-only -I"$ROOT/include" "$ROOT/src/vfs491-image-metrics.c"
gcc -std=gnu11 -Wall -Wextra -Werror -fsyntax-only -I"$ROOT/include" "$ROOT/src/vfs491-bridge.c"
gcc -std=gnu11 -Wall -Wextra -Werror -fsyntax-only "$ROOT/src/vfs491-readfull.c"
echo "PASS: shell, Python, TOD C syntax, bridge C syntax and CH_EVENT read shim C syntax"
