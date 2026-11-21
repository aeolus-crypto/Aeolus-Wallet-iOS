# zephyr-engine

Builds the Zephyr wallet engine for iOS (arm64 devices and the arm64 iOS Simulator) as a static
library with a small C interface, for the iPhone version of Aeolus Wallet.

The engine is built from exactly the sources of the Android library Aeolus ships,
`dev.lateo:zephyr-java-android:2.3.0-sec.2-java.5`: [myzephyr-java](https://github.com/loki-notfound/myzephyr-java)
at tag `v2.3.0-sec.2-java.5` (pinned by commit in `pins.env`), which pins zephyr-cpp
`v2.3.0-sec.1` and zephyr `v2.3.0-sec.2` and patches zephyr's `contrib/depends`. This repository
adds one patch on top (`patches/`): an iOS host for `contrib/depends`, a boost 1.64 backport for
current Clang, OpenSSL without `async` on iOS, and IOKit kept out of iOS builds.

No wallet data, keys or app code live here.

## Build (GitHub Actions, `.github/workflows/engine.yml`)

1. `scripts/setup_tree.sh` – pinned sources, Android build-layer patches, iOS patch
2. `scripts/build_depends.sh <platform>` – boost, OpenSSL, libsodium, unbound, expat, zeromq
3. `scripts/build_zephyr.sh <platform>` – zephyr's wallet libraries (Trezor off, as on Android)
4. `scripts/build_engine.sh <platform>` – zephyr-cpp + `engine/zephyr_ios.cpp`, merged into
   `libzephyr_ios.a`; links `engine/smoke_test.c`
5. `scripts/run_smoke_simulator.sh` – offline test in the iOS Simulator: create, reopen and
   restore a wallet, refuse a wrong password

`<platform>` is `iphoneos` or `iphonesimulator`. The last job packs both into
`ZephyrIOS.xcframework`.

## Licences

zephyr is under the BSD-3-Clause licence of the Monero and Zephyr code; zephyr-cpp and
myzephyr-java are under the MIT licence.
