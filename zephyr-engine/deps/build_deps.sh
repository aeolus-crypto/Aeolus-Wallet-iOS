#!/usr/bin/env bash
# Builds the engine's dependencies for iOS into work/deps/<platform>/prefix, outside the zephyr
# tree (so this recipe never touches files that the zephyr-backports patches change).
# Usage: deps/build_deps.sh <iphoneos|iphonesimulator>
# Options mirror zephyr's contrib/depends recipes where they apply (static, no shared libraries,
# OpenSSL without dso/engines/tests, unbound as library only, zeromq without curve).
set -euo pipefail
. "$(dirname "$0")/../scripts/env.sh" "${1:-iphoneos}"
. "$ROOT/deps/versions.env"

STAMP="$ZIOS_PREFIX/.complete-$(cat "$ROOT/deps/versions.env" "$ROOT/deps/build_deps.sh" | shasum -a 256 | cut -c1-16)"
if [ -f "$STAMP" ]; then
  echo "dependencies up to date in $ZIOS_PREFIX"
  exit 0
fi

SRC="$ROOT/work/deps/sources"
BLD="$ROOT/work/deps/build-$ZIOS_PLATFORM"
rm -rf "$BLD" "$ZIOS_PREFIX"
mkdir -p "$SRC" "$BLD" "$ZIOS_PREFIX"

SDK="$(xcrun --sdk "$ZIOS_PLATFORM" --show-sdk-path)"
if [ "$ZIOS_PLATFORM" = iphonesimulator ]; then
  TRIPLE="arm64-apple-ios$ZIOS_MIN_IOS-simulator"
else
  TRIPLE="arm64-apple-ios$ZIOS_MIN_IOS"
fi
CC="$(xcrun -f clang) -target $TRIPLE -isysroot $SDK"
CXX="$(xcrun -f clang++) -target $TRIPLE -isysroot $SDK -stdlib=libc++"
AR="$(xcrun -f ar)"
RANLIB="$(xcrun -f ranlib)"
LIBTOOL="$(xcrun -f libtool)"
# autoconf: an explicit, different --build makes configure cross-compile (no test programs run)
# config.sub of older packages (libsodium 1.0.18) knows aarch64, not arm64
BUILD_TRIPLE="aarch64-apple-darwin$(uname -r)"
HOST_TRIPLE=aarch64-apple-darwin
echo "SDK $SDK, target $TRIPLE"

fetch() {  # <file> <sha256> <urls>
  local FILE="$1" SHA="$2" URLS="$3" U
  if [ -f "$SRC/$FILE" ] && [ "$(shasum -a 256 "$SRC/$FILE" | cut -d' ' -f1)" = "$SHA" ]; then return 0; fi
  for U in $URLS; do
    echo "fetch $U"
    if curl --location --fail --silent --show-error --connect-timeout 30 --retry 3 \
         --speed-limit 1000 --speed-time 120 -o "$SRC/$FILE.part" "$U"; then
      if [ "$(shasum -a 256 "$SRC/$FILE.part" | cut -d' ' -f1)" = "$SHA" ]; then
        mv "$SRC/$FILE.part" "$SRC/$FILE"
        return 0
      fi
      echo "sha256 mismatch for $U" >&2
    fi
  done
  echo "could not fetch $FILE with sha256 $SHA" >&2
  exit 1
}

unpack() {  # <file> -> prints the directory
  local FILE="$1" D
  D="$BLD/$(basename "$FILE" | sed -E 's/\.tar\.(gz|bz2|xz)$//')"
  rm -rf "$D" && mkdir -p "$D"
  tar -xf "$SRC/$FILE" -C "$D" --strip-components 1
  echo "$D"
}

autotools() {  # <dir> <configure args...>
  local D="$1"; shift
  (cd "$D" && ./configure --build="$BUILD_TRIPLE" --host="$HOST_TRIPLE" --prefix="$ZIOS_PREFIX" \
      --disable-shared --enable-static \
      CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" \
      CFLAGS="-O2" CXXFLAGS="-O2" CPPFLAGS="-I$ZIOS_PREFIX/include" LDFLAGS="-L$ZIOS_PREFIX/lib" "$@")
}

# --- OpenSSL (before unbound)
fetch "$OPENSSL_FILE" "$OPENSSL_SHA256" "$OPENSSL_URLS"
D="$(unpack "$OPENSSL_FILE")"
(cd "$D" &&
  sed -i.old 's|crypto ssl apps util tools fuzz providers doc|crypto ssl util tools providers|' build.info &&
  CC="$CC" AR="$AR" RANLIB="$RANLIB" ./Configure darwin64-arm64-cc \
    --prefix="$ZIOS_PREFIX" --openssldir=/etc/ssl --libdir="$ZIOS_PREFIX/lib" \
    no-async no-shared no-dso no-capieng no-dtls1 no-ec_nistp_64_gcc_128 no-gost no-md2 no-rc5 \
    no-rdrand no-rfc3779 no-sctp no-ssl-trace no-ssl3 no-tests no-unit-test no-weak-ssl-ciphers \
    no-zlib no-zlib-dynamic -O2 &&
  make -j"$NPROC" build_libs ENGINESDIR=/usr/lib/engines-3 MODULESDIR=/usr/lib/ossl-modules &&
  make install_sw)

# --- libsodium
fetch "$SODIUM_FILE" "$SODIUM_SHA256" "$SODIUM_URLS"
D="$(unpack "$SODIUM_FILE")"
autotools "$D"
make -C "$D" -j"$NPROC" && make -C "$D" install

# --- expat (before unbound)
fetch "$EXPAT_FILE" "$EXPAT_SHA256" "$EXPAT_URLS"
D="$(unpack "$EXPAT_FILE")"
autotools "$D" --without-docbook --without-tests --without-examples --without-xmlwf --with-pic
make -C "$D" -j"$NPROC" && make -C "$D" install

# --- unbound (library only)
fetch "$UNBOUND_FILE" "$UNBOUND_SHA256" "$UNBOUND_URLS"
D="$(unpack "$UNBOUND_FILE")"
autotools "$D" --without-pyunbound --with-libexpat="$ZIOS_PREFIX" --with-ssl="$ZIOS_PREFIX" \
  --with-libevent=no --without-pythonmodule --disable-flto --with-pthreads --with-libunbound-only \
  --sysconfdir=/etc ac_cv_func_getentropy=no
make -C "$D" -j"$NPROC" && make -C "$D" install

# --- zeromq (zephyr's CMake requires it; the wallet does not use it)
fetch "$ZEROMQ_FILE" "$ZEROMQ_SHA256" "$ZEROMQ_URLS"
D="$(unpack "$ZEROMQ_FILE")"
autotools "$D" --without-documentation --without-libsodium --disable-curve CXXFLAGS="-O2 -std=c++11"
make -C "$D" -j"$NPROC" src/libzmq.la
make -C "$D" install-libLTLIBRARIES install-includeHEADERS install-pkgconfigDATA

# --- Boost (the libraries zephyr's CMake asks for)
fetch "$BOOST_FILE" "$BOOST_SHA256" "$BOOST_URLS"
D="$(unpack "$BOOST_FILE")"
(cd "$D" &&
  ./bootstrap.sh --without-icu \
    --with-libraries=chrono,date_time,filesystem,program_options,regex,serialization,system,thread &&
  echo "using darwin : : $CXX : <cxxflags>\"-O2\" <archiver>\"$LIBTOOL\" <striper> ;" > user-config.jam &&
  ./b2 -j"$NPROC" -d1 --user-config=user-config.jam toolset=darwin \
    variant=release link=static runtime-link=shared threading=multi cxxstd=17 --layout=system \
    -sNO_BZIP2=1 -sNO_ZLIB=1 --prefix="$ZIOS_PREFIX" install)

rm -f "$ZIOS_PREFIX"/lib/*.la
rm -rf "$BLD"
touch "$STAMP"
ls -l "$ZIOS_PREFIX/lib"
