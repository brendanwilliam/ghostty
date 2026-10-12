import GhosttyKit
import XCTest
@testable import GhosttyiOS

final class MomentumScrollerTests: XCTestCase {
    func testDecaysToAStop() {
        var velocity = CGPoint(x: 0, y: 2000)
        var travelled = 0.0
        var frames = 0
        while frames < 1000 {
            let step = MomentumScroller.step(velocity: velocity, dt: 1.0 / 60)
            XCTAssertLessThan(abs(step.velocity.y), abs(velocity.y))
            XCTAssertGreaterThan(step.delta.y, 0)
            travelled += step.delta.y
            velocity = step.velocity
            frames += 1
            if step.done { break }
        }
        XCTAssertLessThan(frames, 1000, "glide never stopped")
        XCTAssertLessThan(abs(velocity.y), MomentumScroller.stopVelocity)
        // A glide covers at most v / -ln(r) (r per millisecond), like UIScrollView.
        let limit = 2000 / -log(MomentumScroller.decelerationRate) / 1000
        XCTAssertLessThanOrEqual(travelled, limit)
        XCTAssertGreaterThan(travelled, limit * 0.9)
    }

    func testFrameRateDoesNotChangeTheDistance() {
        func distance(fps: Double) -> Double {
            var velocity = CGPoint(x: 0, y: 1500)
            var total = 0.0
            for _ in 0..<Int(fps * 3) {
                let step = MomentumScroller.step(velocity: velocity, dt: 1 / fps)
                total += step.delta.y
                velocity = step.velocity
            }
            return total
        }
        XCTAssertEqual(distance(fps: 60), distance(fps: 120), accuracy: 0.5)
    }

    @MainActor
    func testSlowReleaseDoesNotGlide() {
        var calls = 0
        let scroller = MomentumScroller { _, _ in calls += 1 }
        scroller.start(velocity: CGPoint(x: 0, y: 50), driven: false)
        XCTAssertFalse(scroller.isGliding)
        scroller.advance(dt: 1 / 60)
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testPhasesBeganChangedEnded() {
        var phases: [MomentumScroller.Phase] = []
        let scroller = MomentumScroller { _, phase in phases.append(phase) }
        scroller.start(velocity: CGPoint(x: 0, y: 1000), driven: false)
        scroller.advance(dt: 1 / 60)
        scroller.advance(dt: 1 / 60)
        scroller.stop()
        XCTAssertEqual(phases, [.began, .changed, .ended])
        XCTAssertFalse(scroller.isGliding)
    }
}

/// A flick keeps scrolling the terminal after the finger lifts.
@MainActor
final class MomentumScrollTests: XCTestCase {
    private var view: TerminalSurfaceView!
    private var backend: FakeBackend!
    private var run: Task<Void, Never>?

    override func setUp() async throws {
        let app = try XCTUnwrap(GhosttyRuntime.shared.app)
        backend = FakeBackend()
        view = TerminalSurfaceView(app: app, backend: backend)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.layoutIfNeeded()
        let view = view!
        run = Task { await view.run() }

        let lines = (1...400).map { "line \($0)" }.joined(separator: "\r\n")
        backend.continuation.yield(.output(Data((lines + "\u{1B}[5n").utf8)))
        let ready = await waitUntil {
            String(decoding: self.backend.written, as: UTF8.self).contains("\u{1B}[0n")
        }
        XCTAssertTrue(ready)
    }

    override func tearDown() async throws {
        backend.continuation.finish()
        _ = await run?.value
    }

    /// The number on the top visible line ("line N").
    private func topLine() throws -> Int {
        let surface = try XCTUnwrap(view.surface)
        let columns = ghostty_surface_size(surface).columns
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(columns - 1), y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        XCTAssertTrue(ghostty_surface_read_text(surface, selection, &text))
        defer { ghostty_surface_free_text(surface, &text) }
        let line = String(decoding: Data(bytes: text.text, count: Int(text.text_len)), as: UTF8.self)
        let number = line.trimmingCharacters(in: .whitespaces).dropFirst("line ".count)
        return try XCTUnwrap(Int(number), "top line was \(line.debugDescription)")
    }

    func testFlickKeepsScrolling() throws {
        let start = try topLine()
        let center = CGPoint(x: 100, y: 300)

        // Drag down 100pt (back through the scrollback), then let go fast.
        view.touchScroll(by: .zero, at: center, began: true)
        view.touchScroll(by: CGPoint(x: 0, y: 100), at: center, began: false)
        let afterDrag = try topLine()
        XCTAssertLessThan(afterDrag, start)

        view.touchScrollEnded(velocity: CGPoint(x: 0, y: 1500), driven: false)
        XCTAssertTrue(view.isGliding)
        for _ in 0..<30 { view.advanceGlide(dt: 1 / 60) }
        let afterGlide = try topLine()
        XCTAssertLessThan(afterGlide, afterDrag, "the glide didn't scroll further")

        // A tap stops it.
        view.touchTap(at: center)
        XCTAssertFalse(view.isGliding)
        view.advanceGlide(dt: 1 / 60)
        XCTAssertEqual(try topLine(), afterGlide)
    }
}
