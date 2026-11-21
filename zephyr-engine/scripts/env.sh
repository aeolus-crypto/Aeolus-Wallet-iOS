# Sourced by the build scripts. Usage: . scripts/env.sh <iphoneos|iphonesimulator>
ZIOS_PLATFORM="${1:-iphoneos}"
case "$ZIOS_PLATFORM" in
  iphoneos|iphonesimulator) ;;
  *) echo "platform must be iphoneos or iphonesimulator, not '$ZIOS_PLATFORM'" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/pins.env"
Z="$ROOT/work/zephyr"
ZCPP="$ROOT/work/zephyr-cpp"
ZIOS_PREFIX="$ROOT/work/deps/$ZIOS_PLATFORM/prefix"
ZIOS_MIN_IOS="$IOS_MIN_VERSION"
ZB="$ROOT/work/build/zephyr-$ZIOS_PLATFORM"
EB="$ROOT/work/build/engine-$ZIOS_PLATFORM"
OUT="$ROOT/work/out/$ZIOS_PLATFORM"
NPROC="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
# CMake 4 refuses projects below 3.5; zephyr's externals declare older minimums
export CMAKE_POLICY_VERSION_MINIMUM=3.5
export ZIOS_PLATFORM ZIOS_PREFIX ZIOS_MIN_IOS
