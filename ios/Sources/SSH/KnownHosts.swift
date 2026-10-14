import Foundation

/// Trust-on-first-use storage for server host keys. Keys are stored in
/// OpenSSH public key format.
///
/// A saved host's key is pinned to the host (`host:<id>`), not to an
/// address, so every route to it (local network, tailnet) must present
/// that same key. Earlier versions keyed by `hostname:port`; such an entry
/// moves to the host the first time it's checked.
final class KnownHosts: @unchecked Sendable {
    enum Verdict: Equatable {
        /// The key matches the one previously trusted for this host.
        case trusted

        /// No key is stored for this host yet.
        case unknown(fingerprint: String)

        /// A different key was trusted before. This may mean the server
        /// was reinstalled or that the connection is being intercepted.
        case mismatch(expected: String, presented: String)
    }

    static let shared = KnownHosts()

    private let url: URL
    private let lock = NSLock()
    private var entries: [String: String]

    init(url: URL = KnownHosts.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("known_hosts.json")
    }

    /// The entry for a saved host, whichever route it's reached by.
    static func entry(for host: Host) -> String { "host:\(host.id.uuidString)" }

    func check(host: Host, key: String) -> Verdict {
        migrate(host)
        return check(endpoint: Self.entry(for: host), key: key)
    }

    func trust(host: Host, key: String) {
        trust(endpoint: Self.entry(for: host), key: key)
    }

    /// Forget a host's key, including any entry from before keys were
    /// pinned per host.
    func forget(host: Host) {
        lock.withLock {
            _ = entries.removeValue(forKey: Self.entry(for: host))
            _ = entries.removeValue(forKey: host.endpoint)
        }
        save()
    }

    func fingerprint(host: Host) -> String? {
        migrate(host)
        return fingerprint(endpoint: Self.entry(for: host))
    }

    /// Move a key stored under the host's entered address (by earlier
    /// versions) to the host itself.
    private func migrate(_ host: Host) {
        let moved: Bool = lock.withLock {
            let entry = Self.entry(for: host)
            guard entries[entry] == nil, let legacy = entries.removeValue(forKey: host.endpoint)
            else { return false }
            entries[entry] = legacy
            return true
        }
        if moved { save() }
    }

    func check(endpoint: String, key: String) -> Verdict {
        let presented = OpenSSH.fingerprint(openSSHPublicKey: key) ?? key
        let stored: String? = lock.withLock { entries[endpoint] }
        guard let stored else { return .unknown(fingerprint: presented) }
        if Self.normalized(stored) == Self.normalized(key) { return .trusted }
        return .mismatch(
            expected: OpenSSH.fingerprint(openSSHPublicKey: stored) ?? stored,
            presented: presented)
    }

    func trust(endpoint: String, key: String) {
        lock.withLock { entries[endpoint] = Self.normalized(key) }
        save()
    }

    func forget(endpoint: String) {
        lock.withLock { _ = entries.removeValue(forKey: endpoint) }
        save()
    }

    func fingerprint(endpoint: String) -> String? {
        let stored: String? = lock.withLock { entries[endpoint] }
        return stored.flatMap { OpenSSH.fingerprint(openSSHPublicKey: $0) }
    }

    /// Compare only `<type> <base64>`, ignoring any comment.
    private static func normalized(_ key: String) -> String {
        key.split(separator: " ").prefix(2).joined(separator: " ")
    }

    private func save() {
        let snapshot = lock.withLock { entries }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            print("failed to save known hosts: \(error)")
        }
    }
}
