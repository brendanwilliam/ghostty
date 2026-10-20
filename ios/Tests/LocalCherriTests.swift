import Network
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
        XCTAssertTrue(session.text.contains("Undefined action"), session.text.debugDescription)
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

/// Signing goes to a server over the network; these use a local one.
final class LocalCherriSigningTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(LocalEnvironment.hasDash, "needs the real shell")
        let framework = Bundle.main.bundleURL.appendingPathComponent("Frameworks/cherri.framework")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: framework.path), "cherri isn't bundled")
    }

    func testWithoutAFlagNothingIsSent() async throws {
        let server = try SigningServer(reply: .signed)
        defer { server.stop() }
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("mkdir -p cherri-sign && cd cherri-sign && echo 'alert(\"x\")' > a.cherri\r")
        try await session.type("cherri a.cherri; echo status $?\r")
        XCTAssertTrue(session.text.contains("status 0\r\n"), session.text.debugDescription)
        XCTAssertTrue(session.text.contains("unsigned"), session.text.debugDescription)
        XCTAssertEqual(server.requests, 0)
        try await session.type("cd .. && rm -r cherri-sign\r")
    }

    func testASigningServerReturnsASignedShortcut() async throws {
        let server = try SigningServer(reply: .signed)
        defer { server.stop() }
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("mkdir -p cherri-sign && cd cherri-sign && echo 'alert(\"x\")' > a.cherri\r")
        try await session.type("cherri a.cherri --signing-server=http://127.0.0.1:\(server.port)/sign; echo status $?\r")
        XCTAssertTrue(session.text.contains("status 0\r\n"), session.text.debugDescription)
        XCTAssertTrue(session.text.contains("(signed)"), session.text.debugDescription)
        XCTAssertEqual(server.requests, 1)
        XCTAssertTrue(server.lastBody.contains("\"shortcutName\":\"a\""), server.lastBody)
        try await session.type("head -c 4 a.shortcut; echo; ls\r")
        XCTAssertTrue(session.text.contains("AEA1"), session.text.debugDescription)
        XCTAssertFalse(session.text.contains("a_unsigned"), session.text.debugDescription)
        try await session.type("cd .. && rm -r cherri-sign\r")
    }

    func testAFailedSigningKeepsTheUnsignedShortcut() async throws {
        let server = try SigningServer(reply: .failure)
        defer { server.stop() }
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("mkdir -p cherri-sign && cd cherri-sign && echo 'alert(\"x\")' > a.cherri\r")
        try await session.type("cherri a.cherri --signing-server=http://127.0.0.1:\(server.port)/sign; echo status $?\r")
        XCTAssertTrue(session.text.contains("status 1\r\n"), session.text.debugDescription)
        XCTAssertTrue(session.text.contains("kept the unsigned shortcut"), session.text.debugDescription)
        try await session.type("ls\r")
        XCTAssertTrue(session.text.contains("a.shortcut"), session.text.debugDescription)
        try await session.type("cd .. && rm -r cherri-sign\r")
    }

    func testOfflineKeepsTheUnsignedShortcut() async throws {
        let session = try await LocalTestSession(shell: .dash)
        try await session.type("mkdir -p cherri-sign && cd cherri-sign && echo 'alert(\"x\")' > a.cherri\r")
        // Nothing listens on port 1.
        try await session.type("cherri a.cherri --signing-server=http://127.0.0.1:1/sign; echo status $?\r")
        XCTAssertTrue(session.text.contains("status 1\r\n"), session.text.debugDescription)
        try await session.type("ls\r")
        XCTAssertTrue(session.text.contains("a.shortcut"), session.text.debugDescription)
        try await session.type("cd .. && rm -r cherri-sign\r")
    }
}

/// A one-endpoint HTTP server standing in for a shortcut-signing-server.
final class SigningServer: @unchecked Sendable {
    enum Reply { case signed, failure }

    private let listener: NWListener
    private let reply: Reply
    private let lock = NSLock()
    private var _requests = 0
    private var _lastBody = ""

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var requests: Int { lock.withLock { _requests } }
    var lastBody: String { lock.withLock { _lastBody } }

    init(reply: Reply) throws {
        self.reply = reply
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        var received = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, error in
                guard let self, error == nil else { return }
                received += data ?? Data()
                let text = String(decoding: received, as: UTF8.self)
                guard let split = text.range(of: "\r\n\r\n") else { return read() }
                let head = text[..<split.lowerBound]
                let length = head.lowercased().components(separatedBy: "content-length:").dropFirst().first
                    .flatMap { Int($0.prefix { $0 != "\r" }.trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = String(text[split.upperBound...])
                guard body.utf8.count >= length else { return read() }
                self.lock.withLock { self._requests += 1; self._lastBody = body }
                let response: Data
                switch self.reply {
                case .signed:
                    let payload = Data("AEA1 signed".utf8)
                    response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8) + payload
                case .failure:
                    response = Data("HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/octet-stream\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        read()
    }
}
