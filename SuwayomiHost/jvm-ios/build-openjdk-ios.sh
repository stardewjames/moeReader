#!/usr/bin/env bash
# Cross-builds OpenJDK Mobile (HotSpot **Zero**, the interpreter-only variant
# iOS requires) and its class library for iOS arm64, as static libraries:
#
#   ./build-openjdk-ios.sh iphoneos|iphonesimulator [make targets...]
#
# Output: work/mobile/build/<conf>/images/static-libs/lib/zero/libjvm.a and
#         work/mobile/build/<conf>/images/static-libs/lib/*.a
#         work/mobile/build/<conf>/jdk/modules/<module>   (class library)
# package.sh turns these into the runtime the app bundles.
#
# Prerequisite: ./fetch-openjdk.sh, Xcode, autoconf and GNU make 4.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$HERE/work"
SRC="$W/mobile"
PLATFORM="${1:-iphonesimulator}"; shift || true

case "$PLATFORM" in
  iphoneos)        CONF=ios-aarch64-zero-release;    SDK=iphoneos ;;
  iphonesimulator) CONF=iossim-aarch64-zero-release; SDK=iphonesimulator ;;
  *) echo "usage: build-openjdk-ios.sh iphoneos|iphonesimulator [targets]"; exit 1 ;;
esac
[ -d "$SRC" ] || { echo "build-openjdk-ios: run ./fetch-openjdk.sh first" >&2; exit 1; }
[ -n "${JAVA_HOME:-}" ] || { echo "build-openjdk-ios: JAVA_HOME must be a JDK 26+" >&2; exit 1; }

SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
FFI="$W/libffi/$( [ "$PLATFORM" = iphoneos ] && echo device || echo sim )"
[ -f "$FFI/libffi.a" ] || { echo "build-openjdk-ios: libffi missing; rerun fetch-openjdk.sh" >&2; exit 1; }

EXTRA=()
if [ "$PLATFORM" = iphonesimulator ]; then
  EXTRA=(
    --with-extra-cflags="-target arm64-apple-ios-simulator -mios-simulator-version-min=26.0"
    --with-extra-cxxflags="-target arm64-apple-ios-simulator -mios-simulator-version-min=26.0"
  )
fi

cd "$SRC"

# HotSpot's macOS/arm64 write-xor-execute helpers live in
# os_cpu/bsd_aarch64/os_bsd_aarch64.cpp, but a Zero build compiles
# os_cpu/bsd_zero instead and still defines MACOS_AARCH64 (macros.hpp keys it on
# __APPLE__ && AARCH64), so every inline W^X transition in shared code
# references os::thread_wx_enable_write_impl, os::_jit_exec_enabled and
# DefaultWXWriteMode, which nothing defines: the static link fails. Zero never
# generates code and needs no W^X transition, so the macro is gated on the
# variant here rather than patching the pinned sources upstream. Idempotent.
MACROS="src/hotspot/share/utilities/macros.hpp"
if ! grep -q "defined(ZERO) /\* mihoncompat: no W^X for Zero \*/" "$MACROS"; then
  python3 - "$MACROS" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = "#if defined(__APPLE__) && defined(AARCH64)\n#define MACOS_AARCH64 1\n#endif"
new = ("// Zero builds compile os_cpu/bsd_zero and never generate code, so the\n"
       "// apple/arm64 W^X helpers in os_cpu/bsd_aarch64 are not linked in.\n"
       "#if defined(__APPLE__) && defined(AARCH64) && !defined(ZERO) /* mihoncompat: no W^X for Zero */\n"
       "#define MACOS_AARCH64 1\n"
       "#endif")
if old not in text:
    sys.exit("build-openjdk-ios: MACOS_AARCH64 block not found in macros.hpp")
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
fi

if [ ! -f "build/$CONF/spec.gmk" ]; then
  # configure's compiler checks run in the source root: one configure at a time.
  mkdir -p build
  until mkdir build/.configure.lock 2>/dev/null; do sleep 2; done
  trap 'rmdir build/.configure.lock 2>/dev/null || true' EXIT
  run_configure() {
    bash configure \
      --with-conf-name="$CONF" \
      --with-boot-jdk="$JAVA_HOME" \
      --openjdk-target=aarch64-macos-ios \
      --with-sysroot="$SYSROOT" \
      --with-libffi-include="$FFI/include/ffi" \
      --with-libffi-lib="$FFI" \
      --with-cups-include="$(xcrun --sdk macosx --show-sdk-path)/usr/include" \
      --disable-warnings-as-errors "$@"
  }
  # macOS ships bash 3.2, where "${EXTRA[@]}" on an empty array trips set -u.
  if [ ${#EXTRA[@]} -gt 0 ]; then run_configure "${EXTRA[@]}"; else run_configure; fi
  rmdir build/.configure.lock
  trap - EXIT
fi

TARGETS=("$@")
[ ${#TARGETS[@]} -gt 0 ] || TARGETS=(java static-libs-image)
make CONF="$CONF" "${TARGETS[@]}"
