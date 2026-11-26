import Foundation

/// Which transactions deserve a "Payment received" notification: the iOS counterpart of the Android
/// plugin's newPayments(txs, seen, notifyFrom). Foundation only, so CI can test it without the engine.
///
/// A payment notifies once, and only when it is
///  - purely incoming (no "out" part: a spend from this wallet is never an alert),
///  - not failed,
///  - not one of this app's own sends or swaps (their change comes back as an incoming output),
///  - not notified before, and
///  - new: unconfirmed / in the pool, or confirmed at a height >= notifyFrom (the block height when
///    alerts were turned on), so turning alerts on never announces old payments.
enum PaymentFilter {
    static let seenLimit = 300
    static let ownLimit = 500

    /// txs: the "txs" array of the engine's tx history (hash, height|null, inPool, failed, in:[...], out?).
    /// Returns the hashes to notify about, in history order, without repeats.
    static func newPayments(txs: [[String: Any]], seen: [String], own: Set<String>, notifyFrom: Int64) -> [String] {
        let seenSet = Set(seen.map { $0.lowercased() })
        let ownSet = Set(own.map { $0.lowercased() })
        var out: [String] = []
        var done = Set<String>()
        for t in txs {
            guard let raw = t["hash"] as? String, !raw.isEmpty else { continue }
            let hash = raw.lowercased()
            if done.contains(hash) || seenSet.contains(hash) || ownSet.contains(hash) { continue }
            if let failed = t["failed"] as? Bool, failed { continue }
            // An outgoing part under the same hash: our own tx (send, swap, change, send to self).
            if let o = t["out"], !(o is NSNull) { continue }
            guard let ins = t["in"] as? [Any], !ins.isEmpty else { continue }
            let inPool = (t["inPool"] as? Bool) ?? false
            let height = heightOf(t["height"])
            let confirmed = height != nil && !inPool
            if confirmed, let h = height, h < notifyFrom { continue }
            done.insert(hash)
            out.append(raw)
        }
        return out
    }

    /// seen + new hashes, newest last, at most seenLimit kept.
    static func remember(_ hashes: [String], in seen: [String]) -> [String] {
        var all = seen
        let have = Set(seen.map { $0.lowercased() })
        for h in hashes where !have.contains(h.lowercased()) { all.append(h) }
        return all.count > seenLimit ? Array(all.suffix(seenLimit)) : all
    }

    /// own + new hashes, newest last, at most ownLimit kept.
    static func rememberOwn(_ hashes: [String], in own: [String]) -> [String] {
        var all = own
        let have = Set(own.map { $0.lowercased() })
        for h in hashes where !h.isEmpty && !have.contains(h.lowercased()) { all.append(h) }
        return all.count > ownLimit ? Array(all.suffix(ownLimit)) : all
    }

    /// height of a JSON value: a number, or nil for null / missing / negative.
    private static func heightOf(_ v: Any?) -> Int64? {
        guard let v, !(v is NSNull) else { return nil }
        if let n = v as? NSNumber { let h = n.int64Value; return h >= 0 ? h : nil }
        return nil
    }
}
