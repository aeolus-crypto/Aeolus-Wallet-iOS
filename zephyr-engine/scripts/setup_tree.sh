#!/usr/bin/env bash
# Places the pinned sources under work/ and applies this repo's iOS patch on top of the
# Android build's own patches.
#
#   work/myzephyr-java                                   myzephyr-java at MZJ_SHA
#   work/myzephyr-java/external/zephyr-cpp               its zephyr-cpp submodule (pinned there)
#   work/myzephyr-java/external/zephyr-cpp/external/zephyr  zephyr, placed by its own
#                                                        bin/place_zephyr_tree.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
. ./pins.env

MZJ="$ROOT/work/myzephyr-java"
if [ ! -d "$MZJ/.git" ]; then
  mkdir -p work
  git clone -q --depth 1 --branch "$MZJ_TAG" "$MZJ_URL" "$MZJ"
fi
HEAD="$(git -C "$MZJ" rev-parse HEAD)"
if [ "$HEAD" != "$MZJ_SHA" ]; then
  echo "myzephyr-java is at $HEAD, expected $MZJ_SHA ($MZJ_TAG)" >&2
  exit 1
fi
git -C "$MZJ" submodule update -q --init --depth 1 external/zephyr-cpp
(cd "$MZJ" && bin/place_zephyr_tree.sh)

Z="$MZJ/external/zephyr-cpp/external/zephyr"
for P in "$ROOT"/patches/*.patch; do
  if git -C "$Z" apply -R --check "$P" 2>/dev/null; then
    echo "$(basename "$P"): already applied"
  else
    git -C "$Z" apply "$P"
    echo "$(basename "$P"): applied"
  fi
done

echo "zephyr-cpp: $(git -C "$MZJ/external/zephyr-cpp" rev-parse HEAD)"
echo "zephyr:     $(git -C "$Z" rev-parse HEAD)"
