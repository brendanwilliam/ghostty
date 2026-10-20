import XCTest
@testable import GhosttyiOS

/// `cherri`, the Shortcuts compiler, as a command typed into dash.
final class LocalCherriTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(LocalEnvironment.hasDash, "needs the real shell")
        let framework = Bundle.main.bundleURL.appendingPathComponent("Frameworks/cherri.framework")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: framework.path), "cherri isn't bundled")
    }

    func testPrintsItsVersion() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("cherri --version\r")
        XCTAssertTrue(session.text.contains("Cherri Compiler"), session.text.debugDescription)
    }

    func testCompilesAProgramToAShortcutFile() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("mkdir -p cherri-test && cd cherri-test\r")
        try await session.type("echo 'alert(\"hi\")' > hello.cherri\r")
        try await session.type("cherri hello.cherri; echo status $?\r")
        XCTAssertTrue(session.text.contains("status 0\r\n"), session.text.debugDescription)
        XCTAssertTrue(session.text.contains("hello.shortcut"), session.text.debugDescription)
        try await session.type("ls\r")
        XCTAssertTrue(session.text.contains("hello.shortcut"), session.text.debugDescription)
        XCTAssertFalse(session.text.contains("_unsigned"), session.text.debugDescription)
        try await session.type("cd .. && rm -r cherri-test\r")
    }

    func testASyntaxErrorReportsAStatus() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("mkdir -p cherri-test && cd cherri-test\r")
        try await session.type("echo 'nonsense(' > bad.cherri\r")
        try await session.type("cherri bad.cherri; echo status $?\r")
        XCTAssertTrue(session.text.contains("status 1\r\n"), session.text.debugDescription)
        try await session.type("cherri bad.cherri; echo status $?\r")
        XCTAssertTrue(session.text.contains("Error"), session.text.debugDescription)
        // The app is still here and compiles again afterwards.
        try await session.type("echo 'alert(\"ok\")' > ok.cherri\r")
        try await session.type("cherri ok.cherri; echo status $?\r")
        XCTAssertTrue(session.text.contains("status 0\r\n"), session.text.debugDescription)
        try await session.type("cd .. && rm -r cherri-test\r")
    }

    /// State from one compile (variables, actions) mustn't leak into the next.
    func testRunsAgainWithFreshState() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("mkdir -p cherri-test && cd cherri-test\r")
        try await session.type("echo '@greeting = \"a\"' > one.cherri; echo '@greeting = \"b\"' > two.cherri\r")
        for name in ["one", "two", "one", "two"] {
            try await session.type("cherri \(name).cherri; echo status $?\r")
        }
        XCTAssertEqual(session.text.components(separatedBy: "status 0\r\n").count - 1, 4, session.text.debugDescription)
        try await session.type("cd .. && rm -r cherri-test\r")
    }

    func testCompilesInTwoTabsAtOnce() async throws {
        let a = try await LocalTestSession(shell: .dash)
        let b = try await LocalTestSession(shell: .dash)
        for (s, n) in [(a, "a"), (b, "b")] {
            try await s.type("mkdir -p cherri-\(n) && cd cherri-\(n) && echo 'alert(\"\(n)\")' > x.cherri\r")
        }
        a.backend.write(Data("cherri x.cherri; echo done-a\r".utf8))
        b.backend.write(Data("cherri x.cherri; echo done-b\r".utf8))
        try await a.waitFor { $0.contains("done-a\r\n") && $0.hasSuffix(" $ ") }
        try await b.waitFor { $0.contains("done-b\r\n") && $0.hasSuffix(" $ ") }
        XCTAssertTrue(a.text.contains("Wrote"), a.text.debugDescription)
        XCTAssertTrue(b.text.contains("Wrote"), b.text.debugDescription)
        try await a.type("cd .. && rm -r cherri-a\r")
        try await b.type("cd .. && rm -r cherri-b\r")
    }
}

final class ShortcutFilesTests: XCTestCase {
    func testFindsShortcutFilesNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-files-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.shortcut")
        let new = sub.appendingPathComponent("new.shortcut")
        try Data().write(to: old)
        try Data().write(to: new)
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: old.path)
        XCTAssertEqual(ShortcutFilesView.shortcutFiles(in: root).map(\.lastPathComponent), ["new.shortcut", "old.shortcut"])
    }
}
