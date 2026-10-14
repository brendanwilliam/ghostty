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
        /// The host's tailnet (Tailscale/Headscale) IPv4 address, if it's
        /// on one.
        var tailnetIP: String?
        /// The host's name on the local network (`name.local`), on macOS.
        var localName: String?
        /// Minutes of idle before the host sleeps on its current power
        /// source; 0 never sleeps. Nil if unknown (not macOS).
        var sleepMinutes: Int?

        /// Other ways to reach the host that it reported.
        var routes: [HostRoute] {
            var routes: [HostRoute] = []
            if let tailnetIP { routes.append(HostRoute(address: tailnetIP, kind: .tailnet)) }
            if let localName { routes.append(HostRoute(address: localName, kind: .lan)) }
            return routes
        }

        /// The host sleeps when idle, which pauses sessions and makes it
        /// unreachable.
        var sleeps: Bool { (sleepMinutes ?? 0) > 0 }
    }

    /// Prints what the host has, one fact per line:
    /// - `zmx <path>`, `brew <path>`, and the app's sessions, `session <name>`;
    /// - `tailnet <ip>`: its tailnet address, from the Tailscale CLI
    ///   (Homebrew's, or the Mac app's);
    /// - `local <name>.local` and `sleep <minutes>`, on macOS.
    static var probeCommand: String {
        loginShell("""
            z=$(command -v zmx); b=$(command -v brew)
            [ -n "$z" ] && echo "zmx $z"
            [ -n "$b" ] && echo "brew $b"
            [ -n "$z" ] && "$z" list --short 2>/dev/null | grep '^\(namePrefix)' | sed 's/^/session /'
            t=$(command -v tailscale)
            [ -z "$t" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] && t=/Applications/Tailscale.app/Contents/MacOS/Tailscale
            [ -n "$t" ] && "$t" ip -4 2>/dev/null | head -n 1 | sed 's/^/tailnet /'
            command -v scutil >/dev/null && echo "local $(scutil --get LocalHostName 2>/dev/null).local"
            command -v pmset >/dev/null && pmset -g 2>/dev/null | awk '$1 == "sleep" { print "sleep " $2 }'
            true
            """)
    }

    static func parseProbe(_ output: String) -> Probe {
        var probe = Probe()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "zmx": probe.zmx = value
            case "brew": probe.brew = value
            case "session" where value.hasPrefix(namePrefix): probe.sessions.append(value)
            case "tailnet" where HostRoute.kind(of: value) == .tailnet: probe.tailnetIP = value
            case "local" where value.count > ".local".count: probe.localName = value
            case "sleep": probe.sleepMinutes = Int(value)
            default: break
            }
        }
        return probe
    }

    /// Attach to (creating if needed) `name`, as the PTY's command.
    /// Ctrl+\ is passed to programs rather than detaching. On macOS,
    /// `caffeinate` keeps the host awake while attached.
    static func attachCommand(zmx: String, name: String) -> String {
        let attach = "\(quote(zmx)) attach \(quote(name))"
        return loginShell("""
            export ZMX_NO_DETACH_KEY=1
            if command -v caffeinate >/dev/null; then exec caffeinate -i \(attach); else exec \(attach); fi
            """)
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
