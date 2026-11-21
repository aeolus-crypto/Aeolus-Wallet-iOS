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
        if let v = Self.keychain.getString(k) { call.resolve(["value": v]) } else { call.resolve() }
    }

    @objc func setItem(_ call: CAPPluginCall) {
        guard let k = key(call) else { return }
        guard let v = call.getString("value"), v.count <= Self.maxValueLen else {
            call.reject("Invalid value")
            return
        }
        Self.keychain.set(k, string: v) ? call.resolve() : call.reject("Secure storage write failed")
    }

    @objc func removeItem(_ call: CAPPluginCall) {
        guard let k = key(call) else { return }
        Self.keychain.remove(k) ? call.resolve() : call.reject("Secure storage remove failed")
    }

    /// Wipes only the web app's secrets (used by the wallet wipe).
    @objc func clear(_ call: CAPPluginCall) {
        Self.keychain.clear() ? call.resolve() : call.reject("Secure storage clear failed")
    }
}
