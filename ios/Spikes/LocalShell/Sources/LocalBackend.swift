import Foundation
import ios_system

/// Runs commands on the phone with ios_system. Each line typed at the
/// prompt goes to `ios_system`, which parses pipes and redirection and
/// runs each command on its own thread, wired to this backend's pipes.
///
/// ios_system has no PTY: commands get pipes and `ios_isatty` says
/// they're terminals. So this backend does the TTY's job too: it echoes
/// and edits lines (`LineDiscipline`) unless a full-screen program has
/// asked for raw input (`startInteractive`), and turns `\n` into `\r\n`.
final class LocalBackend: TerminalBackend, @unchecked Sendable {
    let events: AsyncStream<TerminalBackendEvent>
    private let continuation: AsyncStream<TerminalBackendEvent>.Continuation

    /// ios_system identifies sessions (and their context) by pointer.
    /// This string lives as long as the backend.
    let sessionID: UnsafeMutablePointer<CChar>

    /// Commands run one at a time, off the main thread.
    private let commandQueue = DispatchQueue(label: "LocalBackend.commands")

    private let lock = NSLock()
    private var size = TerminalSize.default
    private var discipline = LineDiscipline()
    private var running = false
    private var interactive = false
    private var closed = false

    /// The fake pid `ios_fork` gave the running command (spike: Ctrl-C tests).
    private var commandPid: pid_t = 0

    /// Where command input goes while a command runs: stdin, and the
    /// "tty" that pagers like `less` read keys from.
    private var stdinWriter: FileHandle?
    private var ttyWriter: FileHandle?

    /// All output (commands, echo, prompt) goes through one pipe, so it
    /// arrives in the order it was written.
    private let outputPipe = Pipe()
    private var outputFile: UnsafeMutablePointer<FILE>?
    private var lastOutputByte: UInt8 = 0

    init() {
        (events, continuation) = AsyncStream.makeStream()
        sessionID = strdup(UUID().uuidString)
    }

    deinit {
        free(sessionID)
    }

    func start(size: TerminalSize) async throws {
        LocalEnvironment.prepare()
        lock.withLock { self.size = size }
        outputFile = fdopen(dup(outputPipe.fileHandleForWriting.fileDescriptor), "w")
        // Unbuffered, so nothing a command wrote can show up after the
        // next prompt.
        setvbuf(outputFile, nil, _IONBF, 0)
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            debugLog("output \(String(decoding: data, as: UTF8.self).debugDescription)")
            self.continuation.yield(.output(self.translateNewlines(data)))
        }
        LocalBackend.register(self)
        commandQueue.async {
            ios_switchSession(self.sessionID)
            ios_setContext(self.sessionID)
            ios_setDirectoryURL(LocalEnvironment.home)
            self.printPrompt()
        }
    }

    func write(_ data: Data) {
        lock.lock()
        if running && interactive {
            // ios_system's current session is per thread.
            ios_switchSession(sessionID)
            let pager = ios_activePager() != 0
            let target = pager ? ttyWriter : stdinWriter
            lock.unlock()
            debugLog("raw \(String(decoding: data, as: UTF8.self).debugDescription) -> \(pager ? "tty" : "stdin") \(target == nil ? "(none)" : "")")
            target?.write(data)
            return
        }
        discipline.usesHistory = !running
        let actions = discipline.feed(data)
        lock.unlock()
        debugLog("input \(String(decoding: data, as: UTF8.self).debugDescription) -> \(actions)")
        for action in actions { handle(action) }
    }

    func resize(_ size: TerminalSize) {
        lock.withLock { self.size = size }
        ios_setWindowSize(Int32(size.columns), Int32(size.rows), sessionID)
    }

    func close() {
        let wasClosed = lock.withLock {
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        if lock.withLock({ running }) {
            ios_switchSession(sessionID)
            ios_kill()
        }
        commandQueue.async {
            ios_closeSession(self.sessionID)
            LocalBackend.unregister(self)
            self.outputPipe.fileHandleForReading.readabilityHandler = nil
            if let file = self.outputFile { fclose(file) }
            self.continuation.yield(.exited(code: 0, message: nil))
            self.continuation.finish()
        }
    }

    // MARK: Input

    private func handle(_ action: LineDiscipline.Action) {
        switch action {
        case .echo(let bytes):
            writeOutput(bytes)
        case .line(let text):
            if lock.withLock({ running }) {
                lock.withLock { stdinWriter }?.write(Data((text + "\n").utf8))
            } else {
                run(text)
            }
        case .interrupt:
            if lock.withLock({ running }) {
                interruptCommand()
            } else {
                printPrompt()
            }
        case .endOfFile:
            if lock.withLock({ running }) {
                // Closing stdin is how a reader sees end of input.
                let writer = lock.withLock {
                    defer { stdinWriter = nil }
                    return stdinWriter
                }
                try? writer?.close()
            } else {
                close()
            }
        }
    }

    // MARK: Commands

    private func run(_ line: String) {
        let command = line.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else {
            printPrompt()
            return
        }
        if command == "exit" {
            close()
            return
        }
        commandQueue.async { self.execute(command) }
    }

    /// Runs one command line on the command queue and waits for it.
    private func execute(_ command: String) {
        // Fresh input pipes per command, so Ctrl-D (closing stdin) only
        // ends this one.
        let stdinPipe = Pipe()
        let ttyPipe = Pipe()
        let stdinFile = fdopen(dup(stdinPipe.fileHandleForReading.fileDescriptor), "r")
        let ttyFile = fdopen(dup(ttyPipe.fileHandleForReading.fileDescriptor), "r")
        let size = lock.withLock {
            stdinWriter = stdinPipe.fileHandleForWriting
            ttyWriter = ttyPipe.fileHandleForWriting
            running = true
            interactive = false
            return self.size
        }

        ios_switchSession(sessionID)
        ios_setContext(sessionID)
        ios_setWindowSize(Int32(size.columns), Int32(size.rows), sessionID)
        thread_stdin = nil
        thread_stdout = nil
        thread_stderr = nil
        ios_setStreams(stdinFile, outputFile, outputFile)
        ios_settty(ttyFile)

        let pid = ios_fork()
        lock.withLock { commandPid = pid }
        // NFD, as file names on disk use it; the keyboard sends NFC.
        debugLog("exec \(command.debugDescription) pid=\(pid)")
        let status = ios_system(command.decomposedStringWithCanonicalMapping)
        debugLog("ios_system returned \(status)")
        ios_waitpid(pid)
        debugLog("waitpid returned")
        ios_releaseThreadId(pid)
        fflush(outputFile)

        lock.withLock {
            running = false
            interactive = false
            stdinWriter = nil
            ttyWriter = nil
        }
        if let stdinFile { fclose(stdinFile) }
        if let ttyFile { fclose(ttyFile) }

        if !lock.withLock({ closed }) { printPrompt() }
    }

    /// Ctrl-C while a command runs. `SPIKE_CTRLC` picks the strategy:
    /// `kill` (ios_kill), `pid` (SIGINT to the command's own thread) or
    /// `both` (ios_kill, then SIGINT 300 ms later if it's still running).
    private func interruptCommand() {
        let strategy = ProcessInfo.processInfo.environment["SPIKE_CTRLC"] ?? "kill"
        let pid = lock.withLock { commandPid }
        debugLog("interrupt strategy=\(strategy) pid=\(pid)")
        var current = sigaction()
        sigaction(SIGINT, nil, &current)
        let handler = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
        var info = Dl_info()
        let symbol = dladdr(UnsafeRawPointer(bitPattern: handler), &info) != 0
            ? "\(info.dli_sname.map { String(cString: $0) } ?? "?") in \(info.dli_fname.map { String(cString: $0).split(separator: "/").suffix(2).joined(separator: "/") } ?? "?")"
            : "unknown"
        debugLog("SIGINT disposition: handler=0x\(String(handler, radix: 16)) \(symbol) flags=\(current.sa_flags)")
        debugLog("thread for pid: \(String(describing: ios_getThreadId(pid))) main? \(Thread.isMainThread)")
        ios_switchSession(sessionID)
        switch strategy {
        case "pid":
            debugLog("ios_killpid -> \(ios_killpid(pid, SIGINT))")
        case "sig":
            // Any signal: SPIKE_SIG is its number.
            let number = Int32(ProcessInfo.processInfo.environment["SPIKE_SIG"] ?? "") ?? SIGINT
            debugLog("ios_killpid(\(number)) -> \(ios_killpid(pid, number))")
        case "both":
            ios_kill()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.lock.withLock({ self.running && self.commandPid == pid }) else { return }
                debugLog("still running; ios_killpid -> \(ios_killpid(pid, SIGINT))")
            }
        default:
            ios_kill()
        }
    }

    // MARK: Output

    private func printPrompt() {
        let directory = ios_getLogicalPWD(sessionID) ?? LocalEnvironment.home.path
        let name = directory == LocalEnvironment.home.path ? "~" : (directory as NSString).lastPathComponent
        // Leave mouse reporting and bracketed paste, in case a program
        // left them on.
        writeOutput(Array("\u{1B}[?1000l\u{1B}[?2004l\(name) $ ".utf8))
    }

    private func writeOutput(_ bytes: [UInt8]) {
        guard let file = outputFile, !bytes.isEmpty else { return }
        // Straight to the descriptor, after anything the command buffered.
        fflush(file)
        bytes.withUnsafeBytes { _ = Darwin.write(fileno(file), $0.baseAddress, $0.count) }
    }

    /// A TTY turns `\n` into `\r\n` (ONLCR). Full-screen programs move the
    /// cursor themselves, so they're left alone.
    private func translateNewlines(_ data: Data) -> Data {
        let raw = lock.withLock { running && interactive }
        var out = Data(capacity: data.count + 16)
        for byte in data {
            if byte == 0x0A && lastOutputByte != 0x0D && !raw { out.append(0x0D) }
            out.append(byte)
            lastOutputByte = byte
        }
        return out
    }

    // MARK: Interactive mode (called by ios_system)

    fileprivate func setInteractive(_ value: Bool) {
        debugLog("interactive = \(value)")
        lock.withLock { interactive = value }
    }

    fileprivate var isInteractive: Bool {
        lock.withLock { interactive }
    }

    // ios_system calls the app's interactive hooks with no argument;
    // the session's context (our sessionID) says which backend they're for.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [UnsafeRawPointer: LocalBackend] = [:]

    private static func register(_ backend: LocalBackend) {
        registryLock.withLock { registry[UnsafeRawPointer(backend.sessionID)] = backend }
    }

    private static func unregister(_ backend: LocalBackend) {
        registryLock.withLock { _ = registry.removeValue(forKey: UnsafeRawPointer(backend.sessionID)) }
    }

    fileprivate static var current: LocalBackend? {
        guard let context = ios_getContext() else { return nil }
        return registryLock.withLock { registry[context] }
    }
}

/// Spike-only tracing, on with `-debug`.
func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.arguments.contains("-debug") else { return }
    FileHandle.standardError.write(Data("[spike \(Date().timeIntervalSince1970)] \(message())\n".utf8))
}

// ios_system looks these up by name in the main executable (dlsym) when a
// command takes over the keyboard (vim, less) or hands it back.

@_cdecl("startInteractive")
func startInteractive() {
    LocalBackend.current?.setInteractive(true)
}

@_cdecl("stopInteractive")
func stopInteractive() {
    LocalBackend.current?.setInteractive(false)
}

@_cdecl("storeInteractive")
func storeInteractive() -> Int32 {
    LocalBackend.current?.isInteractive == true ? 1 : 0
}
