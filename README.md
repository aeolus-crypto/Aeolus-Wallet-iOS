# Aeolus Wallet for iOS

The iPhone version of Aeolus Wallet, a non-custodial Zephyr wallet.

| Folder | What it is |
|---|---|
| `zephyr-engine/` | Builds the Zephyr wallet engine (the same pinned sources as the Android app's library) for iOS, with a C interface for Swift. Built by `.github/workflows/engine.yml`. |

The app itself (Capacitor iOS shell, Swift plugins) follows once the engine builds and passes
its Simulator test.
