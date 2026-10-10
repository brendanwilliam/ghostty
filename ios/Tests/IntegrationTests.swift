import CryptoKit
import GhosttyKit
import SwiftUI
import XCTest
@testable import GhosttyiOS

/// A backend that records what the terminal writes and lets the test
/// feed output.
private final class FakeBackend: TerminalBackend, @unchecked Sendable {
    let events: AsyncStream<TerminalBackendEvent>
    let continuation: AsyncStream<TerminalBackendEvent>.Continuation
    private let lock = NSLock()
    private var _written = Data()
    private var _sizes: [TerminalSize] = []

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    var written: Data { lock.withLock { _written } }
    var sizes: [TerminalSize] { lock.withLock { _sizes } }

    func start(size: TerminalSize) async throws {}
    func write(_ data: Data) { lock.withLock { _written.append(data) } }
    func resize(_ size: TerminalSize) { lock.withLock { _sizes.append(size) } }
    func close() { continuation.finish() }
}

/// Wait (without blocking the main run loop) until `condition` holds.
@MainActor
private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Exercises libghostty's manual IO mode end to end: bytes fed into the
/// surface are parsed by the real terminal, and the terminal's responses
/// come back out through the write callback.
@MainActor
final class ManualIOTests: XCTestCase {
    func testTerminalRoundTrip() async throws {
        let app = try XCTUnwrap(GhosttyRuntime.shared.app, "libghostty failed to initialize")
        let backend = FakeBackend()
        let view = TerminalSurfaceView(app: app, backend: backend)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        view.layoutIfNeeded()
        XCTAssertNotNil(view.surface)

        let run = Task { await view.run() }

        // The surface reports its grid size to the backend.
        let sized = await waitUntil { !backend.sizes.isEmpty }
        XCTAssertTrue(sized, "expected a resize callback")
        if let size = backend.sizes.last {
            XCTAssertGreaterThan(size.columns, 0)
            XCTAssertGreaterThan(size.rows, 0)
        }

        // Device status report: the terminal must answer with the cursor
        // position. Move the cursor first so the answer is distinctive.
        backend.continuation.yield(.output(Data("hello\r\n\u{1B}[3;5H\u{1B}[6n".utf8)))
        let answered = await waitUntil {
            String(decoding: backend.written, as: UTF8.self).contains("\u{1B}[3;5R")
        }
        XCTAssertTrue(answered, "terminal did not answer DSR; wrote \(backend.written as NSData)")

        // Typed input is encoded and written to the backend.
        let surface = try XCTUnwrap(view.surface)
        KeyInput.type("ls\n", into: surface, ctrl: false, alt: false)
        let typed = await waitUntil {
            String(decoding: backend.written, as: UTF8.self).contains("ls\r")
        }
        XCTAssertTrue(typed, "typed keys not written; wrote \(backend.written as NSData)")

        // Ctrl+C from the software keyboard sends ETX.
        KeyInput.type("c", into: surface, ctrl: true, alt: false)
        let interrupted = await waitUntil { backend.written.contains(0x03) }
        XCTAssertTrue(interrupted, "ctrl+c not written as 0x03")

        // Ending the session marks the surface's process as exited.
        backend.continuation.yield(.exited(code: 0, message: nil))
        backend.continuation.finish()
        _ = await run.value
        XCTAssertTrue(ghostty_surface_process_exited(surface))
    }
}

@MainActor
final class SurfaceFeatureTests: XCTestCase {
    private func makeView(columns: Int?, width: CGFloat = 390, height: CGFloat = 700) throws -> (TerminalSurfaceView, FakeBackend) {
        let app = try XCTUnwrap(GhosttyRuntime.shared.app)
        let backend = FakeBackend()
        let view = TerminalSurfaceView(app: app, backend: backend, columns: columns)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutIfNeeded()
        return (view, backend)
    }

    func testFitsTargetColumns() throws {
        let (narrow, _) = try makeView(columns: 80)
        let size80 = ghostty_surface_size(try XCTUnwrap(narrow.surface))
        XCTAssertGreaterThanOrEqual(Int(size80.columns), 80,
            "font \(narrow.fontPoints)pt cell \(size80.cell_width_px)px width \(size80.width_px)px")
        XCTAssertLessThanOrEqual(Int(size80.columns), 84)

        let (wide, _) = try makeView(columns: 60)
        let size60 = ghostty_surface_size(try XCTUnwrap(wide.surface))
        XCTAssertGreaterThanOrEqual(Int(size60.columns), 60)
        XCTAssertLessThanOrEqual(Int(size60.columns), 63)
        XCTAssertGreaterThan(wide.fontPoints, narrow.fontPoints)

        // Landscape keeps the portrait font, so it shows more columns.
        let fontBefore = narrow.fontPoints
        narrow.frame = CGRect(x: 0, y: 0, width: 700, height: 390)
        narrow.layoutIfNeeded()
        XCTAssertEqual(narrow.fontPoints, fontBefore)
        XCTAssertGreaterThan(Int(ghostty_surface_size(try XCTUnwrap(narrow.surface)).columns), 130)

        // Turning fitting off restores the config's font size.
        narrow.targetColumns = nil
        XCTAssertEqual(narrow.fontPoints, 12)

        // More columns than the smallest font allows: clamp, don't loop.
        let (dense, _) = try makeView(columns: 300)
        XCTAssertEqual(dense.fontPoints, TerminalSurfaceView.fontPointRange.lowerBound)
    }

    func testShiftTabSendsBacktab() async throws {
        let (view, backend) = try makeView(columns: nil)
        let run = Task { await view.run() }
        defer { backend.continuation.finish() }

        view.accessoryTapped(.shift)
        view.accessoryTapped(.tab)
        let backtab = await waitUntil {
            String(decoding: backend.written, as: UTF8.self).contains("\u{1B}[Z")
        }
        XCTAssertTrue(backtab, "shift+tab wrote \(backend.written as NSData)")

        // Shift is one-shot, and shifts the next accessory symbol.
        view.accessoryTapped(.shift)
        view.accessoryTapped(.character("-"))
        view.accessoryTapped(.character("-"))
        let typed = await waitUntil {
            String(decoding: backend.written, as: UTF8.self).hasSuffix("_-")
        }
        XCTAssertTrue(typed, "wrote \(String(decoding: backend.written, as: UTF8.self).debugDescription)")

        backend.continuation.finish()
        _ = await run.value
    }
}

/// Shows a terminal full screen with sample output and holds it so a
/// screenshot can be taken (`xcrun simctl io booted screenshot`).
/// Skipped unless GHOSTTY_TEST_VISUAL is set.
@MainActor
final class VisualSmokeTests: XCTestCase {
    func testRenderSampleOutput() async throws {
        guard ProcessInfo.processInfo.environment["GHOSTTY_TEST_VISUAL"] != nil else {
            throw XCTSkip("visual smoke test not requested")
        }
        let app = try XCTUnwrap(GhosttyRuntime.shared.app)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first)

        // Render as if connected to a Mac whose config sets a theme.
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("visual-remote.ghostty")
        try "theme = Cutie Pro\nwindow-padding-x = 12\n".write(to: remote, atomically: true, encoding: .utf8)

        let backend = FakeBackend()
        let view = TerminalSurfaceView(app: app, backend: backend, remoteConfig: remote, columns: 80)
        view.frame = window.safeAreaLayoutGuide.layoutFrame
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(view)
        defer { view.removeFromSuperview() }
        _ = view.becomeFirstResponder()
        view.accessoryTapped(.shift)
        let run = Task { await view.run() }

        var sample = "\u{1B}[1mGhostty on iOS\u{1B}[0m — manual IO smoke test\r\n\r\n"
        for color in 0..<16 {
            sample += "\u{1B}[48;5;\(color)m  \u{1B}[0m"
        }
        sample += "\r\n\u{1B}[31mred \u{1B}[32mgreen \u{1B}[34mblue \u{1B}[0m\u{1B}[4munderline\u{1B}[0m\r\n"
        sample += "$ ls\r\nREADME.md  src  build.zig\r\n"
        sample += String(repeating: "0123456789", count: 8) + "\r\n"
        sample += "^ 80 columns: this line should exactly fill the width\r\n$ "
        backend.continuation.yield(.output(Data(sample.utf8)))

        try await Task.sleep(nanoseconds: 8_000_000_000)
        backend.continuation.finish()
        _ = await run.value
    }
}

/// Shows the Settings screen for a screenshot. Skipped unless
/// GHOSTTY_TEST_VISUAL_SETTINGS is set.
@MainActor
final class VisualSettingsTests: XCTestCase {
    func testShowSettings() async throws {
        guard ProcessInfo.processInfo.environment["GHOSTTY_TEST_VISUAL_SETTINGS"] != nil else {
            throw XCTSkip("visual settings test not requested")
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first)
        let store = HostStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("visual-hosts.json"))
        let controller = UIHostingController(rootView: SettingsView().environmentObject(store))
        window.rootViewController?.present(controller, animated: false)
        try await Task.sleep(nanoseconds: 8_000_000_000)
        controller.dismiss(animated: false)
    }
}

/// Connects to a real sshd. Skipped unless these are set (prefix with
/// TEST_RUNNER_ when passing through xcodebuild):
///   GHOSTTY_TEST_SSH_PORT, GHOSTTY_TEST_SSH_USER, GHOSTTY_TEST_SSH_KEY_SEED (hex)
final class SSHIntegrationTests: XCTestCase {
    func testInteractiveShell() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portString = env["GHOSTTY_TEST_SSH_PORT"], let port = Int(portString),
              let user = env["GHOSTTY_TEST_SSH_USER"],
              let seedHex = env["GHOSTTY_TEST_SSH_KEY_SEED"] else {
            throw XCTSkip("SSH integration environment not configured")
        }

        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hex: seedHex))
        let host = Host(name: "test", hostname: "127.0.0.1", port: port, username: user)
        KnownHosts.shared.forget(endpoint: host.endpoint)
        defer { KnownHosts.shared.forget(endpoint: host.endpoint) }

        let approvals = Counter()
        let backend = SSHBackend(
            host: host,
            credentials: SSHCredentials(username: user, deviceKey: key, password: nil),
            approveUnknownHostKey: { fingerprint in
                approvals.increment()
                return fingerprint.hasPrefix("SHA256:")
            })

        let session = Task { try await backend.start(size: TerminalSize(columns: 80, rows: 24, widthPixels: 0, heightPixels: 0)) }

        var output = ""
        var exitCode: Int32?? = nil
        var exitMessage: String?
        var sentCommand = false
        for await event in backend.events {
            switch event {
            case .output(let data):
                output += String(decoding: data, as: UTF8.self)
                if !sentCommand {
                    sentCommand = true
                    backend.write(Data("echo ghostty-$((40+2)) $TERM; exit\r".utf8))
                }
            case .exited(let code, let message):
                exitCode = code
                exitMessage = message
            }
        }
        try await session.value

        XCTAssertTrue(output.contains("ghostty-42 xterm-256color"), "unexpected output: \(output)")
        XCTAssertEqual(exitCode, .some(0), "exit message: \(exitMessage ?? "nil")")
        XCTAssertEqual(approvals.value, 1)

        // The key was remembered, so reconnecting doesn't prompt.
        XCTAssertNotNil(KnownHosts.shared.fingerprint(endpoint: host.endpoint))
    }

    /// Fetches the host's Ghostty config before the shell opens. Expects
    /// the sshd to `SetEnv XDG_CONFIG_HOME` to a fixture whose config
    /// sets `cursor-style = underline`, `initial-command`, and includes
    /// a file setting `scrollback-limit-lines = 4242`.
    func testFetchesRemoteConfigBeforeShell() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portString = env["GHOSTTY_TEST_SSH_PORT"], let port = Int(portString),
              let user = env["GHOSTTY_TEST_SSH_USER"],
              let seedHex = env["GHOSTTY_TEST_SSH_KEY_SEED"],
              env["GHOSTTY_TEST_SSH_CONFIG_FIXTURE"] != nil else {
            throw XCTSkip("SSH config fixture environment not configured")
        }

        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hex: seedHex))
        let host = Host(name: "test", hostname: "127.0.0.1", port: port, username: user)
        KnownHosts.shared.forget(endpoint: host.endpoint)
        defer { KnownHosts.shared.forget(endpoint: host.endpoint) }

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let cache = RemoteConfigCache(directory: cacheDir)
        let fetched = Counter()

        let backend = SSHBackend(
            host: host,
            credentials: SSHCredentials(username: user, deviceKey: key, password: nil),
            approveUnknownHostKey: { _ in true },
            beforeShell: { run in
                let fetcher = RemoteConfigFetcher(run: run, isBundledTheme: { _ in true })
                if let result = try? await fetcher.fetch(), (try? cache.store(result)) != nil {
                    fetched.increment()
                }
            })

        let session = Task { try await backend.start(size: .default) }
        var sentExit = false
        for await event in backend.events {
            if case .output = event, !sentExit {
                // The fetch finished before any shell output arrived.
                XCTAssertEqual(fetched.value, 1)
                sentExit = true
                backend.write(Data("exit\r".utf8))
            }
        }
        try await session.value

        let config = ConfigFile(contentsOf: cache.configURL)
        XCTAssertEqual(config.value("cursor-style"), "underline", cache.text ?? "no config")
        XCTAssertEqual(config.value("scrollback-limit-lines"), "4242")
        XCTAssertNil(config.value("initial-command"))
        XCTAssertNil(config.value("config-file"))
        XCTAssertTrue(cache.metadata?.dropped.contains { $0.hasPrefix("initial-command") } ?? false)
        XCTAssertTrue(cache.metadata?.sources.first?.hasSuffix("/xdg/ghostty/config") ?? false,
                      "sources: \(cache.metadata?.sources ?? [])")
    }

    func testRejectedHostKeyFailsConnection() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portString = env["GHOSTTY_TEST_SSH_PORT"], let port = Int(portString),
              let user = env["GHOSTTY_TEST_SSH_USER"],
              let seedHex = env["GHOSTTY_TEST_SSH_KEY_SEED"] else {
            throw XCTSkip("SSH integration environment not configured")
        }

        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hex: seedHex))
        let host = Host(name: "test", hostname: "127.0.0.1", port: port, username: user)
        KnownHosts.shared.forget(endpoint: host.endpoint)
        defer { KnownHosts.shared.forget(endpoint: host.endpoint) }

        let backend = SSHBackend(
            host: host,
            credentials: SSHCredentials(username: user, deviceKey: key, password: nil),
            approveUnknownHostKey: { _ in false })

        do {
            try await backend.start(size: .default)
            XCTFail("connection should fail when the host key is rejected")
        } catch let error as SSHSessionError {
            guard case .hostKeyRejected = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertNil(KnownHosts.shared.fingerprint(endpoint: host.endpoint))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private extension Data {
    init(hex: String) {
        self.init()
        var rest = hex[...]
        while rest.count >= 2 {
            append(UInt8(rest.prefix(2), radix: 16)!)
            rest = rest.dropFirst(2)
        }
    }
}
