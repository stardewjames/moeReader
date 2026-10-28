#!/usr/bin/env bash
# Builds a macOS JDK of the *same source* as the iOS runtime. package.sh needs
# its jmod and jlink: jlink refuses module images built by a different JDK
# build, so a stock Temurin cannot be used.
#
# Output: work/mobile/build/macos-aarch64/images/jdk
# Prerequisite: ./fetch-openjdk.sh and a JDK 26 boot JDK in JAVA_HOME.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$HERE/work"
SRC="$W/mobile"
CONF=macos-aarch64

[ -d "$SRC" ] || { echo "build-openjdk-macos: run ./fetch-openjdk.sh first" >&2; exit 1; }
[ -n "${JAVA_HOME:-}" ] || { echo "build-openjdk-macos: JAVA_HOME must be a JDK 26+" >&2; exit 1; }

cd "$SRC"
if [ ! -f "build/$CONF/spec.gmk" ]; then
  mkdir -p build
  until mkdir build/.configure.lock 2>/dev/null; do sleep 2; done
  trap 'rmdir build/.configure.lock 2>/dev/null || true' EXIT
  bash configure \
    --with-conf-name="$CONF" \
    --with-boot-jdk="$JAVA_HOME" \
    --disable-warnings-as-errors
  rmdir build/.configure.lock
  trap - EXIT
fi
make CONF="$CONF" jdk-image
"build/$CONF/images/jdk/bin/java" -version
