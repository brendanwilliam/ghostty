import Foundation
import ios_system

/// Process-wide setup for ios_system, done once.
enum LocalEnvironment {
    /// The shell's home: the app's Documents folder, which the Files app
    /// shows. Symlinks are resolved (`/var` is `/private/var` on device),
    /// because that's the form ios_system reports paths in.
    static let home: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let resolved = realpath(documents.path, nil) else { return documents }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }()

    /// dash, vim and lg2 ship only device slices, so simulator builds
    /// don't embed them. Without dash, `LocalBackend` falls back to its
    /// own prompt.
    static let hasDash: Bool = {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return false }
        return FileManager.default.fileExists(
            atPath: frameworks.appendingPathComponent("dash.framework").path)
    }()

    /// The process environment for the local shell, set once at launch.
    ///
    /// dash reads the process's own environment (ios_system's per-command
    /// copy, `ios_setenv`, isn't visible to it), so these have to be set
    /// there: ios_system's setup (PATH, `XDG_*_HOME`, `CLICOLOR`...) and the
    /// shell's own `HOME`, `TERM`, `LANG` and `ENV`.
    ///
    /// This has to run before `ghostty_init`. libghostty keeps a pointer to
    /// the process's `environ` array from then on, and adding a variable
    /// later makes libc reallocate that array, leaving libghostty reading
    /// freed memory (a crash the next time it creates a surface).
    /// `GhosttyRuntime` calls this first. Nothing may add to the process
    /// environment after it; commands started later only change their own
    /// copy.
    static func prepareProcess() {
        _ = process
    }

    private static let process: Void = {
        initializeEnvironment()
        setenv("HOME", home.path, 1)
        setenv("TERM", "xterm-256color", 1)
        setenv("LANG", "en_US.UTF-8", 1)
        setenv("LC_CTYPE", "UTF-8", 1)
        // dash reads this when it starts interactively.
        setenv("ENV", home.appendingPathComponent(".dashrc").path, 1)
    }()

    /// The rest of the setup, done when the first local shell starts.
    static func prepare() {
        prepareProcess()
        _ = once
    }

    private static let once: Void = {
        seedHome()
        // Commands from frameworks that ios_system's own dictionary
        // doesn't list (dash, vim, less, lg2).
        if let extra = Bundle.main.path(forResource: "localCommands", ofType: "plist"),
           let error = addCommandList(extra) {
            NSLog("Local shell: couldn't add commands: \(error)")
        }
    }()

    /// What dash reads at startup. Written once; the user may edit it.
    private static let dashrc = """
        # Read by every interactive dash (ENV points here).
        PS1='${PWD##*/} $ '
        """

    /// Files a new home folder starts with. Never overwrites.
    private static func seedHome() {
        let rc = home.appendingPathComponent(".dashrc")
        if !FileManager.default.fileExists(atPath: rc.path) {
            try? dashrc.write(to: rc, atomically: true, encoding: .utf8)
        }
    }
}
