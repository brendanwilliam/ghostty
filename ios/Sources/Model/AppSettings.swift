import Foundation

/// App settings that aren't Ghostty config options.
enum AppSettings {
    private static let defaultColumnsKey = "defaultColumns"

    /// Columns to fit across the screen when a host doesn't set its own.
    /// Nil turns fitting off, so the config's `font-size` is used as is.
    static var defaultColumns: Int? {
        get {
            guard UserDefaults.standard.object(forKey: defaultColumnsKey) != nil else { return 80 }
            let value = UserDefaults.standard.integer(forKey: defaultColumnsKey)
            return value > 0 ? value : nil
        }
        set {
            UserDefaults.standard.set(newValue ?? 0, forKey: defaultColumnsKey)
        }
    }

    static let columnRange = 20...300

    /// Posted when the default column count changes.
    static let columnsDidChange = Notification.Name("AppSettings.columnsDidChange")

    static func columns(for host: Host) -> Int? {
        host.columns ?? defaultColumns
    }
}
