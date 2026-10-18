import Foundation

/// Launched with `-selftest`: types a script into a LocalBackend, prints
/// the transcript to stdout and exits. Lets the spike be checked from the
/// command line (`xcrun simctl launch --console-pty`) without tapping.
enum SelfTest {
    /// Each step is typed as keystrokes, then the test waits for the prompt.
    static let script: [String] = [
        "echo hello from ios_system\r",
        "pwd\r",
        "printf 'b\\na\\nc\\n' | sort | head -2\r",
        "mkdir -p spike && cd spike && pwd\r",
        "echo one > f.txt; cat f.txt | wc -c\r",
        "cd ..\r",
        "ls -d spike\r",
        // Cooked input to a running command: cat echoes one line, then EOF.
        "cat\r", "typed into cat\r", "\u{4}",
        // Backspace and history editing at the prompt.
        "echo abX\u{7F}c\r",
        "\u{1B}[A\r",
        // Ctrl-C a long-running command.
        "sleep 30\r", "\u{3}",
        "echo frameworks: \(LocalEnvironment.embeddedFrameworks.joined(separator: " "))\r",
        "dash -c 'for i in 1 2 3; do echo dash $i; done'\r",
        "echo done\r",
    ]

    /// `SPIKE_STEPS` (set via `SIMCTL_CHILD_SPIKE_STEPS`) replaces the
    /// script: lines separated by `;;`, each typed with Enter. `^C`, `^D`
    /// and `^[A` (up arrow) are sent without Enter.
    static var steps: [String] {
        guard let custom = ProcessInfo.processInfo.environment["SPIKE_STEPS"] else { return script }
        return custom.components(separatedBy: ";;").map { step in
            switch step {
            case "^C": return "\u{3}"
            case "^D": return "\u{4}"
            case "^[": return "\u{1B}"
            case "^L": return "\u{C}"
            case let resize where resize.hasPrefix("^R"): return resize
            default: return step.replacingOccurrences(of: "^[A", with: "\u{1B}[A") + "\r"
            }
        }
    }

    static func run() {
        // So a reader polling for the file never gets the last run's.
        try? FileManager.default.removeItem(at: LocalEnvironment.home.appendingPathComponent("selftest.txt"))
        let backend = LocalBackend()
        let transcript = Transcript()
        Task.detached {
            for await event in backend.events {
                if case .output(let data) = event { transcript.append(data) }
            }
        }
        Task.detached {
            try await backend.start(size: TerminalSize(columns: 80, rows: 24, widthPixels: 0, heightPixels: 0))
            for step in steps {
                // `^R<cols>x<rows>` resizes the terminal.
                if step.hasPrefix("^R") {
                    let parts = step.dropFirst(2).split(separator: "x").compactMap { Int($0) }
                    backend.resize(TerminalSize(columns: parts[0], rows: parts[1], widthPixels: 0, heightPixels: 0))
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                let mark = transcript.prompts
                let started = Date()
                backend.write(Data(step.utf8))
                // Steps that end a line wait for the next prompt; others
                // (input to a running command) just wait a moment.
                let endsCommand = step.hasSuffix("\r") || step == "\u{3}" || step == "\u{4}"
                while endsCommand && transcript.prompts == mark && Date().timeIntervalSince(started) < 10 {
                    try await Task.sleep(for: .milliseconds(50))
                }
                try await Task.sleep(for: .milliseconds(endsCommand ? 50 : 300))
            }
            try await Task.sleep(for: .milliseconds(300))
            var report = "=== SELFTEST TRANSCRIPT BEGIN ===\n\(transcript.text)\n=== SELFTEST TRANSCRIPT END ===\n"
            if ProcessInfo.processInfo.arguments.contains("-raw") {
                report += "=== RAW ===\n\(transcript.raw)\n"
            }
            print(report)
            fflush(stdout)
            // Also saved, for runs without a console: under
            // `simctl launch --console-pty` the app has a real /dev/tty,
            // which `less` reads keys from instead of ios_system's tty.
            try? report.write(
                to: LocalEnvironment.home.appendingPathComponent("selftest.txt"),
                atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}

/// Collected output, safe to append from the backend's reader thread.
final class Transcript: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }

    /// Output with escape sequences removed, CR dropped.
    var text: String {
        let raw = lock.withLock { String(decoding: data, as: UTF8.self) }
        return raw
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }

    /// Output with control bytes spelled out.
    var raw: String {
        let bytes = lock.withLock { data }
        return bytes.map { byte in
            switch byte {
            case 0x0A: return "\\n\n"
            case 0x0D: return "\\r"
            case 0x08: return "\\b"
            case 0x1B: return "\\e"
            case 0x20..<0x7F: return String(UnicodeScalar(byte))
            default: return String(format: "\\x%02x", byte)
            }
        }.joined()
    }

    /// How many prompts have been printed.
    var prompts: Int {
        lock.withLock { String(decoding: data, as: UTF8.self).components(separatedBy: " $ ").count - 1 }
    }
}
