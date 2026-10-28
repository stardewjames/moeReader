#!/usr/bin/env bash
# Fetch the Eclipse OpenJ9 + OMR + OpenJDK 21 (ibmruntimes) sources into jvm-ios/work/openj9-jdk21/.
# Pinned to exactly what IBM Semeru 21.0.12.15 (OpenJ9 0.61.0) was built from, so the macOS build
# can be compared with work/semeru21 (also the boot JDK and the desktop OpenJ9 for tests).
#   work/openj9-jdk21/          ibmruntimes/openj9-openjdk-jdk21 (JDK 21 class library + build system)
#   work/openj9-jdk21/openj9/   eclipse-openj9/openj9 (the VM, EPL-2.0 / Apache-2.0)
#   work/openj9-jdk21/omr/      eclipse-openj9/openj9-omr (the OMR runtime toolkit, EPL-2.0 / Apache-2.0)
#   work/semeru21/              IBM Semeru 21.0.12.15 (boot JDK; desktop OpenJ9 for EmbeddedHostTests)
#   work/src/, work/tools/      GNU make 4.x (macOS ships 3.81) and the CUPS headers configure wants
#   work/dl/                    downloaded tarballs
# Shallow clones at the pinned commits (no get_source.sh: it clones whole histories).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$HERE/work"
SRC="$W/openj9-jdk21"

JDK_REPO=https://github.com/ibmruntimes/openj9-openjdk-jdk21.git
JDK_COMMIT="${JDK_COMMIT:-2e01e904eaf92c2c2f045763872432cc2053e8cf}"     # branch v0.61.0-21.0.12.15-release (jdk-21.0.12.1+1)
OPENJ9_REPO=https://github.com/eclipse-openj9/openj9.git
OPENJ9_COMMIT="${OPENJ9_COMMIT:-a1daf225f5cb0ccfb5d7309014701570435a94c4}" # tag openj9-0.61.0
OMR_REPO=https://github.com/eclipse-openj9/openj9-omr.git
OMR_COMMIT="${OMR_COMMIT:-ebd02d9129dc06fa67a6f885f99a3926aa869154}"       # tag openj9-0.61.0
# The release tag, so that the build names itself openj9-0.61.0 (closed/OpenJ9.gmk: git describe).
RELEASE_TAG="${RELEASE_TAG:-openj9-0.61.0}"

checkout() { # repo commit dir [tag]
  local repo="$1" commit="$2" dir="$3" tag="${4:-}"
  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$repo"
  fi
  if [ "$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$commit" ]; then
    git -C "$dir" fetch -q --depth 1 origin "$commit"
    git -C "$dir" checkout -q --detach FETCH_HEAD
  fi
  if [ -n "$tag" ] && ! git -C "$dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    git -C "$dir" fetch -q --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
    [ "$(git -C "$dir" rev-parse "$tag^{commit}")" = "$commit" ] || { echo "$tag is not $commit in $dir"; exit 1; }
  fi
  echo "$(basename "$dir"): $(git -C "$dir" rev-parse HEAD)"
}

SEMERU_URL="https://github.com/ibmruntimes/semeru21-binaries/releases/download/jdk-21.0.12.15/ibm-semeru-open-jdk_aarch64_mac_21.0.12.15.tar.gz"
GMAKE_VER=4.4.1
GMAKE_URL="https://ftp.gnu.org/gnu/make/make-${GMAKE_VER}.tar.gz"
CUPS_VER=2.4.11
CUPS_URL="https://github.com/OpenPrinting/cups/releases/download/v${CUPS_VER}/cups-${CUPS_VER}-source.tar.gz"
mkdir -p "$W/dl" "$W/src"
dl() { # url file
  [ -s "$W/dl/$2" ] || curl -fL --retry 3 -o "$W/dl/$2" "$1"
}

# --- Semeru 21 (OpenJ9): boot JDK and desktop OpenJ9 ------------------------
dl "$SEMERU_URL" semeru21.tar.gz
if [ ! -x "$W/semeru21/Contents/Home/bin/java" ]; then
  rm -rf "$W/semeru21" "$W/semeru21.tmp"; mkdir -p "$W/semeru21.tmp"
  tar -xzf "$W/dl/semeru21.tar.gz" -C "$W/semeru21.tmp"
  mv "$W/semeru21.tmp"/*/ "$W/semeru21"; rmdir "$W/semeru21.tmp"
fi

# --- GNU make 4.x and the CUPS headers ---------------------------------------
dl "$GMAKE_URL" "make-${GMAKE_VER}.tar.gz"
[ -d "$W/src/make-${GMAKE_VER}" ] || tar -xzf "$W/dl/make-${GMAKE_VER}.tar.gz" -C "$W/src"
dl "$CUPS_URL" "cups-${CUPS_VER}.tar.gz"
[ -d "$W/src/cups-${CUPS_VER}" ] || tar -xzf "$W/dl/cups-${CUPS_VER}.tar.gz" -C "$W/src"
if [ ! -x "$W/tools/bin/make" ]; then
  (cd "$W/src/make-${GMAKE_VER}" && ./configure --prefix="$W/tools" --disable-dependency-tracking >/dev/null \
     && /usr/bin/make -j8 >/dev/null && /usr/bin/make install >/dev/null)
fi

# --- sources -----------------------------------------------------------------
checkout "$JDK_REPO" "$JDK_COMMIT" "$SRC"
checkout "$OPENJ9_REPO" "$OPENJ9_COMMIT" "$SRC/openj9" "$RELEASE_TAG"
checkout "$OMR_REPO" "$OMR_COMMIT" "$SRC/omr" "$RELEASE_TAG"
echo "fetch-openj9.sh: done"
