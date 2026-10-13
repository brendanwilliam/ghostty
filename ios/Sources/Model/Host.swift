import Foundation

/// A saved SSH destination.
struct Host: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var hostname: String
    var port: Int = 22
    var username: String

    /// The TERM value sent with the PTY request. `xterm-ghostty` needs
    /// Ghostty's terminfo installed on the server; `xterm-256color` works
    /// everywhere.
    var term: String = "xterm-256color"

    /// Whether a password for this host is saved in the Keychain.
    var savesPassword = false

    var displayName: String { name.isEmpty ? hostname : name }

    /// Key used for known-hosts and Keychain entries.
    var endpoint: String { "\(hostname.lowercased()):\(port)" }

    var passwordAccount: String { "password-\(id.uuidString)" }
}

/// Persists saved hosts as JSON in Application Support.
@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [Host] = []

    private let url: URL

    init(url: URL = HostStore.defaultURL) {
        self.url = url
        load()
    }

    nonisolated static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("hosts.json")
    }

    func upsert(_ host: Host) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        save()
    }

    func delete(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        try? Keychain.delete(host.passwordAccount)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        hosts = (try? JSONDecoder().decode([Host].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(hosts).write(to: url, options: .atomic)
        } catch {
            print("failed to save hosts: \(error)")
        }
    }
}
