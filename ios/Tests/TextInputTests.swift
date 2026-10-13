import GhosttyKit
import XCTest
@testable import GhosttyiOS

/// Records the change notifications the terminal sends the keyboard.
private final class RecordingInputDelegate: NSObject, UITextInputDelegate {
    var textChanges = 0
    var selectionChanges = 0
    func selectionWillChange(_ textInput: UITextInput?) {}
    func selectionDidChange(_ textInput: UITextInput?) { selectionChanges += 1 }
    func textWillChange(_ textInput: UITextInput?) {}
    func textDidChange(_ textInput: UITextInput?) { textChanges += 1 }
    @available(iOS 18.4, *)
    func conversationContext(_ context: UIConversationContext?, didChange textInput: UITextInput?) {}
}

/// Dictation and input methods: provisional text is shown but only sent
/// once it's final, and the keyboard's own edits never look like outside
/// changes (which would end dictation).
@MainActor
final class TextInputTests: XCTestCase {
    private var view: TerminalSurfaceView!
    private var backend: FakeBackend!
    private var run: Task<Void, Never>?
    private let delegate = RecordingInputDelegate()

    override func setUp() async throws {
        let app = try XCTUnwrap(GhosttyRuntime.shared.app)
        backend = FakeBackend()
        view = TerminalSurfaceView(app: app, backend: backend)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.layoutIfNeeded()
        view.inputDelegate = delegate
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

    private var document: String { view.text(in: range(0, (view.endOfDocument as! TextOffset).offset)) ?? "" }

    func testTypingIsSentImmediately() async throws {
        view.insertText("l")
        view.insertText("s")
        let sent = await waitUntil { self.written == "ls" }
        XCTAssertTrue(sent, "wrote \(written.debugDescription)")
        XCTAssertEqual(document, "ls", "the keyboard sees what was typed")
        XCTAssertEqual(delegate.textChanges, 0)
    }

    func testStreamingDictationIsHeldUntilFinal() async throws {
        // How dictation streams: a growing provisional guess.
        view.setMarkedText(" Th", selectedRange: NSRange(location: 3, length: 0))
        view.setMarkedText(" The quick", selectedRange: NSRange(location: 10, length: 0))
        view.setMarkedText(" The quick brown fox", selectedRange: NSRange(location: 20, length: 0))
        try await assertNothingSent("provisional dictation reached the program")
        XCTAssertEqual(delegate.textChanges, 0, "telling the keyboard about its own edits ends dictation")

        view.unmarkText()
        let sent = await waitUntil { self.written == " The quick brown fox" }
        XCTAssertTrue(sent, "wrote \(written.debugDescription)")
        XCTAssertEqual(delegate.textChanges, 0)

        // Dictation keeps going after a pause.
        view.setMarkedText(" jumps", selectedRange: NSRange(location: 6, length: 0))
        view.unmarkText()
        let more = await waitUntil { self.written == " The quick brown fox jumps" }
        XCTAssertTrue(more, "wrote \(written.debugDescription)")
    }

    /// Replays the calls iOS 26 made on an iPhone while dictating "The
    /// quick brown fox." (from the text-input trace): no dictation mode,
    /// no marked text, just in-place rewrites, a trailing "\n\n" after a
    /// pause, then everything cleared and the result inserted again.
    func testInPlaceDictationStreamsIntoTheTerminalAndNeverRuns() async throws {
        let expected = " The quick brown fax\u{7F}\u{7F}ox."
        view.insertText(" Th")
        _ = await waitUntil { self.written == " Th" }
        view.replace(range(0, 3), withText: " The ")
        view.replace(range(0, 5), withText: " The quick brown")
        view.replace(range(0, 16), withText: " The quick brown fax")
        // A correction backspaces over just the changed part.
        view.replace(range(0, 20), withText: " The quick brown fox.")
        // Line breaks are dropped without bracketed paste, never Return.
        view.replace(range(0, 21), withText: " The quick brown fox.\n\n")
        let live = await waitUntil { self.written == expected }
        XCTAssertTrue(live, "wrote \(written.debugDescription)")
        XCTAssertEqual(delegate.textChanges, 0)

        // Wrapping up clears everything and inserts the result: held, so
        // the phrase isn't deleted and retyped.
        view.dictationRecordingDidEnd()
        view.insertText("          ")
        view.replace(range(23, 33), withText: "")
        view.replace(range(0, 23), withText: "")
        view.insertText(" ")
        view.finishDictation(inserting: "The quick brown fox.\n\n")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(written, expected, "no Return, nothing deleted or sent twice")
        XCTAssertEqual(delegate.textChanges, 0)
        let expectedAfter = expected

        // Pressing Return right after: iOS's placeholder spaces (typed and
        // deleted as dictation wraps up) never reach the program.
        view.insertText("\n")
        view.dictationRecordingDidEnd()
        view.insertText("          ")
        view.replace(range(0, 10), withText: "")
        // ...and the leftover "\n" result isn't a blank line in the next prompt.
        view.finishDictation(inserting: "\n")
        try await Task.sleep(nanoseconds: 2_300_000_000)
        XCTAssertEqual(written, expectedAfter + "\r")
        XCTAssertEqual(document, "")
    }

    /// From a trace: Return pressed while still dictating. iOS clears the
    /// streamed text and inserts the result before the Return arrives.
    func testReturnDuringDictationSendsTheTextOnce() async throws {
        view.insertText(" I")
        view.replace(range(0, 2), withText: " I am trying new dictation.")
        _ = await waitUntil { self.written == " I am trying new dictation." }
        view.replace(range(0, 27), withText: "")
        view.finishDictation(inserting: " I am trying new dictation.")
        view.insertText("\n")
        let sent = await waitUntil { self.written == " I am trying new dictation.\r" }
        XCTAssertTrue(sent, "wrote \(written.debugDescription)")
    }

    func testDictatedLineBreakIsPastedWhenTheProgramUsesBracketedPaste() async throws {
        // The program (Claude Code, zsh) turns on bracketed paste.
        backend.continuation.yield(.output(Data("\u{1B}[?2004h".utf8)))
        let surface = try XCTUnwrap(view.surface)
        let enabled = await waitUntil { ghostty_surface_bracketed_paste(surface) }
        XCTAssertTrue(enabled)

        view.insertText("one")
        view.replace(range(0, 3), withText: "one\ntwo")
        let sent = await waitUntil { self.written.hasSuffix("two") }
        XCTAssertTrue(sent, "wrote \(written.debugDescription)")
        XCTAssertEqual(written, "one\u{1B}[200~\n\u{1B}[201~two", "a pasted newline, not Return")
    }

    func testRevisingSentTextSendsTheDifference() async throws {
        view.insertText("hello wrld")
        _ = await waitUntil { self.written == "hello wrld" }
        // Dictation corrects a word it already finalized.
        view.replace(range(6, 10), withText: "world")
        view.finishDictation(inserting: "")
        let fixed = await waitUntil { self.written == "hello wrld\u{7F}\u{7F}\u{7F}orld" }
        XCTAssertTrue(fixed, "wrote \(written.debugDescription)")
        XCTAssertEqual(document, "hello world")
    }

    func testDictationModeHoldsInsertedText() async throws {
        // Older dictation: a placeholder, then plain inserts and revisions.
        _ = view.insertDictationResultPlaceholder()
        view.insertText("echo hello")
        view.insertText(" world")
        view.replace(range(5, 10), withText: "Hello")
        try await assertNothingSent("dictation must not reach the program early")

        // Return sends the final text, then runs it.
        view.insertText("\n")
        let sent = await waitUntil { self.written == "echo Hello world\r" }
        XCTAssertTrue(sent, "wrote \(written.debugDescription)")
        XCTAssertEqual(document, "", "a new line starts a new document")

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

        // Deleting sent text backspaces in the program.
        view.deleteBackward()
        let deleted = await waitUntil { self.written == "ab\u{7F}" }
        XCTAssertTrue(deleted, "wrote \(written.debugDescription)")

        // With an empty document, backspace still reaches the program.
        view.commitComposing()
        view.deleteBackward()
        let again = await waitUntil { self.written == "ab\u{7F}\u{7F}" }
        XCTAssertTrue(again, "wrote \(written.debugDescription)")
    }

    func testCommittingSendsHeldTextAndResets() async throws {
        _ = view.insertDictationResultPlaceholder()
        view.insertText("pending")
        try await assertNothingSent()
        view.commitComposing()
        let sent = await waitUntil { self.written == "pending" }
        XCTAssertTrue(sent, "wrote \(written.debugDescription)")
        XCTAssertEqual(document, "")
        XCTAssertEqual(delegate.textChanges, 1, "the app's own reset is announced")
    }
}
