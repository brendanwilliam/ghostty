import SwiftUI

/// One terminal in a tab or split: its own SSH connection to the host and
/// its surface view. Mediates that connection's prompts (host key
/// approval, password).
@MainActor
final class TerminalPane: ObservableObject, Identifiable {
    struct HostKeyPrompt: Identifiable {
        let id = UUID()
        let fingerprint: String
        let respond: (Bool) -> Void
    }

    let id = UUID()
    let host: Host

    @Published private(set) var surfaceView: TerminalSurfaceView?
    @Published var title: String
    @Published var hostKeyPrompt: HostKeyPrompt?
    @Published var needsPassword = false
    @Published private(set) var ended = false

    /// Bumped on each connection attempt so SwiftUI swaps the view.
    @Published private(set) var attempt = 0

    /// Whether this pane fetches the host's Ghostty config before its
    /// shell opens. Only one pane per screen does; the rest use the cache.
    var syncsRemoteConfig = true
    /// Called when a fetch changed the host's config.
    var onRemoteConfigChanged: ((URL) -> Void)?

    /// Sets up each new surface (callbacks, columns, font) before it
    /// connects.
    var configureSurface: ((TerminalSurfaceView) -> Void)?

    init(host: Host) {
        self.host = host
        self.title = host.displayName
    }

    /// Connect, using the device key and (if given or saved) a password.
    /// Returns when the session ends.
    func connect(password: String? = nil) async {
        guard let app = GhosttyRuntime.shared.app else {
            title = "Ghostty failed to initialize"
            return
        }

        let deviceKey = try? DeviceKey.loadOrCreate()
        let savedPassword = host.savesPassword
            ? (try? Keychain.read(host.passwordAccount)).flatMap { String(data: $0, encoding: .utf8) }
            : nil

        // Start from the host's config as last fetched so the first frame
        // looks right; it's refreshed before the shell opens.
        let cache = RemoteConfigCache(hostID: host.id)
        let usesRemote = host.usesRemoteConfig
        let cachedConfig = usesRemote && cache.exists ? cache.configURL : nil
        var beforeShell: (@Sendable (@escaping RemoteConfigFetcher.Runner) async -> Void)?
        if usesRemote && syncsRemoteConfig {
            beforeShell = { [weak self] run in
                await self?.syncRemoteConfig(cache: cache, run: run)
            }
        }

        let backend = SSHBackend(
            host: host,
            credentials: SSHCredentials(
                username: host.username,
                deviceKey: deviceKey,
                password: password ?? savedPassword),
            approveUnknownHostKey: { [weak self] fingerprint in
                await self?.askToTrust(fingerprint: fingerprint) ?? false
            },
            beforeShell: beforeShell)

        let view = TerminalSurfaceView(app: app, backend: backend, remoteConfig: cachedConfig)
        let error = await run(view)
        // Key (and any saved password) was refused: offer a password.
        if let error = error as? SSHSessionError, case .authenticationFailed = error, password == nil {
            needsPassword = true
        }
    }

    /// Show `view` and run its session until it ends.
    @discardableResult
    func run(_ view: TerminalSurfaceView) async -> Error? {
        view.onTitleChange = { [weak self] in self?.title = $0 }
        configureSurface?(view)
        attempt += 1
        ended = false
        surfaceView = view
        let error = await view.run()
        ended = true
        return error
    }

    func disconnect() {
        surfaceView = nil
    }

    /// Fetch the host's Ghostty config, cache it, and apply it to the
    /// terminal if it changed. Failures keep the cached config.
    private func syncRemoteConfig(cache: RemoteConfigCache, run: @escaping RemoteConfigFetcher.Runner) async {
        let fetcher = RemoteConfigFetcher(run: run, isBundledTheme: ThemeCatalog.isBundled)
        do {
            let result = try await fetcher.fetch()
            let changed = try cache.store(result)
            if changed || surfaceView?.remoteConfig == nil {
                surfaceView?.remoteConfig = cache.configURL
                if changed { onRemoteConfigChanged?(cache.configURL) }
            }
        } catch {
            surfaceView?.writeNotice("Couldn't read the host's Ghostty config: \(error.localizedDescription)")
        }
    }

    private func askToTrust(fingerprint: String) async -> Bool {
        await withCheckedContinuation { continuation in
            hostKeyPrompt = HostKeyPrompt(fingerprint: fingerprint) { trusted in
                continuation.resume(returning: trusted)
            }
        }
    }
}
