import SwiftUI

/// Drives one terminal connection to a host: builds the backend, owns the
/// surface view, and mediates prompts (host key approval, password).
@MainActor
final class TerminalSession: ObservableObject {
    struct HostKeyPrompt: Identifiable {
        let id = UUID()
        let fingerprint: String
        let respond: (Bool) -> Void
    }

    let host: Host

    @Published private(set) var surfaceView: TerminalSurfaceView?
    @Published var title: String
    @Published var hostKeyPrompt: HostKeyPrompt?
    @Published var needsPassword = false
    @Published private(set) var ended = false

    /// Bumped on each connection attempt so SwiftUI swaps the view.
    @Published private(set) var attempt = 0

    /// Saves the column count a pinch settles on.
    var onColumnsSettled: ((Int) -> Void)?

    private var columns: Int?
    /// Whether this host has its own column count (otherwise it follows
    /// the default in Settings).
    private var hasOwnColumns: Bool
    private var columnsObserver: NSObjectProtocol?

    init(host: Host) {
        self.host = host
        self.title = host.displayName
        self.columns = AppSettings.columns(for: host)
        self.hasOwnColumns = host.columns != nil
        columnsObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.columnsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultColumnsChanged() }
        }
    }

    deinit {
        if let columnsObserver { NotificationCenter.default.removeObserver(columnsObserver) }
    }

    private func defaultColumnsChanged() {
        guard !hasOwnColumns else { return }
        columns = AppSettings.defaultColumns
        surfaceView?.targetColumns = columns
    }

    /// Connect, using the device key and (if given or saved) a password.
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
        if usesRemote {
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

        let view = TerminalSurfaceView(
            app: app,
            backend: backend,
            remoteConfig: cachedConfig,
            columns: columns)
        view.onTitleChange = { [weak self] in self?.title = $0 }
        view.onColumnsSettled = { [weak self] columns in
            self?.columns = columns
            self?.hasOwnColumns = true
            self?.onColumnsSettled?(columns)
        }
        attempt += 1
        ended = false
        surfaceView = view

        let error = await view.run()
        ended = true
        // Key (and any saved password) was refused: offer a password.
        if let error = error as? SSHSessionError, case .authenticationFailed = error, password == nil {
            needsPassword = true
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
