#!/usr/bin/env bash
# Fetches the OpenJDK Mobile sources and the iOS libffi build used by the
# embedded HotSpot Zero runtime. Everything is pinned: a commit for the JDK and
# SHA-256 digests for the libffi archives.
#
#   work/mobile/      openjdk/mobile at MOBILE_COMMIT (HotSpot Zero + class library)
#   work/libffi/device, work/libffi/sim   libffi for iOS and the simulator
#   work/dl/          downloaded archives
#
# Prerequisite: a JDK 26 (or newer) as JAVA_HOME, the build JDK for the
# cross build, plus GNU make 4 (macOS ships 3.81; `brew install make` and put
# its libexec/gnubin on PATH) and autoconf.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$HERE/work"

MOBILE_REPO=https://github.com/openjdk/mobile.git
MOBILE_COMMIT="${MOBILE_COMMIT:-c1ed06aaef34c8dccf71e236d1ffa20918a77cfb}" # 2026-07-30, JDK 28

FFI_DEVICE_URL=https://github.com/openjdk-mobile/ios-tools/releases/download/libffi-build/libffi-ios.zip
FFI_DEVICE_SHA=4f39fd1d53fbd69d1bdbd915413077d130daa3f6792d1b3a03a690a9cbd4dea3
FFI_SIM_URL=https://github.com/openjdk-mobile/ios-tools/releases/download/libffi-build/libffi-ios-sim.zip
FFI_SIM_SHA=701b522e3eff0263f18d4a9e487f0a7ac30050fb2af20e86b6849daa14f5781f

java_major() {
  "$1/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -1
}

if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
  echo "fetch-openjdk: set JAVA_HOME to a JDK 26 or newer (the cross-build boot JDK)" >&2
  exit 1
fi
major="$(java_major "$JAVA_HOME")"
if [ -z "$major" ] || [ "$major" -lt 26 ]; then
  echo "fetch-openjdk: JAVA_HOME is JDK ${major:-unknown}; JDK 26+ is required" >&2
  exit 1
fi
if ! make --version 2>/dev/null | head -1 | grep -q 'GNU Make 4'; then
  echo "fetch-openjdk: GNU make 4 is required (brew install make; add its gnubin directory to PATH)" >&2
  exit 1
fi

mkdir -p "$W/dl"
dl() { # url sha file
  local url="$1" sha="$2" file="$W/dl/$3"
  if [ ! -s "$file" ] || [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha" ]; then
    rm -f "$file"
    curl -fL --retry 3 -o "$file" "$url"
    [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ] || {
      echo "fetch-openjdk: $3 does not match its pinned SHA-256" >&2; exit 1; }
  fi
}

# --- libffi (build dependency of the JDK's native code) ----------------------
for variant in device sim; do
  eval "url=\$FFI_$(echo "$variant" | tr a-z A-Z)_URL"
  eval "sha=\$FFI_$(echo "$variant" | tr a-z A-Z)_SHA"
  dl "$url" "$sha" "libffi-ios-$variant.zip"
  if [ ! -f "$W/libffi/$variant/libffi.a" ]; then
    rm -rf "$W/libffi/$variant.tmp"; mkdir -p "$W/libffi/$variant.tmp"
    unzip -q -o "$W/dl/libffi-ios-$variant.zip" -d "$W/libffi/$variant.tmp"
    rm -rf "$W/libffi/$variant"; mv "$W/libffi/$variant.tmp" "$W/libffi/$variant"
  fi
done

# --- openjdk/mobile sources at the pinned commit -----------------------------
SRC="$W/mobile"
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$MOBILE_REPO"
fi
if [ "$(git -C "$SRC" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$MOBILE_COMMIT" ]; then
  git -C "$SRC" fetch -q --depth 1 origin "$MOBILE_COMMIT"
  git -C "$SRC" checkout -q --detach FETCH_HEAD
fi
echo "openjdk/mobile: $(git -C "$SRC" rev-parse HEAD)"
echo "fetch-openjdk.sh: done"
