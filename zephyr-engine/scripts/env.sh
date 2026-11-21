# Sourced by the build scripts. Usage: . scripts/env.sh <iphoneos|iphonesimulator>
ZIOS_PLATFORM="${1:-iphoneos}"
case "$ZIOS_PLATFORM" in
  iphoneos|iphonesimulator) ;;
  *) echo "platform must be iphoneos or iphonesimulator, not '$ZIOS_PLATFORM'" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/pins.env"
MZJ="$ROOT/work/myzephyr-java"
ZCPP="$MZJ/external/zephyr-cpp"
Z="$ZCPP/external/zephyr"
ZIOS_PREFIX="$Z/contrib/depends/aarch64-apple-ios"
ZIOS_MIN_IOS="$IOS_MIN_VERSION"
ZB="$Z/build/ios-$ZIOS_PLATFORM"
EB="$ROOT/work/build/engine-$ZIOS_PLATFORM"
OUT="$ROOT/work/out/$ZIOS_PLATFORM"
NPROC="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
# CMake 4 refuses projects below 3.5; zephyr's externals declare older minimums
export CMAKE_POLICY_VERSION_MINIMUM=3.5
export ZIOS_PLATFORM ZIOS_PREFIX ZIOS_MIN_IOS
