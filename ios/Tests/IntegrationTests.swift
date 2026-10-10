import CryptoKit
import GhosttyKit
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

        let backend = FakeBackend()
        let view = TerminalSurfaceView(app: app, backend: backend)
        view.frame = window.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(view)
        defer { view.removeFromSuperview() }
        let run = Task { await view.run() }

        var sample = "\u{1B}[1mGhostty on iOS\u{1B}[0m — manual IO smoke test\r\n\r\n"
        for color in 0..<16 {
            sample += "\u{1B}[48;5;\(color)m  \u{1B}[0m"
        }
        sample += "\r\n\u{1B}[31mred \u{1B}[32mgreen \u{1B}[34mblue \u{1B}[0m\u{1B}[4munderline\u{1B}[0m\r\n"
        sample += "$ ls\r\nREADME.md  src  build.zig\r\n$ "
        backend.continuation.yield(.output(Data(sample.utf8)))

        try await Task.sleep(nanoseconds: 8_000_000_000)
        backend.continuation.finish()
        _ = await run.value
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
