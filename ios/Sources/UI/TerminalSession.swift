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

    init(host: Host) {
        self.host = host
        self.title = host.displayName
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

        let backend = SSHBackend(
            host: host,
            credentials: SSHCredentials(
                username: host.username,
                deviceKey: deviceKey,
                password: password ?? savedPassword),
            approveUnknownHostKey: { [weak self] fingerprint in
                await self?.askToTrust(fingerprint: fingerprint) ?? false
            })

        let view = TerminalSurfaceView(app: app, backend: backend)
        view.onTitleChange = { [weak self] in self?.title = $0 }
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

    private func askToTrust(fingerprint: String) async -> Bool {
        await withCheckedContinuation { continuation in
            hostKeyPrompt = HostKeyPrompt(fingerprint: fingerprint) { trusted in
                continuation.resume(returning: trusted)
            }
        }
    }
}
