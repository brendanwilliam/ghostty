import XCTest
@testable import GhosttyiOS

/// A running backend and everything it has written, as a terminal
/// would see it.
final class LocalTestSession: @unchecked Sendable {
    let backend: LocalBackend
    private let lock = NSLock()
    private var output = ""
    private var exited = false
    private var pump: Task<Void, Never>?

    init(shell: LocalBackend.Shell) async throws {
        backend = LocalBackend(shell: shell)
        pump = Task { [backend, weak self] in
            for await event in backend.events {
                switch event {
                case .output(let data):
                    self?.lock.withLock { self?.output += String(decoding: data, as: UTF8.self) }
                case .exited:
                    self?.lock.withLock { self?.exited = true }
                }
            }
        }
        try await backend.start(size: .default)
        try await waitFor { $0.hasSuffix(" $ ") }
    }

    deinit { backend.close() }

    var text: String { lock.withLock { output } }
    var hasExited: Bool { lock.withLock { exited } }

    /// Types `input`, waiting until the output ends in a new prompt.
    func type(_ input: String) async throws {
        let before = text.components(separatedBy: " $ ").count
        backend.write(Data(input.utf8))
        try await waitFor { $0.components(separatedBy: " $ ").count > before && $0.hasSuffix(" $ ") }
    }

    func waitFor(_ condition: @escaping (String) -> Bool,
                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(text) {
            if Date() > deadline {
                XCTFail("Timed out. Output so far: \(text.debugDescription)", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Presses Ctrl-C (again, up to four times, a second apart) until the
    /// output ends in a prompt after a "^C".
    func pressControlCUntilPrompt() async throws {
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(300))
            backend.write(Data("\u{3}".utf8))
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                if text.contains("^C") && text.hasSuffix(" $ ") { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await waitFor { $0.contains("^C") && $0.hasSuffix(" $ ") }
    }
}
