import GhosttyKit
import SwiftUI
import XCTest
@testable import GhosttyiOS

final class SplitTreeTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)

    func testInsertPlacesTheNewPaneOnTheRequestedSide() {
        var tree = SplitTree(a)
        tree.insert(b, splitting: a, direction: .down)
        XCTAssertEqual(tree.panes, [a, b])
        tree.insert(c, splitting: b, direction: .left)
        XCTAssertEqual(tree.panes, [a, c, b])

        let frames = tree.frames(in: bounds)
        XCTAssertEqual(frames[a], CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(frames[c], CGRect(x: 0, y: 400, width: 200, height: 400))
        XCTAssertEqual(frames[b], CGRect(x: 200, y: 400, width: 200, height: 400))
    }

    func testRemoveCollapsesTheSiblingIntoItsParent() {
        var tree = SplitTree(a)
        tree.insert(b, splitting: a, direction: .right)
        tree.insert(c, splitting: b, direction: .down)
        XCTAssertTrue(tree.remove(b))
        XCTAssertEqual(tree.panes, [a, c])
        XCTAssertEqual(tree.frames(in: bounds)[c], CGRect(x: 200, y: 0, width: 200, height: 800))
        XCTAssertTrue(tree.remove(a))
        XCTAssertEqual(tree.panes, [c])
        XCTAssertFalse(tree.remove(c), "the last pane can't be removed")
        XCTAssertEqual(tree.panes, [c])
    }

    func testResizeMovesTheNearestDividerOnThatAxisAndClamps() {
        var tree = SplitTree(a)
        tree.insert(b, splitting: a, direction: .right)
        tree.insert(c, splitting: b, direction: .down)
        // b's left edge is the a | b divider.
        XCTAssertTrue(tree.resize(b, toward: .left, by: 0.25))
        XCTAssertEqual(tree.frames(in: bounds)[a]?.width, 100)
        XCTAssertTrue(tree.resize(b, toward: .left, by: 0.5))
        XCTAssertEqual(tree.frames(in: bounds)[a]?.width, 40, "clamped to 10%")
        XCTAssertTrue(tree.resize(c, toward: .up, by: 0.1))
        XCTAssertEqual(tree.frames(in: bounds)[b]?.height, 320)
    }

    func testEqualizeGivesEachPaneAnEqualShare() {
        var tree = SplitTree(a)
        tree.insert(b, splitting: a, direction: .right)
        tree.insert(c, splitting: b, direction: .right)
        tree.equalize()
        let widths = tree.panes.compactMap { tree.frames(in: CGRect(x: 0, y: 0, width: 300, height: 100))[$0]?.width }
        XCTAssertEqual(widths, [100, 100, 100])
    }

    func testNeighborsBySpaceAndOrder() {
        // a | b
        // --+--
        //   c (spans the bottom)
        var tree = SplitTree(a)
        tree.insert(c, splitting: a, direction: .down)
        tree.insert(b, splitting: a, direction: .right)
        XCTAssertEqual(tree.panes, [a, b, c])
        XCTAssertEqual(tree.pane(from: a, toward: .right, in: bounds), b)
        XCTAssertEqual(tree.pane(from: b, toward: .left, in: bounds), a)
        XCTAssertEqual(tree.pane(from: b, toward: .down, in: bounds), c)
        XCTAssertNil(tree.pane(from: a, toward: .up, in: bounds))
        XCTAssertEqual(tree.pane(after: c), a, "next wraps")
        XCTAssertEqual(tree.pane(after: a, forward: false), c, "previous wraps")
    }
}

/// Shows the terminal screen with two tabs, the second split in two, for
/// a screenshot. Skipped unless GHOSTTY_TEST_VISUAL_SPLITS is set.
@MainActor
final class VisualSplitsTests: XCTestCase {
    func testShowTabsAndSplits() async throws {
        guard ProcessInfo.processInfo.environment["GHOSTTY_TEST_VISUAL_SPLITS"] != nil else {
            throw XCTSkip("visual splits test not requested")
        }
        let app = try XCTUnwrap(GhosttyRuntime.shared.app)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first)
        var backends: [FakeBackend] = []
        var count = 0
        let host = Host(name: "MacBook", hostname: "mac.local", username: "me")
        let workspace = TerminalWorkspace(host: host) { pane in
            let backend = FakeBackend()
            backends.append(backend)
            count += 1
            let view = TerminalSurfaceView(app: app, backend: backend)
            let n = count
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let text = "\u{1B}]2;pane \(n)\u{07}\u{1B}[1mpane \(n)\u{1B}[0m\r\n$ ls\r\nREADME.md  src  build.zig\r\n$ "
                backend.continuation.yield(.output(Data(text.utf8)))
            }
            await pane.run(view)
        }
        let store = HostStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("visual-hosts.json"))
        let controller = UIHostingController(rootView:
            NavigationStack { TerminalScreen(workspace: workspace) }.environmentObject(store))
        controller.modalPresentationStyle = .fullScreen
        window.rootViewController?.present(controller, animated: false)

        try await Task.sleep(nanoseconds: 1_000_000_000)
        workspace.perform(.newTab)
        workspace.splitFocused()
        try await Task.sleep(nanoseconds: 8_000_000_000)
        for backend in backends { backend.continuation.finish() }
        controller.dismiss(animated: false)
    }
}

/// Tabs and splits, driven through Ghostty's keybind actions.
@MainActor
final class WorkspaceTests: XCTestCase {
    private var backends: [UUID: FakeBackend] = [:]
    private var workspace: TerminalWorkspace!

    override func setUp() async throws {
        let app = try XCTUnwrap(GhosttyRuntime.shared.app)
        let host = Host(name: "test", hostname: "localhost", username: "me")
        workspace = TerminalWorkspace(host: host) { [weak self] pane in
            let backend = FakeBackend()
            self?.backends[pane.id] = backend
            let view = TerminalSurfaceView(app: app, backend: backend)
            view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
            view.layoutIfNeeded()
            await pane.run(view)
        }
        workspace.layoutSize = CGSize(width: 390, height: 700)
        workspace.start()
        _ = await surfacesReady()
    }

    override func tearDown() async throws {
        for backend in backends.values { backend.continuation.finish() }
        workspace.disconnectAll()
    }

    private func surfacesReady() async -> Bool {
        await waitUntil { self.workspace.panes.values.allSatisfy { $0.surfaceView != nil } }
    }

    private var focused: TerminalPane { workspace.focusedPane! }

    /// Run a Ghostty keybind action on the focused pane's surface.
    private func bind(_ action: String) throws {
        let surface = try XCTUnwrap(focused.surfaceView?.surface)
        XCTAssertTrue(ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)),
                      "\(action) wasn't performed")
    }

    func testNewSplitKeybindAddsAPaneAndFocusesIt() async throws {
        let first = focused.id
        try bind("new_split:down")
        XCTAssertEqual(workspace.selectedTab?.tree.panes.count, 2)
        XCTAssertNotEqual(focused.id, first)
        let ready = await surfacesReady()
        XCTAssertTrue(ready)

        // Splits share the font a lone pane would have; only the focused
        // one takes taps.
        let firstView = try XCTUnwrap(workspace.panes[first]?.surfaceView)
        let newView = try XCTUnwrap(focused.surfaceView)
        XCTAssertEqual(firstView.fitWidth, 390)
        XCTAssertFalse(firstView.isActivePane)
        XCTAssertTrue(newView.isActivePane)
        XCTAssertEqual(newView.fontPoints, firstView.fontPoints, "panes in a split share a font")

        // Tapping the other pane focuses it rather than clicking in it.
        firstView.touchTap(at: CGPoint(x: 20, y: 20))
        XCTAssertEqual(focused.id, first)
    }

    func testGotoSplitAndCloseFocusesTheNeighbor() async throws {
        let first = focused.id
        try bind("new_split:right")
        let second = focused.id
        _ = await surfacesReady()
        try bind("goto_split:previous")
        XCTAssertEqual(focused.id, first)
        try bind("goto_split:right")
        XCTAssertEqual(focused.id, second)

        workspace.close(second)
        XCTAssertEqual(workspace.selectedTab?.tree.panes, [first])
        XCTAssertEqual(focused.id, first)
        XCTAssertNil(workspace.panes[second])
        XCTAssertNil(workspace.panes[first]?.surfaceView?.fitWidth, "a lone pane fits its own width again")
    }

    func testNewTabKeybindAndTabNavigation() async throws {
        let firstTab = try XCTUnwrap(workspace.selectedTab?.id)
        try bind("new_tab")
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertNotEqual(workspace.selectedTabID, firstTab)
        _ = await surfacesReady()

        try bind("goto_tab:1")
        XCTAssertEqual(workspace.selectedTabID, firstTab)
        try bind("next_tab")
        XCTAssertNotEqual(workspace.selectedTabID, firstTab)
        try bind("next_tab")
        XCTAssertEqual(workspace.selectedTabID, firstTab, "next wraps around")

        // Closing the last tab closes the screen.
        workspace.perform(.closeTab(.others))
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertFalse(workspace.closed)
        workspace.perform(.closeTab(.this))
        XCTAssertTrue(workspace.closed)
    }

    func testDefaultSplitFollowsOrientation() throws {
        workspace.layoutSize = CGSize(width: 390, height: 700)
        XCTAssertEqual(workspace.defaultSplitDirection, .down)
        workspace.splitFocused()
        let portraitTree = try XCTUnwrap(workspace.selectedTab?.tree)
        guard case .split(.vertical, _, _, _) = portraitTree.root else {
            return XCTFail("portrait should stack panes: \(portraitTree.root)")
        }

        workspace.layoutSize = CGSize(width: 800, height: 390)
        XCTAssertEqual(workspace.defaultSplitDirection, .right)
        workspace.perform(.newTab)
        workspace.splitFocused()
        let landscapeTree = try XCTUnwrap(workspace.selectedTab?.tree)
        guard case .split(.horizontal, _, _, _) = landscapeTree.root else {
            return XCTFail("landscape should put panes side by side: \(landscapeTree.root)")
        }
    }

    func testZoomShowsOnlyTheFocusedSplit() async throws {
        workspace.splitFocused()
        _ = await surfacesReady()
        try bind("toggle_split_zoom")
        XCTAssertEqual(workspace.selectedTab?.visiblePanes, [focused.id])
        try bind("toggle_split_zoom")
        XCTAssertEqual(workspace.selectedTab?.visiblePanes.count, 2)
    }

    func testShellExitClosesOnlyThatPane() async throws {
        let first = focused.id
        workspace.splitFocused()
        let second = focused.id
        _ = await surfacesReady()

        // The shell in the new split exits normally. (Exits in the first
        // 250ms count as abnormal and leave the pane open with a message.)
        try await Task.sleep(nanoseconds: 400_000_000)
        backends[second]?.continuation.yield(.exited(code: 0, message: nil))
        backends[second]?.continuation.finish()
        let closed = await waitUntil { self.workspace.panes[second] == nil }
        XCTAssertTrue(closed, "the exited pane should close")
        XCTAssertEqual(workspace.selectedTab?.tree.panes, [first])
        XCTAssertFalse(workspace.closed)
    }

    func testDroppedConnectionKeepsThePane() async throws {
        workspace.splitFocused()
        let second = focused.id
        _ = await surfacesReady()

        backends[second]?.continuation.yield(.exited(code: nil, message: "Disconnected"))
        backends[second]?.continuation.finish()
        let ended = await waitUntil { self.workspace.panes[second]?.ended == true }
        XCTAssertTrue(ended)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(workspace.panes[second], "a dropped pane stays to reconnect")
    }
}
