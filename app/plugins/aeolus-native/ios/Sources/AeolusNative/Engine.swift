import Foundation
import ZephyrIOS

/// Thin Swift layer over the engine's C interface (zephyr_ios.h).
enum Engine {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    typealias ErrOut = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>

    /// Takes ownership of a string the engine returned (wiped and freed by zios_free).
    static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        let s = String(cString: p)
        zios_free(p)
        return s
    }

    /// Runs an engine call that returns a JSON object string, or throws its error message.
    static func json(_ call: (ErrOut) -> UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        var err: UnsafeMutablePointer<CChar>? = nil
        let r = withUnsafeMutablePointer(to: &err) { call($0) }
        guard let s = take(r) else { throw Failure(message: take(err) ?? "unknown native error") }
        guard let o = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
            throw Failure(message: "bad engine result")
        }
        return o
    }

    /// Runs an engine call that returns a string.
    static func string(_ call: (ErrOut) -> UnsafeMutablePointer<CChar>?) throws -> String {
        var err: UnsafeMutablePointer<CChar>? = nil
        let r = withUnsafeMutablePointer(to: &err) { call($0) }
        guard let s = take(r) else { throw Failure(message: take(err) ?? "unknown native error") }
        return s
    }

    /// Runs an engine call that returns 0 on success.
    static func check(_ call: (ErrOut) -> Int32) throws {
        var err: UnsafeMutablePointer<CChar>? = nil
        let rc = withUnsafeMutablePointer(to: &err) { call($0) }
        if rc != 0 { throw Failure(message: take(err) ?? "unknown native error") }
    }

    /// Runs an engine call that returns a wallet handle.
    static func wallet(_ call: (ErrOut) -> OpaquePointer?) throws -> OpaquePointer {
        var err: UnsafeMutablePointer<CChar>? = nil
        let w = withUnsafeMutablePointer(to: &err) { call($0) }
        guard let w else { throw Failure(message: take(err) ?? "unknown native error") }
        return w
    }

    static func jsonString(_ o: [String: Any]) throws -> String {
        let d = try JSONSerialization.data(withJSONObject: o)
        return String(decoding: d, as: UTF8.self)
    }

    /// Keys and cache data of an open wallet, as the files hold them.
    static func data(_ w: OpaquePointer, password: String) throws -> (keys: Data, cache: Data) {
        var k: UnsafeMutablePointer<UInt8>? = nil, c: UnsafeMutablePointer<UInt8>? = nil
        var kl = 0, cl = 0
        try check { zios_wallet_get_data(w, password, &k, &kl, &c, &cl, $0) }
        defer { zios_free_bytes(k, kl); zios_free_bytes(c, cl) }
        return (Data(bytes: k!, count: kl), Data(bytes: c!, count: cl))
    }

    static func open(password: String, keys: Data, cache: Data) throws -> OpaquePointer {
        try keys.withUnsafeBytes { kb in
            try cache.withUnsafeBytes { cb in
                try wallet {
                    zios_wallet_open_data(password, 0,
                                          kb.bindMemory(to: UInt8.self).baseAddress, kb.count,
                                          cb.bindMemory(to: UInt8.self).baseAddress, cb.count, $0)
                }
            }
        }
    }

    static func create(config: [String: Any]) throws -> OpaquePointer {
        let cfg = try jsonString(config)
        return try wallet { zios_wallet_create(cfg, $0) }
    }

    static func close(_ w: OpaquePointer) {
        _ = zios_wallet_close(w, 0, nil)
    }
}
