import Foundation
import CommonCrypto
import CryptoKit

/// Native send PIN, the iOS counterpart of the Android plugin's enrollSendPin / authorizeSend.
/// The verifier lives in its own Keychain service that the page cannot read or write (it is not
/// SecureStorage), so an injected script cannot plant a verifier for a PIN it chose.
///
///   key   = PBKDF2-HMAC-SHA256(pin + ":" + pepperB64, salt, iterations, 32 bytes)
///   token = AES-256-GCM(key, nonce = 12 zero bytes, "zephyr_pin_verify")  (ciphertext || tag)
///   verifier = "v2$" + iterations + "$" + base64(token)      (PinVerifier.java, index.html hashPin)
///
/// Failures share one limiter: 5 free tries, then 30 s doubling up to 1 h.
/// A successful authorizeSend allows ONE relayPrepared within 180 s.
enum NativeAuth {
    static let keychain = Keychain(service: "com.aeolus.wallet.nativeauth")
    static let iterations = 600_000
    private static let minIterations = 100_000, maxIterations = 5_000_000
    private static let window: TimeInterval = 180
    private static let lock = NSLock()
    private static var authUntil: Date = .distantPast

    enum Result {
        case ok
        case fail(reason: String, retryMs: Int64?)
    }

    static func validPin(_ p: String) -> Bool {
        p.count >= 4 && p.count <= 8 && p.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private static func int(_ k: String) -> Int64 { Int64(keychain.getString(k) ?? "") ?? 0 }

    private static func lockedFor() -> Int64? {
        let left = int("lock_until") - now()
        return left > 0 ? left : nil
    }

    /// Records a failed check; returns ms locked (0 = not locked yet).
    private static func recordFail() -> Int64 {
        let fails = int("fails") + 1
        let lockMs: Int64 = fails >= 5 ? min(3_600_000, Int64(30_000) << min(fails - 5, 7)) : 0
        keychain.set("fails", string: String(fails))
        keychain.set("lock_until", string: String(lockMs > 0 ? now() + lockMs : 0))
        return lockMs
    }

    private static func clearFails() {
        keychain.set("fails", string: "0")
        keychain.set("lock_until", string: "0")
    }

    static func pbkdf2(_ password: String, salt: Data, iterations: Int) -> Data? {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        let st = out.withUnsafeMutableBytes { ob in
            salt.withUnsafeBytes { sb in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.map { Int8(bitPattern: $0) }, pw.count,
                                     sb.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     ob.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return st == Int32(kCCSuccess) ? out : nil
    }

    static func token(pin: String, pepperB64: String, salt: Data, iterations: Int) throws -> Data {
        guard let k = pbkdf2(pin + ":" + pepperB64, salt: salt, iterations: iterations) else {
            throw Engine.Failure(message: "kdf failed")
        }
        let box = try AES.GCM.seal(Data("zephyr_pin_verify".utf8), using: SymmetricKey(data: k),
                                   nonce: AES.GCM.Nonce(data: Data(count: 12)))
        return box.ciphertext + box.tag
    }

    private static func checkPin(_ pin: String) -> Bool {
        guard let v = keychain.getString("verifier"), v.hasPrefix("v2$"),
              let pepper = keychain.getString("pepper"),
              let saltB64 = keychain.getString("salt"), let salt = Data(base64Encoded: saltB64) else { return false }
        let parts = v.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 3, let it = Int(parts[1]), it >= minIterations, it <= maxIterations,
              let want = Data(base64Encoded: String(parts[2])),
              let got = try? token(pin: pin, pepperB64: pepper, salt: salt, iterations: it) else { return false }
        // constant-time comparison
        guard got.count == want.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<got.count { diff |= got[got.startIndex + i] ^ want[want.startIndex + i] }
        return diff == 0
    }

    private static func random(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }

    static func enroll(pin: String, oldPin: String) -> Result {
        lock.lock(); defer { lock.unlock() }
        if let l = lockedFor() { return .fail(reason: "locked", retryMs: l) }
        guard validPin(pin) else { return .fail(reason: "invalid", retryMs: nil) }
        if keychain.getString("verifier") != nil {
            guard validPin(oldPin), checkPin(oldPin) else {
                let l = recordFail()
                return .fail(reason: l > 0 ? "locked" : "wrong", retryMs: l > 0 ? l : nil)
            }
            if oldPin == pin { clearFails(); return .ok }   // already enrolled
        }
        let pepper = random(32).base64EncodedString(), salt = random(16)
        guard let tok = try? token(pin: pin, pepperB64: pepper, salt: salt, iterations: iterations) else {
            return .fail(reason: "error", retryMs: nil)
        }
        let ok = keychain.set("pepper", string: pepper)
            && keychain.set("salt", string: salt.base64EncodedString())
            && keychain.set("verifier", string: "v2$\(iterations)$" + tok.base64EncodedString())
        clearFails()
        return ok ? .ok : .fail(reason: "error", retryMs: nil)
    }

    static func authorize(pin: String) -> Result {
        lock.lock(); defer { lock.unlock() }
        if let l = lockedFor() { return .fail(reason: "locked", retryMs: l) }
        guard keychain.getString("verifier") != nil else { return .fail(reason: "enroll", retryMs: nil) }
        if validPin(pin) && checkPin(pin) {
            clearFails()
            authUntil = Date().addingTimeInterval(window)
            return .ok
        }
        let l = recordFail()
        return .fail(reason: l > 0 ? "locked" : "wrong", retryMs: l > 0 ? l : nil)
    }

    /// True once per authorize(), within the window.
    static func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let ok = Date() < authUntil
        authUntil = .distantPast
        return ok
    }

    /// A new send is being built or one was dropped: an earlier PIN entry must not carry over.
    static func disarm() {
        lock.lock(); defer { lock.unlock() }
        authUntil = .distantPast
    }

    /// Wallet wipe: forget the send PIN too.
    static func clear() {
        lock.lock(); defer { lock.unlock() }
        keychain.clear()
        authUntil = .distantPast
    }
}

/// Keychain items outlive an uninstall on iOS, app files and UserDefaults do not. On the first
/// launch of an install, drop what a previous install left in the Keychain, so a reinstall starts
/// clean (as on Android, where uninstalling deletes everything).
enum InstallGuard {
    private static let lock = NSLock()
    private static var done = false

    static func run() {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        let flag = "aeolus.installed"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        NativeAuth.keychain.clear()
        WalletStore.keychain.clear()
        SecureStoragePlugin.keychain.clear()
        Biometric.reset()
        UserDefaults.standard.set(true, forKey: flag)
    }
}
