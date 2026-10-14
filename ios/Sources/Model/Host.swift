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

    /// Run shells inside zmx on the host (when it's installed) so they
    /// keep running while the app is closed.
    var keepsSessions = true

    /// Other addresses for the same machine, learned from it once
    /// connected: its tailnet address and its `.local` name.
    var learnedRoutes: [HostRoute] = []

    var displayName: String { name.isEmpty ? hostname : name }

    /// The address as entered (`hostname:port`).
    var endpoint: String { "\(hostname.lowercased()):\(port)" }

    var passwordAccount: String { "password-\(id.uuidString)" }

    /// The address as entered.
    var primaryRoute: HostRoute { HostRoute(address: hostname, port: port) }

    /// Every way to reach the host, best first: tailnet addresses (which
    /// keep working as the phone changes networks), then the local
    /// network, then anything else. Ties keep the entered address first.
    var routes: [HostRoute] {
        var seen = Set<String>()
        let all = ([primaryRoute] + learnedRoutes).filter { seen.insert($0.key).inserted }
        return all.enumerated()
            .sorted { ($0.element.kind.rank, $0.offset) < ($1.element.kind.rank, $1.offset) }
            .map(\.element)
    }

    /// Adds routes the host reported about itself. Returns whether any
    /// were new.
    @discardableResult
    mutating func learn(_ found: [HostRoute]) -> Bool {
        let known = Set(routes.map(\.key))
        let new = found.filter { !known.contains($0.key) && !$0.address.isEmpty }
        // A route of a kind replaces an older learned one of that kind
        // (the tailnet address can change if the Mac rejoins).
        let kinds = Set(new.map(\.kind))
        guard !new.isEmpty else { return false }
        learnedRoutes.removeAll { kinds.contains($0.kind) }
        learnedRoutes.append(contentsOf: new)
        return true
    }
}

/// One address a host can be reached at.
struct HostRoute: Codable, Hashable {
    enum Kind: String, Codable {
        /// A tailnet (Tailscale/Headscale) address: stays the same as the
        /// phone moves between networks.
        case tailnet
        /// Only reachable on the same local network.
        case lan
        /// Anything else, e.g. a public name.
        case other

        var label: String {
            switch self {
            case .tailnet: "Tailnet"
            case .lan: "Local network"
            case .other: "Address"
            }
        }

        var rank: Int {
            switch self {
            case .tailnet: 0
            case .lan: 1
            case .other: 2
            }
        }
    }

    var address: String
    var port: Int = 22
    var kind: Kind

    init(address: String, port: Int = 22, kind: Kind? = nil) {
        self.address = address
        self.port = port
        self.kind = kind ?? Self.kind(of: address)
    }

    /// Identifies the route for de-duplication.
    var key: String { "\(address.lowercased()):\(port)" }

    /// Guess a route's kind from its address.
    static func kind(of address: String) -> Kind {
        let a = address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if let v4 = ipv4(a) {
            if v4[0] == 100 && (64...127).contains(v4[1]) { return .tailnet }
            if v4[0] == 10 || (v4[0] == 172 && (16...31).contains(v4[1]))
                || (v4[0] == 192 && v4[1] == 168) || (v4[0] == 169 && v4[1] == 254) {
                return .lan
            }
            return .other
        }
        if a.contains(":") {
            if a.hasPrefix("fd7a:115c:a1e0:") { return .tailnet }
            if a.hasPrefix("fe80:") || a.hasPrefix("fc") || a.hasPrefix("fd") { return .lan }
            return .other
        }
        if a.hasSuffix(".ts.net") { return .tailnet }
        if a.hasSuffix(".local") { return .lan }
        return .other
    }

    private static func ipv4(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }.filter { (0...255).contains($0) }
        return octets.count == 4 ? octets : nil
    }
}

extension Host {
    // Decoded by hand so hosts saved by older versions (without the
    // newer fields) still load.
    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, term, savesPassword, usesRemoteConfig, columns
        case keepsSessions, learnedRoutes
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
        keepsSessions = try c.decodeIfPresent(Bool.self, forKey: .keepsSessions) ?? true
        learnedRoutes = try c.decodeIfPresent([HostRoute].self, forKey: .learnedRoutes) ?? []
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

    /// Remember other addresses a host reported for itself.
    func learnRoutes(_ routes: [HostRoute], for hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }),
              hosts[index].learn(routes) else { return }
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
