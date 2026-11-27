import Foundation
import Security

/// Keeps a PIN pepper encrypted under a Secure Enclave key (security audit LOW-01).
///
/// Both PIN schemes (the page's seed-encryption PIN, `zw_kdf_pepper`, and the native send PIN) mix a
/// random pepper into PBKDF2. Stored as a plain Keychain item, the pepper sits next to what it
/// protects, so a full Keychain extraction (jailbreak, forensic tools) would allow an offline PIN
/// guess. Encrypted to a Secure Enclave P-256 key (ECIES), the pepper can only be read on this
/// phone, by this app, while it is unlocked; every guess then has to go through the Secure Enclave
/// on the device. This is what Android gets from keeping the pepper in the hardware Keystore.
///
/// Stored form: "sew1:" + base64(ECIES ciphertext). A value without the prefix is a pepper from an
/// older build: read as it is and re-stored wrapped. Where there is no Secure Enclave (Simulator)
/// the pepper stays plain. A wrapped value that can't be unwrapped is an error, never "absent", so
/// nobody creates a new pepper over the old one (the page's rule too).
enum PepperWrap {
    static let prefix = "sew1:"
    private static let alg = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
    private static let lock = NSLock()

    enum Scope: String {
        case web = "com.aeolus.wallet.pepperwrap.web"
        case native = "com.aeolus.wallet.pepperwrap.native"
        var tag: Data { Data(rawValue.utf8) }
    }

    /// The wrapped form, or nil where no Secure Enclave key can be made (then store it plain).
    static func wrap(_ plain: String, _ scope: Scope) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let key = privateKey(scope, create: true), let pub = SecKeyCopyPublicKey(key),
              SecKeyIsAlgorithmSupported(pub, .encrypt, alg) else { return nil }
        var err: Unmanaged<CFError>?
        guard let ct = SecKeyCreateEncryptedData(pub, alg, Data(plain.utf8) as CFData, &err) as Data? else { return nil }
        return prefix + ct.base64EncodedString()
    }

    /// The pepper from its stored form; nil if a wrapped value can't be opened.
    static func unwrap(_ stored: String, _ scope: Scope) -> String? {
        guard stored.hasPrefix(prefix) else { return stored }   // plain (older build or no Secure Enclave)
        lock.lock(); defer { lock.unlock() }
        guard let ct = Data(base64Encoded: String(stored.dropFirst(prefix.count))),
              let key = privateKey(scope, create: false) else { return nil }
        var err: Unmanaged<CFError>?
        guard let pt = SecKeyCreateDecryptedData(key, alg, ct as CFData, &err) as Data? else { return nil }
        return String(data: pt, encoding: .utf8)
    }

    static func isWrapped(_ stored: String) -> Bool { stored.hasPrefix(prefix) }

    /// Wallet wipe / fresh install: the key goes with the peppers it protected.
    static func reset(_ scope: Scope) {
        lock.lock(); defer { lock.unlock() }
        let q: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: scope.tag]
        SecItemDelete(q as CFDictionary)
    }

    private static func privateKey(_ scope: Scope, create: Bool) -> SecKey? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: scope.tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let o = out {
            return (o as! SecKey)
        }
        guard create else { return nil }
        #if targetEnvironment(simulator)
        return nil   // no Secure Enclave: the pepper stays a plain Keychain item
        #else
        var err: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage], &err) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: scope.tag,
                kSecAttrAccessControl as String: access
            ] as [String: Any]
        ]
        return SecKeyCreateRandomKey(attrs as CFDictionary, &err)
        #endif
    }
}
