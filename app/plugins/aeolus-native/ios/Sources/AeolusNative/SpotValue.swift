import Foundation

/// USD per coin of ZPH, ZSD, ZRS and ZYS from the oracle pricing record of the node's latest block
/// (the iOS counterpart of SpotValue.java: rates are atomic units, 1e12 per coin).
enum SpotValue {
    private static let unit = Decimal(sign: .plus, exponent: 12, significand: 1)

    static func prices(node: String, session: URLSession) async throws -> [String: Double] {
        let base = try NodeAllowlist.check(node)
        var req = URLRequest(url: base.appendingPathComponent("json_rpc"), timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"jsonrpc":"2.0","id":"0","method":"get_last_block_header"}"#.utf8)
        let (data, _) = try await session.data(for: req)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = o["result"] as? [String: Any],
              let h = r["block_header"] as? [String: Any],
              let pr = h["pricing_record"] as? [String: Any] else {
            throw Engine.Failure(message: "The block header has no pricing record")
        }
        func rate(_ k: String) throws -> Decimal {
            guard let n = pr[k] as? NSNumber else { throw Engine.Failure(message: "The pricing record has no \(k)") }
            let d = (n as? NSDecimalNumber)?.decimalValue ?? Decimal(string: n.stringValue) ?? 0
            return d / unit
        }
        let spot = try rate("spot"), stable = try rate("stable"), reserve = try rate("reserve"),
            yield = try rate("yield_price")
        func usd(_ zph: Decimal) -> Double { NSDecimalNumber(decimal: zph * spot).doubleValue }
        return ["ZPH": usd(1), "ZSD": usd(stable), "ZRS": usd(reserve), "ZYS": usd(yield * stable)]
    }
}
