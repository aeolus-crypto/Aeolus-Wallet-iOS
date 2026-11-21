#!/usr/bin/env bash
# Builds the engine library, merges it with zephyr's and the depends prefix's static libraries
# into work/out/<platform>/libzephyr_ios.a, and links the smoke test against that archive.
# Usage: scripts/build_engine.sh <iphoneos|iphonesimulator>
set -euo pipefail
. "$(dirname "$0")/env.sh" "${1:-iphoneos}"

. "$ROOT/deps/versions.env"
BP="$(git -C "$Z" diff --quiet -- src/wallet/wallet2.cpp && echo off || echo on)"
SOURCES="zephyr $ZEPHYR_TAG $(git -C "$Z" rev-parse --short=12 HEAD), zephyr-cpp $(git -C "$ZCPP" rev-parse --short=12 HEAD), boost $BOOST_VERSION, backports $BP, $ZIOS_PLATFORM"
rm -rf "$EB"
cmake -S "$ROOT/engine" -B "$EB" -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/ios.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DZEPHYR_CPP="$ZCPP" -DZEPHYR_SRC="$Z" -DZEPHYR_BUILD="$ZB" -DZIOS_SOURCES="$SOURCES"
make -C "$EB" -j"$NPROC" VERBOSE=1

# the archives to merge: the engine, zephyr's libraries as zephyr-cpp lists them, the depends libraries
LIBS=("$EB/libzephyr_engine.a")
for LIB in $(grep -o '\${MONERO_PROJECT_BUILD}/[^)[:space:]]*\.a' "$ZCPP/CMakeLists.txt" | sort -u); do
  F="$ZB/${LIB#\$\{MONERO_PROJECT_BUILD\}/}"
  [ -f "$F" ] && LIBS+=("$F")
done
# zephyr's liboracle.a (pricing records) is not in zephyr-cpp's list; myzephyr-java links it too
LIBS+=("$ZB/src/oracle/liboracle.a")
for F in "$ZIOS_PREFIX"/lib/libboost_*.a; do LIBS+=("$F"); done
for N in ssl crypto sodium unbound expat; do LIBS+=("$ZIOS_PREFIX/lib/lib$N.a"); done

mkdir -p "$OUT/include"
rm -f "$OUT/libzephyr_ios.a"
xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/libzephyr_ios.a" "${LIBS[@]}" 2> >(grep -v 'same member name' >&2)
cp "$ROOT/engine/zephyr_ios.h" "$OUT/include/"
ls -l "$OUT/libzephyr_ios.a"

# link the smoke test: every symbol the wallet needs must resolve
if [ "$ZIOS_PLATFORM" = iphonesimulator ]; then T="arm64-apple-ios$ZIOS_MIN_IOS-simulator"; else T="arm64-apple-ios$ZIOS_MIN_IOS"; fi
xcrun --sdk "$ZIOS_PLATFORM" clang -target "$T" -O1 \
  "$ROOT/engine/smoke_test.c" -I"$ROOT/engine" "$OUT/libzephyr_ios.a" \
  -lc++ -framework Foundation -framework Security -framework CoreFoundation \
  -o "$OUT/zios_smoke"
ls -l "$OUT/zios_smoke"
