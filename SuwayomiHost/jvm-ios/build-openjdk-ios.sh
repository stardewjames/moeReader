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
# os_cpu/bsd_aarch64/os_bsd_aarch64.cpp. A Zero build compiles
# os_cpu/bsd_zero instead, and that file provides current_thread_enable_wx for
# apple/arm64 but not the W^X switch the shared inline transitions use
# (os::thread_wx_enable_write_impl, os::_jit_exec_enabled) nor the
# DefaultWXWriteMode policy value, so the static link fails on them. Zero never
# generates code, so the helpers are no-ops here; they are injected into the
# zero file the pinned sources already ship rather than into aarch64 code this
# variant does not compile. Idempotent.
ZERO_OS="src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp"
if ! grep -q "mihoncompat: Zero W^X helpers" "$ZERO_OS"; then
  python3 - "$ZERO_OS" <<'PATCHEOF'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
anchor = """#if defined(AARCH64) && defined(__APPLE__)
void os::current_thread_enable_wx(WXMode mode) {
#ifndef __IOS__
  pthread_jit_write_protect_np(mode == WXExec);
#endif
}
#endif"""
addition = anchor.replace("#endif", """
// mihoncompat: Zero W^X helpers. The shared inline transitions in
// interfaceSupport.inline.hpp reference these on apple/arm64, but only the
// aarch64 os_cpu file defines them and this variant compiles this file. Zero
// executes no generated code, so enabling writes is a no-op.
WXMode DefaultWXWriteMode = WXExec;
THREAD_LOCAL bool os::_jit_exec_enabled = false;
void os::thread_wx_enable_write_impl() {}
#endif""")
if anchor not in text:
    sys.exit("build-openjdk-ios: W^X block not found in os_bsd_zero.cpp")
open(path, "w", encoding="utf-8").write(text.replace(anchor, addition, 1))
PATCHEOF
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
