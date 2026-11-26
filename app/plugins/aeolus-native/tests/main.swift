import Foundation

// Compiled together with PaymentFilter.swift by CI (swiftc, no engine needed):
//   swiftc -o pftest ios/Sources/AeolusNative/PaymentFilter.swift tests/main.swift && ./pftest

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what)"); failures += 1 }
}

func tx(_ hash: String, height: Int? = nil, inPool: Bool = false, failed: Bool = false,
        incoming: Bool = true, outgoing: Bool = false) -> [String: Any] {
    var t: [String: Any] = ["hash": hash, "inPool": inPool, "failed": failed, "confirmed": height != nil && !inPool]
    if let h = height { t["height"] = NSNumber(value: h) } else { t["height"] = NSNull() }
    if incoming { t["in"] = [["asset": "ZPH", "amount": "1000000000000"]] }
    if outgoing { t["out"] = ["asset": "ZPH", "amount": "1000000000000"] }
    return t
}

let none = Set<String>()

// 1. a payment in the pool notifies, whatever the pinned height
check(PaymentFilter.newPayments(txs: [tx("aa", inPool: true)], seen: [], own: none, notifyFrom: 500) == ["aa"], "pool payment notifies")
check(PaymentFilter.newPayments(txs: [tx("aa")], seen: [], own: none, notifyFrom: Int64.max) == ["aa"], "unconfirmed notifies even when the start height is not pinned yet")

// 2. confirmed: only from the start height on
check(PaymentFilter.newPayments(txs: [tx("aa", height: 499)], seen: [], own: none, notifyFrom: 500).isEmpty, "confirmed below the start height is old news")
check(PaymentFilter.newPayments(txs: [tx("aa", height: 500)], seen: [], own: none, notifyFrom: 500) == ["aa"], "confirmed at the start height notifies")
check(PaymentFilter.newPayments(txs: [tx("aa", height: 900)], seen: [], own: none, notifyFrom: Int64.max).isEmpty, "confirmed is never announced while the start height is unpinned")

// 3. own sends and swaps
check(PaymentFilter.newPayments(txs: [tx("aa", height: 900, outgoing: true)], seen: [], own: none, notifyFrom: 500).isEmpty, "a tx with an outgoing part is ours")
check(PaymentFilter.newPayments(txs: [tx("AA", height: 900)], seen: [], own: ["aa"], notifyFrom: 500).isEmpty, "a recorded own send (change) is ignored, case-insensitively")

// 4. failed, empty and malformed
check(PaymentFilter.newPayments(txs: [tx("aa", inPool: true, failed: true)], seen: [], own: none, notifyFrom: 0).isEmpty, "failed tx is ignored")
check(PaymentFilter.newPayments(txs: [tx("aa", inPool: true, incoming: false)], seen: [], own: none, notifyFrom: 0).isEmpty, "no incoming part, no alert")
check(PaymentFilter.newPayments(txs: [["height": NSNumber(value: 900), "in": [1]]], seen: [], own: none, notifyFrom: 0).isEmpty, "no hash, no alert")
check(PaymentFilter.newPayments(txs: [tx("", inPool: true)], seen: [], own: none, notifyFrom: 0).isEmpty, "empty hash, no alert")

// 5. seen
check(PaymentFilter.newPayments(txs: [tx("aa", inPool: true)], seen: ["AA"], own: none, notifyFrom: 0).isEmpty, "announced before: not again")
let twice = PaymentFilter.newPayments(txs: [tx("aa", inPool: true), tx("aa", height: 900)], seen: [], own: none, notifyFrom: 0)
check(twice == ["aa"], "the same hash twice in one history counts once")

// 6. several, in history order
let many = PaymentFilter.newPayments(txs: [tx("c1", height: 700), tx("c2", inPool: true), tx("c3", height: 900)],
                                     seen: [], own: none, notifyFrom: 800)
check(many == ["c2", "c3"], "several payments: only the new ones, in order")

// 7. remembering
var seen: [String] = []
for i in 0..<350 { seen = PaymentFilter.remember(["h\(i)"], in: seen) }
check(seen.count == PaymentFilter.seenLimit && seen.last == "h349" && seen.first == "h50", "seen list keeps the newest 300")
check(PaymentFilter.remember(["H349"], in: seen) == seen, "remember does not add a hash twice")
var own: [String] = []
for i in 0..<600 { own = PaymentFilter.rememberOwn(["o\(i)"], in: own) }
check(own.count == PaymentFilter.ownLimit && own.last == "o599", "own list keeps the newest 500")
check(PaymentFilter.rememberOwn(["", "x"], in: []) == ["x"], "empty own hash is skipped")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
