import SwiftUI
import XCTest
@testable import GhosttyiOS

/// Terminals outlive their screen: leaving for the host list and coming
/// back finds the same tabs and sessions.
@MainActor
final class WorkspaceStoreTests: XCTestCase {
    private var backends: [FakeBackend] = []
    private var store: WorkspaceStore!
    private let host = Host(name: "test", hostname: "localhost", username: "me")

    override func setUp() async throws {
        let app = try XCTUnwrap(GhosttyRuntime.shared.app)
        store = WorkspaceStore(archive: WorkspaceArchive(url: nil)) { host, layout, sessions in
            TerminalWorkspace(host: host, layout: layout, sessions: sessions) { [weak self] pane in
                let backend = FakeBackend()
                self?.backends.append(backend)
                await pane.run(TerminalSurfaceView(app: app, backend: backend))
            }
        }
    }

    override func tearDown() async throws {
        for backend in backends { backend.continuation.finish() }
    }

    func testTheSameHostGetsTheSameWorkspace() {
        let workspace = store.workspace(for: host)
        XCTAssertTrue(store.workspace(for: host) === workspace)
        XCTAssertTrue(store.openWorkspace(for: host) === workspace)
        let other = Host(name: "other", hostname: "other.local", username: "me")
        XCTAssertFalse(store.workspace(for: other) === workspace)
    }

    func testLeavingTheScreenKeepsSessionsRunning() async throws {
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first)
        let workspace = store.workspace(for: host)
        let hosts = HostStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("store-hosts.json"))
        let controller = UIHostingController(rootView:
            NavigationStack { TerminalScreen(workspace: workspace) }.environmentObject(hosts))
        window.rootViewController?.present(controller, animated: false)

        let shown = await waitUntil { workspace.focusedPane?.surfaceView?.window != nil }
        XCTAssertTrue(shown)
        workspace.perform(.newTab)
        let opened = await waitUntil { workspace.focusedPane?.surfaceView?.window != nil }
        XCTAssertTrue(opened)
        let view = try XCTUnwrap(workspace.focusedPane?.surfaceView)

        // Back to the host list.
        controller.dismiss(animated: false)
        let gone = await waitUntil { view.window == nil }
        XCTAssertTrue(gone)
        try await Task.sleep(nanoseconds: 300_000_000)

        // Coming back finds both tabs, with the same live terminal.
        let again = store.workspace(for: host)
        XCTAssertTrue(again === workspace)
        XCTAssertEqual(again.tabs.count, 2)
        XCTAssertTrue(again.focusedPane?.surfaceView === view)
        XCTAssertEqual(again.focusedPane?.ended, false)
    }

    func testClosingTheLastTabForgetsTheWorkspace() async throws {
        let workspace = store.workspace(for: host)
        workspace.start()
        workspace.perform(.closeWindow)
        XCTAssertTrue(workspace.closed)
        XCTAssertNil(store.openWorkspace(for: host))
        let forgotten = await waitUntil { !(self.store.workspace(for: self.host) === workspace) }
        XCTAssertTrue(forgotten, "a closed workspace isn't reopened")
    }

    func testEndSessionsEndsThem() async throws {
        let workspace = store.workspace(for: host)
        workspace.start()
        let connected = await waitUntil { workspace.focusedPane?.surfaceView != nil }
        XCTAssertTrue(connected)
        let pane = try XCTUnwrap(workspace.focusedPane)

        store.endSessions(host)
        XCTAssertNil(pane.surfaceView)
        XCTAssertNil(store.openWorkspace(for: host))
    }
}
