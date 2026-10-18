import XCTest
@testable import GhosttyiOS

/// The local shell as users get it: dash. It only has device slices, so
/// these skip on the simulator.
final class LocalDashTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(LocalEnvironment.hasDash, "dash only runs on a device")
    }

    func testShellSyntaxWorks() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("echo a && echo b; for i in 1 2; do echo n$i; done\r")
        XCTAssertTrue(session.text.contains("a\r\nb\r\nn1\r\nn2\r\n"), session.text.debugDescription)
        try await session.type("echo $((6 * 7))\r")
        XCTAssertTrue(session.text.contains("42\r\n"), session.text.debugDescription)
    }

    func testVariablesAndTheDirectoryLastBetweenLines() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("X=kept\r")
        try await session.type("echo $X\r")
        XCTAssertTrue(session.text.contains("kept\r\n"), session.text.debugDescription)

        try await session.type("mkdir -p dash-dir && cd dash-dir\r")
        try await session.type("pwd\r")
        XCTAssertTrue(session.text.contains("dash-dir\r\n"), session.text.debugDescription)
        // The prompt (from ~/.dashrc) names the directory.
        XCTAssertTrue(session.text.hasSuffix("dash-dir $ "), session.text.debugDescription)
        try await session.type("cd .. && rm -r dash-dir\r")
    }

    func testExitEndsTheSession() async throws {
        let session = try await LocalTestSession(shell: .dash)
        session.backend.write(Data("exit\r".utf8))
        try await session.waitFor { _ in session.hasExited }
    }

    func testControlCStopsACommandWaitingForInput() async throws {
        let session = try await LocalTestSession(shell: .dash)
        session.backend.write(Data("cat\r".utf8))
        try await session.waitFor { $0.hasSuffix("cat\r\n") }
        try await Task.sleep(for: .milliseconds(300))
        session.backend.write(Data("\u{3}".utf8))
        try await session.waitFor { $0.contains("^C") && $0.hasSuffix(" $ ") }
        // The shell is still there.
        try await session.type("echo alive\r")
        XCTAssertTrue(session.text.contains("alive\r\n"), session.text.debugDescription)
    }

    func testHistoryRecallsTheLastLine() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("echo again\r")
        try await session.type("\u{1B}[A\r")
        XCTAssertEqual(session.text.components(separatedBy: "\r\nagain\r\n").count - 1, 2,
                       session.text.debugDescription)
    }

    /// Two tabs share one process, and so one working directory.
    func testTwoShellsKeepTheirOwnDirectories() async throws {
        let first = try await LocalTestSession(shell: .dash)
        let second = try await LocalTestSession(shell: .dash)
        try await first.type("mkdir -p dash-tab && cd dash-tab\r")
        try await second.type("pwd\r")
        try await first.type("pwd\r")
        XCTAssertTrue(first.text.contains("dash-tab\r\n"), first.text.debugDescription)
        XCTAssertFalse(second.text.contains("dash-tab"), second.text.debugDescription)
        try await first.type("cd .. && rm -r dash-tab\r")
    }

    /// libghostty reads `environ` through a pointer it took at startup, so
    /// the shell's variables must not reach the process environment.
    func testExportStaysOutOfTheProcessEnvironment() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("export DASH_TEST_VAR=1\r")
        XCTAssertNil(getenv("DASH_TEST_VAR"))
        // Commands the shell starts do see it.
        try await session.type("env | grep DASH_TEST_VAR\r")
        XCTAssertTrue(session.text.contains("DASH_TEST_VAR=1\r\n"), session.text.debugDescription)
    }

    @MainActor
    func testANewTerminalCanBeCreatedAfterTheShellExports() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("export DASH_TEST_VAR=1\r")
        let app = try XCTUnwrap(GhosttyRuntime.shared.app, "libghostty failed to initialize")
        let view = TerminalSurfaceView(app: app, backend: FakeBackend())
        XCTAssertNotNil(view.surface)
    }

    func testVimEditsAFileInsideTheShell() async throws {
        let session = try await LocalTestSession(shell: .dash)
        session.backend.write(Data("vim -u NONE dash-vim.txt\r".utf8))
        try await session.waitFor { $0.contains("[New File]") }
        try await Task.sleep(for: .milliseconds(300))
        // vim has the keyboard now: raw bytes.
        session.backend.write(Data("ihello from vim".utf8))
        try await Task.sleep(for: .milliseconds(200))
        session.backend.write(Data("\u{1B}".utf8))
        try await Task.sleep(for: .milliseconds(300))
        session.backend.write(Data(":wq\r".utf8))
        try await session.waitFor { $0.hasSuffix(" $ ") }

        try await session.type("cat dash-vim.txt\r")
        XCTAssertTrue(session.text.contains("hello from vim\r\n"), session.text.debugDescription)
        try await session.type("rm dash-vim.txt\r")
    }

    func testGitCommitsInALocalRepository() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("rm -rf dash-repo && lg2 init dash-repo && cd dash-repo\r")
        try await session.type("echo hi > a.txt && lg2 add a.txt\r")
        try await session.type("lg2 config user.name Test && lg2 config user.email test@example.com\r")
        try await session.type("lg2 commit -m first\r")
        try await session.type("lg2 log\r")
        XCTAssertTrue(session.text.contains("first"), session.text.debugDescription)
        try await session.type("cd .. && rm -rf dash-repo\r")
    }
}
