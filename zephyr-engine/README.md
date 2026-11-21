# zephyr-engine

Builds the Zephyr wallet engine for iOS (arm64 devices and the arm64 iOS Simulator) as
`ZephyrIOS.xcframework`: zephyr-cpp's in-process wallet plus a small C interface
(`engine/zephyr_ios.h`) for the app's Swift code.

## Sources and layers

- **Base:** the original repositories, pinned by commit in `pins.env`:
  ZephyrProtocol/zephyr **v2.3.0** (`67c5f53b`) and ZephyrProtocol/zephyr-cpp `4a99272f`.
- **iOS layer** (`patches/ios/`, always on):
  - `zephyr/0001-ios-build.patch`: drop the legacy `CMakeLists_IOS.txt` include; keep macOS
    IOKit code out of iOS builds.
  - `zephyr/0002-monero-246d76f4f-...`: Monero's fix of the ARMv8 slow-hash inline assembly.
    Without it, Apple clang makes the wallet-password key derivation non-deterministic and no
    saved wallet can be reopened.
- **Backports layer** (`patches/backports/`, off by default): the zephyr-backports security
  fixes, for a production release if upstream has not merged them. See its README.

The two layers touch different code, so each can be switched or refreshed on its own.

## Dependencies (`deps/`)

Built outside the zephyr tree by `deps/build_deps.sh` from checksum-pinned archives
(`deps/versions.env`): **Boost 1.84.0**, OpenSSL 3.0.22, libsodium 1.0.18, expat 2.6.0,
unbound 1.26.1, zeromq 4.3.5. Boost 1.84 is the newest Boost that upstream Zephyr v2.3.0 builds
against unchanged (1.85 removes `copy_option`, used by `wallet2.cpp`; 1.87 removes the asio
`io_service` used by epee).

## Build (`.github/workflows/engine.yml`)

1. `scripts/setup_tree.sh`: pinned sources and patch layers (`ZIOS_BACKPORTS=1` adds backports)
2. `deps/build_deps.sh <platform>`: dependencies (cached by CI)
3. `scripts/build_zephyr.sh <platform>`: zephyr's wallet libraries (Trezor off)
4. `scripts/build_engine.sh <platform>`: zephyr-cpp + C interface, merged into `libzephyr_ios.a`;
   links the smoke test
5. `scripts/run_smoke_simulator.sh`: offline checks in the iOS Simulator (create, memory round
   trip, reopen, restore, wrong password, open a wallet made on Linux)

`<platform>` is `iphoneos` or `iphonesimulator`; the last job packs both into the xcframework.

## Licences

zephyr is under the BSD-3-Clause licence of the Monero and Zephyr code; zephyr-cpp is under the
MIT licence.
