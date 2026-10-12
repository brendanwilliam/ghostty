import GhosttyKit
import XCTest
@testable import GhosttyiOS

/// Dictation and input methods: provisional text is shown but only sent
/// once it's final, because the terminal can't take bytes back.
@MainActor
final class TextInputTests: XCTestCase {
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
    }

    override func tearDown() async throws {
        backend.continuation.finish()
        _ = await run?.value
    }

    private var written: String { String(decoding: backend.written, as: UTF8.self) }

    /// Let the IO thread flush, then check nothing has been written.
    private func assertNothingSent(_ message: String = "", line: UInt = #line) async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(written, "", message, line: line)
    }

    private func range(_ a: Int, _ b: Int) -> UITextRange {
        view.textRange(from: view.position(from: view.beginningOfDocument, offset: a)!,
                       to: view.position(from: view.beginningOfDocument, offset: b)!)!
    }

    func testTypingIsSentImmediately() async throws {
        view.insertText("ls")
        let sent = await waitUntil { self.written == "ls" }
        XCTAssertTrue(sent, "wrote \(written.debugDescription)")
        XCTAssertEqual(view.text(in: range(0, 0)), "")
    }

    func testMarkedTextIsSentOnceWhenUnmarked() async throws {
        view.setMarkedText("hel", selectedRange: NSRange(location: 3, length: 0))
        view.setMarkedText("hello", selectedRange: NSRange(location: 5, length: 0))
        try await assertNothingSent()
        XCTAssertNotNil(view.markedTextRange)

        view.unmarkText()
        let sent = await waitUntil { self.written == "hello" }
        XCTAssertTrue(sent, "wrote \(written.debugDescription)")
        XCTAssertNil(view.markedTextRange)
    }

    func testDictationIsHeldWhileItRevisesItself() async throws {
        // Speech arrives, then dictation revises an earlier word.
        view.insertText("echo hello", alternatives: [], style: .none)
        view.insertText(" world", alternatives: [], style: .none)
        XCTAssertEqual(view.text(in: range(0, 16)), "echo hello world")
        view.replace(range(5, 10), withText: "Hello")
        try await assertNothingSent("dictation must not reach the program early")

        // Pressing return sends the final text, then runs it.
        view.insertText("\n")
        let sent = await waitUntil { self.written == "echo Hello world\r" }
        XCTAssertTrue(sent, "wrote \(written.debugDescription)")

        // Typing afterwards goes straight through again.
        view.insertText("x")
        let typed = await waitUntil { self.written.hasSuffix("\rx") }
        XCTAssertTrue(typed, "wrote \(written.debugDescription)")
    }

    func testDictationPlaceholderThenFailure() async throws {
        _ = view.insertDictationResultPlaceholder()
        view.insertText("partial")
        try await assertNothingSent()
        view.dictationRecognitionFailed()
        let sent = await waitUntil { self.written == "partial" }
        XCTAssertTrue(sent, "wrote \(written.debugDescription)")
    }

    func testBackspaceEditsComposingTextFirst() async throws {
        view.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0))
        view.deleteBackward()
        try await assertNothingSent("backspace reached the program")
        view.unmarkText()
        let sent = await waitUntil { self.written == "ab" }
        XCTAssertTrue(sent, "wrote \(written.debugDescription)")

        // With nothing composed, backspace goes to the program.
        view.deleteBackward()
        let deleted = await waitUntil { self.written == "ab\u{7F}" }
        XCTAssertTrue(deleted, "wrote \(written.debugDescription)")
    }

    func testResigningCommitsDictation() async throws {
        view.insertText("pending", alternatives: [], style: .none)
        try await assertNothingSent()
        view.commitComposing()
        let sent = await waitUntil { self.written == "pending" }
        XCTAssertTrue(sent, "wrote \(written.debugDescription)")
    }
}
