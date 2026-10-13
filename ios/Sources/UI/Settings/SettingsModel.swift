import SwiftUI

/// Backs the Settings screens: edits the app's overrides file and
/// explains where each effective value comes from.
@MainActor
final class SettingsModel: ObservableObject {
    /// Which layer an effective value comes from.
    enum Source: String {
        case ghostty = "Default"
        case app = "iOS default"
        case host = "Mac"
        case settings = "Settings"
    }

    struct Effective {
        var values: [String]
        var source: Source
        var display: String {
            let shown = values.filter { !$0.isEmpty }
            return shown.isEmpty ? "—" : shown.joined(separator: ", ")
        }
    }

    @Published private(set) var overrides: ConfigFile
    /// The host whose config is shown as the "Mac" layer.
    @Published var previewHostID: UUID? {
        didSet { loadHostLayer() }
    }
    @Published var defaultColumns: Int? {
        didSet {
            guard defaultColumns != oldValue else { return }
            AppSettings.defaultColumns = defaultColumns
            NotificationCenter.default.post(name: AppSettings.columnsDidChange, object: nil)
        }
    }

    private let overridesURL: URL
    private let appDefaults: ConfigFile
    private(set) var hostLayer = ConfigFile()

    init(overridesURL: URL = ConfigPaths.overrides, previewHostID: UUID? = nil) {
        self.overridesURL = overridesURL
        self.overrides = ConfigFile(contentsOf: overridesURL)
        self.appDefaults = ConfigPaths.defaults.map(ConfigFile.init(contentsOf:)) ?? ConfigFile()
        self.defaultColumns = AppSettings.defaultColumns
        self.previewHostID = previewHostID
        loadHostLayer()
    }

    private func loadHostLayer() {
        guard let previewHostID else {
            hostLayer = ConfigFile()
            return
        }
        hostLayer = ConfigFile(contentsOf: RemoteConfigCache(hostID: previewHostID).configURL)
        objectWillChange.send()
    }

    // MARK: Reading

    func effective(_ key: String) -> Effective {
        if overrides.keys.contains(key) {
            return Effective(values: overrides.values(key), source: .settings)
        }
        if hostLayer.keys.contains(key) {
            return Effective(values: hostLayer.values(key), source: .host)
        }
        if appDefaults.keys.contains(key) {
            return Effective(values: appDefaults.values(key), source: .app)
        }
        let fallback = ConfigCatalog.shared.option(key)?.defaultValue ?? ""
        return Effective(values: fallback.isEmpty ? [] : [fallback], source: .ghostty)
    }

    /// The value the key would have without the app's override.
    func inherited(_ key: String) -> Effective {
        if hostLayer.keys.contains(key) {
            return Effective(values: hostLayer.values(key), source: .host)
        }
        if appDefaults.keys.contains(key) {
            return Effective(values: appDefaults.values(key), source: .app)
        }
        let fallback = ConfigCatalog.shared.option(key)?.defaultValue ?? ""
        return Effective(values: fallback.isEmpty ? [] : [fallback], source: .ghostty)
    }

    func isOverridden(_ key: String) -> Bool {
        overrides.keys.contains(key)
    }

    // MARK: Writing

    /// Set (or with an empty list, reset) a key in the app's overrides.
    /// Returns error messages if libghostty rejects the new value; the
    /// change is not saved in that case.
    @discardableResult
    func set(_ key: String, values: [String]) -> [String] {
        var updated = overrides
        updated.set(key, values: values)
        return save(updated)
    }

    @discardableResult
    func set(_ key: String, _ value: String) -> [String] {
        set(key, values: [value])
    }

    func reset(_ key: String) {
        set(key, values: [])
    }

    /// Replace the whole overrides file (raw editor).
    @discardableResult
    func saveText(_ text: String) -> [String] {
        save(ConfigFile(text: text))
    }

    private func save(_ updated: ConfigFile) -> [String] {
        // Only complain about problems the edit introduced, so an existing
        // bad line elsewhere doesn't block every change.
        let before = Set(Self.clean(ConfigBuilder.validate(overrides.text)))
        let after = Self.clean(ConfigBuilder.validate(updated.text))
        let introduced = after.filter { !before.contains($0) }
        guard introduced.isEmpty else { return introduced }

        do {
            try FileManager.default.createDirectory(
                at: overridesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try updated.text.write(to: overridesURL, atomically: true, encoding: .utf8)
        } catch {
            return ["Couldn't save: \(error.localizedDescription)"]
        }
        overrides = updated
        GhosttyRuntime.shared.reloadConfig()
        return []
    }

    /// Diagnostics name the temporary file they came from; drop that.
    static func clean(_ diagnostics: [String]) -> [String] {
        diagnostics.map { message in
            guard let range = message.range(of: ".ghostty:") else { return message }
            return String(message[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
    }
}
