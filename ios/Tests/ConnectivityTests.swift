import CryptoKit
import XCTest
@testable import GhosttyiOS

// MARK: Routes

final class HostRouteTests: XCTestCase {
    func testKindIsInferredFromTheAddress() {
        XCTAssertEqual(HostRoute.kind(of: "100.64.0.5"), .tailnet)
        XCTAssertEqual(HostRoute.kind(of: "100.127.255.1"), .tailnet)
        XCTAssertEqual(HostRoute.kind(of: "fd7a:115c:a1e0::1"), .tailnet)
        XCTAssertEqual(HostRoute.kind(of: "mac.tail1234.ts.net"), .tailnet)
        XCTAssertEqual(HostRoute.kind(of: "Brendans-Mac.local"), .lan)
        XCTAssertEqual(HostRoute.kind(of: "192.168.1.20"), .lan)
        XCTAssertEqual(HostRoute.kind(of: "10.0.0.2"), .lan)
        XCTAssertEqual(HostRoute.kind(of: "172.20.1.1"), .lan)
        XCTAssertEqual(HostRoute.kind(of: "fe80::1"), .lan)
        XCTAssertEqual(HostRoute.kind(of: "100.128.0.1"), .other, "outside 100.64.0.0/10")
        XCTAssertEqual(HostRoute.kind(of: "example.com"), .other)
        XCTAssertEqual(HostRoute.kind(of: "203.0.113.4"), .other)
    }

    func testHostsSavedBeforeRoutesStillLoad() throws {
        let id = UUID()
        let json = """
            {"id":"\(id.uuidString)","name":"Mac","hostname":"mac.local","port":22,"username":"me"}
            """
        let host = try JSONDecoder().decode(Host.self, from: Data(json.utf8))
        XCTAssertEqual(host.learnedRoutes, [])
        XCTAssertEqual(host.routes, [HostRoute(address: "mac.local", port: 22, kind: .lan)])
    }

    func testTailnetRoutesComeFirstAndLearningReplacesOldOnes() {
        var host = Host(name: "Mac", hostname: "mac.local", username: "me")
        XCTAssertTrue(host.learn([HostRoute(address: "100.64.0.7", kind: .tailnet)]))
        XCTAssertEqual(host.routes.map(\.address), ["100.64.0.7", "mac.local"])

        XCTAssertFalse(host.learn([HostRoute(address: "100.64.0.7", kind: .tailnet)]), "already known")
        XCTAssertFalse(host.learn([HostRoute(address: "mac.local", kind: .lan)]), "the entered address")

        // The Mac rejoined the tailnet with a new address.
        XCTAssertTrue(host.learn([HostRoute(address: "100.64.0.9", kind: .tailnet)]))
        XCTAssertEqual(host.learnedRoutes.map(\.address), ["100.64.0.9"])

        // Round-trips through JSON.
        let decoded = try? JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))
        XCTAssertEqual(decoded?.routes, host.routes)
    }
}

// MARK: Host keys

final class PerHostKnownHostsTests: XCTestCase {
    private let keyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
    private let keyB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB9IaEqHBHSHnTbqNWW6g5x7xoRZOtnmOubHsR0gH5qG"

    private func store() -> KnownHosts {
        KnownHosts(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("known-\(UUID().uuidString).json"))
    }

    func testAKeyTrustedOverOneRouteIsRequiredOnEvery() {
        let known = store()
        var host = Host(name: "Mac", hostname: "mac.local", username: "me")
        known.trust(host: host, key: keyA)

        // Reached over the tailnet: same host, so the same key is trusted...
        host.learn([HostRoute(address: "100.64.0.7", kind: .tailnet)])
        XCTAssertEqual(known.check(host: host, key: keyA), .trusted)
        // ...and a different key is a mismatch, not a new host to trust.
        guard case .mismatch = known.check(host: host, key: keyB) else {
            return XCTFail("a different key on another route must not be trusted")
        }
    }

    func testKeysSavedPerAddressMoveToTheHost() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("known-\(UUID().uuidString).json")
        let host = Host(name: "Mac", hostname: "Mac.local", username: "me")
        // As saved by an earlier version, keyed by hostname:port.
        try JSONEncoder().encode(["mac.local:22": keyA]).write(to: url)

        let known = KnownHosts(url: url)
        XCTAssertEqual(known.check(host: host, key: keyA), .trusted)
        XCTAssertNotNil(known.fingerprint(host: host))

        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        XCTAssertEqual(Array(saved.keys), [KnownHosts.entry(for: host)])

        known.forget(host: host)
        guard case .unknown = known.check(host: host, key: keyA) else { return XCTFail("forgotten") }
    }
}

// MARK: Probe

final class HostProbeTests: XCTestCase {
    func testProbeReadsTheTailnetAddressLocalNameAndSleep() {
        let probe = ZmxSession.parseProbe("""
            zmx /opt/homebrew/bin/zmx
            tailnet 100.64.0.7
            local Brendans-Mac.local
            sleep 1
            """)
        XCTAssertEqual(probe.tailnetIP, "100.64.0.7")
        XCTAssertEqual(probe.localName, "Brendans-Mac.local")
        XCTAssertEqual(probe.sleepMinutes, 1)
        XCTAssertTrue(probe.sleeps)
        XCTAssertEqual(probe.routes, [
            HostRoute(address: "100.64.0.7", kind: .tailnet),
            HostRoute(address: "Brendans-Mac.local", kind: .lan),
        ])
    }

    func testProbeIgnoresAnythingThatIsntATailnetAddress() {
        let probe = ZmxSession.parseProbe("tailnet 192.168.1.4\nlocal .local\nsleep 0\n")
        XCTAssertNil(probe.tailnetIP)
        XCTAssertNil(probe.localName)
        XCTAssertFalse(probe.sleeps)
        XCTAssertEqual(probe.routes, [])
    }

    func testAttachKeepsTheMacAwakeWhereItCan() {
        let command = ZmxSession.attachCommand(zmx: "/opt/homebrew/bin/zmx", name: "gios-ab12-12345678")
        XCTAssertTrue(command.contains("caffeinate -i"))
        XCTAssertTrue(command.contains("ZMX_NO_DETACH_KEY=1"))
    }

    @MainActor
    func testProbeTeachesTheHostItsRoutes() async {
        let host = Host(name: "Mac", hostname: "mac.local", username: "me")
        let sessions = HostSessions(host: host)
        var learned: [HostRoute] = []
        sessions.onRoutesFound = { learned = $0 }
        _ = await sessions.prepare(session: "gios-x", run: { _ in Data("tailnet 100.64.0.7\n".utf8) })
        XCTAssertEqual(learned, [HostRoute(address: "100.64.0.7", kind: .tailnet)])
        XCTAssertEqual(sessions.host.routes.first?.address, "100.64.0.7")

        // Nothing new the second time.
        learned = []
        _ = await sessions.prepare(session: "gios-x", run: { _ in Data("tailnet 100.64.0.7\n".utf8) })
        XCTAssertEqual(learned, [])
    }
}

// MARK: Dialing

final class RouteDialerTests: XCTestCase {
    private let tailnet = HostRoute(address: "100.64.0.7", kind: .tailnet)
    private let lan = HostRoute(address: "mac.local", kind: .lan)
    private let other = HostRoute(address: "example.com", kind: .other)

    func testOrderPrefersTheTailnetOnlyWhenItsUp() {
        XCTAssertEqual(RouteDialer.order([lan, other, tailnet], tunnelUp: true), [tailnet, lan, other])
        XCTAssertEqual(RouteDialer.order([tailnet, lan, other], tunnelUp: false), [lan, other, tailnet])
        let lan2 = HostRoute(address: "192.168.1.4", kind: .lan)
        XCTAssertEqual(RouteDialer.order([lan, lan2], tunnelUp: false, preferred: lan2), [lan2, lan])
    }

    /// Records dials and what was discarded.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _dialed: [String] = []
        private var _discarded: [String] = []
        var dialed: [String] { lock.withLock { _dialed } }
        var discarded: [String] { lock.withLock { _discarded } }
        func dial(_ s: String) { lock.withLock { _dialed.append(s) } }
        func discard(_ s: String) { lock.withLock { _discarded.append(s) } }
    }

    func testASlowRouteDoesntHoldUpTheNext() async throws {
        let log = Log()
        let start = ContinuousClock.now
        let (route, value) = try await RouteDialer.race([tailnet, lan], headStart: .milliseconds(100)) { route in
            log.dial(route.address)
            if route == self.tailnet { try await Task.sleep(for: .seconds(1)) }
            return route.address
        } discard: { log.discard($0) }
        XCTAssertEqual(route, lan)
        XCTAssertEqual(value, "mac.local")
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(800))

        // The slow route finishing later is thrown away.
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(log.discarded, ["100.64.0.7"])
    }

    func testTheFirstRouteWinsWhenItsQuick() async throws {
        let log = Log()
        let (route, _) = try await RouteDialer.race([tailnet, lan], headStart: .milliseconds(300)) { route in
            log.dial(route.address)
            return route.address
        } discard: { log.discard($0) }
        XCTAssertEqual(route, tailnet)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(log.dialed, ["100.64.0.7"], "the next route never started")
    }

    func testUnstaggeredTriesOneAtATime() async throws {
        let log = Log()
        let (route, _) = try await RouteDialer.race([tailnet, lan], staggered: false, headStart: .milliseconds(10)) { route in
            log.dial(route.address)
            if route == self.tailnet {
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(log.dialed, ["100.64.0.7"], "the second waits for the first to fail")
                throw URLError(.timedOut)
            }
            return route.address
        } discard: { log.discard($0) }
        XCTAssertEqual(route, lan)
    }

    func testAChangedHostKeyIsReportedOverOtherFailures() async {
        do {
            _ = try await RouteDialer.race([tailnet, lan, other], headStart: .milliseconds(10)) { route -> String in
                switch route.kind {
                case .tailnet: throw URLError(.timedOut)
                case .lan: throw SSHSessionError.hostKeyMismatch(expected: "a", presented: "b")
                case .other: throw SSHSessionError.authenticationFailed
                }
            } discard: { _ in }
            XCTFail("expected a failure")
        } catch SSHSessionError.hostKeyMismatch {
        } catch {
            XCTFail("expected the host key mismatch, got \(error)")
        }
    }
}

// MARK: Network changes

final class NetworkChangeTests: XCTestCase {
    private func snapshot(_ type: NetworkMonitor.Snapshot.InterfaceKind, gateway: String = "192.168.1.1",
                          address: String = "192.168.1.20", tunnel: Bool = false,
                          satisfied: Bool = true) -> NetworkMonitor.Snapshot {
        NetworkMonitor.Snapshot(
            satisfied: satisfied, interface: type == .wifi ? "en0" : "pdp_ip0", interfaceType: type,
            gateways: [gateway], addresses: [address], tunnel: tunnel)
    }

    func testChanges() {
        let home = snapshot(.wifi)
        XCTAssertEqual(NetworkMonitor.changes(from: home, to: home), [])
        XCTAssertEqual(NetworkMonitor.changes(from: home, to: snapshot(.cellular, gateway: "", address: "10.20.30.40")),
                       [.switched])
        XCTAssertEqual(NetworkMonitor.changes(from: home, to: snapshot(.wifi, gateway: "10.0.0.1", address: "10.0.0.5")),
                       [.switched], "another Wi-Fi network")
        XCTAssertEqual(NetworkMonitor.changes(from: home, to: snapshot(.wifi, gateway: "192.168.1.1", address: "192.168.0.9")),
                       [.switched], "another network with the same gateway address")
        XCTAssertEqual(NetworkMonitor.changes(from: home, to: snapshot(.wifi, satisfied: false)), [.wentDown])
        XCTAssertEqual(NetworkMonitor.changes(from: snapshot(.wifi, satisfied: false), to: snapshot(.cellular)), [.cameUp])
        XCTAssertEqual(NetworkMonitor.changes(from: home, to: snapshot(.wifi, tunnel: true)), [.tunnelUp])
        XCTAssertEqual(NetworkMonitor.changes(from: snapshot(.wifi, tunnel: true), to: home), [.tunnelDown])
    }

    func testReactions() {
        let lanPane = NetworkReaction.Pane(id: UUID(), route: .lan, connected: true, attached: true)
        let tailnetPane = NetworkReaction.Pane(id: UUID(), route: .tailnet, connected: true, attached: true)
        let plainShell = NetworkReaction.Pane(id: UUID(), route: .lan, connected: true, attached: false)
        let ended = NetworkReaction.Pane(id: UUID(), route: .lan, connected: false, attached: true)
        let panes = [lanPane, tailnetPane, plainShell, ended]

        // Onto cellular: the local-network connection is gone, the tailnet
        // one is checked; plain shells and ended panes are left alone.
        let toCellular = NetworkReaction.actions(for: [.switched], on: snapshot(.cellular), panes: panes)
        XCTAssertEqual(toCellular, [lanPane.id: .drop, tailnetPane.id: .check])

        // Onto another Wi-Fi: either may have survived.
        let toWifi = NetworkReaction.actions(for: [.switched], on: snapshot(.wifi), panes: panes)
        XCTAssertEqual(toWifi, [lanPane.id: .check, tailnetPane.id: .check])

        // The tunnel went down: check connections over it.
        let down = NetworkReaction.actions(for: [.tunnelDown], on: snapshot(.wifi), panes: panes)
        XCTAssertEqual(down, [tailnetPane.id: .check])
    }

    func testMovingToTheTailnet() {
        let routes = [HostRoute(address: "mac.local", kind: .lan), HostRoute(address: "100.64.0.7", kind: .tailnet)]
        XCTAssertTrue(NetworkReaction.shouldMoveToTailnet(route: .lan, connected: true, attached: true, hostRoutes: routes))
        XCTAssertFalse(NetworkReaction.shouldMoveToTailnet(route: .tailnet, connected: true, attached: true, hostRoutes: routes))
        XCTAssertFalse(NetworkReaction.shouldMoveToTailnet(route: .lan, connected: true, attached: false, hostRoutes: routes),
                       "a plain shell can't move")
        XCTAssertFalse(NetworkReaction.shouldMoveToTailnet(route: .lan, connected: true, attached: true,
                                                           hostRoutes: [routes[0]]), "no tailnet route")
    }
}

// MARK: Handing off

/// A fake backend that can be asked whether it's alive.
final class CheckableBackend: TerminalBackend, LivenessChecking, @unchecked Sendable {
    let events: AsyncStream<TerminalBackendEvent>
    let continuation: AsyncStream<TerminalBackendEvent>.Continuation
    private let lock = NSLock()
    private var _written = Data()
    private var _closed = false
    private var _alive = true

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    var written: String { lock.withLock { String(decoding: _written, as: UTF8.self) } }
    var closed: Bool { lock.withLock { _closed } }
    var alive: Bool {
        get { lock.withLock { _alive } }
        set { lock.withLock { _alive = newValue } }
    }

    func start(size: TerminalSize) async throws {}
    func write(_ data: Data) { lock.withLock { _written.append(data) } }
    func resize(_ size: TerminalSize) {}
    func close() {
        lock.withLock { _closed = true }
        continuation.yield(.exited(code: nil, message: nil))
        continuation.finish()
    }
    func isAlive(within timeout: Duration) async -> Bool { alive }
}

@MainActor
final class HandOffTests: XCTestCase {
    private let host = Host(name: "test", hostname: "mac.local", username: "me")
    private var backends: [CheckableBackend] = []
    private var views: [TerminalSurfaceView] = []

    /// Makes `pane` connect "over the LAN" and hand off "over the
    /// tailnet", through fake backends.
    private func install(on pane: TerminalPane) throws {
        let app = try XCTUnwrap(GhosttyRuntime.shared.app)
        pane.connectionMaker = { [unowned self, weak pane] handingOff in
            let backend = CheckableBackend()
            self.backends.append(backend)
            let view = TerminalSurfaceView(app: app, backend: backend)
            view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
            self.views.append(view)
            if !handingOff { pane?.attachedToSession = true }
            let route = handingOff ? HostRoute(address: "100.64.0.7", kind: .tailnet)
                                   : HostRoute(address: "mac.local", kind: .lan)
            return (view, BackendLink(backend: backend, route: route))
        }
    }

    private func makePane() throws -> TerminalPane {
        let pane = TerminalPane(host: host)
        try install(on: pane)
        return pane
    }

    /// A workspace whose panes connect through `install(on:)`.
    private func makeWorkspace(host: Host) -> TerminalWorkspace {
        let workspace = TerminalWorkspace(host: host) { [unowned self] pane in
            if pane.connectionMaker == nil { try? self.install(on: pane) }
            await pane.connect()
        }
        workspace.waitToRetry = { _ in }
        return workspace
    }

    func testHandOffSwapsOnlyOnceTheNewConnectionHasDrawn() async throws {
        let pane = try makePane()
        let run = Task { await pane.connect() }
        _ = await waitUntil { self.backends.count == 1 }
        backends[0].continuation.yield(.output(Data("hello".utf8)))
        XCTAssertEqual(pane.route?.kind, .lan)
        XCTAssertTrue(pane.isConnected)

        pane.handOff()
        _ = await waitUntil { self.backends.count == 2 }
        XCTAssertTrue(pane.isHandingOff)

        // Until the new connection draws, keys go to the old one.
        views[0].insertText("a")
        let toOld = await waitUntil { self.backends[0].written.contains("a") }
        XCTAssertTrue(toOld)
        XCTAssertTrue(pane.surfaceView === views[0])

        // zmx redraws the screen on the new connection: it takes over.
        backends[1].continuation.yield(.output(Data("\u{1B}[2J\u{1B}[Hhello".utf8)))
        let swapped = await waitUntil { pane.surfaceView === self.views[1] }
        XCTAssertTrue(swapped)
        XCTAssertEqual(pane.route?.kind, .tailnet)

        views[1].insertText("b")
        let toNew = await waitUntil { self.backends[1].written.contains("b") }
        XCTAssertTrue(toNew)
        XCTAssertFalse(backends[0].written.contains("b"), "no key goes to both")
        XCTAssertFalse(backends[1].written.contains("a"), "no key is sent twice")

        // The old connection is let go, and the pane carries on.
        let closed = await waitUntil { self.backends[0].closed }
        XCTAssertTrue(closed)
        let settled = await waitUntil { !pane.isHandingOff }
        XCTAssertTrue(settled)
        XCTAssertFalse(pane.ended)

        // The session ends on the new connection.
        backends[1].continuation.yield(.exited(code: 0, message: nil))
        backends[1].continuation.finish()
        await run.value
        XCTAssertTrue(pane.ended)
    }

    func testAFailedHandOffLeavesTheOldConnection() async throws {
        let pane = try makePane()
        let run = Task { await pane.connect() }
        _ = await waitUntil { self.backends.count == 1 }
        backends[0].continuation.yield(.output(Data("hello".utf8)))

        pane.handOff()
        _ = await waitUntil { self.backends.count == 2 }
        // The new connection fails before drawing anything.
        backends[1].continuation.yield(.exited(code: nil, message: "Connection refused"))
        backends[1].continuation.finish()
        let gaveUp = await waitUntil { !pane.isHandingOff }
        XCTAssertTrue(gaveUp)
        XCTAssertTrue(pane.surfaceView === views[0])
        XCTAssertFalse(backends[0].closed)
        XCTAssertEqual(pane.route?.kind, .lan)

        views[0].insertText("c")
        let stillWorks = await waitUntil { self.backends[0].written.contains("c") }
        XCTAssertTrue(stillWorks)

        backends[0].continuation.yield(.exited(code: 0, message: nil))
        backends[0].continuation.finish()
        await run.value
    }

    func testSwitchingNetworksDropsOnlyDeadConnections() async throws {
        let workspace = makeWorkspace(host: host)
        workspace.start()
        let pane = try XCTUnwrap(workspace.focusedPane)
        _ = await waitUntil { self.backends.count == 1 }
        backends[0].continuation.yield(.output(Data("hello".utf8)))
        _ = await waitUntil { pane.isConnected }

        // Another Wi-Fi network, and the connection still answers: kept.
        let wifi = NetworkMonitor.Snapshot(satisfied: true, interface: "en0", interfaceType: .wifi,
                                           gateways: ["10.0.0.1"], addresses: ["10.0.0.5"])
        workspace.networkChanged([.switched], wifi)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(backends.count, 1)
        XCTAssertFalse(backends[0].closed)

        // It stops answering after the next change: attached again.
        backends[0].alive = false
        workspace.networkChanged([.switched], wifi)
        let again = await waitUntil { self.backends.count == 2 }
        XCTAssertTrue(again)
        XCTAssertTrue(backends[0].closed)

        // Onto cellular from a local-network route: dropped without asking.
        backends[1].continuation.yield(.output(Data("hello".utf8)))
        _ = await waitUntil { pane.surfaceView === self.views[1] }
        let cellular = NetworkMonitor.Snapshot(satisfied: true, interface: "pdp_ip0", interfaceType: .cellular,
                                               gateways: [], addresses: ["10.20.30.40"])
        workspace.networkChanged([.switched], cellular)
        let dropped = await waitUntil { self.backends.count == 3 }
        XCTAssertTrue(dropped)
        XCTAssertTrue(backends[1].closed)
    }

    func testTheTunnelComingUpMovesConnectionsOntoIt() async throws {
        var tailnetHost = host
        tailnetHost.learn([HostRoute(address: "100.64.0.7", kind: .tailnet)])
        let workspace = makeWorkspace(host: tailnetHost)
        workspace.upgradeDelay = .milliseconds(200)
        workspace.start()
        let pane = try XCTUnwrap(workspace.focusedPane)
        _ = await waitUntil { self.backends.count == 1 }
        backends[0].continuation.yield(.output(Data("hello".utf8)))
        _ = await waitUntil { pane.isConnected }
        XCTAssertEqual(pane.route?.kind, .lan)

        // A tunnel that blips doesn't trigger a move.
        var network = workspace.network
        network.tunnel = true
        workspace.networkChanged([.tunnelUp], network)
        network.tunnel = false
        workspace.networkChanged([.tunnelDown], network)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(backends.count, 1)

        // One that stays up does.
        network.tunnel = true
        workspace.networkChanged([.tunnelUp], network)
        let moving = await waitUntil { self.backends.count == 2 }
        XCTAssertTrue(moving)
        backends[1].continuation.yield(.output(Data("hello".utf8)))
        let moved = await waitUntil { pane.route?.kind == .tailnet }
        XCTAssertTrue(moved)
        let released = await waitUntil { self.backends[0].closed }
        XCTAssertTrue(released)
        XCTAssertFalse(pane.ended)
    }
}

// MARK: Integration

/// Runs against a real sshd. Skipped unless the SSH variables (see
/// SSHIntegrationTests) are set. The sshd must listen on both 127.0.0.1
/// and ::1.
final class RouteIntegrationTests: XCTestCase {
    private func environment() throws -> (port: Int, user: String, key: Curve25519.Signing.PrivateKey) {
        let env = ProcessInfo.processInfo.environment
        guard let portString = env["GHOSTTY_TEST_SSH_PORT"], let port = Int(portString),
              let user = env["GHOSTTY_TEST_SSH_USER"],
              let seedHex = env["GHOSTTY_TEST_SSH_KEY_SEED"] else {
            throw XCTSkip("SSH integration environment not configured")
        }
        return (port, user, try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hex: seedHex)))
    }

    /// A route that never answers (the SYN goes nowhere) doesn't hold up
    /// one that works, and a route presenting the host's key is trusted
    /// without asking.
    func testAWorkingRouteWinsOverOneThatHangs() async throws {
        let (port, user, key) = try environment()
        var host = Host(name: "test", hostname: "127.0.0.1", port: port, username: user)
        KnownHosts.shared.forget(host: host)
        defer { KnownHosts.shared.forget(host: host) }
        let credentials = SSHCredentials(username: user, deviceKey: key, password: nil)

        // Trust the key over the first route.
        let first = try await SSHBackend.connect(host: host, credentials: credentials) { _ in true }
        try await first.client.close()
        XCTAssertEqual(first.route.address, "127.0.0.1")

        // Now a blackholed "local network" route is tried first, and ::1
        // second, and the entered address last.
        host.hostname = "10.255.255.1"
        host.learn([HostRoute(address: "::1", port: port, kind: .other)])
        let start = ContinuousClock.now
        let second = try await SSHBackend.connect(host: host, credentials: credentials) { _ in
            XCTFail("the host's key was already trusted")
            return false
        }
        try await second.client.close()
        XCTAssertEqual(second.route.address, "::1")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(4))
    }

    /// Two connections attach to the same zmx session; the first can go
    /// once the second is attached, and the shell carries on.
    @MainActor
    func testASessionMovesToASecondConnection() async throws {
        let (port, user, key) = try environment()
        guard ProcessInfo.processInfo.environment["GHOSTTY_TEST_ZMX"] != nil else {
            throw XCTSkip("zmx integration environment not configured")
        }
        let host = Host(name: "test", hostname: "127.0.0.1", port: port, username: user)
        KnownHosts.shared.forget(host: host)
        defer { KnownHosts.shared.forget(host: host) }
        let credentials = SSHCredentials(username: user, deviceKey: key, password: nil)
        let sessions = HostSessions(host: host)
        let name = ZmxSession.name(for: UUID(), device: "test")
        let size = TerminalSize(columns: 80, rows: 24, widthPixels: 0, heightPixels: 0)

        final class Output: @unchecked Sendable {
            private let lock = NSLock()
            private var text = ""
            var value: String { lock.withLock { text } }
            init(_ backend: SSHBackend) {
                Task { for await case .output(let data) in backend.events {
                    lock.withLock { text += String(decoding: data, as: UTF8.self) }
                } }
            }
        }
        func makeBackend() -> SSHBackend {
            SSHBackend(host: host, credentials: credentials, approveUnknownHostKey: { _ in true },
                       command: { run in await sessions.prepare(session: name, run: run) },
                       sessionLivesOn: { run in await sessions.isRunning(name, run: run) })
        }

        let old = makeBackend()
        let oldOutput = Output(old)
        let oldRun = Task { try await old.start(size: size) }
        _ = await waitUntil(timeout: 15) { !oldOutput.value.isEmpty }
        old.write(Data("echo before-$((1+1))\r".utf8))
        _ = await waitUntil(timeout: 5) { oldOutput.value.contains("before-2") }

        // The new connection attaches alongside and gets the screen.
        let new = makeBackend()
        let newOutput = Output(new)
        let newRun = Task { try await new.start(size: size) }
        let replayed = await waitUntil(timeout: 15) { newOutput.value.contains("before-2") }
        XCTAssertTrue(replayed, newOutput.value)

        // The old one goes; the shell carries on through the new one.
        old.close()
        try await oldRun.value
        new.write(Data("echo after-$((2+2))\r".utf8))
        let carriedOn = await waitUntil(timeout: 5) { newOutput.value.contains("after-4") }
        XCTAssertTrue(carriedOn, newOutput.value)
        XCTAssertFalse(oldOutput.value.contains("after-4"))

        new.write(Data("exit\r".utf8))
        try await newRun.value
    }
}
