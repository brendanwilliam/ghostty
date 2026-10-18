import XCTest
@testable import GhosttyiOS

/// The on-device shell, run through ios_system. These use the builtin
/// shell: dash only has device slices, so it can't run in the simulator.
final class LocalBackendTests: XCTestCase {
    func testACommandRunsAndOutputUsesCRLF() async throws {
        let session = try await LocalTestSession(shell: .builtin)
        try await session.type("echo hi\r")
        XCTAssertTrue(session.text.contains("echo hi\r\nhi\r\n"), session.text.debugDescription)
    }

    func testPipesAndRedirectionWork() async throws {
        let session = try await LocalTestSession(shell: .builtin)
        try await session.type("echo abc | tr a-z A-Z\r")
        XCTAssertTrue(session.text.contains("ABC\r\n"), session.text.debugDescription)

        try await session.type("echo kept > local-backend-test.txt\r")
        try await session.type("cat local-backend-test.txt\r")
        XCTAssertTrue(session.text.contains("kept\r\n"), session.text.debugDescription)
        try await session.type("rm local-backend-test.txt\r")
    }

    func testTypedLinesReachACommandThatReadsStdin() async throws {
        let session = try await LocalTestSession(shell: .builtin)
        session.backend.write(Data("cat\r".utf8))
        try await session.waitFor { $0.hasSuffix("cat\r\n") }
        session.backend.write(Data("typed\r".utf8))
        try await session.waitFor { $0.hasSuffix("typed\r\ntyped\r\n") }
        // Ctrl-D ends the input, so cat exits and the prompt returns.
        session.backend.write(Data("\u{4}".utf8))
        try await session.waitFor { $0.hasSuffix(" $ ") }
    }

    func testBackspaceAndHistoryEditTheLine() async throws {
        let session = try await LocalTestSession(shell: .builtin)
        try await session.type("echo abX\u{7F}c\r")
        XCTAssertTrue(session.text.contains("abc\r\n"), session.text.debugDescription)

        try await session.type("echo again\r")
        try await session.type("\u{1B}[A\r")
        // Up-arrow recalled the line, so it ran twice.
        XCTAssertEqual(session.text.components(separatedBy: "\r\nagain\r\n").count - 1, 2,
                       session.text.debugDescription)
    }

    func testControlCAtThePromptStartsANewLine() async throws {
        let session = try await LocalTestSession(shell: .builtin)
        try await session.type("echo draft\u{3}")
        XCTAssertTrue(session.text.contains("^C\r\n"), session.text.debugDescription)
        XCTAssertFalse(session.text.contains("draft\r\ndraft"), session.text.debugDescription)
    }

    func testControlCStopsACommandWaitingForInput() async throws {
        let session = try await LocalTestSession(shell: .builtin)
        session.backend.write(Data("cat\r".utf8))
        try await session.waitFor { $0.hasSuffix("cat\r\n") }
        // Give the command a moment to start: Ctrl-C only reaches a
        // command that's running.
        try await Task.sleep(for: .milliseconds(300))
        session.backend.write(Data("\u{3}".utf8))
        try await session.waitFor { $0.contains("^C") && $0.hasSuffix(" $ ") }
    }

    // Not tested here: a command that ignores Ctrl-C (awk 'BEGIN { while (1) { } }').
    // ios_system can't stop it, and the thread it leaves spinning breaks every
    // session after it in the process. See `LocalBackend.interruptCommand`.

    func testTheSizeReachesCommandsAsColumnsAndLines() async throws {
        let session = try await LocalTestSession(shell: .builtin)
        session.backend.resize(TerminalSize(columns: 61, rows: 17, widthPixels: 0, heightPixels: 0))
        try await session.type("echo $COLUMNS x $LINES\r")
        XCTAssertTrue(session.text.contains("61 x 17\r\n"), session.text.debugDescription)
    }

    func testExitEndsTheSession() async throws {
        let session = try await LocalTestSession(shell: .builtin)
        session.backend.write(Data("exit\r".utf8))
        try await session.waitFor { _ in session.hasExited }
    }

    func testEachSessionKeepsItsOwnDirectory() async throws {
        let first = try await LocalTestSession(shell: .builtin)
        let second = try await LocalTestSession(shell: .builtin)
        try await first.type("mkdir -p local-backend-dir\r")
        try await first.type("cd local-backend-dir\r")
        try await first.type("pwd\r")
        try await second.type("pwd\r")
        XCTAssertTrue(first.text.contains("local-backend-dir\r\n"), first.text.debugDescription)
        XCTAssertFalse(second.text.contains("local-backend-dir"), second.text.debugDescription)
        try await first.type("cd ..\r")
        try await first.type("rm -r local-backend-dir\r")
    }

    /// libghostty keeps a pointer to the process's `environ` array from
    /// `ghostty_init`, so adding a variable later (which can make libc move
    /// the array) leaves it reading freed memory: the next terminal's
    /// config build crashed. Starting a shell and running commands must not
    /// add to the process environment.
    ///
    /// (`export` in the builtin shell does, because its parent "process" is
    /// the real one. dash's children have dash as their parent.)
    func testRunningCommandsLeavesTheProcessEnvironmentAlone() async throws {
        LocalEnvironment.prepareProcess()
        func snapshot() -> (array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int) {
            let entries = environ
            var count = 0
            while entries[count] != nil { count += 1 }
            return (entries, count)
        }
        let before = snapshot()

        let session = try await LocalTestSession(shell: .builtin)
        try await session.type("echo $HOME $TERM\r")
        let after = snapshot()

        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.array, before.array)
        // The shell sees its own variables.
        XCTAssertTrue(session.text.contains("\(LocalEnvironment.home.path) xterm-256color\r\n"),
                      session.text.debugDescription)
    }

    @MainActor
    func testANewTerminalCanBeCreatedAfterAShellHasRun() async throws {
        let session = try await LocalTestSession(shell: .builtin)
        try await session.type("echo hi\r")
        let app = try XCTUnwrap(GhosttyRuntime.shared.app, "libghostty failed to initialize")
        let view = TerminalSurfaceView(app: app, backend: FakeBackend())
        XCTAssertNotNil(view.surface)
    }

    func testTheHostIsRecognizedAsLocal() {
        XCTAssertTrue(Host.local.isLocal)
        XCTAssertFalse(Host(name: "x", hostname: "h", username: "u").isLocal)
        XCTAssertEqual(Host.local.displayName, "This iPhone")
    }
}
