#!/usr/bin/env bash
# Applies patches/openj9/*.patch (idempotently) to the three OpenJ9 source trees fetched by
# fetch-openj9.sh. Each patch names its tree in its file name:
#   jdk-*.patch    -> work/openj9-jdk21          (ibmruntimes/openj9-openjdk-jdk21)
#   openj9-*.patch -> work/openj9-jdk21/openj9   (eclipse-openj9/openj9)
#   omr-*.patch    -> work/openj9-jdk21/omr      (eclipse-openj9/openj9-omr)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/work/openj9-jdk21"
shopt -s nullglob
for p in "$HERE"/patches/openj9/*.patch; do
  name="$(basename "$p")"
  case "$name" in
    jdk-*) tree="$SRC" ;;
    openj9-*) tree="$SRC/openj9" ;;
    omr-*) tree="$SRC/omr" ;;
    *) echo "apply-openj9-patches: cannot tell the tree of $name"; exit 1 ;;
  esac
  if git -C "$tree" apply --check -R "$p" 2>/dev/null; then
    continue # already applied
  fi
  git -C "$tree" apply "$p"
  echo "applied $name"
done
