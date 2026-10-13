import Foundation
import GhosttyKit

/// Where the app's config layers live.
enum ConfigPaths {
    /// The app's XDG config home, exported as `XDG_CONFIG_HOME` so
    /// libghostty resolves relative `config-file` includes and user themes
    /// (`ghostty/themes`) here. It can't be `~/.config`: on a device the
    /// root of the app container isn't writable (the simulator allows it).
    static var configHome: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("config")
    }

    /// The app's own settings (global overrides). Settings edits this file.
    static var overrides: URL {
        configHome.appendingPathComponent("ghostty/config.ghostty")
    }

    /// Where versions before this one put the overrides file. Only ever
    /// written successfully on the simulator.
    static var legacyOverrides: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/ghostty/config.ghostty")
    }

    /// Phone-friendly defaults shipped in the app bundle.
    static var defaults: URL? {
        Bundle.main.url(forResource: "defaults", withExtension: "ghostty")
    }

    /// libghostty's resources directory (`GHOSTTY_RESOURCES_DIR`). Not
    /// named `ghostty`: on a case-insensitive filesystem that collides
    /// with the app's `Ghostty` executable.
    static var resources: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("GhosttyResources")
    }

    static var bundledThemes: URL? {
        resources?.appendingPathComponent("themes")
    }

    /// The cached, sanitized config fetched from a host.
    static func remoteDirectory(for hostID: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("remote-config")
            .appendingPathComponent(hostID.uuidString)
    }

    static func remoteConfig(for hostID: UUID) -> URL {
        remoteDirectory(for: hostID).appendingPathComponent("config.ghostty")
    }
}

/// A finalized libghostty config. The caller owns it; libghostty copies
/// what it needs when the config is applied, so free it afterwards.
final class BuiltConfig {
    let config: ghostty_config_t
    let diagnostics: [String]

    fileprivate init(config: ghostty_config_t, diagnostics: [String]) {
        self.config = config
        self.diagnostics = diagnostics
    }

    deinit { ghostty_config_free(config) }

    func float(_ key: String) -> Float? {
        var value: Float = 0
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count)) ? value : nil
    }

    /// For options that are f64 in Ghostty (e.g. `unfocused-split-opacity`).
    func double(_ key: String) -> Double? {
        var value: Double = 0
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count)) ? value : nil
    }

    func uint32(_ key: String) -> UInt32? {
        var value: UInt32 = 0
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count)) ? value : nil
    }

    func bool(_ key: String) -> Bool? {
        var value = false
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count)) ? value : nil
    }

    func string(_ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)), let value else { return nil }
        return String(cString: value)
    }
}

/// Builds the layered config for a session. Ghostty config is last-wins,
/// so the layers are loaded in increasing priority:
///
/// 1. App defaults (bundled `defaults.ghostty`)
/// 2. The connected Mac's config (cached per host), if enabled
/// 3. The app's own overrides (Settings)
enum ConfigBuilder {
    static func layers(remote: URL?, overrides: URL = ConfigPaths.overrides) -> [URL] {
        var layers: [URL] = []
        if let defaults = ConfigPaths.defaults { layers.append(defaults) }
        if let remote { layers.append(remote) }
        layers.append(overrides)
        return layers.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func build(layers: [URL]) -> BuiltConfig? {
        guard let config = ghostty_config_new() else { return nil }
        for url in layers {
            url.path.withCString { ghostty_config_load_file(config, $0) }
        }
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        var diagnostics: [String] = []
        for i in 0..<ghostty_config_diagnostics_count(config) {
            let diagnostic = ghostty_config_get_diagnostic(config, i)
            if let message = diagnostic.message {
                diagnostics.append(String(cString: message))
            }
        }
        return BuiltConfig(config: config, diagnostics: diagnostics)
    }

    static func build(remote: URL?, overridesURL: URL = ConfigPaths.overrides) -> BuiltConfig? {
        build(layers: layers(remote: remote, overrides: overridesURL))
    }

    /// Diagnostics for a config text on its own, used to validate edits
    /// before saving them.
    static func validate(_ text: String) -> [String] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("validate-\(UUID().uuidString).ghostty")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return ["Couldn't check the config: \(error.localizedDescription)"]
        }
        return build(layers: [url])?.diagnostics ?? ["libghostty failed to create a config"]
    }
}
