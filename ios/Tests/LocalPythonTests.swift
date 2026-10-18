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

    func testControlCStopsALoop() async throws {
        let session = try await LocalTestSession(shell: .dash)
        session.backend.write(Data("python3 -c 'while True: pass'\r".utf8))
        try await session.waitFor { $0.hasSuffix("pass'\r\n") }
        try await Task.sleep(for: .milliseconds(500))
        session.backend.write(Data("\u{3}".utf8))
        try await session.waitFor { $0.contains("KeyboardInterrupt") && $0.hasSuffix(" $ ") }
        try await session.type("echo status $?\r")
        XCTAssertTrue(session.text.contains("status 130\r\n"), session.text.debugDescription)
        // Python can be started again.
        try await session.type("python3 -c 'print(5)'\r")
        XCTAssertTrue(session.text.contains("5\r\n"), session.text.debugDescription)
    }

    /// There is one interpreter per process: Ctrl-C in another tab must not
    /// stop it.
    func testControlCInAnotherTabLeavesPythonRunning() async throws {
        let python = try await LocalTestSession(shell: .dash)
        let other = try await LocalTestSession(shell: .dash)
        python.backend.write(Data("python3 -c 'import time; time.sleep(2); print(\"finished\")'\r".utf8))
        try await python.waitFor { $0.hasSuffix("print(\"finished\")'\r\n") }
        other.backend.write(Data("cat\r".utf8))
        try await other.waitFor { $0.hasSuffix("cat\r\n") }
        try await Task.sleep(for: .milliseconds(300))
        other.backend.write(Data("\u{3}".utf8))
        try await other.waitFor { $0.contains("^C") && $0.hasSuffix(" $ ") }
        try await python.waitFor { $0.contains("finished\r\n") }
        XCTAssertFalse(python.text.contains("KeyboardInterrupt"), python.text.debugDescription)
    }

    /// Runs in different tabs overlap: neither waits for the other.
    func testTwoTabsRunPythonAtTheSameTime() async throws {
        let first = try await LocalTestSession(shell: .dash)
        let second = try await LocalTestSession(shell: .dash)
        let started = Date()
        let program = "python3 -c 'import time; time.sleep(1.5); print(\"done-\" + str(7 * 6))'\r"
        first.backend.write(Data(program.utf8))
        second.backend.write(Data(program.utf8))
        try await first.waitFor { $0.contains("done-42\r\n") }
        try await second.waitFor { $0.contains("done-42\r\n") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.8, "ran one after the other")
    }

    /// Ctrl-C reaches the run in its own tab only.
    func testControlCStopsOnlyTheTabItWasPressedIn() async throws {
        let first = try await LocalTestSession(shell: .dash)
        let second = try await LocalTestSession(shell: .dash)
        first.backend.write(Data("python3 -c 'while True: pass'\r".utf8))
        second.backend.write(Data("python3 -c 'import time; time.sleep(2); print(\"second-done\")'\r".utf8))
        try await first.waitFor { $0.hasSuffix("pass'\r\n") }
        try await second.waitFor { $0.hasSuffix("print(\"second-done\")'\r\n") }
        try await Task.sleep(for: .milliseconds(500))
        first.backend.write(Data("\u{3}".utf8))
        try await first.waitFor { $0.contains("KeyboardInterrupt") && $0.hasSuffix(" $ ") }
        try await second.waitFor { $0.contains("second-done\r\n") }
        XCTAssertFalse(second.text.contains("KeyboardInterrupt"), second.text.debugDescription)
    }

    /// Each run starts clean: nothing a program set is visible to the next.
    func testRunsDoNotShareState() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("python3 -c 'import builtins, sys; builtins.leak = 1; sys.modules[\"leakmod\"] = sys'\r")
        try await session.type("python3 -c 'import builtins, sys; print(hasattr(builtins, \"leak\"), \"leakmod\" in sys.modules)'\r")
        XCTAssertTrue(session.text.contains("False False\r\n"), session.text.debugDescription)
    }

    func testAThreadAProgramStartsIsJoinedAtTheEnd() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("python3 -c 'import threading, time; threading.Thread(target=lambda: (time.sleep(0.3), print(\"from thread\"))).start()'\r")
        XCTAssertTrue(session.text.contains("from thread\r\n"), session.text.debugDescription)
        try await session.type("python3 -c 'print(\"still fine\")'\r")
        XCTAssertTrue(session.text.contains("still fine\r\n"), session.text.debugDescription)
    }

    func testRunsAModuleAndAProgramFromStandardInput() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("python3 -m json.tool --help | head -1\r")
        XCTAssertTrue(session.text.contains("usage:"), session.text.debugDescription)
        try await session.type("echo 'print(2 ** 10)' | python3\r")
        XCTAssertTrue(session.text.contains("1024\r\n"), session.text.debugDescription)
        try await session.type("echo '{\"a\": 1}' | python3 -m json.tool\r")
        XCTAssertTrue(session.text.contains("\"a\": 1"), session.text.debugDescription)
    }

    /// Every extension module in the bundled standard library has to load
    /// in a sub-interpreter. A module that doesn't would fail only for the
    /// programs that use it.
    func testEveryExtensionModuleImports() async throws {
        let session = try await LocalTestSession(shell: .dash)
        let program = """
            python3 -c 'import importlib, pkgutil, os, sys, _imp; \
            d = os.path.join(sys.prefix, "lib/python3.14/lib-dynload"); \
            names = sorted({f.split(".")[0] for f in os.listdir(d)}); \
            bad = []; \
            exec("for n in names:\\n try: importlib.import_module(n)\\n except Exception as e: bad.append(n + \\": \\" + repr(e))"); \
            print("modules", len(names), "failed", len(bad)); print(*bad, sep=chr(10))'\r
            """
        try await session.type(program)
        XCTAssertTrue(session.text.contains("failed 0\r\n"), session.text.debugDescription)
    }
}
