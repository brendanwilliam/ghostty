import CryptoKit
import Foundation

/// Runs each pane's shell inside a [zmx](https://github.com/neurosnap/zmx)
/// session on the host, so it outlives the SSH connection: iOS suspends
/// and kills the app, which drops the connection, and reattaching picks up
/// the same shell with its screen redrawn.
///
/// Everything runs through the user's login shell (`$SHELL -lc`) so
/// Homebrew's PATH is set, the same as Terminal on the Mac.
enum ZmxSession {
    /// Session names this app creates. `zmx list` filters on it.
    static let namePrefix = "gios-"

    /// The zmx session for a pane, stable across launches:
    /// `gios-<device>-<pane>`.
    static func name(for pane: UUID, device: String) -> String {
        let hex = pane.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return devicePrefix(device) + hex.prefix(8)
    }

    /// Names of sessions this device made, so another phone's are left
    /// alone.
    static func devicePrefix(_ device: String) -> String {
        namePrefix + device + "-"
    }

    /// Identifies this device in session names: the start of its SSH
    /// key's fingerprint, which lives as long as the key does.
    static func deviceTag(publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    /// What a probe found on the host.
    struct Probe: Equatable, Codable {
        /// Absolute path to zmx, if installed.
        var zmx: String?
        /// Absolute path to Homebrew, used to offer installing zmx.
        var brew: String?
        /// This app's sessions running on the host.
        var sessions: [String] = []
    }

    /// Prints zmx's and Homebrew's paths and, if zmx is there, the app's
    /// sessions, one per line: `zmx <path>`, `brew <path>`, `session <name>`.
    static var probeCommand: String {
        loginShell("""
            z=$(command -v zmx); b=$(command -v brew)
            [ -n "$z" ] && echo "zmx $z"
            [ -n "$b" ] && echo "brew $b"
            [ -n "$z" ] && "$z" list --short 2>/dev/null | grep '^\(namePrefix)' | sed 's/^/session /'
            true
            """)
    }

    static func parseProbe(_ output: String) -> Probe {
        var probe = Probe()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "zmx": probe.zmx = parts[1]
            case "brew": probe.brew = parts[1]
            case "session" where parts[1].hasPrefix(namePrefix): probe.sessions.append(parts[1])
            default: break
            }
        }
        return probe
    }

    /// Attach to (creating if needed) `name`, as the PTY's command.
    /// Ctrl+\ is passed to programs rather than detaching.
    static func attachCommand(zmx: String, name: String) -> String {
        loginShell("ZMX_NO_DETACH_KEY=1 exec \(quote(zmx)) attach \(quote(name))")
    }

    /// Prints the app's running sessions, one name per line.
    static func listCommand(zmx: String) -> String {
        loginShell("\(quote(zmx)) list --short 2>/dev/null; true")
    }

    static func parseList(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(namePrefix) }
    }

    /// Ends sessions. Missing ones are ignored.
    static func killCommand(zmx: String, names: [String]) -> String {
        loginShell("\(quote(zmx)) kill \(names.map(quote).joined(separator: " ")) >/dev/null 2>&1; true")
    }

    /// Installs zmx with Homebrew, output and errors included.
    static func installCommand(brew: String) -> String {
        loginShell("\(quote(brew)) install neurosnap/tap/zmx 2>&1")
    }

    /// Runs `script` in the user's login shell.
    static func loginShell(_ script: String) -> String {
        "exec \"${SHELL:-/bin/sh}\" -lc \(quote(script))"
    }

    /// Single-quotes `s` for a POSIX shell.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
