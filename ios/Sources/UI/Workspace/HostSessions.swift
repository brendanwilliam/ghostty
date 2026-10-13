import CryptoKit
import Foundation

/// A host's zmx sessions: whether zmx is installed there, which of this
/// device's sessions are running, and sessions waiting to be ended. Lives
/// as long as the app (not just a terminal screen), since ending a session
/// can outlast its screen.
@MainActor
final class HostSessions: ObservableObject {
    typealias Runner = SSHBackend.Runner

    /// The host as last opened, for its settings and credentials.
    var host: Host

    /// What the last probe found. Saved, so a probe that times out can
    /// fall back to it.
    @Published private(set) var probe: ZmxSession.Probe?
    /// Whether a probe has finished since launch.
    @Published private(set) var probed = false
    /// Sessions to end the next time the host is reachable.
    private(set) var pendingKills: [String]

    /// Called when `probe` or `pendingKills` change, to save them.
    var onChange: (() -> Void)?
    /// Called after a probe with this device's running sessions.
    var onSessionsFound: (([String]) -> Void)?

    /// Runs one command on the host over its own connection. Tests set
    /// this to avoid SSH.
    var runner: Runner?

    static let probeTimeout: Duration = .seconds(6)

    init(host: Host, record: HostSessionRecord = HostSessionRecord()) {
        self.host = host
        self.probe = record.probe
        self.pendingKills = record.pendingKills
    }

    private var runOnce: Runner {
        if let runner { return runner }
        let host = host
        return { command in
            try await SSHBackend.run(command, on: host, credentials: SSHCredentials.saved(for: host))
        }
    }

    var record: HostSessionRecord {
        HostSessionRecord(probe: probe, pendingKills: pendingKills)
    }

    /// Whether new panes run inside zmx.
    var available: Bool { host.keepsSessions && probe?.zmx != nil }

    /// Probed, and zmx isn't installed: worth offering to install it.
    var missing: Bool { host.keepsSessions && probed && probe?.zmx == nil }

    /// This device's tag in session names.
    static let deviceTag: String = {
        guard let key = try? DeviceKey.loadOrCreate() else { return "0000" }
        return ZmxSession.deviceTag(publicKey: key.publicKey.rawRepresentation)
    }()

    // MARK: Connecting

    /// Before a pane's PTY opens: probe the host, end pending sessions,
    /// and return the command that attaches to `session` (nil when zmx
    /// isn't there, for a plain login shell).
    func prepare(session: String, run: @escaping Runner) async -> String? {
        guard host.keepsSessions else { return nil }
        if let output = await withTimeout(Self.probeTimeout, { try await run(ZmxSession.probeCommand) }) {
            update(ZmxSession.parseProbe(String(decoding: output, as: UTF8.self)))
        }
        guard let zmx = probe?.zmx else { return nil }
        await flushKills(run: run, zmx: zmx)
        return ZmxSession.attachCommand(zmx: zmx, name: session)
    }

    /// After an attach ended by itself: whether the session is still
    /// running (it was detached, not exited).
    func isRunning(_ session: String, run: @escaping Runner) async -> Bool {
        guard let zmx = probe?.zmx,
              let output = await withTimeout(.seconds(4), { try await run(ZmxSession.listCommand(zmx: zmx)) })
        else { return false }
        return ZmxSession.parseList(String(decoding: output, as: UTF8.self)).contains(session)
    }

    private func update(_ found: ZmxSession.Probe) {
        probe = found
        probed = true
        onChange?()
        let mine = ZmxSession.devicePrefix(Self.deviceTag)
        let sessions = found.sessions.filter { $0.hasPrefix(mine) && !pendingKills.contains($0) }
        onSessionsFound?(sessions)
    }

    // MARK: Ending sessions

    /// End sessions on the host now if it's reachable, else the next
    /// time a pane connects.
    func end(_ sessions: [String]) {
        guard !sessions.isEmpty, probe?.zmx != nil else { return }
        pendingKills.append(contentsOf: sessions.filter { !pendingKills.contains($0) })
        onChange?()
        Task { await flushKills() }
    }

    /// End pending sessions over a connection of their own.
    func flushKills() async {
        guard let zmx = probe?.zmx, !pendingKills.isEmpty else { return }
        await flushKills(run: runOnce, zmx: zmx)
    }

    private func flushKills(run: @escaping Runner, zmx: String) async {
        let names = pendingKills
        guard !names.isEmpty else { return }
        guard await withTimeout(.seconds(10), { try await run(ZmxSession.killCommand(zmx: zmx, names: names)) }) != nil
        else { return }
        pendingKills.removeAll { names.contains($0) }
        onChange?()
    }

    // MARK: Installing

    /// Install zmx with Homebrew and probe again. Returns brew's output.
    func install() async throws -> String {
        guard let brew = probe?.brew else { throw InstallError.noHomebrew }
        let output = try await runOnce(ZmxSession.installCommand(brew: brew))
        try await reprobe()
        return String(decoding: output, as: UTF8.self)
    }

    /// Probe over a connection of its own.
    func reprobe() async throws {
        let output = try await runOnce(ZmxSession.probeCommand)
        update(ZmxSession.parseProbe(String(decoding: output, as: UTF8.self)))
    }

    enum InstallError: LocalizedError {
        case noHomebrew
        var errorDescription: String? { "Homebrew isn't installed on the host." }
    }
}

/// A host's saved session state.
struct HostSessionRecord: Codable, Equatable {
    var probe: ZmxSession.Probe?
    var pendingKills: [String] = []
}

extension SSHCredentials {
    /// The device key and, if the host saves one, its password.
    static func saved(for host: Host, password: String? = nil) -> SSHCredentials {
        let savedPassword = host.savesPassword
            ? (try? Keychain.read(host.passwordAccount)).flatMap { String(data: $0, encoding: .utf8) }
            : nil
        return SSHCredentials(
            username: host.username,
            deviceKey: try? DeviceKey.loadOrCreate(),
            password: password ?? savedPassword)
    }
}

/// `operation`'s result, or nil if it fails or takes longer than
/// `timeout`. Doesn't wait for a stuck operation to notice.
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = TimeoutOnce()
        Task {
            let result = try? await operation()
            if once.claim() { continuation.resume(returning: result) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            if once.claim() { continuation.resume(returning: nil) }
        }
    }
}

private final class TimeoutOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
