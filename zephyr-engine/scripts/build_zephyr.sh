#!/usr/bin/env bash
# Builds zephyr's wallet libraries for iOS against deps/build_deps.sh's prefix (the targets the
# Android build builds: wallet and cryptonote_protocol, Trezor off). Usage: scripts/build_zephyr.sh <iphoneos|iphonesimulator>
set -euo pipefail
. "$(dirname "$0")/env.sh" "${1:-iphoneos}"
mkdir -p "$ZB"
rm -f "$ZB/CMakeCache.txt"
cmake -S "$Z" -B "$ZB" -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/ios.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTS=OFF -DUSE_CCACHE=OFF -DUSE_DEVICE_TREZOR=OFF \
  -DBUILD_DOCUMENTATION=OFF -DUSE_READLINE=OFF \
  -DNO_AES=ON
make -C "$ZB" -j"$NPROC" wallet cryptonote_protocol

# every static library zephyr-cpp imports must exist (as in myzephyr-java's build scripts:
# libwallet-crypto.a is optional, libblocks.a is never built)
MISSING=0
for LIB in $(grep -o '\${MONERO_PROJECT_BUILD}/[^)[:space:]]*\.a' "$ZCPP/CMakeLists.txt" \
             | grep -v -e '/libwallet-crypto\.a$' -e '/libblocks\.a$' | sort -u); do
  F="$ZB/${LIB#\$\{MONERO_PROJECT_BUILD\}/}"
  if [ -f "$F" ]; then echo "ok  $F"; else echo "MISSING $F" >&2; MISSING=1; fi
done
if [ -f "$ZB/src/oracle/liboracle.a" ]; then echo "ok  $ZB/src/oracle/liboracle.a"; else echo "MISSING $ZB/src/oracle/liboracle.a" >&2; MISSING=1; fi
[ "$MISSING" = 0 ]
