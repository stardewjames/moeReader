#!/usr/bin/env bash
# Sanity build: Eclipse OpenJ9 (+ OMR) with the OpenJDK 21 class library for macOS arm64, the
# platform OpenJ9 supports upstream. Same sources and patches as the iOS builds, so a regression
# from a patch shows up here first. The JIT stays in on macOS (it is never linked for iOS).
# Non-compressed references, like IBM Semeru on macOS arm64: compressed refs need memory below
# 4 GB for class data, and arm64 Mach-O executables (macOS and iOS) reserve it as __PAGEZERO.
#   ./build-openj9-macos.sh [make targets...]        (default: images)
# Output: work/openj9-jdk21/build/macosx-aarch64-openj9-release/images/jdk
# Prereq: ./fetch-openj9.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$HERE/work"
SRC="$W/openj9-jdk21"
CONF=macosx-aarch64-openj9-release
JOBS="${JOBS:-12}"
MAKE="$W/tools/bin/make"
BOOT_JDK="${BOOT_JDK:-$W/semeru21/Contents/Home}"
TARGETS=("$@"); [ ${#TARGETS[@]} -gt 0 ] || TARGETS=(images)

"$HERE/apply-openj9-patches.sh"

cd "$SRC"
if [ ! -f "build/$CONF/spec.gmk" ]; then
  # OpenJDK's configure runs its compiler checks in the source root: one configure at a time
  # (the builds themselves may run in parallel).
  mkdir -p build
  until mkdir build/.configure.lock 2>/dev/null; do sleep 2; done
  trap 'rmdir build/.configure.lock 2>/dev/null || true' EXIT
  bash configure \
    --with-conf-name="$CONF" \
    --with-boot-jdk="$BOOT_JDK" \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --disable-ddr \
    --with-noncompressedrefs \
    --disable-warnings-as-errors \
    --disable-warnings-as-errors-omr \
    --disable-warnings-as-errors-openj9 \
    --with-vendor-name=MoeReader \
    --without-version-pre --without-version-opt --with-version-build=1 --with-build-user=moereader \
    MAKE="$MAKE"
  rmdir build/.configure.lock
  trap - EXIT
fi
"$MAKE" CONF="$CONF" JOBS="$JOBS" "${TARGETS[@]}"
[ ! -x "build/$CONF/images/jdk/bin/java" ] || "build/$CONF/images/jdk/bin/java" -Xint -version
