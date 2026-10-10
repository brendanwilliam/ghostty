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

    /// Apply the host's own Ghostty config (fetched on each connect)
    /// beneath the app's settings.
    var usesRemoteConfig = true

    /// Columns to fit across the screen for this host. Nil uses the
    /// app-wide default from Settings.
    var columns: Int?

    var displayName: String { name.isEmpty ? hostname : name }

    /// Key used for known-hosts and Keychain entries.
    var endpoint: String { "\(hostname.lowercased()):\(port)" }

    var passwordAccount: String { "password-\(id.uuidString)" }
}

extension Host {
    // Decoded by hand so hosts saved by older versions (without the
    // newer fields) still load.
    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, term, savesPassword, usesRemoteConfig, columns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decode(String.self, forKey: .username)
        term = try c.decodeIfPresent(String.self, forKey: .term) ?? "xterm-256color"
        savesPassword = try c.decodeIfPresent(Bool.self, forKey: .savesPassword) ?? false
        usesRemoteConfig = try c.decodeIfPresent(Bool.self, forKey: .usesRemoteConfig) ?? true
        columns = try c.decodeIfPresent(Int.self, forKey: .columns)
    }
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
        RemoteConfigCache(hostID: host.id).clear()
        save()
    }

    /// Remember the column count a pinch settled on for a host.
    func setColumns(_ columns: Int?, for hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }),
              hosts[index].columns != columns else { return }
        hosts[index].columns = columns
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
