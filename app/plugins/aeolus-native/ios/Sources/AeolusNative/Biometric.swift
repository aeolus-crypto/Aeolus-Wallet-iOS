import Foundation
import LocalAuthentication
import Security

/// Biometric unlock bound to a key, as on Android: a P-256 key in the Secure Enclave that can only
/// be used after Face ID / Touch ID, and that iOS deletes when the enrolled biometrics change
/// (.biometryCurrentSet). Success means the Secure Enclave signed a fresh challenge that verifies
/// with the key's public key, not just that a callback said "true". After a new enrolment the key
/// is gone: biometric unlock turns itself off and the user unlocks with the PIN and turns it on again.
enum Biometric {
    private static let tag = Data("com.aeolus.wallet.biometric".utf8)
    private static let flags = Keychain(service: "com.aeolus.wallet.biometric")

    static var available: Bool {
        var e: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e)
    }

    static var enabled: Bool { flags.getString("enabled") == "1" }

    static func setEnabled(_ on: Bool) {
        if on {
            deleteKey()
            _ = try? createKey()
            flags.set("enabled", string: "1")
        } else {
            deleteKey()
            flags.set("enabled", string: "0")
        }
    }

    static func reset() {
        deleteKey()
        flags.clear()
    }

    private static func createKey() throws -> SecKey {
        var err: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], &err) else {
            throw err!.takeRetainedValue() as Error
        }
        var attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access
            ] as [String: Any]
        ]
        #if !targetEnvironment(simulator)
        attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        #endif
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw err!.takeRetainedValue() as Error
        }
        return key
    }

    private static func deleteKey() {
        let q: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag]
        SecItemDelete(q as CFDictionary)
    }

    enum Outcome { case ok, failed, invalidated }

    /// Shows Face ID / Touch ID and proves it with a Secure Enclave signature. Calls back on main.
    static func prompt(_ done: @escaping (Outcome) -> Void) {
        let finish: (Outcome) -> Void = { o in DispatchQueue.main.async { done(o) } }
        guard enabled, available else { finish(.failed); return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use PIN"
        ctx.localizedCancelTitle = "Use PIN"
        DispatchQueue.global(qos: .userInitiated).async {
            let q: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecReturnRef as String: true,
                kSecUseAuthenticationContext as String: ctx,
                kSecUseOperationPrompt as String: "Unlock Aeolus"
            ]
            var ref: CFTypeRef?
            let st = SecItemCopyMatching(q as CFDictionary, &ref)
            if st == errSecItemNotFound {
                // the enrolled biometrics changed: the key is gone
                flags.set("enabled", string: "0")
                finish(.invalidated)
                return
            }
            guard st == errSecSuccess, let r = ref, CFGetTypeID(r) == SecKeyGetTypeID() else { finish(.failed); return }
            let key = r as! SecKey
            var challenge = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, challenge.count, &challenge)
            let msg = Data(challenge) as CFData
            var err: Unmanaged<CFError>?
            guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, msg, &err),
                  let pub = SecKeyCopyPublicKey(key),
                  SecKeyVerifySignature(pub, .ecdsaSignatureMessageX962SHA256, msg, sig, &err) else {
                finish(.failed)
                return
            }
            finish(.ok)
        }
    }
}
