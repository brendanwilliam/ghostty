import CryptoKit
import XCTest
@testable import GhosttyiOS

/// A host that answers the app's zmx commands from a list of sessions.
final class FakeZmxHost: @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [String] = []
    private var _sessions: [String]
    var zmx: String?
    var brew: String? = "/opt/homebrew/bin/brew"
    /// Fail every command, as if the host were unreachable.
    var offline = false

    init(zmx: String? = "/opt/homebrew/bin/zmx", sessions: [String] = []) {
        self.zmx = zmx
        self._sessions = sessions
    }

    var commands: [String] { lock.withLock { _commands } }
    var sessions: [String] { lock.withLock { _sessions } }

    var runner: SSHBackend.Runner {
        { [self] command in try self.run(command) }
    }

    private func run(_ command: String) throws -> Data {
        if offline { throw URLError(.notConnectedToInternet) }
        return lock.withLock {
            _commands.append(command)
            var out = ""
            if command.contains("command -v zmx") {
                if let zmx { out += "zmx \(zmx)\n" }
                if let brew { out += "brew \(brew)\n" }
                if zmx != nil { out += _sessions.map { "session \($0)\n" }.joined() }
            } else if command.contains(" kill ") {
                _sessions.removeAll { command.contains($0) }
            } else if command.contains(" list --short") {
                out = _sessions.joined(separator: "\n")
            }
            return Data(out.utf8)
        }
    }
}

@MainActor
final class ZmxSessionTests: XCTestCase {
    func testSessionNames() throws {
        let pane = try XCTUnwrap(UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0"))
        XCTAssertEqual(ZmxSession.name(for: pane, device: "ab12"), "gios-ab12-12345678")
        XCTAssertEqual(ZmxSession.deviceTag(publicKey: Data([1, 2, 3])).count, 4)
    }

    func testCommandsQuoteForTheShell() {
        XCTAssertEqual(ZmxSession.quote("it's"), "'it'\\''s'")
        let attach = ZmxSession.attachCommand(zmx: "/opt/homebrew/bin/zmx", name: "gios-ab12-12345678")
        XCTAssertTrue(attach.hasPrefix("exec \"${SHELL:-/bin/sh}\" -lc '"), attach)
        XCTAssertTrue(attach.contains("ZMX_NO_DETACH_KEY=1 exec '\\''/opt/homebrew/bin/zmx'\\'' attach '\\''gios-ab12-12345678'\\''"), attach)
        let kill = ZmxSession.killCommand(zmx: "/z", names: ["gios-a", "gios-b"])
        XCTAssertTrue(kill.contains("kill '\\''gios-a'\\'' '\\''gios-b'\\''"), kill)
    }

    func testParsesProbeAndList() {
        let probe = ZmxSession.parseProbe("""
            zmx /opt/homebrew/bin/zmx
            brew /opt/homebrew/bin/brew
            session gios-ab12-1
            session someone-else
            """)
        XCTAssertEqual(probe, ZmxSession.Probe(zmx: "/opt/homebrew/bin/zmx", brew: "/opt/homebrew/bin/brew",
                                               sessions: ["gios-ab12-1"]))
        XCTAssertEqual(ZmxSession.parseProbe("brew /usr/local/bin/brew\n").zmx, nil)
        XCTAssertEqual(ZmxSession.parseList("gios-a\nwork\n gios-b \n"), ["gios-a", "gios-b"])
    }
}

/// Panes run in zmx sessions on the host, so they survive the app being
/// closed: the layout is saved and the same sessions are attached again.
@MainActor
final class SessionPersistenceTests: XCTestCase {
    private let host = Host(name: "test", hostname: "localhost", username: "me")
    private var archiveURL: URL!
    private var backends: [FakeBackend] = []

    override func setUp() async throws {
        archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspaces-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        for backend in backends { backend.continuation.finish() }
        try? FileManager.default.removeItem(at: archiveURL)
    }

    private var mine: String { ZmxSession.devicePrefix(HostSessions.deviceTag) }

    /// A store whose workspaces never connect.
    private func makeStore(_ archive: WorkspaceArchive) -> WorkspaceStore {
        WorkspaceStore(archive: archive) { host, layout, sessions in
            TerminalWorkspace(host: host, layout: layout, sessions: sessions) { _ in }
        }
    }

    private func zmxRecord() -> HostSessionRecord {
        HostSessionRecord(probe: ZmxSession.Probe(zmx: "/opt/homebrew/bin/zmx"))
    }

    func testLayoutRoundTrips() throws {
        let workspace = TerminalWorkspace(host: host) { _ in }
        workspace.perform(.newTab)
        workspace.splitFocused(.right)
        workspace.perform(.toggleSplitZoom)

        let layout = workspace.layout
        let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)

        let restored = TerminalWorkspace(host: host, layout: decoded) { _ in }
        XCTAssertEqual(restored.tabs, workspace.tabs)
        XCTAssertEqual(restored.selectedTabID, workspace.selectedTabID)
        XCTAssertEqual(restored.focusedPane?.id, workspace.focusedPane?.id)
        XCTAssertEqual(restored.panes.mapValues(\.sessionName), workspace.panes.mapValues(\.sessionName))
        XCTAssertTrue(restored.panes.values.allSatisfy { $0.sessionName.hasPrefix(mine) })
    }

    func testRestoresTabsAfterRelaunch() async throws {
        let archive = WorkspaceArchive(url: archiveURL)
        archive.setRecord(zmxRecord(), for: host.id)
        let store = makeStore(archive)
        let workspace = store.workspace(for: host)
        workspace.perform(.newTab)
        workspace.splitFocused()
        let saved = await waitUntil { archive.layout(for: self.host.id) == workspace.layout }
        XCTAssertTrue(saved, "the layout is saved as it changes")

        // The app is closed and launched again.
        let relaunched = makeStore(WorkspaceArchive(url: archiveURL))
        XCTAssertEqual(relaunched.savedTabCount(for: host), 2, "the host list shows the tabs before opening")
        XCTAssertTrue(relaunched.hasSessions(host))
        let restored = relaunched.workspace(for: host)
        XCTAssertEqual(restored.tabs, workspace.tabs)
        XCTAssertEqual(restored.panes.mapValues(\.sessionName), workspace.panes.mapValues(\.sessionName))
        XCTAssertNil(relaunched.savedTabCount(for: host), "now open")

        // Ending them kills every session on the host and forgets the layout.
        let fake = FakeZmxHost(sessions: Array(workspace.panes.values.map(\.sessionName)))
        relaunched.sessions(for: host).runner = fake.runner
        relaunched.endSessions(host)
        let killed = await waitUntil { fake.sessions.isEmpty }
        XCTAssertTrue(killed, "commands: \(fake.commands)")
        XCTAssertNil(relaunched.openWorkspace(for: host))
        XCTAssertNil(WorkspaceArchive(url: archiveURL).layout(for: host.id))
    }

    func testWorkspaceWithoutZmxIsNotSaved() async throws {
        let archive = WorkspaceArchive(url: archiveURL)
        let workspace = makeStore(archive).workspace(for: host)
        workspace.perform(.newTab)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertNil(archive.layout(for: host.id), "plain shells don't survive, so there's nothing to restore")
    }

    func testPrepareProbesAndAttaches() async throws {
        let fake = FakeZmxHost()
        let sessions = HostSessions(host: host)
        let command = await sessions.prepare(session: "gios-test-1", run: fake.runner)
        XCTAssertEqual(command, ZmxSession.attachCommand(zmx: "/opt/homebrew/bin/zmx", name: "gios-test-1"))
        XCTAssertTrue(sessions.available)
        XCTAssertFalse(sessions.missing)

        // Without zmx, a plain shell, and an offer to install it.
        fake.zmx = nil
        let plain = await sessions.prepare(session: "gios-test-1", run: fake.runner)
        XCTAssertNil(plain)
        XCTAssertTrue(sessions.missing)
        XCTAssertEqual(sessions.probe?.brew, "/opt/homebrew/bin/brew")

        // Turned off for the host: no probe at all.
        var off = host
        off.keepsSessions = false
        let disabled = HostSessions(host: off)
        let count = fake.commands.count
        let none = await disabled.prepare(session: "gios-test-1", run: fake.runner)
        XCTAssertNil(none)
        XCTAssertEqual(fake.commands.count, count)
        XCTAssertFalse(disabled.missing)
    }

    func testDetachedSessionIsStillRunning() async throws {
        let fake = FakeZmxHost(sessions: ["gios-test-1"])
        let sessions = HostSessions(host: host, record: zmxRecord())
        let running = await sessions.isRunning("gios-test-1", run: fake.runner)
        XCTAssertTrue(running)
        let exited = await sessions.isRunning("gios-test-2", run: fake.runner)
        XCTAssertFalse(exited)
    }

    func testSessionsEndedOfflineAreKilledOnTheNextConnect() async throws {
        let fake = FakeZmxHost(sessions: ["gios-test-1", "gios-test-2"])
        fake.offline = true
        let sessions = HostSessions(host: host, record: zmxRecord())
        sessions.runner = fake.runner
        sessions.end(["gios-test-1"])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(sessions.pendingKills, ["gios-test-1"], "kept until the host is reachable")

        fake.offline = false
        let command = await sessions.prepare(session: "gios-test-2", run: fake.runner)
        XCTAssertNotNil(command)
        XCTAssertEqual(fake.sessions, ["gios-test-2"])
        XCTAssertEqual(sessions.pendingKills, [])
    }

    func testClosingAPaneEndsItsSession() async throws {
        let sessions = HostSessions(host: host, record: zmxRecord())
        let fake = FakeZmxHost()
        sessions.runner = fake.runner
        let workspace = TerminalWorkspace(host: host, sessions: sessions) { _ in }
        workspace.splitFocused()
        let doomed = try XCTUnwrap(workspace.focusedPane)
        workspace.close(doomed.id)
        let killed = await waitUntil { fake.commands.contains { $0.contains(" kill ") && $0.contains(doomed.sessionName) } }
        XCTAssertTrue(killed, "commands: \(fake.commands)")
    }

    func testAdoptsThisDevicesSessionsThatNoPaneShows() async throws {
        let sessions = HostSessions(host: host, record: zmxRecord())
        let workspace = TerminalWorkspace(host: host, sessions: sessions) { _ in }
        let own = try XCTUnwrap(workspace.focusedPane?.sessionName)
        let orphan = mine + "aaaa1111"
        let otherDevice = ZmxSession.devicePrefix(HostSessions.deviceTag == "ffff" ? "eeee" : "ffff") + "bbbb2222"
        let fake = FakeZmxHost(sessions: [own, orphan, otherDevice, "work"])

        _ = await sessions.prepare(session: own, run: fake.runner)
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(Set(workspace.panes.values.map(\.sessionName)), [own, orphan])
    }

    // MARK: Attaching again

    /// A workspace whose panes run "in zmx" over fake backends.
    private func attachingWorkspace() throws -> (TerminalWorkspace, () -> [TerminalSurfaceView]) {
        let app = try XCTUnwrap(GhosttyRuntime.shared.app)
        var views: [TerminalSurfaceView] = []
        let workspace = TerminalWorkspace(host: host) { [weak self] pane in
            let backend = FakeBackend()
            self?.backends.append(backend)
            let view = TerminalSurfaceView(app: app, backend: backend)
            view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
            views.append(view)
            pane.attachedToSession = true
            await pane.run(view)
        }
        workspace.waitToRetry = { _ in }
        workspace.start()
        return (workspace, { views })
    }

    func testDroppedSessionAttachesAgainWithoutABlankScreen() async throws {
        let (workspace, views) = try attachingWorkspace()
        let pane = try XCTUnwrap(workspace.focusedPane)
        _ = await waitUntil { self.backends.count == 1 }
        backends[0].continuation.yield(.output(Data("hello".utf8)))
        let first = try XCTUnwrap(views().first)
        XCTAssertTrue(pane.surfaceView === first)

        // The connection drops: attach again.
        backends[0].continuation.yield(.exited(code: nil, message: "Disconnected"))
        backends[0].continuation.finish()
        let again = await waitUntil { self.backends.count == 2 }
        XCTAssertTrue(again)
        XCTAssertTrue(pane.surfaceView === first, "the old screen stays until zmx redraws")
        XCTAssertTrue(pane.reconnecting)

        backends[1].continuation.yield(.output(Data("\u{1B}[2J\u{1B}[Hhello".utf8)))
        let swapped = await waitUntil { pane.surfaceView === views()[1] }
        XCTAssertTrue(swapped)
        XCTAssertFalse(pane.reconnecting)
        XCTAssertFalse(pane.ended)

        // The shell exits: the pane closes, nothing attaches again.
        try await Task.sleep(nanoseconds: 300_000_000)
        backends[1].continuation.yield(.exited(code: 0, message: nil))
        backends[1].continuation.finish()
        let closed = await waitUntil { workspace.closed }
        XCTAssertTrue(closed)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(backends.count, 2)
    }

    func testSuspendDetachesAndResumeAttachesAgain() async throws {
        let (workspace, _) = try attachingWorkspace()
        let pane = try XCTUnwrap(workspace.focusedPane)
        _ = await waitUntil { self.backends.count == 1 }

        var paused = true
        workspace.waitToRetry = { _ in
            while paused { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        workspace.suspend()
        let waiting = await waitUntil { pane.ended && pane.reconnecting }
        XCTAssertTrue(waiting, "a suspended pane waits to attach again")
        XCTAssertNotNil(workspace.panes[pane.id])
        XCTAssertEqual(backends.count, 1)

        paused = false
        let again = await waitUntil { self.backends.count == 2 }
        XCTAssertTrue(again)
    }
}

/// Runs against a real sshd with zmx installed on it. Skipped unless the
/// SSH variables (see SSHIntegrationTests) and GHOSTTY_TEST_ZMX are set.
final class ZmxIntegrationTests: XCTestCase {
    /// Collects a backend's output and how it ended.
    private final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var _output = ""
        private var _exit: (code: Int32?, message: String?)?
        var output: String { lock.withLock { _output } }
        var exit: (code: Int32?, message: String?)? { lock.withLock { _exit } }

        init(_ backend: SSHBackend) {
            Task {
                for await event in backend.events {
                    switch event {
                    case .output(let data):
                        lock.withLock { _output += String(decoding: data, as: UTF8.self) }
                    case .exited(let code, let message):
                        lock.withLock { _exit = (code, message) }
                    }
                }
            }
        }
    }

    @MainActor
    func testSessionSurvivesTheConnection() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portString = env["GHOSTTY_TEST_SSH_PORT"], let port = Int(portString),
              let user = env["GHOSTTY_TEST_SSH_USER"],
              let seedHex = env["GHOSTTY_TEST_SSH_KEY_SEED"],
              env["GHOSTTY_TEST_ZMX"] != nil else {
            throw XCTSkip("zmx integration environment not configured")
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hex: seedHex))
        let host = Host(name: "test", hostname: "127.0.0.1", port: port, username: user)
        let credentials = SSHCredentials(username: user, deviceKey: key, password: nil)
        KnownHosts.shared.forget(endpoint: host.endpoint)
        defer { KnownHosts.shared.forget(endpoint: host.endpoint) }

        let sessions = HostSessions(host: host)
        let name = ZmxSession.name(for: UUID(), device: "test")
        let size = TerminalSize(columns: 80, rows: 24, widthPixels: 0, heightPixels: 0)
        func makeBackend() -> SSHBackend {
            SSHBackend(
                host: host, credentials: credentials,
                approveUnknownHostKey: { _ in true },
                command: { run in await sessions.prepare(session: name, run: run) },
                sessionLivesOn: { run in await sessions.isRunning(name, run: run) })
        }

        // Attach, run something, then lose the connection.
        let first = makeBackend()
        let one = Session(first)
        let started = Task { try await first.start(size: size) }
        let ready = await waitUntil(timeout: 15) { !one.output.isEmpty }
        XCTAssertTrue(ready, "no output")
        XCTAssertNotNil(sessions.probe?.zmx, "zmx wasn't found on the host")
        first.write(Data("echo marker-$((40+2))\r".utf8))
        let ran = await waitUntil(timeout: 5) { one.output.contains("marker-42") }
        XCTAssertTrue(ran, one.output)
        first.close()
        try await started.value
        let dropped = await waitUntil(timeout: 5) { one.exit != nil }
        XCTAssertTrue(dropped)
        XCTAssertNil(one.exit?.code ?? nil, "closing from our side is a drop, not an exit")

        // A new connection picks up the same shell, screen and all.
        let second = makeBackend()
        let two = Session(second)
        let resumed = Task { try await second.start(size: size) }
        let replayed = await waitUntil(timeout: 15) { two.output.contains("marker-42") }
        XCTAssertTrue(replayed, two.output)

        // Exiting the shell ends the session for good.
        second.write(Data("exit\r".utf8))
        try await resumed.value
        let exited = await waitUntil(timeout: 5) { two.exit != nil }
        XCTAssertTrue(exited)
        XCTAssertEqual(two.exit?.code, 0, two.exit?.message ?? "")
        let list = try await SSHBackend.run(ZmxSession.listCommand(zmx: XCTUnwrap(sessions.probe?.zmx)),
                                            on: host, credentials: credentials)
        XCTAssertFalse(ZmxSession.parseList(String(decoding: list, as: UTF8.self)).contains(name))
    }
}
