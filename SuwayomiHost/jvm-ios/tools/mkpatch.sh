#!/usr/bin/env bash
# Developer helper: saves the working-tree changes of some files in one of the OpenJ9 source trees
# as patches/openj9/<tree>-<name>.patch, with a header comment (git apply skips text before the
# first "diff --git" line).
#   tools/mkpatch.sh jdk|openj9|omr NAME "header line" ["header line"...] -- PATH...
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/work/openj9-jdk21"
tree="$1"; name="$2"; shift 2
case "$tree" in
  jdk) dir="$SRC" ;;
  openj9) dir="$SRC/openj9" ;;
  omr) dir="$SRC/omr" ;;
  *) echo "unknown tree $tree"; exit 1 ;;
esac
header=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do header+=("$1"); shift; done
[ "${1:-}" = "--" ] && shift
[ $# -gt 0 ] || { echo "no paths"; exit 1; }
out="$HERE/patches/openj9/$tree-$name.patch"
{
  for line in "${header[@]}"; do echo "# $line"; done
  echo "#"
  echo "# Tree: $(basename "$dir") ($(git -C "$dir" rev-parse HEAD)). Applied by apply-openj9-patches.sh."
  echo
  git -C "$dir" diff --no-color -- "$@"
  # New, untracked files are added as well.
  for f in $(git -C "$dir" ls-files --others --exclude-standard -- "$@"); do
    git -C "$dir" diff --no-color --no-index -- /dev/null "$f" | sed -e "s#^+++ b/$dir/#+++ b/#" || true
  done
} > "$out"
echo "wrote $out ($(rg -c '^diff --git' "$out") files)"
