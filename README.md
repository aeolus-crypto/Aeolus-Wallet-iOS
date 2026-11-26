# Aeolus Wallet for iOS

The iPhone version of Aeolus Wallet, a non-custodial Zephyr wallet.

| Folder | What it is |
|---|---|
| `zephyr-engine/` | Builds the Zephyr wallet engine (the same pinned sources as the Android app's library) for iOS, with a C interface for Swift. Built by `.github/workflows/engine.yml`. |

The app itself (Capacitor iOS shell, Swift plugins) follows once the engine builds and passes
its Simulator test.

## Background payment alerts

Settings → Background Sync + Payment Alerts. iOS has no always-on service like Android's, so this works
differently, and honestly less often:

- iOS wakes the app now and then (app refresh, about 30 s; processing, a few minutes, mostly while
  charging) when it decides to: roughly every 15 minutes to a few hours. Never after you swipe the app
  away, and not with Background App Refresh off or Low Power Mode on.
- A separate **view-only watch wallet** (address + private view key, no seed, no spend key) syncs in those
  wake-ups, starting at the chain tip when you switch it on. The real wallet stays fully locked while the
  phone is locked.
- A payment shows as "Payment received": no amount, no address. Your own sends and swaps never alert.
- No push server, no Apple Push: nothing leaves the phone except the node requests the wallet already makes.
- Switching Background Sync off, or deleting the wallet, deletes the watch wallet and its Keychain item.

Code: `app/plugins/aeolus-native/ios/Sources/AeolusNative/BackgroundSync.swift` (watcher),
`PaymentFilter.swift` (which transactions alert; tested in CI).
