import SwiftUI

/// The Ghostty themes bundled with the app (from Ghostty's build).
enum ThemeCatalog {
    struct Theme: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let background: Color?
        let foreground: Color?
        let palette: [Color]

        /// Rough light/dark classification from the background color.
        var isLight: Bool {
            guard let background else { return false }
            var white: CGFloat = 0
            UIColor(background).getWhite(&white, alpha: nil)
            return white > 0.5
        }
    }

    static let names: [String] = {
        guard let dir = ConfigPaths.bundledThemes,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    private static let nameSet = Set(names)

    static func isBundled(_ name: String) -> Bool {
        nameSet.contains(name)
    }

    static func theme(named name: String) -> Theme? {
        guard let url = ConfigPaths.bundledThemes?.appendingPathComponent(name) else { return nil }
        let file = ConfigFile(contentsOf: url)
        guard !file.lines.isEmpty else { return nil }
        var palette: [Int: Color] = [:]
        for entry in file.values("palette") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
               let color = Color(ghosttyHex: String(parts[1])) {
                palette[index] = color
            }
        }
        return Theme(
            name: name,
            background: file.value("background").flatMap(Color.init(ghosttyHex:)),
            foreground: file.value("foreground").flatMap(Color.init(ghosttyHex:)),
            palette: (0..<8).compactMap { palette[$0] })
    }
}

extension Color {
    /// Parses Ghostty's `#rrggbb` / `rrggbb` color syntax.
    init?(ghosttyHex value: String) {
        var hex = value.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }

    /// `#rrggbb` for writing back to a config file.
    var ghosttyHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: nil)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }
}
