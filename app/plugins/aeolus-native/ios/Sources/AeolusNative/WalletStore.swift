import Foundation
import Security

/// Where the wallet lives on the phone (the iOS counterpart of the Android plugin's filesDir/zephyr
/// and KeystoreVault):
///  - keys.bin  the wallet's keys data, encrypted by the core with the vault password
///  - cache.bin the wallet's cache data, encrypted by the core
///  - the vault password: 32 random bytes in the Keychain (this device only)
/// The files use complete file protection and are excluded from backups. Without this device's
/// Keychain item they cannot be opened; the plugin then rebuilds the wallet from the seed.
final class WalletStore {
    static let keychain = Keychain(service: "com.aeolus.wallet.vault")
    private let lock = NSLock()

    let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("zephyr", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? d.setResourceValues(rv)
        return d
    }()

    var keysFile: URL { dir.appendingPathComponent("keys.bin") }
    var cacheFile: URL { dir.appendingPathComponent("cache.bin") }

    /// The password that encrypts keys.bin; made once per install.
    func vaultPassword() throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let pw = Self.keychain.getString("wallet_password"), !pw.isEmpty { return pw }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Engine.Failure(message: "no randomness")
        }
        let pw = Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
        guard Self.keychain.set("wallet_password", string: pw) else { throw Engine.Failure(message: "keychain write failed") }
        return pw
    }

    var hasWallet: Bool {
        FileManager.default.fileExists(atPath: keysFile.path) && FileManager.default.fileExists(atPath: cacheFile.path)
    }

    func read() throws -> (keys: Data, cache: Data) {
        (try Data(contentsOf: keysFile), try Data(contentsOf: cacheFile))
    }

    /// Cache first, then keys, each written atomically (temporary file + rename).
    func write(keys: Data, cache: Data) throws {
        try cache.write(to: cacheFile, options: [.atomic, .completeFileProtection])
        try keys.write(to: keysFile, options: [.atomic, .completeFileProtection])
    }

    func wipeFiles() {
        try? FileManager.default.removeItem(at: keysFile)
        try? FileManager.default.removeItem(at: cacheFile)
    }
}
