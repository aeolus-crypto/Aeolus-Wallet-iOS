import Foundation
import Security

/// Generic-password items in the app's Keychain, never migrated to another device (no iCloud
/// Keychain, not in backups restored elsewhere). By default an item is readable only while the
/// device is unlocked; only the background payment watcher (WatchStore, view key only) asks for
/// "after first unlock" so it can run while the phone is locked.
struct Keychain {
    let service: String
    var accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    func get(_ account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func getString(_ account: String) -> String? {
        get(account).map { String(decoding: $0, as: UTF8.self) }
    }

    @discardableResult
    func set(_ account: String, _ data: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]
        var st = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        if st == errSecItemNotFound {
            var add = base
            attrs.forEach { add[$0.key] = $0.value }
            st = SecItemAdd(add as CFDictionary, nil)
        }
        return st == errSecSuccess
    }

    @discardableResult
    func set(_ account: String, string: String) -> Bool { set(account, Data(string.utf8)) }

    @discardableResult
    func remove(_ account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let st = SecItemDelete(q as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }

    /// Removes every item of this service.
    @discardableResult
    func clear() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let st = SecItemDelete(q as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }
}
