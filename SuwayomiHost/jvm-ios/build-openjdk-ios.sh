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
if [ ! -f "build/$CONF/spec.gmk" ]; then
  # configure's compiler checks run in the source root: one configure at a time.
  mkdir -p build
  until mkdir build/.configure.lock 2>/dev/null; do sleep 2; done
  trap 'rmdir build/.configure.lock 2>/dev/null || true' EXIT
  bash configure \
    --with-conf-name="$CONF" \
    --with-boot-jdk="$JAVA_HOME" \
    --openjdk-target=aarch64-macos-ios \
    --with-sysroot="$SYSROOT" \
    --with-libffi-include="$FFI/include/ffi" \
    --with-libffi-lib="$FFI" \
    --with-cups-include="$(xcrun --sdk macosx --show-sdk-path)/usr/include" \
    --disable-warnings-as-errors \
    "${EXTRA[@]}"
  rmdir build/.configure.lock
  trap - EXIT
fi

TARGETS=("$@")
[ ${#TARGETS[@]} -gt 0 ] || TARGETS=(java static-libs-image)
make CONF="$CONF" "${TARGETS[@]}"
