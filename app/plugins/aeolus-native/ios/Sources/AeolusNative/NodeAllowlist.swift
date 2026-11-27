import Foundation

/// The only hosts the native layer talks to: the built-in nodes (index.html BUILTIN_NODES).
/// Keep in sync with BUILTIN_NODES and with the Android plugin's NODE_HOSTS.
enum NodeAllowlist {
    static let hosts: Set<String> = [
        "node.lateo.dev", "remote-node.zephyrprotocol.com", "nodes.hashvault.pro"
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

/// Node HTTP never follows a redirect: a node could otherwise send the request on to a host that
/// is not on the list (ATS only stops redirects to plain http).
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum EngineTLS {
    /// The core's OpenSSL verifies https nodes against the shipped Mozilla roots (as zephyr-java does
    /// on Android); iOS has no OpenSSL CA directory of its own. Needed before ANY engine connection,
    /// including a background wake-up that launches the app without loading the web view's plugins.
    static func configure() {
        if getenv("SSL_CERT_FILE") == nil, let pem = Bundle.module.path(forResource: "cacert", ofType: "pem") {
            setenv("SSL_CERT_FILE", pem, 1)
        }
    }
}
