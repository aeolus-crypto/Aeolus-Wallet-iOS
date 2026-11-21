#!/usr/bin/env bash
# Places the pinned upstream sources under work/ and applies the patch layers:
#
#   work/zephyr      ZephyrProtocol/zephyr at ZEPHYR_SHA, with its submodules
#   work/zephyr-cpp  ZephyrProtocol/zephyr-cpp at ZEPHYR_CPP_SHA (its own zephyr submodule is
#                    not used; the engine build points at work/zephyr)
#
# Patch layers, in order:
#   1. patches/backports/   only with ZIOS_BACKPORTS=1 (zephyr/ and zephyr-cpp/ subfolders): the zephyr-backports security fixes
#                           (optional; see patches/backports/README.md)
#   2. patches/ios/         always: the minimal iOS build patches (zephyr/, zephyr-cpp/)
# Each layer touches different files, so they apply in either order and stay independent.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
. ./pins.env

fetch_pinned() {  # <dir> <url> <sha>
  local DIR="$1" URL="$2" SHA="$3"
  if [ ! -d "$DIR/.git" ]; then
    git init -q "$DIR"
    git -C "$DIR" remote add origin "$URL"
  fi
  if [ "$(git -C "$DIR" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$SHA" ]; then
    git -C "$DIR" fetch -q --depth 1 origin "$SHA"
    git -C "$DIR" checkout -q --force FETCH_HEAD
  fi
  [ "$(git -C "$DIR" rev-parse HEAD)" = "$SHA" ] || { echo "$DIR is not at $SHA" >&2; exit 1; }
}

mkdir -p work
fetch_pinned work/zephyr "$ZEPHYR_URL" "$ZEPHYR_SHA"
git -C work/zephyr submodule update -q --init --recursive --depth 1
fetch_pinned work/zephyr-cpp "$ZEPHYR_CPP_URL" "$ZEPHYR_CPP_SHA"

apply_layer() {  # <tree> <patch>...
  local TREE="$1"; shift
  for P in "$@"; do
    [ -e "$P" ] || continue
    if git -C "$TREE" apply -R --check "$P" 2>/dev/null; then
      echo "$(basename "$P"): already applied"
    else
      git -C "$TREE" apply --whitespace=nowarn "$P"
      echo "$(basename "$P"): applied to $(basename "$TREE")"
    fi
  done
}

if [ "${ZIOS_BACKPORTS:-0}" = 1 ]; then
  apply_layer work/zephyr "$ROOT"/patches/backports/zephyr/*.patch
  apply_layer work/zephyr-cpp "$ROOT"/patches/backports/zephyr-cpp/*.patch
fi
apply_layer work/zephyr "$ROOT"/patches/ios/zephyr/*.patch
apply_layer work/zephyr-cpp "$ROOT"/patches/ios/zephyr-cpp/*.patch

echo "zephyr:     $(git -C work/zephyr rev-parse HEAD) ($ZEPHYR_TAG)"
echo "zephyr-cpp: $(git -C work/zephyr-cpp rev-parse HEAD)"
echo "backports layer: $([ "${ZIOS_BACKPORTS:-0}" = 1 ] && echo applied || echo off)"
