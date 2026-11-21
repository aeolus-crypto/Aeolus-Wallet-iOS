#!/usr/bin/env bash
# Builds zephyr's contrib/depends packages (boost, OpenSSL, libsodium, unbound, expat, zeromq)
# for iOS with the iOS host from patches/. Usage: scripts/build_depends.sh <iphoneos|iphonesimulator>
set -euo pipefail
. "$(dirname "$0")/env.sh" "${1:-iphoneos}"
xcodebuild -version
xcrun --sdk "$ZIOS_PLATFORM" --show-sdk-path
make -C "$Z/contrib/depends" HOST=aarch64-apple-ios IOS_PLATFORM="$ZIOS_PLATFORM" \
  IOS_MIN_VERSION="$ZIOS_MIN_IOS" -j"$NPROC"
ls -l "$ZIOS_PREFIX/lib"
