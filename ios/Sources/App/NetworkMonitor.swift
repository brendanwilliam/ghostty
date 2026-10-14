import Foundation
import Network

/// Watches the phone's network and reports changes that matter to open
/// connections: losing the network, getting it back, moving to another
/// network (Wi-Fi to cellular, one Wi-Fi to another), and the tailnet
/// tunnel (Tailscale's VPN) coming up or going down.
final class NetworkMonitor: @unchecked Sendable {
    /// What the network looks like at a moment.
    struct Snapshot: Equatable, Sendable {
        var satisfied = false
        /// The interface traffic goes out on (ignoring VPNs).
        var interface: String?
        var interfaceType: InterfaceKind = .none
        /// The local network's gateways, which differ between Wi-Fi
        /// networks on the same interface.
        var gateways: [String] = []
        /// The phone's addresses on `interface`.
        var addresses: Set<String> = []
        /// The phone has a tailnet address (a tunnel is up).
        var tunnel = false

        enum InterfaceKind: String, Sendable {
            case wifi, cellular, wired, other, none
        }

        /// Whether traffic now leaves on a different network than before.
        func isDifferentNetwork(from old: Snapshot) -> Bool {
            satisfied && old.satisfied
                && (interface != old.interface || interfaceType != old.interfaceType
                    || gateways != old.gateways
                    || (!addresses.isEmpty && !old.addresses.isEmpty && addresses.isDisjoint(with: old.addresses)))
        }

        /// Identifies the network, to remember which route worked on it.
        var identity: String {
            "\(interfaceType.rawValue)|\(gateways.joined(separator: ","))"
        }
    }

    enum Change: Equatable, Sendable {
        case wentDown
        case cameUp
        /// Moved to a different network without going down in between.
        case switched
        case tunnelUp
        case tunnelDown
    }

    /// The changes between two snapshots.
    static func changes(from old: Snapshot, to new: Snapshot) -> [Change] {
        var changes: [Change] = []
        if old.satisfied && !new.satisfied { changes.append(.wentDown) }
        if !old.satisfied && new.satisfied { changes.append(.cameUp) }
        if new.isDifferentNetwork(from: old) { changes.append(.switched) }
        if !old.tunnel && new.tunnel { changes.append(.tunnelUp) }
        if old.tunnel && !new.tunnel { changes.append(.tunnelDown) }
        return changes
    }

    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private let lock = NSLock()
    private var snapshot = Snapshot(satisfied: true, tunnel: NetworkMonitor.hasTailnetAddress())
    private var handlers: [UUID: @Sendable ([Change], Snapshot) -> Void] = [:]
    private var started = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(Self.snapshot(of: path))
        }
        monitor.start(queue: queue)
    }

    var current: Snapshot { lock.withLock { snapshot } }
    var tunnelUp: Bool { current.tunnel }

    /// Calls `handler` (on a background queue) with each set of changes.
    /// Keep the token; dropping it stops the calls.
    func observe(_ handler: @escaping @Sendable ([Change], Snapshot) -> Void) -> Token {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return Token { [weak self] in
            _ = self?.lock.withLock { self?.handlers.removeValue(forKey: id) }
        }
    }

    final class Token: @unchecked Sendable {
        private let cancel: () -> Void
        init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
        deinit { cancel() }
    }

    private func update(_ new: Snapshot) {
        let (changes, observers): ([Change], [@Sendable ([Change], Snapshot) -> Void]) = lock.withLock {
            // The first path is the starting point, not a change.
            let changes = started ? Self.changes(from: snapshot, to: new) : []
            started = true
            snapshot = new
            return (changes, Array(handlers.values))
        }
        guard !changes.isEmpty else { return }
        for observer in observers { observer(changes, new) }
    }

    private static func snapshot(of path: NWPath) -> Snapshot {
        var snapshot = Snapshot(satisfied: path.status == .satisfied)
        let primary = path.availableInterfaces.first { $0.type != .other && $0.type != .loopback }
        if let primary {
            snapshot.interface = primary.name
            snapshot.interfaceType = switch primary.type {
            case .wifi: .wifi
            case .cellular: .cellular
            case .wiredEthernet: .wired
            default: .other
            }
            snapshot.addresses = addresses(on: primary.name)
        }
        snapshot.gateways = path.gateways.map { "\($0)" }.sorted()
        snapshot.tunnel = hasTailnetAddress()
        return snapshot
    }

    /// The phone's IP addresses on an interface (not link-local).
    private static func addresses(on interface: String) -> Set<String> {
        var result = Set<String>()
        forEachAddress { name, address in
            if name == interface && !address.hasPrefix("fe80:") && !address.hasPrefix("169.254.") {
                result.insert(address)
            }
        }
        return result
    }

    /// Whether a tunnel interface has a tailnet (Tailscale/Headscale)
    /// address, which is how a tailnet VPN shows up on the phone.
    static func hasTailnetAddress() -> Bool {
        var found = false
        forEachAddress { name, address in
            if name.hasPrefix("utun") && HostRoute.kind(of: address) == .tailnet { found = true }
        }
        return found
    }

    private static func forEachAddress(_ body: (String, String) -> Void) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = entry.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host).split(separator: "%").first.map(String.init) ?? ""
            body(String(cString: entry.pointee.ifa_name), address)
        }
    }
}
