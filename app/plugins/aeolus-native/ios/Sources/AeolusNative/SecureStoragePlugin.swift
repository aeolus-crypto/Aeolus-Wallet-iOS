import Foundation
import Capacitor

/// SecureStorage: a place for the web app's secrets that is NOT WebView localStorage (the iOS
/// counterpart of the Android plugin, which uses EncryptedSharedPreferences). Values are Keychain
/// items of this device only, readable while it is unlocked. Same rules as Android: keys
/// [A-Za-z0-9_]{1,64}, values up to 64 KiB, absent key -> no "value". Never logs values.
@objc(SecureStoragePlugin)
public class SecureStoragePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SecureStoragePlugin"
    public let jsName = "SecureStorage"
    public let pluginMethods: [CAPPluginMethod] = ["getItem", "setItem", "removeItem", "clear"]
        .map { CAPPluginMethod(name: $0, returnType: CAPPluginReturnPromise) }

    static let keychain = Keychain(service: "com.aeolus.wallet.web")
    private static let maxValueLen = 64 * 1024
    /// Kept encrypted under a Secure Enclave key (PepperWrap): the page's PIN pepper, which guards
    /// the encrypted seed.
    private static let wrapped: Set<String> = ["zw_kdf_pepper"]

    override public func load() { InstallGuard.run() }

    private func key(_ call: CAPPluginCall) -> String? {
        guard let k = call.getString("key"), (1...64).contains(k.count),
              k.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            call.reject("Invalid key")
            return nil
        }
        return k
    }

    @objc func getItem(_ call: CAPPluginCall) {
        guard let k = key(call) else { return }
        guard let stored = Self.keychain.getString(k) else { call.resolve(); return }
        guard Self.wrapped.contains(k) else { call.resolve(["value": stored]); return }
        guard let v = PepperWrap.unwrap(stored, .web) else {
            call.reject("Secure storage read failed")   // never "absent": the page must not make a new pepper
            return
        }
        if !PepperWrap.isWrapped(stored), let w = PepperWrap.wrap(v, .web) {
            Self.keychain.set(k, string: w)   // pepper from an older build: wrap it now
        }
        call.resolve(["value": v])
    }

    @objc func setItem(_ call: CAPPluginCall) {
        guard let k = key(call) else { return }
        guard let v = call.getString("value"), v.count <= Self.maxValueLen else {
            call.reject("Invalid value")
            return
        }
        let stored = Self.wrapped.contains(k) ? (PepperWrap.wrap(v, .web) ?? v) : v
        Self.keychain.set(k, string: stored) ? call.resolve() : call.reject("Secure storage write failed")
    }

    @objc func removeItem(_ call: CAPPluginCall) {
        guard let k = key(call) else { return }
        Self.keychain.remove(k) ? call.resolve() : call.reject("Secure storage remove failed")
    }

    /// Wipes only the web app's secrets (used by the wallet wipe).
    @objc func clear(_ call: CAPPluginCall) {
        let ok = Self.keychain.clear()
        PepperWrap.reset(.web)
        ok ? call.resolve() : call.reject("Secure storage clear failed")
    }
}
