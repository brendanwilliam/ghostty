import SwiftUI

/// One terminal in a tab or split: its own SSH connection to the host and
/// its surface view. Mediates that connection's prompts (host key
/// approval, password).
///
/// When the host has zmx, the shell runs in a zmx session named
/// `sessionName`, so it keeps running when the connection drops (or the
/// app is closed) and a new connection picks it up again.
@MainActor
final class TerminalPane: ObservableObject, Identifiable {
    struct HostKeyPrompt: Identifiable {
        let id = UUID()
        let fingerprint: String
        let respond: (Bool) -> Void
    }

    let id: UUID
    let host: Host
    /// This pane's zmx session on the host.
    let sessionName: String

    @Published private(set) var surfaceView: TerminalSurfaceView?
    @Published var title: String
    @Published var hostKeyPrompt: HostKeyPrompt?
    @Published var needsPassword = false
    @Published private(set) var ended = false
    /// Attaching to its session again after the connection dropped.
    @Published var reconnecting = false

    /// Bumped each time the view changes so SwiftUI swaps it.
    @Published private(set) var attempt = 0

    /// Whether this pane fetches the host's Ghostty config before its
    /// shell opens. Only one pane per screen does; the rest use the cache.
    var syncsRemoteConfig = true
    /// Called when a fetch changed the host's config.
    var onRemoteConfigChanged: ((URL) -> Void)?

    /// Sets up each new surface (callbacks, columns, font) before it
    /// connects.
    var configureSurface: ((TerminalSurfaceView) -> Void)?
    /// Called as a new surface replaces one that had the keyboard.
    var onKeyboardHandoff: (() -> Void)?

    /// The host's zmx sessions. Nil runs a plain login shell.
    var sessions: HostSessions?
    /// Whether the current (or last) connection attached to a zmx
    /// session, so a drop can be picked up again.
    var attachedToSession = false
    /// Why the last connection failed to start, if it did.
    private(set) var lastError: Error?

    init(id: UUID = UUID(), host: Host, sessionName: String? = nil) {
        self.id = id
        self.host = host
        self.sessionName = sessionName ?? ZmxSession.name(for: id, device: HostSessions.deviceTag)
        self.title = host.displayName
    }

    /// Whether the session dropped in a way that attaching again fixes:
    /// its zmx session lives on, and nothing needs the user.
    var canReattach: Bool {
        guard ended, attachedToSession, hostKeyPrompt == nil, !needsPassword else { return false }
        if lastError is SSHSessionError { return false }
        guard let view = surfaceView else { return true }
        return view.sessionDropped || view.startFailed
    }

    /// Connect, using the device key and (if given or saved) a password.
    /// Returns when the session ends.
    func connect(password: String? = nil) async {
        guard let app = GhosttyRuntime.shared.app else {
            title = "Ghostty failed to initialize"
            return
        }

        // Start from the host's config as last fetched so the first frame
        // looks right; it's refreshed before the shell opens.
        let cache = RemoteConfigCache(hostID: host.id)
        let usesRemote = host.usesRemoteConfig
        let cachedConfig = usesRemote && cache.exists ? cache.configURL : nil
        var beforeShell: (@Sendable (@escaping SSHBackend.Runner) async -> Void)?
        if usesRemote && syncsRemoteConfig {
            beforeShell = { [weak self] run in
                await self?.syncRemoteConfig(cache: cache, run: run)
            }
        }

        let name = sessionName
        let sessions = sessions
        let backend = SSHBackend(
            host: host,
            credentials: .saved(for: host, password: password),
            approveUnknownHostKey: { [weak self] fingerprint in
                await self?.askToTrust(fingerprint: fingerprint) ?? false
            },
            beforeShell: beforeShell,
            command: { [weak self] run in
                let command = await sessions?.prepare(session: name, run: run)
                await self?.setAttached(command != nil)
                return command
            },
            sessionLivesOn: { run in
                await sessions?.isRunning(name, run: run) ?? false
            })

        let view = TerminalSurfaceView(app: app, backend: backend, remoteConfig: cachedConfig)
        let error = await run(view)
        // Key (and any saved password) was refused: offer a password.
        if let error = error as? SSHSessionError, case .authenticationFailed = error, password == nil {
            needsPassword = true
        }
    }

    private func setAttached(_ attached: Bool) {
        attachedToSession = attached
    }

    /// Show `view` and run its session until it ends.
    ///
    /// Attaching to a zmx session again keeps the old view on screen
    /// until the new one has output (zmx redraws the screen as it
    /// attaches), so there's no blank flash; if it never gets any, the
    /// old view stays.
    @discardableResult
    func run(_ view: TerminalSurfaceView) async -> Error? {
        view.onTitleChange = { [weak self] in self?.title = $0 }
        configureSurface?(view)
        ended = false
        lastError = nil

        if let old = surfaceView, attachedToSession {
            view.frame = old.bounds
            view.layoutIfNeeded()
            view.onFirstOutput = { [weak self, weak view] in
                guard let self, let view else { return }
                self.show(view, replacing: old)
            }
        } else {
            show(view, replacing: nil)
        }

        let error = await view.run()
        lastError = error
        ended = true
        reconnecting = reconnecting && canReattach
        return error
    }

    private func show(_ view: TerminalSurfaceView, replacing old: TerminalSurfaceView?) {
        if old?.isFirstResponder == true { onKeyboardHandoff?() }
        attempt += 1
        surfaceView = view
        reconnecting = false
    }

    /// Close the connection, keeping the view. Its session keeps running
    /// on the host if it's in zmx.
    func suspend() {
        surfaceView?.closeBackend()
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
