import Foundation

/// Trust-on-first-use storage for server host keys, keyed by
/// `host:port`. Keys are stored in OpenSSH public key format.
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
