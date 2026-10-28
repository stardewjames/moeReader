#!/usr/bin/env bash
# Create a jlinked runtime image (java.home) for an iOS static JVM.
#   ./jlink-ios.sh [iphoneos|iphonesimulator] OUTDIR [modules=java.base]
# The iOS builds cannot produce jmods themselves (the JDK's jmods depend on dynamic native
# libraries, which the app does not ship: everything native is linked statically). So jmods are
# packed here from the build's class/conf/lib outputs (`make java gendata copy`) without native
# libraries, and jlinked with a macOS JDK of the exact same version: the macOS OpenJ9 build
# (build-openj9-macos.sh). The classes are the same for device and simulator.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$HERE/work"
PLATFORM="${1:-iphoneos}"; OUT="${2:?usage: jlink-ios.sh PLATFORM OUTDIR [modules]}"; MODS="${3:-java.base}"
case "$PLATFORM" in
  iphoneos)        B="$W/openj9-jdk21/build/ios-aarch64-openj9-release" ;;
  iphonesimulator) B="$W/openj9-jdk21/build/iossim-aarch64-openj9-release" ;;
  *) echo "unknown platform $PLATFORM"; exit 1 ;;
esac
BJDK="$W/openj9-jdk21/build/macosx-aarch64-openj9-release/images/jdk"
JM="$B/images/jmods-nolibs"
VER="$(sed -n 's/^VERSION_SHORT *:= *//p' "$B/spec.gmk")"
PLAT="$(sed -n 's/^OPENJDK_MODULE_TARGET_PLATFORM *:= *//p' "$B/spec.gmk")"
[ -d "$B/jdk/modules/java.base" ] || "$HERE/build-openj9-ios.sh" "$PLATFORM" java gendata copy
mkdir -p "$JM" "$W/trash"
# Notices (<module>/<file> in the module's legal directory) of third-party code that is not in the
# app, so that the app does not claim it. Each was checked against this build's sources:
#  - java.desktop's native libraries are not linked: prelink-openj9-ios.py links the natives of
#    java.base, java.prefs, java.management, jdk.management and jdk.net only, and the jmods carry no
#    libraries. The module's Java classes are shipped, but none of these files covers Java code:
#    FreeType, HarfBuzz, libjpeg, LittleCMS, libpng and giflib are C libraries; Mesa is the OpenGL
#    headers (gl.h, glext.h, glx.h) of the Unix OpenGL pipeline; PipeWire is the screen-cast headers
#    and xwd is X11 screen-capture code, both in libawt_xawt.
#  - java.base's SipHash is used by HotSpot's AltHashing only. OpenJ9 has no such code, and neither
#    java.base's Java nor its native sources use SipHash.
# Deliberately kept: java.desktop/colorimaging.md (Eastman Kodak: its copyright is in the headers of
# shipped java.awt.color and java.awt.image classes) and java.base/zlib.md (libzip is built with
# the JDK's bundled zlib sources).
NOT_LINKED_NOTICES="
  java.desktop/freetype.md java.desktop/giflib.md java.desktop/harfbuzz.md java.desktop/jpeg.md
  java.desktop/lcms.md java.desktop/libpng.md java.desktop/mesa3d.md java.desktop/pipewire.md
  java.desktop/xwd.md java.base/siphash.md"
for d in "$B"/jdk/modules/*/; do
  m="$(basename "$d")"
  # Reuse a jmod unless the module's classes changed since, or this script (which decides which
  # notices go in) did.
  [ -f "$JM/$m.jmod" ] && [ -z "$(find "$d" -newer "$JM/$m.jmod" -print -quit)" ] && [ ! "$0" -nt "$JM/$m.jmod" ] && continue
  rm -f "$JM/$m.jmod"
  args=(--class-path "$d" --target-platform "$PLAT" --module-version "$VER" --compress zip-6)
  [ -d "$B/support/modules_conf/$m" ] && args+=(--config "$B/support/modules_conf/$m")
  [ -d "$B/support/modules_libs/$m" ] && args+=(--libs "$B/support/modules_libs/$m")
  # As the JDK's own jmods: the common notices (LICENSE, ASSEMBLY_EXCEPTION,
  # ADDITIONAL_LICENSE_INFO) go into every module's legal/ directory.
  # Third-party notices of native code that the app does not link (NOT_LINKED_NOTICES) are left
  # out: the module's own legal directory is copied without them. The common notices stay.
  own="$B/support/modules_legal/$m"
  if [ -d "$own" ]; then
    own="$W/trash/legal.$$/$m"; rm -rf "$own"; mkdir -p "$own"
    cp -RL "$B/support/modules_legal/$m/." "$own/"
    for n in $NOT_LINKED_NOTICES; do
      case "$n" in "$m/"*) rm -f "$own/${n#"$m/"}" ;; esac
    done
  fi
  legal=()
  for l in "$B/support/modules_legal/common" "$own"; do [ -d "$l" ] && legal+=("$l"); done
  [ ${#legal[@]} -eq 0 ] || args+=(--legal-notices "$(IFS=:; echo "${legal[*]}")")
  # No native code (it is linked into the app), no launcher configuration, no debug symbols.
  "$BJDK/bin/jmod" create "${args[@]}" \
    --exclude '**{_the.*,_*.marker*,*.so,*.dylib,*.a,*.dSYM/**,jvm.cfg}' "$JM/$m.jmod"
done
[ ! -e "$OUT" ] || { echo "$OUT exists; move it away first"; exit 1; }
"$BJDK/bin/jlink" --module-path "$JM" --add-modules "$MODS" --output "$OUT" \
  --strip-debug --no-header-files --no-man-pages ${JLINK_EXTRA:-}
# No launcher/bin on iOS; jvm.cfg is only read by the java launcher.
rm -rf "$W/trash/legal.$$"
mkdir -p "$W/trash"; [ -d "$OUT/bin" ] && mv "$OUT/bin" "$W/trash/bin.$$.$RANDOM"
du -sh "$OUT"; du -sh "$OUT/lib/modules"
