import Foundation

/// Fetches a host's Ghostty config over SSH and turns it into a config
/// that's safe and meaningful on iOS.
///
/// The fetcher only needs a way to run a shell command on the host, so it
/// can be tested without SSH.
struct RemoteConfigFetcher {
    /// Runs a command on the host and returns its stdout.
    typealias Runner = @Sendable (String) async throws -> Data

    /// Keys dropped from the host's config. They either launch processes
    /// or describe desktop windowing, neither of which applies to a
    /// terminal on the phone whose program runs on the host.
    static let droppedKeys: Set<String> = [
        "command", "initial-command", "working-directory", "input",
        "config-file", "keybind", "window-save-state", "wait-after-command",
    ]

    static let droppedPrefixes = [
        "macos-", "gtk-", "linux-", "x11-", "quick-terminal-",
        "auto-update", "shell-integration", "window-position-",
    ]

    /// Ghostty's default config locations, in the order it loads them.
    static let defaultLocations = [
        "${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config",
        "${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config.ghostty",
        "$HOME/Library/Application Support/com.mitchellh.ghostty/config",
        "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
    ]

    static let maxIncludeDepth = 5
    static let maxTotalBytes = 1 << 20
    private static let fileMarker = "@@GHOSTTY-IOS-FILE@@"

    struct Result: Equatable {
        /// The sanitized config, ready to load as a layer.
        var config: ConfigFile
        /// Theme files the config refers to that aren't bundled, by name.
        var themes: [String: Data]
        /// Remote files that were read, in load order.
        var sources: [String]
        /// Lines that were removed, as `key = value`.
        var dropped: [String]
    }

    let run: Runner
    /// Whether a theme name ships in the app bundle.
    let isBundledTheme: (String) -> Bool

    func fetch() async throws -> Result {
        var sources: [String] = []
        var collected: [(path: String, text: String)] = []
        var totalBytes = 0

        // Round 0 reads the default locations; later rounds read
        // `config-file` includes, which Ghostty loads after the files
        // that name them.
        var pending = Self.defaultLocations.map { (path: $0, optional: true) }
        var home = ""
        for depth in 0...Self.maxIncludeDepth where !pending.isEmpty {
            let files = try await readFiles(pending.map(\.path), includeHome: depth == 0)
            if depth == 0 { home = files.home }
            var next: [(path: String, optional: Bool)] = []
            for file in files.contents {
                totalBytes += file.text.utf8.count
                guard totalBytes <= Self.maxTotalBytes else { break }
                sources.append(file.path)
                collected.append((file.path, file.text))
                for include in Self.includes(in: ConfigFile(text: file.text)) {
                    let resolved = Self.resolve(include.path, relativeTo: file.path, home: home)
                    if !sources.contains(resolved) {
                        next.append((resolved, include.optional))
                    }
                }
            }
            pending = next
        }

        var config = ConfigFile()
        var dropped: [String] = []
        for file in collected {
            config.lines.append(.other("# from \(file.path)"))
            for line in ConfigFile(text: file.text).lines {
                if case .entry(let key, let value) = line, Self.shouldDrop(key) {
                    dropped.append("\(key) = \(value)")
                    continue
                }
                config.lines.append(line)
            }
        }

        // Fetch custom themes the app doesn't ship.
        var themes: [String: Data] = [:]
        let names = Set(config.values("theme").flatMap(Self.themeNames))
        let missing = names.filter { !isBundledTheme($0) && Self.isSafeThemeName($0) }.sorted()
        if !missing.isEmpty {
            let paths = missing.map { "${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/themes/\($0)" }
            let files = try await readFiles(paths, includeHome: false)
            for (name, path) in zip(missing, paths) {
                if let file = files.contents.first(where: { $0.requested == path }) {
                    themes[name] = Data(file.text.utf8)
                }
            }
        }
        for absolute in names.filter({ $0.hasPrefix("/") }) {
            let files = try await readFiles([absolute], includeHome: false)
            let name = (absolute as NSString).lastPathComponent
            if let file = files.contents.first, Self.isSafeThemeName(name) {
                themes[name] = Data(file.text.utf8)
            }
        }

        return Result(config: config, themes: themes, sources: sources, dropped: dropped)
    }

    /// Theme names become file names in the cache, so they must be a
    /// single path component.
    static func isSafeThemeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    static func shouldDrop(_ key: String) -> Bool {
        droppedKeys.contains(key) || droppedPrefixes.contains { key.hasPrefix($0) }
    }

    /// `config-file` entries. A leading `?` marks the file optional.
    static func includes(in file: ConfigFile) -> [(path: String, optional: Bool)] {
        file.values("config-file").compactMap { raw in
            var value = unquote(raw)
            guard !value.isEmpty else { return nil }
            let optional = value.hasPrefix("?")
            if optional { value.removeFirst() }
            return (value, optional)
        }
    }

    /// Resolve an include path the way Ghostty does: `~/` is the home
    /// directory and relative paths are relative to the including file.
    static func resolve(_ path: String, relativeTo file: String, home: String) -> String {
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        if path.hasPrefix("/") { return path }
        let dir = (file as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent(path)
    }

    /// Theme names in a `theme` value: `Name` or `light:A,dark:B`.
    static func themeNames(_ value: String) -> [String] {
        let value = unquote(value)
        guard value.contains(":"), !value.hasPrefix("/") else { return value.isEmpty ? [] : [value] }
        return value.split(separator: ",").compactMap { part in
            let pair = part.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            let name = pair[1].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    // MARK: Remote file reading

    private struct RemoteFiles {
        struct File { var requested: String; var path: String; var text: String }
        var contents: [File]
        var home: String
    }

    /// Read files in one round trip. Each path is printed after a marker
    /// line holding its index and expanded path. Paths may use `$HOME`
    /// and `${XDG_CONFIG_HOME:-...}`, which the remote shell expands.
    private func readFiles(_ paths: [String], includeHome: Bool) async throws -> RemoteFiles {
        var script = ""
        for (index, path) in paths.enumerated() {
            let quoted = Self.shellDoubleQuoted(path)
            script += "f=\(quoted); if [ -f \"$f\" ]; then printf '\\n\(Self.fileMarker) \(index) %s\\n' \"$f\"; "
            script += "head -c \(Self.maxTotalBytes) \"$f\"; fi; "
        }
        if includeHome { script += "printf '\\n\(Self.fileMarker) home %s\\n' \"$HOME\"; " }
        script += "exit 0"

        let data = try await run("/bin/sh -c " + Self.shellSingleQuoted(script))
        return Self.parse(String(decoding: data, as: UTF8.self), requested: paths)
    }

    private static func parse(_ output: String, requested: [String]) -> RemoteFiles {
        var result = RemoteFiles(contents: [], home: "")
        let chunks = output.components(separatedBy: "\n\(fileMarker) ").dropFirst()
        for chunk in chunks {
            let header = chunk.prefix { $0 != "\n" }
            let body = String(chunk.dropFirst(header.count + 1))
            let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "home" {
                result.home = parts[1]
                continue
            }
            guard let index = Int(parts[0]), requested.indices.contains(index) else { continue }
            result.contents.append(.init(requested: requested[index], path: parts[1], text: body))
        }
        return result
    }

    /// Quote for `sh` inside double quotes so `$HOME` and
    /// `${XDG_CONFIG_HOME:-$HOME/.config}` expand but nothing else does.
    static func shellDoubleQuoted(_ path: String) -> String {
        let expandable = ["${XDG_CONFIG_HOME:-$HOME/.config}", "$HOME"]
        var out = "\""
        var rest = Substring(path)
        outer: while let ch = rest.first {
            for token in expandable where rest.hasPrefix(token) {
                out += token
                rest = rest.dropFirst(token.count)
                continue outer
            }
            if "$\"\\`".contains(ch) { out += "\\" }
            out.append(ch)
            rest = rest.dropFirst()
        }
        return out + "\""
    }

    static func shellSingleQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Per-host cache of the fetched config.
struct RemoteConfigCache {
    struct Metadata: Codable, Equatable {
        var fetchedAt: Date
        var sources: [String]
        var dropped: [String]
    }

    let directory: URL

    init(hostID: UUID) {
        directory = ConfigPaths.remoteDirectory(for: hostID)
    }

    init(directory: URL) {
        self.directory = directory
    }

    var configURL: URL { directory.appendingPathComponent("config.ghostty") }
    var themesURL: URL { directory.appendingPathComponent("themes") }
    private var metadataURL: URL { directory.appendingPathComponent("meta.json") }

    var exists: Bool { FileManager.default.fileExists(atPath: configURL.path) }

    var metadata: Metadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    var text: String? { try? String(contentsOf: configURL, encoding: .utf8) }

    /// Store a fetch result. Theme lines that name a fetched custom theme
    /// are rewritten to its absolute cached path. Returns whether the
    /// stored config changed.
    @discardableResult
    func store(_ result: RemoteConfigFetcher.Result, at date: Date = Date()) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: themesURL, withIntermediateDirectories: true)
        for (name, data) in result.themes {
            try data.write(to: themesURL.appendingPathComponent(name), options: .atomic)
        }

        var config = result.config
        if !result.themes.isEmpty {
            config.lines = config.lines.map { line in
                guard case .entry("theme", let value) = line else { return line }
                return .entry(key: "theme", value: rewriteTheme(value, themes: result.themes))
            }
        }

        let text = config.text
        let changed = self.text != text
        if changed {
            try text.write(to: configURL, atomically: true, encoding: .utf8)
        }
        let metadata = Metadata(fetchedAt: date, sources: result.sources, dropped: result.dropped)
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        return changed
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func rewriteTheme(_ value: String, themes: [String: Data]) -> String {
        func path(_ name: String) -> String {
            let key = name.hasPrefix("/") ? (name as NSString).lastPathComponent : name
            return themes[key] != nil ? themesURL.appendingPathComponent(key).path : name
        }
        let raw = RemoteConfigFetcher.unquote(value)
        guard raw.contains(":"), !raw.hasPrefix("/") else { return path(raw) }
        return raw.split(separator: ",").map { part in
            let pair = part.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { return String(part) }
            let name = pair[1].trimmingCharacters(in: .whitespaces)
            return "\(pair[0].trimmingCharacters(in: .whitespaces)):\(path(name))"
        }.joined(separator: ",")
    }
}
