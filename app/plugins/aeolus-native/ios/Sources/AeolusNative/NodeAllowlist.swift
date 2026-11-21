import Foundation

/// The only hosts the native layer talks to: the built-in nodes (index.html BUILTIN_NODES).
/// Keep in sync with BUILTIN_NODES and with the Android plugin's NODE_HOSTS.
enum NodeAllowlist {
    static let hosts: Set<String> = [
        "node.zeph.network", "remote-node.zephyrprotocol.com", "nodes.hashvault.pro", "node.lateo.dev"
    ]

    /// Returns the URL if it is http(s) to an allowed node host without user info, else throws.
    @discardableResult
    static func check(_ url: String) throws -> URL {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              u.user == nil, u.password == nil,
              let host = u.host?.lowercased() else {
            throw Engine.Failure(message: "bad url")
        }
        guard hosts.contains(host) else { throw Engine.Failure(message: "node not allowed: \(host)") }
        return u
    }
}
