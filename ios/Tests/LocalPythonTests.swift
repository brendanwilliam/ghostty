import XCTest
@testable import GhosttyiOS

/// `python3` as the shell's users run it: a command typed into dash.
final class LocalPythonTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(LocalEnvironment.hasDash, "needs the real shell")
        let python = Bundle.main.bundleURL.appendingPathComponent("python/lib/python3.14")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: python.path), "Python isn't bundled")
    }

    func testPrintsFromACommandLine() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("python3 -c 'print(6 * 7)'\r")
        XCTAssertTrue(session.text.contains("42\r\n"), session.text.debugDescription)
    }

    func testRunsAScriptFromTheCurrentDirectory() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("echo 'import sys; print(\"hello\", sys.version_info[:2])' > py-test.py\r")
        try await session.type("python3 py-test.py\r")
        XCTAssertTrue(session.text.contains("hello (3, 14)\r\n"), session.text.debugDescription)
        try await session.type("rm py-test.py\r")
    }

    func testPipesInAndOut() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("echo 20 | python3 -c 'import sys; print(int(sys.stdin.read()) * 2)' | cat\r")
        XCTAssertTrue(session.text.contains("40\r\n"), session.text.debugDescription)
    }

    func testAnErrorReportsAStatus() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("python3 -c 'raise SystemExit(3)'; echo status $?\r")
        XCTAssertTrue(session.text.contains("status 3\r\n"), session.text.debugDescription)
        try await session.type("python3 -c '1/0'\r")
        XCTAssertTrue(session.text.contains("ZeroDivisionError"), session.text.debugDescription)
    }

    /// There are six copies of the command framework; later runs must
    /// get them back.
    func testRunsMoreTimesThanThereAreCopies() async throws {
        let session = try await LocalTestSession(shell: .dash)
        for i in 1...10 {
            try await session.type("python3 -c 'print(\(i + 100))'\r")
            XCTAssertTrue(session.text.contains("\(i + 100)\r\n"), "run \(i): \(session.text.debugDescription)")
        }
    }
}
