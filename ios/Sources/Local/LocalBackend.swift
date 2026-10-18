import Foundation
import ios_system

/// Runs a shell on the phone with ios_system, for a terminal that works
/// with no network.
///
/// ios_system has no PTY: commands read and write pipes, and `ios_isatty`
/// tells them they're terminals. So this backend does the TTY's job too.
/// It echoes and edits typed lines (`LineDiscipline`) unless a full-screen
/// program has asked for raw input (`startInteractive`), and turns `\n`
/// into `\r\n` on output.
///
/// There are two shells:
/// - `dash` runs as one long-lived command and owns the session: variables,
///   `cd`, scripts and `&&` all work. This is the normal mode.
/// - `builtin` is a small prompt of our own that sends each line to
///   `ios_system`, which only understands pipes and redirection. It's for
///   builds without dash (the simulator, which has no dash slice).
final class LocalBackend: TerminalBackend, @unchecked Sendable {
    enum Shell {
        case dash, builtin
    }

    let events: AsyncStream<TerminalBackendEvent>
    private let continuation: AsyncStream<TerminalBackendEvent>.Continuation

    let shell: Shell

    /// ios_system identifies sessions (and their context) by pointer.
    /// This string lives as long as the backend.
    private let sessionID: UnsafeMutablePointer<CChar>

    /// Commands run one at a time, off the main thread.
    private let commandQueue = DispatchQueue(label: "LocalBackend.commands")

    private let lock = NSLock()
    private var size = TerminalSize.default
    private var discipline = LineDiscipline()
    private var running = false
    private var interactive = false
    private var closed = false

    /// The fake pid `ios_fork` gave the running command.
    private var commandPid: pid_t = 0
    /// Whether dash is waiting at its prompt: the last output ended in
    /// one, and nothing has been sent to it since.
    private var promptShown = false
    /// When Ctrl-C was last pressed with a command running and no prompt
    /// since. A second Ctrl-C then stops the command for good.
    private var interruptedAt: Date?

    /// Where a running command's input goes: its stdin, and the "tty"
    /// that pagers like `less` read keys from.
    private var stdinWriter: FileHandle?
    private var ttyWriter: FileHandle?

    /// All output (commands, echo, prompt) goes through one pipe, so it
    /// arrives in the order it was written.
    private let outputPipe = Pipe()
    private var outputFile: UnsafeMutablePointer<FILE>?
    private var lastOutputByte: UInt8 = 0

    init(shell: Shell? = nil) {
        self.shell = shell ?? (LocalEnvironment.hasDash ? .dash : .builtin)
        (events, continuation) = AsyncStream.makeStream()
        sessionID = strdup(UUID().uuidString)
    }

    deinit {
        free(sessionID)
    }

    // MARK: TerminalBackend

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
            self.continuation.yield(.output(self.translateNewlines(data)))
        }
        LocalBackend.register(self)
        commandQueue.async { [self] in
            ios_switchSession(sessionID)
            ios_setContext(sessionID)
            ios_setDirectoryURL(LocalEnvironment.home)
            switch shell {
            case .dash:
                execute("dash")
                // The shell exited: the tab is done.
                close()
            case .builtin:
                printPrompt()
            }
        }
    }

    func write(_ data: Data) {
        lock.lock()
        if running && interactive {
            // A full-screen program or pager has the keyboard: raw bytes.
            // (ios_system's current session is per thread.)
            ios_switchSession(sessionID)
            let target = ios_activePager() != 0 ? ttyWriter : stdinWriter
            lock.unlock()
            target?.write(data)
            return
        }
        // History belongs to the shell's own prompt, not to input typed
        // into a command the builtin shell is running.
        discipline.usesHistory = shell == .dash || !running
        let actions = discipline.feed(data)
        lock.unlock()
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
        if lock.withLock({ running }) { killCommand() }
        // The tab ends now, even if a command that ignores `ios_kill` is
        // still running on the command queue.
        outputPipe.fileHandleForReading.readabilityHandler = nil
        LocalBackend.unregister(self)
        continuation.yield(.exited(code: 0, message: nil))
        continuation.finish()
        commandQueue.async { [self] in
            ios_closeSession(sessionID)
            if let file = outputFile { fclose(file) }
        }
    }

    // MARK: Input

    private func handle(_ action: LineDiscipline.Action) {
        switch action {
        case .echo(let bytes):
            writeOutput(bytes)
        case .line(let text):
            if lock.withLock({ running }) {
                let writer = lock.withLock { () -> FileHandle? in
                    promptShown = false
                    return stdinWriter
                }
                writer?.write(Data((text + "\n").utf8))
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

    /// Ctrl-C while a command runs.
    ///
    /// In dash mode dash itself is always running, and the command to stop
    /// is the child it started (the innermost thread in this session).
    /// With no child, dash is either waiting at its prompt, where Ctrl-C
    /// just gets a fresh one, or busy in a loop of its own.
    ///
    /// ios_system stops a command with `pthread_cancel`, which only takes
    /// effect at a blocking call (a read, a write). That covers waiting for
    /// input and commands that print, but a command that's silently
    /// computing, like dash running `while true; do :; done`, ignores it.
    /// Nothing else reaches such a thread. Dash installs no SIGINT handler;
    /// SIGSEGV lands in libghostty's crash reporter; and terminating the
    /// thread (tried) leaves ios_system's internal locks held, which stops
    /// every session. So the user is told, and can close the tab, which
    /// leaves the thread spinning until the app is quit. Fixing this needs
    /// the command to poll for an interrupt itself (a patched dash).
    private func interruptCommand() {
        let (previous, idle, writer) = lock.withLock { (interruptedAt, promptShown, stdinWriter) }
        if shell == .dash && idle {
            writer?.write(Data("\n".utf8))
            return
        }
        if let previous, Date().timeIntervalSince(previous) > Self.stuckDelay {
            lock.withLock { interruptedAt = nil }
            writeOutput(Array("\r\n[can't interrupt this command; close the tab to leave it running]\r\n".utf8))
            return
        }
        lock.withLock { interruptedAt = Date() }
        killCommand(innermostOnly: shell == .dash)
    }

    /// `ios_kill` looks up the process's SIGINT handler, and if there is
    /// one calls it as a plain function (to let a command clean up, on the
    /// calling thread) before cancelling the command's thread. Two things
    /// follow:
    /// - libghostty's crash reporter owns SIGINT in this app. It's built to
    ///   run as a real signal handler and panics when called like that, so
    ///   it's put back to the default while `ios_kill` runs. A handler a
    ///   command installed itself (python, dash with `trap`) is left alone.
    /// - Handlers built for ios_system end with `exit`, which is
    ///   `pthread_exit`, so this runs on a thread of its own, never one the
    ///   app needs (libghostty's IO thread calls `write`).
    private func killCommand(innermostOnly: Bool = false) {
        let session = sessionID
        let root = lock.withLock { commandPid }
        Thread.detachNewThread {
            LocalBackend.withAppSigintHandlerMasked {
                ios_switchSession(session)
                guard innermostOnly else {
                    ios_kill()
                    return
                }
                // Cancel the innermost command, not the shell running it.
                if let last = ios_getLastThreadId(), last != ios_getThreadId(root) {
                    pthread_cancel(last)
                }
            }
        }
    }

    private static let sigintLock = NSLock()

    private static func withAppSigintHandlerMasked(_ body: () -> Void) {
        sigintLock.withLock {
            var saved = sigaction()
            sigaction(SIGINT, nil, &saved)
            var masked = false
            // The handler's address is 0 for the default and 1 for ignore.
            let address = unsafeBitCast(saved.__sigaction_u.__sa_handler, to: UInt.self)
            if address > 1 {
                var info = Dl_info()
                let image = dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0
                    ? info.dli_fname.map { String(cString: $0) } ?? "" : ""
                // Commands live in frameworks inside the app; anything else
                // is the app's own (libghostty).
                if !image.contains("/Frameworks/") {
                    var defaults = sigaction()
                    sigaction(SIGINT, &defaults, nil)
                    masked = true
                }
            }
            body()
            if masked { sigaction(SIGINT, &saved, nil) }
        }
    }

    /// How long a first Ctrl-C gets before a second one is taken to mean
    /// the command isn't stopping.
    private static let stuckDelay: TimeInterval = 0.3

    // MARK: Commands

    /// A line typed at the builtin prompt.
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
        commandQueue.async { [self] in
            execute(command)
            if shell == .builtin, !lock.withLock({ closed }) { printPrompt() }
        }
    }

    /// Runs one command line on the command queue and waits for it.
    private func execute(_ command: String) {
        // Fresh input pipes per command, so closing stdin (Ctrl-D) only
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
        // The process has one working directory for every tab, and
        // ios_system only restores a session's own when it switches from
        // another one on this thread. So set it here.
        if let directory = ios_getLogicalPWD(sessionID) {
            FileManager.default.changeCurrentDirectoryPath(directory)
        }
        ios_setWindowSize(Int32(size.columns), Int32(size.rows), sessionID)
        thread_stdin = nil
        thread_stdout = nil
        thread_stderr = nil
        ios_setStreams(stdinFile, outputFile, outputFile)
        ios_settty(ttyFile)

        // `ios_fork` makes a new "process" with its own copy of the
        // environment, and uses a global current pid, so no other tab may
        // fork in between.
        let pid = LocalBackend.forkLock.withLock { ios_fork() }
        lock.withLock {
            commandPid = pid
            interruptedAt = nil
            promptShown = false
        }
        // NFD, as file names on disk use it; the keyboard sends NFC.
        _ = ios_system(command.decomposedStringWithCanonicalMapping)
        ios_waitpid(pid)
        ios_releaseThreadId(pid)
        fflush(outputFile)

        lock.withLock {
            running = false
            interactive = false
            interruptedAt = nil
            stdinWriter = nil
            ttyWriter = nil
        }
        if let stdinFile { fclose(stdinFile) }
        if let ttyFile { fclose(ttyFile) }
    }

    // MARK: Output

    /// The builtin shell's prompt.
    private func printPrompt() {
        let directory = ios_getLogicalPWD(sessionID) ?? LocalEnvironment.home.path
        let name = directory == LocalEnvironment.home.path ? "~" : (directory as NSString).lastPathComponent
        // Leave mouse reporting and bracketed paste, in case a program
        // left them on.
        writeOutput(Array("\u{1B}[?1000l\u{1B}[?2004l\(name) $ ".utf8))
    }

    private func writeOutput(_ bytes: [UInt8]) {
        guard let file = outputFile, !bytes.isEmpty else { return }
        // Straight to the descriptor, after anything a command buffered.
        fflush(file)
        bytes.withUnsafeBytes { _ = Darwin.write(fileno(file), $0.baseAddress, $0.count) }
    }

    private static let promptEnd = Data("$ ".utf8)

    /// A TTY turns `\n` into `\r\n` (ONLCR). Full-screen programs move the
    /// cursor themselves, so they're left alone.
    private func translateNewlines(_ data: Data) -> Data {
        let raw = lock.withLock { () -> Bool in
            // Output ending in a prompt means the command has come back.
            let atPrompt = data.suffix(2) == Self.promptEnd
            if atPrompt { interruptedAt = nil }
            promptShown = atPrompt
            return running && interactive
        }
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
        lock.withLock { interactive = value }
    }

    fileprivate var isInteractive: Bool {
        lock.withLock { interactive }
    }

    private static let forkLock = NSLock()

    // ios_system calls the app's interactive hooks with no argument; the
    // session's context (our sessionID) says which backend they're for.
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
