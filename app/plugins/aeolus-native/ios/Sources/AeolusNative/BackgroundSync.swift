import Foundation
import UIKit
import BackgroundTasks
import UserNotifications
import Security
import ZephyrIOS

// Background payment alerts on iOS.
//
// Android keeps a foreground service running and syncs the real wallet with the screen off. iOS has
// no such service: an app can only be woken now and then (BGAppRefreshTask, about 30 s; BGProcessingTask,
// a few minutes, usually while charging), when iOS decides, and never after the user swipes it away.
// iOS also keeps the wallet files and the vault password locked while the phone is locked, on purpose.
//
// So the real wallet is left exactly as it was (complete file protection, Keychain "when unlocked").
// Background sync uses a separate VIEW-ONLY watch wallet made from the address and private view key:
//  - it can see incoming payments, it cannot spend anything and holds no seed or spend key;
//  - it starts at the chain tip when Background Sync is switched on, so it never scans old blocks;
//  - its files use "until first unlock" protection and its password lives in the Keychain "after first
//    unlock", so it can run while the phone is locked (after the first unlock since a restart);
//  - a payment shows as a plain "Payment received" notification: no amount, no address, ever.
// Turning Background Sync off, or deleting the wallet, deletes the watch wallet and its Keychain item.

// MARK: - settings (not secret: flags, a node URL, block heights and transaction ids)

enum BgState {
    private static let d = UserDefaults.standard
    private static let kEnabled = "aeolus.bg.enabled"
    private static let kAlerts = "aeolus.bg.alerts"
    private static let kFrom = "aeolus.bg.notifyFrom"
    private static let kNode = "aeolus.bg.node"
    private static let kSeen = "aeolus.bg.seen"
    private static let kOwn = "aeolus.bg.own"
    private static let kEngine = "aeolus.bg.engineOK"

    /// Background Sync switch.
    static var enabled: Bool {
        get { d.bool(forKey: kEnabled) }
        set { d.set(newValue, forKey: kEnabled) }
    }
    /// Payment Alerts switch (on by default). Without alerts the watcher has nothing to do.
    static var alerts: Bool {
        get { (d.object(forKey: kAlerts) as? Bool) ?? true }
        set { d.set(newValue, forKey: kAlerts) }
    }
    /// Confirmed payments below this height are never announced. Int64.max = not pinned yet: only
    /// unconfirmed payments notify until the next run learns the node's height.
    static var notifyFrom: Int64 {
        get { (d.object(forKey: kFrom) as? NSNumber)?.int64Value ?? Int64.max }
        set { d.set(NSNumber(value: newValue), forKey: kFrom) }
    }
    /// The node the app last connected to (always an allowlisted built-in node).
    static var node: String? {
        get { d.string(forKey: kNode) }
        set { d.set(newValue, forKey: kNode) }
    }
    /// Transactions already announced (last 300).
    static var seen: [String] {
        get { d.stringArray(forKey: kSeen) ?? [] }
        set { d.set(newValue, forKey: kSeen) }
    }
    /// This app's own sends and swaps (last 500): their change comes back as an incoming output.
    static var own: [String] {
        get { d.stringArray(forKey: kOwn) ?? [] }
        set { d.set(newValue, forKey: kOwn) }
    }
    /// The engine build whose slow-hash self-test passed in the app. A background run needs it to match.
    static var engineOK: String? {
        get { d.string(forKey: kEngine) }
        set { d.set(newValue, forKey: kEngine) }
    }

    /// Forget everything but the engine marker.
    static func clear() {
        for k in [kEnabled, kAlerts, kFrom, kNode, kSeen, kOwn] { d.removeObject(forKey: k) }
    }
}

// MARK: - the watch wallet's files

/// The view-only watch wallet: keys.bin / cache.bin (encrypted by the core with a random password) in
/// Application Support/watch, excluded from backups. File protection "until first user authentication"
/// and a Keychain item "after first unlock, this device only": readable while the phone is locked.
final class WatchStore {
    static let keychain = Keychain(service: "com.aeolus.wallet.watch",
                                   accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    private static let lock = NSLock()

    let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("watch", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: d, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? d.setResourceValues(rv)
        return d
    }()

    var keysFile: URL { dir.appendingPathComponent("keys.bin") }
    var cacheFile: URL { dir.appendingPathComponent("cache.bin") }

    /// The password of the watch wallet's files. `create` makes one if there is none (foreground only:
    /// when the phone is unlocked the Keychain always answers, so a missing item really is missing).
    func password(create: Bool) -> String? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let pw = Self.keychain.getString("watch_password"), !pw.isEmpty { return pw }
        guard create else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let pw = Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return Self.keychain.set("watch_password", string: pw) ? pw : nil
    }

    var hasWallet: Bool {
        FileManager.default.fileExists(atPath: keysFile.path) && FileManager.default.fileExists(atPath: cacheFile.path)
    }

    func read() throws -> (keys: Data, cache: Data) {
        (try Data(contentsOf: keysFile), try Data(contentsOf: cacheFile))
    }

    /// Cache first, then keys, each written atomically.
    func write(keys: Data, cache: Data) throws {
        try cache.write(to: cacheFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try keys.write(to: keysFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func wipeFiles() {
        try? FileManager.default.removeItem(at: keysFile)
        try? FileManager.default.removeItem(at: cacheFile)
    }

    /// Files and the Keychain item.
    func wipe() {
        wipeFiles()
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.keychain.clear()
    }
}

// MARK: - helpers

/// Lets the expiry handler and the worker end a sync: stop_syncing is the one engine call that may
/// run on another thread during a sync, and it must never touch a wallet that was already closed.
final class SyncStopper: @unchecked Sendable {
    private let lock = NSLock()
    private var wallet: OpaquePointer?
    private var stopped = false

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// false when stop() already ran: the caller must not start.
    func attach(_ w: OpaquePointer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stopped { return false }
        wallet = w
        return true
    }

    func detach() { lock.lock(); wallet = nil; lock.unlock() }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if let w = wallet { zios_wallet_stop_syncing(w) }
    }
}

/// Runs a closure at most once (a BGTask must be completed exactly one time).
final class RunOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        f()
    }
}

private final class HeightBox: @unchecked Sendable {
    var value: UInt64?
}

// MARK: - the watcher

public enum AeolusBackground {
    static let refreshID = "com.aeolus.wallet.refresh"
    static let processingID = "com.aeolus.wallet.processing"
    /// Seconds of syncing allowed per wake-up. iOS gives an app-refresh task about 30 s.
    static let refreshBudget: TimeInterval = 20
    static let processingBudget: TimeInterval = 150
    static let defaultNode = "https://node.lateo.dev:443"

    /// What the watch wallet is made from: the open wallet's address and private view key.
    struct Source {
        let address: String
        let viewKey: String
    }

    private static let gate = NSLock()
    private static var epoch = 0
    private static var running = false

    private static var engineVersion: String { String(cString: zios_version()) }

    // MARK: epoch: a switch-off or wipe makes every run that started earlier stand down

    private static func currentEpoch() -> Int { gate.lock(); defer { gate.unlock() }; return epoch }
    private static func bump() { gate.lock(); epoch += 1; gate.unlock() }

    /// Runs body only if nothing was turned off or wiped since epoch e; false when it did not run.
    @discardableResult
    private static func ifCurrent(_ e: Int, _ body: () -> Void) -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard epoch == e else { return false }
        body()
        return true
    }

    // MARK: setup, called from the app's AppDelegate and from the wallet plugin

    /// Must run before the app finishes launching (iOS refuses late registration).
    public static func register() {
        let s = BGTaskScheduler.shared
        _ = s.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            handle(task, budget: refreshBudget)
        }
        _ = s.register(forTaskWithIdentifier: processingID, using: nil) { task in
            handle(task, budget: processingBudget)
        }
        // iOS only runs tasks that were requested while the app was alive: ask again on leaving.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { _ in scheduleIfEnabled() }
    }

    /// Asks iOS for the next wake-ups (or cancels them when the watcher has nothing to do).
    static func scheduleIfEnabled() {
        let s = BGTaskScheduler.shared
        s.cancel(taskRequestWithIdentifier: refreshID)
        s.cancel(taskRequestWithIdentifier: processingID)
        guard BgState.enabled, BgState.alerts else { return }
        let r = BGAppRefreshTaskRequest(identifier: refreshID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? s.submit(r)
        let p = BGProcessingTaskRequest(identifier: processingID)
        p.requiresNetworkConnectivity = true
        p.requiresExternalPower = false
        p.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? s.submit(p)
    }

    private static func cancelTasks() {
        let s = BGTaskScheduler.shared
        s.cancel(taskRequestWithIdentifier: refreshID)
        s.cancel(taskRequestWithIdentifier: processingID)
    }

    /// The foreground self-test passed for this engine build (a background run needs that).
    static func markEngineVerified() { BgState.engineOK = engineVersion }

    /// Remember the node the app is connected to; background runs use the same one.
    static func rememberNode(_ url: String) { if !url.isEmpty { BgState.node = url } }

    // MARK: plugin calls (the plugin's wallet queue)

    /// startBackgroundSync. fromNow = the user just switched it on: needs the open wallet and Background
    /// App Refresh, and starts a fresh watch wallet at the chain tip. Without it (every unlock): only make
    /// sure the wake-ups are requested and a missing watch wallet is rebuilt.
    static func start(fromNow: Bool, source: Source?, refresh: UIBackgroundRefreshStatus) throws -> [String: Any] {
        if fromNow {
            guard let src = source else { throw Engine.Failure(message: "Open your wallet first") }
            guard refresh == .available else {
                throw Engine.Failure(message: "Turn on Background App Refresh for Aeolus (Settings → General → Background App Refresh) and turn off Low Power Mode, then try again")
            }
            try createWatchWallet(source: src)
            BgState.enabled = true
            if BgState.alerts { requestNotificationPermission() }
        } else if BgState.enabled, let src = source, !WatchStore().hasWallet {
            _ = try? createWatchWallet(source: src)
        }
        scheduleIfEnabled()
        return ["ok": true, "active": BgState.enabled && BgState.alerts]
    }

    /// Payment Alerts switch. Turning alerts back on starts a fresh watch wallet: only payments from now on.
    static func setAlerts(_ on: Bool, source: Source?) {
        let was = BgState.alerts
        BgState.alerts = on
        if on && !was && BgState.enabled {
            if let src = source { _ = try? createWatchWallet(source: src) } else { BgState.notifyFrom = Int64.max }
            requestNotificationPermission()
        }
        scheduleIfEnabled()
    }

    /// The wallet was opened: rebuild a missing watch wallet (after a failed run, say).
    static func walletOpened(_ source: Source) {
        guard BgState.enabled, !WatchStore().hasWallet else { return }
        _ = try? createWatchWallet(source: source)
    }

    /// The page relayed a send or swap: its change is not a payment.
    static func recordOwn(_ hashes: [String]) {
        guard BgState.enabled, !hashes.isEmpty else { return }
        BgState.own = PaymentFilter.rememberOwn(hashes, in: BgState.own)
    }

    /// Background Sync switched off.
    static func stop() {
        bump()
        BgState.enabled = false
        cancelTasks()
        WatchStore().wipe()
        BgState.seen = []
        BgState.own = []
    }

    /// Wallet deleted: everything of the watcher goes.
    static func wipeAll() {
        stop()
        BgState.clear()
    }

    /// Builds the view-only watch wallet at the current chain tip and stores it. Needs the node, because
    /// a wrong (old) start height would announce payments you already know about.
    static func createWatchWallet(source: Source) throws {
        let node = BgState.node ?? defaultNode
        guard let tip = nodeHeight(node), tip > 0 else {
            throw Engine.Failure(message: "Could not reach the node. Try again in a moment.")
        }
        let store = WatchStore()
        guard let pw = store.password(create: true) else {
            throw Engine.Failure(message: "Could not create the background key")
        }
        let cfg: [String: Any] = ["password": pw, "networkType": 0, "restoreHeight": tip,
                                  "primaryAddress": source.address, "privateViewKey": source.viewKey]
        let w = try Engine.create(config: cfg)
        defer { Engine.close(w) }
        let d = try Engine.data(w, password: pw)
        bump()   // a run that started before this must not write its old cache over the new files
        try store.write(keys: d.keys, cache: d.cache)
        BgState.notifyFrom = Int64(clamping: tip)
        BgState.seen = []
    }

    // MARK: notifications

    static func requestNotificationPermission() {
        let c = UNUserNotificationCenter.current()
        c.getNotificationSettings { s in
            if s.authorizationStatus == .notDetermined {
                c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    /// Same text as on Android: no amount, no address, locked or unlocked.
    private static func notify(count: Int, ids: [String]) {
        let center = UNUserNotificationCenter.current()
        let group = DispatchGroup()
        func post(_ id: String, _ body: String) {
            let c = UNMutableNotificationContent()
            c.title = "Aeolus"
            c.body = body
            c.sound = .default
            c.threadIdentifier = "aeolus.payments"
            c.interruptionLevel = .active
            group.enter()
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { _ in group.leave() }
        }
        if count <= 3 {
            for h in ids { post("aeolus.pay." + String(h.prefix(16)), "Payment received") }
        } else {
            post("aeolus.pay.batch." + String(Int(Date().timeIntervalSince1970)), "\(count) payments received")
        }
        _ = group.wait(timeout: .now() + 5)
    }

    // MARK: a wake-up

    private static func handle(_ task: BGTask, budget: TimeInterval) {
        scheduleIfEnabled()   // keep the chain going whatever happens below
        let stopper = SyncStopper()
        let once = RunOnce()
        task.expirationHandler = {
            stopper.stop()
            once.run { task.setTaskCompleted(success: false) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + budget) { stopper.stop() }
        DispatchQueue.global(qos: .utility).async {
            let ok = syncOnce(stopper: stopper)
            once.run { task.setTaskCompleted(success: ok) }
        }
    }

    /// One background run: open the watch wallet, sync from its own height, announce new payments, save.
    /// true = nothing to complain about (including "nothing to do"), false = could not reach a node.
    private static func syncOnce(stopper: SyncStopper) -> Bool {
        gate.lock()
        if running { gate.unlock(); return true }
        running = true
        let e = epoch
        gate.unlock()
        defer { gate.lock(); running = false; gate.unlock() }

        guard BgState.enabled, BgState.alerts else { return true }
        guard BgState.engineOK == engineVersion else { return true }   // the foreground self-test has not passed for this build
        let store = WatchStore()
        guard store.hasWallet, let pw = store.password(create: false) else { return true }   // locked since restart: try later

        let h: OpaquePointer
        do {
            let (k, c) = try store.read()
            h = try Engine.open(password: pw, keys: k, cache: c)
        } catch {
            // Damaged files: drop them, the next unlock rebuilds the watch wallet.
            ifCurrent(e) { store.wipeFiles() }
            return false
        }
        guard stopper.attach(h) else { Engine.close(h); return true }
        defer { stopper.detach(); Engine.close(h) }

        // Sync from the wallet's own height, on the node the app uses.
        let node = BgState.node ?? defaultNode
        var daemonHeight: Int64?
        if !stopper.isStopped {
            do {
                try NodeAllowlist.check(node)   // same host rule as the foreground wallet
                try Engine.check { zios_wallet_set_daemon(h, node, "", "", $0) }
                let r = try Engine.json { zios_wallet_sync(h, $0) }
                if let d = (r["daemonHeight"] as? NSNumber)?.int64Value, d > 0 { daemonHeight = d }
            } catch {
                // a sync ended by the time limit, or no node: what was fetched so far is still kept below
            }
        }
        if let d = daemonHeight, BgState.notifyFrom == Int64.max { BgState.notifyFrom = d }

        // New payments.
        var fresh: [String] = []
        if let hist = try? Engine.json({ zios_wallet_tx_history(h, $0) }), let txs = hist["txs"] as? [[String: Any]] {
            fresh = PaymentFilter.newPayments(txs: txs, seen: BgState.seen, own: Set(BgState.own),
                                              notifyFrom: BgState.notifyFrom)
        }

        // Save the watch wallet (unless it was switched off or replaced meanwhile).
        if let d = try? Engine.data(h, password: pw) {
            ifCurrent(e) { _ = try? store.write(keys: d.keys, cache: d.cache) }
        }

        if !fresh.isEmpty {
            var announce = false
            ifCurrent(e) {
                if BgState.alerts {
                    BgState.seen = PaymentFilter.remember(fresh, in: BgState.seen)
                    announce = true
                }
            }
            if announce { notify(count: fresh.count, ids: fresh) }
        }
        return daemonHeight != nil
    }

    // MARK: node height

    /// Chain height from the node (get_block_count), nil when it does not answer in time.
    static func nodeHeight(_ node: String) -> UInt64? {
        guard let base = try? NodeAllowlist.check(node) else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("json_rpc"), timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"jsonrpc":"2.0","id":"0","method":"get_block_count"}"#.utf8)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        let session = URLSession(configuration: cfg)
        let box = HeightBox()
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, _, _ in
            if let data,
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let r = o["result"] as? [String: Any],
               let n = r["count"] as? NSNumber {
                box.value = n.uint64Value
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        session.invalidateAndCancel()
        return box.value
    }
}
