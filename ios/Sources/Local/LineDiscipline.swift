import Foundation

/// Cooked-mode input, standing in for a TTY's line discipline: ios_system
/// commands read from pipes, so nothing else echoes typing or handles
/// backspace. Used at the prompt and for commands that read lines (`cat`,
/// `dash`, the Python REPL); full-screen programs get raw bytes instead.
struct LineDiscipline {
    enum Action: Equatable {
        /// Bytes to show on screen.
        case echo([UInt8])
        /// A finished line (without its newline).
        case line(String)
        /// Ctrl-C.
        case interrupt
        /// Ctrl-D on an empty line.
        case endOfFile
    }

    private(set) var line: [UInt8] = []

    /// Whether up and down arrows step through history. Only at the
    /// prompt; a running command's input has none.
    var usesHistory = false
    private(set) var history: [String] = []
    private var historyIndex = 0

    /// Bytes still to skip from an escape sequence (arrow keys etc.).
    private var escape: [UInt8] = []

    mutating func feed(_ data: Data) -> [Action] {
        var actions: [Action] = []
        for byte in data {
            if !escape.isEmpty {
                escape.append(byte)
                if let older = finishEscape(), usesHistory, let redraw = stepHistory(older: older) {
                    actions.append(.echo(redraw))
                }
                continue
            }
            switch byte {
            case 0x1B:
                escape = [byte]
            case 0x0D, 0x0A:
                let text = String(decoding: line, as: UTF8.self)
                actions.append(.echo(Array("\r\n".utf8)))
                actions.append(.line(text))
                line.removeAll()
                if usesHistory {
                    let command = text.trimmingCharacters(in: .whitespaces)
                    if !command.isEmpty && history.last != command { history.append(command) }
                    historyIndex = history.count
                }
            case 0x7F, 0x08:
                guard !line.isEmpty else { continue }
                // Drop a whole UTF-8 character, not just its last byte.
                while let last = line.popLast(), last & 0xC0 == 0x80 {}
                actions.append(.echo(Array("\u{8} \u{8}".utf8)))
            case 0x03:
                line.removeAll()
                actions.append(.echo(Array("^C\r\n".utf8)))
                actions.append(.interrupt)
            case 0x04:
                if line.isEmpty { actions.append(.endOfFile) }
            case 0x15:
                actions.append(.echo(erase(count: characterCount)))
                line.removeAll()
            case 0x00..<0x20:
                continue
            default:
                line.append(byte)
                actions.append(.echo([byte]))
            }
        }
        return actions
    }

    /// Moves through history, returning the bytes that redraw the line.
    private mutating func stepHistory(older: Bool) -> [UInt8]? {
        guard !history.isEmpty else { return nil }
        historyIndex = older ? max(historyIndex - 1, 0) : min(historyIndex + 1, history.count)
        let text = historyIndex < history.count ? history[historyIndex] : ""
        let erased = erase(count: characterCount)
        line = Array(text.utf8)
        return erased + line
    }

    private var characterCount: Int {
        String(decoding: line, as: UTF8.self).count
    }

    private func erase(count: Int) -> [UInt8] {
        Array(String(repeating: "\u{8} \u{8}", count: count).utf8)
    }

    /// Ends an escape sequence once its final byte arrives. Returns
    /// whether it was up (true) or down (false); nil for anything else.
    private mutating func finishEscape() -> Bool? {
        // ESC alone followed by a non-CSI/SS3 byte: drop both.
        if escape.count == 2 && escape[1] != UInt8(ascii: "[") && escape[1] != UInt8(ascii: "O") {
            escape.removeAll()
            return nil
        }
        guard escape.count > 2, let last = escape.last, (0x40...0x7E).contains(last) else { return nil }
        defer { escape.removeAll() }
        switch last {
        case UInt8(ascii: "A"): return true
        case UInt8(ascii: "B"): return false
        default: return nil
        }
    }
}
