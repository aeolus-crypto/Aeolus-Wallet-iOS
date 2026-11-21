import Foundation
import UIKit
import Capacitor
import ZephyrIOS

// Listener callbacks from the engine (C function pointers): hand off to the plugin and return.
private func zwProgress(_ ctx: UnsafeMutableRawPointer?, _ h: UInt64, _ s: UInt64, _ e: UInt64, _ p: Double) {
    guard let ctx else { return }
    Unmanaged<ZephyrWalletPlugin>.fromOpaque(ctx).takeUnretainedValue().onProgress(h, s, e, p)
}

private func zwBalances(_ ctx: UnsafeMutableRawPointer?, _ b: UnsafePointer<CChar>?, _ u: UnsafePointer<CChar>?,
                        _ a: UnsafePointer<CChar>?) {
    guard let ctx, let b, let u, let a else { return }
    Unmanaged<ZephyrWalletPlugin>.fromOpaque(ctx).takeUnretainedValue()
        .onBalances(String(cString: b), String(cString: u), String(cString: a))
}

private func zwOutput(_ ctx: UnsafeMutableRawPointer?, _ spent: Int32, _ h: Int64, _ txid: UnsafePointer<CChar>?) {
    guard let ctx else { return }
    Unmanaged<ZephyrWalletPlugin>.fromOpaque(ctx).takeUnretainedValue()
        .onOutput(spent != 0, h, txid.map { String(cString: $0) })
}

/// Bridges the Zephyr wallet engine to the web UI: the iOS counterpart of the Android plugin
/// com.aeolus.wallet.ZephyrWalletPlugin, with the same methods, results and "wallet" events, so
/// zephyr-native.js and index.html run unchanged.
///
/// Threading (as on Android):
///  - every wallet call runs on ONE serial queue (walletQ); calls block and never overlap;
///  - stopSyncing runs on controlQ so it can reach a sync that is blocking walletQ;
///  - listener callbacks only hand off to eventQ and return.
@objc(ZephyrWalletPlugin)
public class ZephyrWalletPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ZephyrWalletPlugin"
    public let jsName = "ZephyrWallet"
    public let pluginMethods: [CAPPluginMethod] = [
        "warmUp", "open", "setDaemon", "setListener", "sync", "stopSyncing", "createKeys", "restoreKeys",
        "createSubaddress", "getPrices", "getTxHistory", "getBalances", "validateAddress", "getReserveInfo",
        "enrollSendPin", "authorizeSend", "createTxs", "closeWallet", "wipe", "httpPost"
    ].map { CAPPluginMethod(name: $0, returnType: CAPPluginReturnPromise) }

    static weak var shared: ZephyrWalletPlugin?

    private static let v2: Set<String> = ["ZPH", "ZSD", "ZRS", "ZYS"]

    private let walletQ = DispatchQueue(label: "zw-wallet", qos: .userInitiated)
    private let controlQ = DispatchQueue(label: "zw-control")
    private let keysQ = DispatchQueue(label: "zw-keys", qos: .userInitiated)
    private let eventQ = DispatchQueue(label: "zw-events")
    private let store = WalletStore()

    /// walletQ only.
    private var wallet: OpaquePointer?
    /// Read by controlQ (stopSyncing) under liveLock; cleared under the lock before the wallet is freed.
    private let liveLock = NSLock()
    private var live: OpaquePointer?
    private let flags = NSLock()
    private var _stopRequested = false, _wiped = false
    private var stopRequested: Bool {
        get { flags.lock(); defer { flags.unlock() }; return _stopRequested }
        set { flags.lock(); _stopRequested = newValue; flags.unlock() }
    }
    private var wiped: Bool {
        get { flags.lock(); defer { flags.unlock() }; return _wiped }
        set { flags.lock(); _wiped = newValue; flags.unlock() }
    }
    private let progressLock = NSLock()
    private var lastProgressEmit: TimeInterval = 0

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    override public func load() {
        InstallGuard.run()
        // The core's OpenSSL verifies https nodes against the shipped Mozilla roots (as zephyr-java
        // does on Android); iOS has no OpenSSL CA directory of its own.
        if getenv("SSL_CERT_FILE") == nil, let pem = Bundle.module.path(forResource: "cacert", ofType: "pem") {
            setenv("SSL_CERT_FILE", pem, 1)
        }
        zios_set_log_level(0)
        Self.shared = self
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate),
                                               name: UIApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    /// Save and close on termination, but never hold the main thread for more than 3 s.
    @objc private func willTerminate() {
        stopRequested = true
        stopLive()
        let done = DispatchSemaphore(value: 0)
        walletQ.async { [self] in closeNow(); done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }

    /// Save once when the app leaves the screen: iOS may end it without warning afterwards.
    @objc private func didEnterBackground() {
        let task = UIApplication.shared.beginBackgroundTask(withName: "zw-persist", expirationHandler: nil)
        walletQ.async { [weak self] in
            try? self?.persist()
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    // MARK: - node HTTP for the UI

    /// POSTs JSON to a built-in node. In: {url, body, timeoutMs}. Out: {status, body}. "timeout" on a timeout.
    @objc func httpPost(_ call: CAPPluginCall) {
        let url = call.getString("url") ?? "", body = call.getString("body") ?? ""
        let timeout = Double(max(1000, min(call.getInt("timeoutMs") ?? 12000, 60000))) / 1000
        Task {
            do {
                var req = URLRequest(url: try NodeAllowlist.check(url), timeoutInterval: timeout)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = Data(body.utf8)
                let (data, resp) = try await session.data(for: req)
                if data.count > 8 * 1024 * 1024 { throw Engine.Failure(message: "response too large") }
                call.resolve(["status": (resp as? HTTPURLResponse)?.statusCode ?? 0,
                              "body": String(decoding: data, as: UTF8.self)])
            } catch let e as URLError where e.code == .timedOut {
                call.reject("timeout")
            } catch {
                call.reject(Self.msg(error))
            }
        }
    }

    // MARK: - commands

    /// Replaces the old "loadWasm". The engine is linked in; this runs its slow-hash known-answer
    /// self-test once, and refuses to start a wallet on a build whose key derivation is wrong.
    @objc func warmUp(_ call: CAPPluginCall) {
        walletQ.async { [self] in
            do {
                try selfTest()
                call.resolve(["ready": true])
            } catch {
                call.reject(Self.msg(error))
            }
        }
    }

    private var selfTestPassed = false   // walletQ / keysQ: set once

    private func selfTest() throws {
        if selfTestPassed { return }
        guard let s = Engine.take(zios_selftest(0)), s.contains("\"ok\":true") else {
            throw Engine.Failure(message: "Wallet engine self-test failed on this device")
        }
        selfTestPassed = true
    }

    @objc func open(_ call: CAPPluginCall) {
        let cfg = call.getObject("config")
        let expect = call.getString("expectAddress") ?? ""
        walletQ.async { [self] in
            do {
                try selfTest()
                try openNow(cfg, expectAddress: expect)
                let info = try Engine.json { zios_wallet_info(wallet, $0) }
                call.resolve(["address": info["address"] ?? "", "viewKey": info["viewKey"] ?? "",
                              "viewOnly": info["viewOnly"] ?? false])
            } catch {
                call.reject(Self.msg(error))
            }
        }
    }

    @objc func setDaemon(_ call: CAPPluginCall) {
        let url = call.getString("url") ?? "", user = call.getString("user") ?? "", pass = call.getString("pass") ?? ""
        walletQ.async { [self] in
            do {
                if let w = wallet { try connect(w, url, user, pass) }
                call.resolve(["ok": true])
            } catch {
                call.reject(Self.msg(error))
            }
        }
    }

    /// The listener is attached when the wallet opens; this only keeps the old command working.
    @objc func setListener(_ call: CAPPluginCall) { call.resolve(["ok": true]) }

    /// Syncs from the wallet's OWN height; the UI's startHeight is ignored on purpose (starting above
    /// the wallet's real height would skip blocks and lose outputs).
    @objc func sync(_ call: CAPPluginCall) {
        walletQ.async { [self] in
            stopRequested = false
            do {
                guard let w = wallet else { throw Engine.Failure(message: "No wallet") }
                var r = try Engine.json { zios_wallet_sync(w, $0) }
                if let f = r["fetched"] as? NSNumber, f.int64Value > 0 { try persist() }
                r.removeValue(forKey: "receivedMoney")
                r["ok"] = true
                call.resolve(r)
            } catch {
                // Not an error for the UI: a sync ended by stopSyncing() or by a wipe meanwhile.
                if stopRequested || wiped {
                    var o: [String: Any] = ["ok": true]
                    if !stopRequested { o["cancelled"] = true }
                    call.resolve(o)
                } else {
                    call.reject(Self.msg(error))
                }
            }
        }
    }

    /// A brand-new wallet's keys: {address, mnemonic, viewKey}. Never written to disk.
    @objc func createKeys(_ call: CAPPluginCall) {
        keysQ.async { Self.keys(call, phrase: nil) }
    }

    /// The keys of an existing seed phrase: {address, mnemonic, viewKey}.
    @objc func restoreKeys(_ call: CAPPluginCall) {
        let phrase = call.getString("phrase") ?? ""
        keysQ.async { Self.keys(call, phrase: phrase) }
    }

    private static func keys(_ call: CAPPluginCall, phrase: String?) {
        var w: OpaquePointer?
        defer { if let w { Engine.close(w) } }
        do {
            if let p = phrase, p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw Engine.Failure(message: "Enter your seed phrase")
            }
            // Lookahead 1/1: this wallet only exists to read the address and keys.
            var c: [String: Any] = ["password": "", "networkType": 0, "accountLookahead": 1, "subaddressLookahead": 1]
            if let p = phrase { c["mnemonic"] = p.trimmingCharacters(in: .whitespacesAndNewlines) } else { c["language"] = "English" }
            let h = try Engine.create(config: c)
            w = h
            let info = try Engine.json { zios_wallet_info(h, $0) }
            let mnemonic = try Engine.string { zios_wallet_mnemonic(h, $0) }
            call.resolve(["ok": true, "address": info["address"] ?? "", "mnemonic": mnemonic,
                          "viewKey": info["viewKey"] ?? ""])
        } catch {
            call.reject(msg(error))   // never log the phrase
        }
    }

    /// New subaddress of account 0 (after making sure at least minCount exist), then save.
    @objc func createSubaddress(_ call: CAPPluginCall) {
        let label = call.getString("label") ?? "", minCount = call.getInt("minCount") ?? 0
        walletQ.async { [self] in
            do {
                guard let w = wallet else { throw Engine.Failure(message: "No wallet") }
                var r = try Engine.json { zios_wallet_create_subaddress(w, label, Int32(minCount), $0) }
                try persist()
                r["ok"] = true
                call.resolve(r)
            } catch {
                call.reject(Self.msg(error))
            }
        }
    }

    /// USD price of one ZPH, ZSD, ZRS and ZYS from the node's latest pricing record.
    @objc func getPrices(_ call: CAPPluginCall) {
        let node = call.getString("nodeUrl") ?? ""
        Task {
            do {
                if node.isEmpty { throw Engine.Failure(message: "No node") }
                var r: [String: Any] = try await SpotValue.prices(node: node, session: session)
                r["ok"] = true
                call.resolve(r)
            } catch {
                call.reject(Self.msg(error))
            }
        }
    }

    @objc func getTxHistory(_ call: CAPPluginCall) {
        walletQuery(call) { w in try Engine.json { zios_wallet_tx_history(w, $0) } }
    }

    @objc func getBalances(_ call: CAPPluginCall) {
        walletQuery(call) { w in try Engine.json { zios_wallet_balances(w, $0) } }
    }

    @objc func getReserveInfo(_ call: CAPPluginCall) {
        walletQuery(call) { w in try Engine.json { zios_wallet_reserve_info(w, $0) } }
    }

    /// Full address check including the Keccak checksum: {valid, reason}.
    @objc func validateAddress(_ call: CAPPluginCall) {
        let a = call.getString("address") ?? ""
        var reason: UnsafeMutablePointer<CChar>? = nil
        let ok = zios_validate_address(a, 0, &reason) == 1
        let why = Engine.take(reason)
        var r: [String: Any] = ["valid": ok]
        if !ok { r["reason"] = why ?? "invalid address" }
        call.resolve(r)
    }

    /// Own queue: it has to get past a sync that is blocking walletQ.
    @objc func stopSyncing(_ call: CAPPluginCall) {
        stopRequested = true
        controlQ.async { [self] in
            stopLive()
            call.resolve(["ok": true])
        }
    }

    // MARK: - native send PIN

    @objc func enrollSendPin(_ call: CAPPluginCall) {
        let pin = call.getString("pin") ?? "", old = call.getString("oldPin") ?? ""
        keysQ.async { call.resolve(Self.authResult(NativeAuth.enroll(pin: pin, oldPin: old))) }
    }

    @objc func authorizeSend(_ call: CAPPluginCall) {
        let pin = call.getString("pin") ?? ""
        keysQ.async { call.resolve(Self.authResult(NativeAuth.authorize(pin: pin))) }
    }

    private static func authResult(_ r: NativeAuth.Result) -> [String: Any] {
        switch r {
        case .ok: return ["ok": true]
        case let .fail(reason, retryMs):
            var o: [String: Any] = ["ok": false, "reason": reason]
            if let retryMs { o["retryMs"] = retryMs }
            return o
        }
    }

    /// Builds, signs and (relay:true) broadcasts; needs an authorizeSend() within the last 180 s.
    @objc func createTxs(_ call: CAPPluginCall) {
        let json = call.getString("txConfigJson") ?? "{}", node = call.getString("nodeUrl") ?? ""
        guard NativeAuth.consume() else {
            call.reject("Send not authorized — enter your PIN again")
            return
        }
        walletQ.async { [self] in
            do {
                guard let w = wallet else { throw Engine.Failure(message: "No wallet") }
                if !node.isEmpty { try connect(w, node, "", "") }
                let r = try Engine.json { zios_wallet_create_txs(w, json, $0) }
                // A sent transaction's secret key exists only in the cache: store it right away.
                try? persist()
                call.resolve(r)
            } catch {
                call.reject(Self.msg(error))
            }
        }
    }

    @objc func closeWallet(_ call: CAPPluginCall) {
        stopRequested = true
        controlQ.async { [self] in stopLive() }
        walletQ.async { [self] in
            closeNow()
            call.resolve(["ok": true])
        }
    }

    /// "Forget this wallet": drop the stored keys and cache.
    @objc func wipe(_ call: CAPPluginCall) {
        Self.wipeFromNative()
        call.resolve(["ok": true])
    }

    /// Deletes the stored wallet and closes the open one WITHOUT saving it. Any thread, any time.
    static func wipeFromNative() {
        NativeAuth.clear()
        WalletStore().wipeFiles()
        guard let p = shared else { return }
        p.stopRequested = true
        p.wiped = true
        p.controlQ.async { p.stopLive() }
        p.walletQ.async {
            p.wiped = true
            p.closeNow()
            p.store.wipeFiles()
        }
    }

    // MARK: - internals (walletQ only unless noted)

    private func walletQuery(_ call: CAPPluginCall, _ f: @escaping (OpaquePointer) throws -> [String: Any]) {
        walletQ.async { [self] in
            do {
                guard let w = wallet else { throw Engine.Failure(message: "No wallet") }
                call.resolve(try f(w))
            } catch {
                call.reject(Self.msg(error))
            }
        }
    }

    private func connect(_ w: OpaquePointer, _ url: String, _ user: String, _ pass: String) throws {
        if url.isEmpty {
            try Engine.check { zios_wallet_set_daemon(w, nil, nil, nil, $0) }
        } else {
            try NodeAllowlist.check(url)
            try Engine.check { zios_wallet_set_daemon(w, url, user, pass, $0) }
        }
    }

    /// controlQ / any thread: interrupts a running sync of the open wallet.
    private func stopLive() {
        liveLock.lock(); defer { liveLock.unlock() }
        if let w = live { zios_wallet_stop_syncing(w) }
    }

    private func openNow(_ cfg: JSObject?, expectAddress: String) throws {
        closeNow()
        wiped = false
        guard let cfg else { throw Engine.Failure(message: "No wallet config") }
        let password = try store.vaultPassword()
        let uri = ((cfg["server"] as? JSObject)?["uri"] as? String) ?? ""
        let mnemonic = ((cfg["mnemonic"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wantSpend = !mnemonic.isEmpty
        let restoreHeight = (cfg["restoreHeight"] as? NSNumber)?.uint64Value
            ?? UInt64(max(0, (cfg["restoreHeight"] as? Int) ?? 0))
        var w: OpaquePointer?

        // 1) Warm start: keys + cache from disk, no re-scan from the birthday.
        if store.hasWallet {
            do {
                let (k, c) = try store.read()
                let h = try Engine.open(password: password, keys: k, cache: c)
                w = h
                let info = try Engine.json { zios_wallet_info(h, $0) }
                let other = !expectAddress.isEmpty && expectAddress != (info["address"] as? String)
                let needsSpend = wantSpend && ((info["viewOnly"] as? Bool) ?? false)
                if other || needsSpend {
                    Engine.close(h)
                    w = nil
                    store.wipeFiles()
                }
            } catch {
                if let h = w { Engine.close(h) }
                w = nil
                store.wipeFiles()
            }
        }

        // 2) Cold start: rebuild from the mnemonic (or the view key) and scan from the birthday.
        if w == nil {
            var c: [String: Any] = ["password": password, "networkType": 0, "restoreHeight": restoreHeight]
            if wantSpend {
                c["mnemonic"] = mnemonic
            } else {
                guard let a = cfg["primaryAddress"] as? String, let v = cfg["privateViewKey"] as? String else {
                    throw Engine.Failure(message: "No wallet keys")
                }
                c["primaryAddress"] = a
                c["privateViewKey"] = v
            }
            w = try Engine.create(config: c)
        }

        guard let h = w else { throw Engine.Failure(message: "No wallet") }
        do {
            try connect(h, uri, "", "")
            var l = zios_listener(ctx: Unmanaged.passUnretained(self).toOpaque(),
                                  on_progress: zwProgress, on_balances: zwBalances, on_output: zwOutput)
            try Engine.check { zios_wallet_set_listener(h, &l, $0) }
        } catch {
            Engine.close(h)
            throw error
        }
        wallet = h
        liveLock.lock(); live = h; liveLock.unlock()
        progressLock.lock(); lastProgressEmit = 0; progressLock.unlock()
    }

    /// Keys + cache as two files, written atomically. Again after every sync and send.
    private func persist() throws {
        guard let w = wallet, !wiped else { return }
        let d = try Engine.data(w, password: try store.vaultPassword())
        try store.write(keys: d.keys, cache: d.cache)
    }

    private func closeNow() {
        guard let w = wallet else { return }
        wallet = nil
        liveLock.lock(); live = nil; liveLock.unlock()
        zios_wallet_stop_syncing(w)
        if !wiped {
            if let pw = try? store.vaultPassword(), let d = try? Engine.data(w, password: pw) {
                try? store.write(keys: d.keys, cache: d.cache)
            }
        }
        _ = zios_wallet_set_listener(w, nil, nil)
        Engine.close(w)
    }

    // MARK: - events (called on the engine's threads: hand off and return)

    fileprivate func onProgress(_ h: UInt64, _ s: UInt64, _ e: UInt64, _ p: Double) {
        // One call per block would flood the bridge; the UI shows about one update per second.
        progressLock.lock()
        let now = Date().timeIntervalSince1970
        if now - lastProgressEmit < 0.5 && h < e { progressLock.unlock(); return }
        lastProgressEmit = now
        progressLock.unlock()
        emit(["type": "progress", "height": h, "startHeight": s, "endHeight": e, "percent": p])
    }

    fileprivate func onBalances(_ b: String, _ u: String, _ a: String) {
        guard Self.v2.contains(a) else { return }
        emit(["type": "balancesChanged", "a1": b, "a2": u, "a3": a])   // atomic units as strings
    }

    fileprivate func onOutput(_ spent: Bool, _ h: Int64, _ txid: String?) {
        var e: [String: Any] = ["type": spent ? "outputSpent" : "outputReceived"]
        if h >= 0 { e["height"] = h }   // absent for a pool transaction
        if let txid { e["txid"] = txid }
        emit(e)
    }

    private func emit(_ e: [String: Any]) {
        eventQ.async { [weak self] in self?.notifyListeners("wallet", data: e) }
    }

    private static func msg(_ e: Error) -> String {
        let m = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
        return m.isEmpty ? String(describing: type(of: e)) : m
    }
}
