#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSROOT="$ROOT/sysroot"
BUILD="$ROOT/build"
REF="$ROOT/reference/libfprint"
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)"
LIBDIR="/usr/lib/$MULTIARCH"
[[ -e "$LIBDIR/libfprint-2-tod.so.1" ]] || LIBDIR="/lib/$MULTIARCH"

for pkg in libfprint-2-2 libfprint-2-tod1; do
    dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -qx 'install ok installed' || {
        echo "Required installed runtime package is missing: $pkg" >&2
        exit 1
    }
done
CORE_VERSION="$(dpkg-query -W -f='${Version}' libfprint-2-2)"
TOD_VERSION="$(dpkg-query -W -f='${Version}' libfprint-2-tod1)"
case "$TOD_VERSION" in
    *1.94.7+tod1*) ;;
    *) echo "Unsupported TOD ABI: $TOD_VERSION (expected 1.94.7+tod1); refusing ABI substitution." >&2; exit 1 ;;
esac
[[ "$CORE_VERSION" == "$TOD_VERSION" ]] || {
    echo "libfprint core/TOD versions differ ($CORE_VERSION vs $TOD_VERSION)." >&2
    exit 1
}
[[ -e "$LIBDIR/libfprint-2.so.2" && -e "$LIBDIR/libfprint-2-tod.so.1" ]] || {
    echo "Installed target libfprint libraries not found in $LIBDIR" >&2
    exit 1
}
[[ -f "$REF/fpi-image-device.h" && -f "$REF/fpi-device.h" ]] || {
    echo "Bundled 1.94.7+tod1 headers are incomplete." >&2
    exit 1
}
[[ -d "$SYSROOT/usr/include/glib-2.0" ]] || {
    echo "Private build sysroot is missing. Run make bootstrap first." >&2
    exit 1
}
[[ -x "$ROOT/reference/working-prototype/vfs_proprietary-capture-helper.reference" ]] || {
    echo "Known-good legacy capture helper ELF is missing from reference/working-prototype/." >&2
    exit 1
}

find_header_dir() { find "$SYSROOT/usr/include" -type f -name "$1" -print -quit | xargs -r dirname; }
GLIBCONFIG="$(find "$SYSROOT/usr" -type f -name glibconfig.h -print -quit | xargs -r dirname)"
GUSB="$(find_header_dir gusb.h)"
LIBUSB="$(find_header_dir libusb.h)"
JSON_HEADER="$(find "$SYSROOT/usr/include" -type f -path '*/json-glib/json-glib.h' -print -quit)"
JSON_INC="${JSON_HEADER%/json-glib/json-glib.h}"
HEADERS="$BUILD/tod-headers"
mkdir -p "$BUILD/tod" "$HEADERS"
printf '#pragma once\n' > "$HEADERS/fp-enums.h"
printf '#pragma once\n' > "$HEADERS/fpi-enums.h"

CFLAGS=(-std=gnu11 -O2 -g -Wall -Wextra -Wformat=2 -D_FORTIFY_SOURCE=2
        -fstack-protector-strong -Werror=implicit-function-declaration)
EXE_HARDENING=(-fPIE -pie -Wl,-z,relro,-z,now)
SHARED_HARDENING=(-Wl,-z,relro,-z,now)
INCLUDES=(-I"$HEADERS" -I"$REF" -I"$REF/tod"
          -I"$SYSROOT/usr/include/glib-2.0" -I"$GLIBCONFIG"
          -I"$GUSB" -I"$LIBUSB" -I"$JSON_INC" -I"$ROOT/include")
TOD_LIBS=(-L"$LIBDIR" -Wl,--no-as-needed
          -Wl,-l:libfprint-2.so.2 -Wl,-l:libfprint-2-tod.so.1
          -Wl,-l:libgio-2.0.so.0 -Wl,-l:libgobject-2.0.so.0
          -Wl,-l:libglib-2.0.so.0 -Wl,-l:libgmodule-2.0.so.0
          -Wl,--as-needed -lm)

printf 'Verifying SP84530 vendor payload...\n'
"$ROOT/scripts/verify-vendor.sh"

printf 'Building service-safe legacy capture bridge...\n'
gcc "${CFLAGS[@]}" "${EXE_HARDENING[@]}" -I"$ROOT/include" \
    "$ROOT/src/vfs491-bridge.c" -o "$BUILD/vfs491-bridge"

printf 'Building 0.3.2-proven CH_EVENT full-read compatibility shim...\n'
gcc -shared -fPIC -O2 -Wall -Wextra -Werror \
    "$ROOT/src/vfs491-readfull.c" -ldl \
    -Wl,-z,relro,-z,now -o "$BUILD/libvfs491-readfull.so"

printf 'Building native TOD module against installed %s...\n' "$TOD_VERSION"
gcc "${CFLAGS[@]}" -fPIC -fvisibility=hidden -shared "${SHARED_HARDENING[@]}" \
    "${INCLUDES[@]}" \
    -DVFS491_DEFAULT_CLIENT='"/usr/libexec/vfs491/vfs491-client"' \
    -DVFS491_DEFAULT_BRIDGE='"/usr/libexec/vfs491/vfs491-bridge"' \
    -DVFS491_DEFAULT_HELPER='"/usr/libexec/vfs491/vfs_proprietary-capture-helper"' \
    -DVFS491_DEFAULT_HP_LIBDIR='"/usr/lib/vfs491/vendor"' \
    -DVFS491_DEFAULT_FIRMWARE='"/usr/lib/vfs491/vendor/firmware/HPUsbVFS491.img"' \
    "$ROOT/src/vfs491-tod.c" "$ROOT/src/vfs491-image-metrics.c" "${TOD_LIBS[@]}" \
    -o "$BUILD/tod/libfprint-tod-vfs491.so"

printf '\nValidating target-linked TOD module...\n'
ldd -r "$BUILD/tod/libfprint-tod-vfs491.so"
nm -D --defined-only "$BUILD/tod/libfprint-tod-vfs491.so" | \
    grep -q 'fpi_tod_shared_driver_get_type' || {
        echo "TOD entry point is not exported." >&2
        exit 1
    }

printf '\nBuild outputs:\n'
file "$BUILD/vfs491-bridge" "$BUILD/libvfs491-readfull.so" \
     "$BUILD/tod/libfprint-tod-vfs491.so"
