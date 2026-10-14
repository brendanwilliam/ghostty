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

    /// The route the shown connection went over.
    @Published private(set) var route: HostRoute?
    /// Called when the connection's network offers a better path (e.g.
    /// Wi-Fi is back while on cellular).
    var onBetterPath: (() -> Void)?

    /// The shown connection's backend.
    private var backend: (any TerminalBackend)?
    /// Makes a view and its connection. Tests replace this to avoid SSH.
    var connectionMaker: ((_ handingOff: Bool) -> (TerminalSurfaceView, BackendLink)?)?
    /// A connection opened to take over from the shown one (`handOff`).
    private var handoff: (view: TerminalSurfaceView, task: Task<Error?, Never>)?

    /// How long a connection's path may be unusable before it's given up
    /// on and attached again.
    static let unviableGrace: Duration = .seconds(2)
    /// How long a connection has to answer a liveness check.
    static let livenessTimeout: Duration = .seconds(3)

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
        guard let (view, link) = connectionMaker?(false) ?? makeConnection(password: password, handingOff: false)
        else { return }
        let error = await run(view, link: link)
        // Key (and any saved password) was refused: offer a password.
        if let error = error as? SSHSessionError, case .authenticationFailed = error, password == nil {
            needsPassword = true
        }
    }

    /// A new view and its SSH connection, not yet started.
    ///
    /// - Parameter handingOff: For `handOff`: attaches only to this pane's
    ///   zmx session (never a fresh shell) and doesn't refresh the config.
    private func makeConnection(password: String?, handingOff: Bool) -> (TerminalSurfaceView, BackendLink)? {
        guard let app = GhosttyRuntime.shared.app else {
            title = "Ghostty failed to initialize"
            return nil
        }

        // Start from the host's config as last fetched so the first frame
        // looks right; it's refreshed before the shell opens.
        let cache = RemoteConfigCache(hostID: host.id)
        let usesRemote = host.usesRemoteConfig
        let cachedConfig = usesRemote && cache.exists ? cache.configURL : nil
        var beforeShell: (@Sendable (@escaping SSHBackend.Runner) async -> Void)?
        if usesRemote && syncsRemoteConfig && !handingOff {
            beforeShell = { [weak self] run in
                await self?.syncRemoteConfig(cache: cache, run: run)
            }
        }

        // The host as the workspace last learned it, with every route.
        let target = sessions?.host ?? host
        let name = sessionName
        let sessions = sessions
        let link = BackendLink()
        let backend = SSHBackend(
            host: target,
            credentials: .saved(for: target, password: password),
            approveUnknownHostKey: { [weak self] fingerprint in
                await self?.askToTrust(fingerprint: fingerprint) ?? false
            },
            beforeShell: beforeShell,
            command: { [weak self] run in
                let command = await sessions?.prepare(session: name, run: run)
                if handingOff {
                    // Only ever take over the same session.
                    if command == nil { link.backend?.close() }
                    return command
                }
                await self?.setAttached(command != nil)
                return command
            },
            sessionLivesOn: { run in
                await sessions?.isRunning(name, run: run) ?? false
            },
            onConnected: { [weak self] route, events in
                Task { @MainActor in self?.watch(link, route: route, events: events) }
            })
        link.backend = backend

        let view = TerminalSurfaceView(app: app, backend: backend, remoteConfig: cachedConfig)
        view.onTitleChange = { [weak self] in self?.title = $0 }
        configureSurface?(view)
        return (view, link)
    }

    private func setAttached(_ attached: Bool) {
        attachedToSession = attached
    }

    /// Show `view` and run its session until it ends.
    ///
    /// Attaching to a zmx session again keeps the old view on screen
    /// until the new one has output (zmx redraws the screen as it
    /// attaches), so there's no blank flash; if it never gets any, the
    /// old view stays. If the session is handed off to a new connection
    /// meanwhile, this follows it and returns when that one ends.
    @discardableResult
    func run(_ view: TerminalSurfaceView, link: BackendLink? = nil) async -> Error? {
        if view.onTitleChange == nil {
            view.onTitleChange = { [weak self] in self?.title = $0 }
            configureSurface?(view)
        }
        ended = false
        lastError = nil

        if let old = surfaceView, attachedToSession {
            view.frame = old.bounds
            view.layoutIfNeeded()
            view.onFirstOutput = { [weak self, weak view] in
                guard let self, let view else { return }
                self.show(view, replacing: old, link: link)
            }
        } else {
            show(view, replacing: nil, link: link)
        }

        var error = await view.run()
        // Handed off while this connection ran: carry on with the new one.
        while let next = handoff {
            handoff = nil
            let nextError = await next.task.value
            guard surfaceView === next.view else { break }
            error = nextError
        }
        lastError = error
        ended = true
        reconnecting = reconnecting && canReattach
        return error
    }

    private func show(_ view: TerminalSurfaceView, replacing old: TerminalSurfaceView?, link: BackendLink?) {
        if old?.isFirstResponder == true { onKeyboardHandoff?() }
        attempt += 1
        surfaceView = view
        backend = link?.backend
        route = link?.route
        reconnecting = false
    }

    /// Close the connection, keeping the view. Its session keeps running
    /// on the host if it's in zmx.
    func suspend() {
        surfaceView?.closeBackend()
    }

    /// Whether this pane has a live connection to check or move.
    var isConnected: Bool { !ended && backend != nil && surfaceView != nil }

    /// Whether the connection still carries traffic.
    func checkAlive() async -> Bool {
        guard let backend = backend as? LivenessChecking else { return false }
        return await backend.isAlive(within: Self.livenessTimeout)
    }

    /// Give up on the connection (its network is gone) so the pane
    /// attaches again over whatever works now.
    func dropConnection() {
        guard attachedToSession, isConnected else { return }
        suspend()
    }

    /// Move to a new connection without a gap: open one alongside the
    /// current connection (over the best route now), and once it has
    /// attached and zmx has redrawn the screen, show it and close the old
    /// one. Until then, keys go to the old connection, so none are lost
    /// or sent twice; if the new one fails, the old one carries on.
    func handOff() {
        guard attachedToSession, isConnected, handoff == nil, let old = surfaceView,
              let (view, link) = connectionMaker?(true) ?? makeConnection(password: nil, handingOff: true)
        else { return }
        view.frame = old.bounds
        view.layoutIfNeeded()
        view.onFirstOutput = { [weak self, weak view] in
            guard let self, let view, self.surfaceView === old else { return }
            self.show(view, replacing: old, link: link)
            // Let keys typed just before the swap reach the host first.
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                old.closeBackend()
            }
        }
        let task = Task { await view.run() }
        handoff = (view, task)
        Task { [weak self] in
            _ = await task.value
            // Ended without taking over: forget it.
            if let self, self.handoff?.view === view { self.handoff = nil }
        }
    }

    var isHandingOff: Bool { handoff != nil }

    /// Follow a connection's route and network events.
    private func watch(_ link: BackendLink, route: HostRoute, events: AsyncStream<RouteEvent>) {
        link.route = route
        if link.backend != nil && link.backend === backend { self.route = route }
        Task { [weak self] in
            var giveUp: Task<Void, Never>?
            for await event in events {
                guard let self, link.backend === self.backend else { continue }
                switch event {
                case .viable(false):
                    giveUp?.cancel()
                    giveUp = Task { [weak self] in
                        try? await Task.sleep(for: Self.unviableGrace)
                        guard !Task.isCancelled, let self, link.backend === self.backend else { return }
                        self.dropConnection()
                    }
                case .viable(true):
                    giveUp?.cancel()
                case .betterPathAvailable:
                    self.onBetterPath?()
                }
            }
            giveUp?.cancel()
        }
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

/// Ties a view's backend to what's known about its connection, so events
/// from a connection that's no longer shown are ignored.
final class BackendLink: @unchecked Sendable {
    weak var backend: (any TerminalBackend)?
    var route: HostRoute?

    init(backend: (any TerminalBackend)? = nil, route: HostRoute? = nil) {
        self.backend = backend
        self.route = route
    }
}

/// A backend that can tell whether its connection still works.
protocol LivenessChecking {
    func isAlive(within timeout: Duration) async -> Bool
}

extension SSHBackend: LivenessChecking {}
