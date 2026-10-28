#!/usr/bin/env bash
# Starts a desktop HotSpot with the bundled iOS options. This catches rejected
# options (including diagnostic-option ordering) without an iOS cross-build.
# Needs a HotSpot JDK on PATH, or JAVA_HOME pointing at one.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$(mktemp -d)"
trap 'rm -rf "$CACHE"' EXIT

OPTIONS=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|\#*) continue ;;
  esac
  OPTIONS+=("${line//\$\{cacheDir\}/$CACHE}")
done < "$HERE/../jvm-options/openjdk.options"

"${JAVA_HOME:+$JAVA_HOME/bin/}java" "${OPTIONS[@]}" -version
