import Foundation

/// A Ghostty config file as editable lines. Comments, blank lines, and
/// line order are preserved so that editing one key through Settings
/// doesn't rewrite the rest of a hand-written file.
struct ConfigFile: Equatable {
    enum Line: Equatable {
        case entry(key: String, value: String)
        case other(String)
    }

    var lines: [Line]

    init(lines: [Line] = []) {
        self.lines = lines
    }

    init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            return Self.parse(line)
        }
        // A trailing newline yields one empty element; don't keep it as a line.
        if lines.last == .other("") { lines.removeLast() }
    }

    init(contentsOf url: URL) {
        self.init(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    static func parse(_ line: String) -> Line {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let eq = trimmed.firstIndex(of: "=") else {
            return .other(line)
        }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return .other(line) }
        let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return .entry(key: key, value: value)
    }

    var text: String {
        lines.map { line in
            switch line {
            case .entry(let key, let value): return "\(key) = \(value)"
            case .other(let raw): return raw
            }
        }.joined(separator: "\n") + "\n"
    }

    /// All `(key, value)` entries in order.
    var entries: [(key: String, value: String)] {
        lines.compactMap {
            if case .entry(let key, let value) = $0 { return (key, value) }
            return nil
        }
    }

    /// Every value set for `key`, in order. Repeatable keys like
    /// `palette` or `font-family` can have several.
    func values(_ key: String) -> [String] {
        entries.filter { $0.key == key }.map(\.value)
    }

    /// The effective value of a single-valued key (the last one wins).
    func value(_ key: String) -> String? {
        values(key).last
    }

    var keys: Set<String> { Set(entries.map(\.key)) }

    /// Replace all values for `key`. The first existing entry keeps its
    /// position; new keys are appended. An empty list removes the key.
    mutating func set(_ key: String, values newValues: [String]) {
        let firstIndex = lines.firstIndex {
            if case .entry(let k, _) = $0 { return k == key }
            return false
        }
        lines.removeAll {
            if case .entry(let k, _) = $0 { return k == key }
            return false
        }
        let newLines = newValues.map { Line.entry(key: key, value: $0) }
        if let firstIndex {
            lines.insert(contentsOf: newLines, at: min(firstIndex, lines.count))
        } else {
            lines.append(contentsOf: newLines)
        }
    }

    mutating func set(_ key: String, _ value: String?) {
        set(key, values: value.map { [$0] } ?? [])
    }

    mutating func remove(_ key: String) {
        set(key, values: [])
    }
}
