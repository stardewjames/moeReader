#!/usr/bin/env bash
# Packages the HotSpot Zero runtime the app bundles, into $OUT (default
# SuwayomiHost/build/runtime/ios):
#
#   SuwayomiRuntime/host/suwayomi-host.jar   the host (SuwayomiHost/host)
#   SuwayomiRuntime/jvm.options              HotSpot options (SuwayomiJVM reads it)
#   SuwayomiRuntime/licenses/                GPLv2/OpenJDK, libffi and source notices
#   lib/                                     java.home: HotSpot sets it to <bundle>/lib
#     lib/modules                            jlinked java.base + the modules the host uses
#     conf/, lib/security/                   java.security, cacerts, tzdb
#   native/<sdk>/lib*.a                      static VM + class-library natives
#   jvm.xcconfig                             per-SDK link flags (SUWAYOMI_JVM_LDFLAGS)
#
# Prerequisites (once, on a Mac with Xcode):
#   ./fetch-openjdk.sh && ./build-openjdk-macos.sh \
#     && ./build-openjdk-ios.sh iphoneos [iphonesimulator] && ./package.sh
#
# Licensing: libjvm.a is OpenJDK HotSpot (GPL-2.0 *only*, no Classpath
# Exception), so an app built with this runtime is a GPLv2 combined work. The
# exact source is openjdk/mobile at the commit pinned by fetch-openjdk.sh, the
# build scripts in this directory and MoeReader's own source; SOURCE.md in the
# bundle says so. The class library is GPL-2.0 with the Classpath Exception.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
W="$HERE/work"
OUT="${OUT:-$ROOT/build/runtime/ios}"
RUNTIME="$OUT/SuwayomiRuntime"
BUNDLE_LIB="$OUT/lib"
NATIVE="$OUT/native"
SRC="$W/mobile"
MOBILE_COMMIT="${MOBILE_COMMIT:-c1ed06aaef34c8dccf71e236d1ffa20918a77cfb}"

# The modules the host jar and its dependencies use (same set the previous
# runtime shipped). java.desktop's classes are included; its AWT natives are
# not linked, so bitmap-descrambling extensions fail as they did before.
MODULES="${MODULES:-java.base,java.desktop,java.logging,java.management,java.naming,java.net.http,java.scripting,java.sql,java.xml,jdk.charsets,jdk.localedata,jdk.management,jdk.unsupported,jdk.zipfs}"
# Static libraries merged into the app: java.base's set plus the management
# natives android.os.SystemClock uses (it reads ManagementFactory uptime).
STATIC_LIBS="java zip net nio jimage management management_ext"

FFI_LICENSE_URL="https://raw.githubusercontent.com/libffi/libffi/v3.5.2/LICENSE"
FFI_LICENSE_SHA=d5699fa516968e3a1550e6c902b7441c78856f2603d61bedd0b0662a26655366

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
dl() { # url sha file
  local url="$1" sum="$2" file="$W/dl/$3"
  mkdir -p "$W/dl"
  if [ ! -s "$file" ] || [ "$(sha "$file")" != "$sum" ]; then
    rm -f "$file"; curl -fL --retry 3 -o "$file" "$url"
    [ "$(sha "$file")" = "$sum" ] || { echo "package: $3 failed its pinned SHA-256" >&2; exit 1; }
  fi
}

conf_of() { case "$1" in iphoneos) echo ios-aarch64-zero-release ;; iphonesimulator) echo iossim-aarch64-zero-release ;; esac; }
build_of() { echo "$SRC/build/$(conf_of "$1")"; }

mkdir -p "$RUNTIME/host" "$W/trash"

# 1. The host jar, built with a desktop JDK 21 (or supplied by CI).
if [ "${SKIP_HOST_BUILD:-0}" != 1 ]; then
  (cd "$ROOT" && ./gradlew --console=plain -q :host:shadowJar)
fi
[ -s "$ROOT/host/build/libs/suwayomi-host.jar" ] || {
  echo "package: the host jar is missing; build it with ./gradlew :host:shadowJar" >&2; exit 1; }
cp "$ROOT/host/build/libs/suwayomi-host.jar" "$RUNTIME/host/suwayomi-host.jar"
cp "$HERE/../jvm-options/openjdk.options" "$RUNTIME/jvm.options"
if [ "${HOST_ONLY:-0}" = 1 ]; then
  for file in "$OUT/jvm.xcconfig" "$BUNDLE_LIB/lib/modules"; do
    [ -s "$file" ] || { echo "HOST_ONLY=1 needs an existing package in $OUT (missing $file)" >&2; exit 1; }
  done
  [ -d "$RUNTIME/licenses" ] || { echo "HOST_ONLY=1 needs bundled licenses in $OUT" >&2; exit 1; }
  du -sh "$RUNTIME/host/suwayomi-host.jar"
  exit 0
fi

# 2. The module image. jlink rejects modules from a different JDK build than
# itself, so both tools and modules come from this same pinned source: the
# macOS JDK built by build-openjdk-macos.sh plus the iOS class library.
HOST_JDK="$SRC/build/macos-aarch64/images/jdk"
[ -x "$HOST_JDK/bin/jlink" ] || {
  echo "package: build the macOS JDK first (./build-openjdk-macos.sh)" >&2; exit 1; }
TOOLS="$HOST_JDK/bin"
JDK_HOME="$HOST_JDK"

MODULE_BUILD=""
for p in iphoneos iphonesimulator; do
  [ -d "$(build_of "$p")/jdk/modules/java.base" ] && { MODULE_BUILD="$(build_of "$p")"; break; }
done
[ -n "$MODULE_BUILD" ] || { echo "package: no iOS build with jdk/modules; run build-openjdk-ios.sh" >&2; exit 1; }

rm -rf "$W/jmods" "$W/image"; mkdir -p "$W/jmods"
# jlink resolves the requested modules' dependencies, so every module the
# build produced gets a jmod; only the requested closure lands in the image.
for dir in "$MODULE_BUILD"/jdk/modules/*/; do
  m="$(basename "$dir")"
  "$TOOLS/jmod" create --class-path "$dir" --target-platform ios-aarch64 "$W/jmods/$m.jmod"
done
for m in ${MODULES//,/ }; do
  [ -f "$W/jmods/$m.jmod" ] || {
    echo "package: module $m was not built; run build-openjdk-ios.sh <platform> java static-libs-image" >&2; exit 1; }
done
"$TOOLS/jlink" --module-path "$W/jmods" --add-modules "$MODULES" \
  --output "$W/image" --strip-debug --no-header-files --no-man-pages
[ -s "$W/image/lib/modules" ] || { echo "package: jlink produced no lib/modules" >&2; exit 1; }

# java.home is <bundle>/lib for a statically linked HotSpot (os_bsd.cpp appends
# "/lib" to the executable's directory), so the image's conf/ and lib/ go to
# <bundle>/lib/ and lib/modules lands at <bundle>/lib/lib/modules.
rm -rf "$BUNDLE_LIB"; mkdir -p "$BUNDLE_LIB"
cp -R "$W/image/lib" "$BUNDLE_LIB/"
# jlink links classes only; the portable data files come from the same-major
# host JDK (security providers, trust store, time-zone database).
if [ -d "$W/image/conf" ]; then cp -R "$W/image/conf" "$BUNDLE_LIB/"; else mkdir -p "$BUNDLE_LIB/conf"; fi
mkdir -p "$BUNDLE_LIB/lib/security"
cp -R "$JDK_HOME/conf/." "$BUNDLE_LIB/conf/"
cp "$JDK_HOME/lib/tzdb.dat" "$BUNDLE_LIB/lib/tzdb.dat"
[ -f "$JDK_HOME/lib/security/cacerts" ] && cp "$JDK_HOME/lib/security/cacerts" "$BUNDLE_LIB/lib/security/cacerts"
if [ -f "$W/image/release" ]; then cp "$W/image/release" "$BUNDLE_LIB/release"; fi

# 3. Static libraries and their linker flags, per SDK.
rm -rf "$NATIVE"
for p in iphoneos iphonesimulator; do
  B="$(build_of "$p")"
  [ -d "$B/images/static-libs/lib/zero" ] || continue
  mkdir -p "$NATIVE/$p"
  for name in $STATIC_LIBS; do
    lib="$B/images/static-libs/lib/lib$name.a"
    [ -s "$lib" ] || { echo "package: missing $lib" >&2; exit 1; }
    cp "$lib" "$NATIVE/$p/"
  done
  cp "$B/images/static-libs/lib/zero/libjvm.a" "$NATIVE/$p/"
  ffi="$W/libffi/$( [ "$p" = iphoneos ] && echo device || echo sim )/libffi.a"
  [ -s "$ffi" ] || { echo "package: missing $ffi" >&2; exit 1; }
  cp "$ffi" "$NATIVE/$p/libffi.a"
  python3 - "$B" $STATIC_LIBS > "$NATIVE/$p/external-flags.txt" <<'PY'
import os, shlex, sys
build, names = sys.argv[1], sys.argv[2:]
flags = []
found = {name: [] for name in names}
for root, dirs, files in os.walk(os.path.join(build, "support", "native")):
    if os.path.basename(root) != "static":
        continue
    for name in names:
        lib = f"lib{name}.a"
        flags_file = f"lib{name}.a.lib-flags.txt"
        if lib in files and flags_file in files:
            found[name].append(os.path.join(root, flags_file))
for name in names:
    for path in found[name][:1]:
        flags += shlex.split(open(path).read())
pairs, i = [], 0
while i < len(flags):
    if flags[i] == "-framework" and i + 1 < len(flags):
        pairs.append(("-framework", flags[i + 1])); i += 2
    else:
        pairs.append((flags[i],)); i += 1
seen, out = set(), []
for pair in pairs:
    if pair not in seen:
        seen.add(pair); out += list(pair)
print(" ".join(out))
PY
done
[ -d "$NATIVE/iphoneos" ] || [ -d "$NATIVE/iphonesimulator" ] || {
  echo "package: no static libraries were built; run build-openjdk-ios.sh" >&2; exit 1; }

{
  echo "// Generated by SuwayomiHost/jvm-ios/package.sh: links the static HotSpot Zero VM into the app."
  echo "// java.home is <bundle>/lib, so the jlinked image lives in the bundle's lib/ directory."
  for p in iphoneos iphonesimulator; do
    [ -d "$NATIVE/$p" ] || continue
    line=""
    for archive in "$NATIVE/$p"/lib*.a; do
      line="$line -force_load \"\$(PROJECT_DIR)/SuwayomiHost/build/runtime/ios/native/$p/$(basename "$archive")\""
    done
    ext="$(cat "$NATIVE/$p/external-flags.txt")"
    line="$line -lz -lc++"
    [ -z "$ext" ] || line="$line $ext"
    echo "SUWAYOMI_JVM_LDFLAGS[sdk=$p*] =$line"
    echo "SUWAYOMI_JVM_DEAD_CODE_STRIPPING[sdk=$p*] = NO"
  done
} > "$OUT/jvm.xcconfig"

# 4. Licenses and the GPL source notice of the bundled VM.
L="$OUT/licenses"
rm -rf "$L"; mkdir -p "$L/openjdk" "$L/libffi"
for f in LICENSE ASSEMBLY_EXCEPTION ADDITIONAL_LICENSE_INFO; do
  if ! curl -fsSL --retry 3 -o "$L/openjdk/$f" \
      "https://raw.githubusercontent.com/openjdk/mobile/$MOBILE_COMMIT/$f"; then
    echo "package: cannot fetch OpenJDK $f for the licenses directory" >&2; exit 1
  fi
done
dl "$FFI_LICENSE_URL" "$FFI_LICENSE_SHA" libffi-LICENSE
cp "$W/dl/libffi-LICENSE" "$L/libffi/LICENSE"
cat > "$L/SOURCE.md" <<EOF
The app bundle includes libjvm.a and the JDK class library built from
OpenJDK Mobile:

  https://github.com/openjdk/mobile
  commit $MOBILE_COMMIT

libjvm.a is HotSpot Zero, distributed under the GNU General Public License
version 2 only (no Classpath Exception). The class library is GPL-2.0 with the
Classpath Exception. An app built with this runtime is therefore a GPLv2
combined work: complete corresponding source is this repository (including
SuwayomiHost/jvm-ios/fetch-openjdk.sh, build-openjdk-ios.sh, package.sh and
the application source) plus openjdk/mobile at the commit above. The bundled
LICENSE and ASSEMBLY_EXCEPTION files are OpenJDK's.

libffi (used by HotSpot) is MIT-licensed; libffi/LICENSE is bundled.
EOF
cp -R "$L" "$RUNTIME/licenses"

du -sh "$BUNDLE_LIB" "$RUNTIME/host/suwayomi-host.jar" "$NATIVE"/* 2>/dev/null || true
