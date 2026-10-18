import UIKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty.ios", category: "runtime")

/// Owns the process-wide libghostty app and implements the runtime
/// callbacks libghostty uses to talk to the host (wakeups, actions,
/// clipboard, surface close).
///
/// Surfaces register with `ghostty_surface_config_s.userdata` pointing
/// at their `TerminalSurfaceView`, which is how callbacks find the view.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?

    /// The app-level config (defaults + the app's overrides).
    private(set) var config: BuiltConfig?

    /// Live terminals, so config changes apply to open sessions.
    private let surfaces = NSHashTable<TerminalSurfaceView>.weakObjects()

    private init() {
        // ios_system's setup adds to the process environment, which has to
        // be done before libghostty takes its snapshot of it.
        LocalEnvironment.prepareProcess()

        // Bundled themes live in <bundle>/GhosttyResources/themes; libghostty
        // finds them through its resources directory.
        if let resources = ConfigPaths.resources {
            setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)
        }
        // Keep libghostty's XDG config lookups inside a writable directory.
        try? FileManager.default.createDirectory(
            at: ConfigPaths.overrides.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        setenv("XDG_CONFIG_HOME", ConfigPaths.configHome.path, 1)

        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            logger.critical("ghostty_init failed")
            return
        }

        Self.migrateLegacyOverrides()
        Self.removeLegacySeedConfig()
        guard let built = ConfigBuilder.build(remote: nil) else {
            logger.critical("ghostty_config_new failed")
            return
        }
        self.config = built
        let cfg = built.config

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
            },
            action_cb: { _, target, action in
                GhosttyRuntime.handleAction(target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                GhosttyRuntime.readClipboard(
                    userdata,
                    location: location,
                    state: state,
                    mimes: mimes,
                    mimesLen: mimesLen,
                    list: list)
            },
            confirm_read_clipboard_cb: { userdata, _, state, _ in
                // Reads that require confirmation (e.g. OSC 52 from the
                // remote program) are denied until we have a confirmation UI.
                guard let view = TerminalSurfaceView.from(userdata),
                      let surface = view.surface else { return }
                ghostty_surface_deny_clipboard_request(surface, state)
            },
            write_clipboard_cb: { _, location, content, len, confirm in
                GhosttyRuntime.writeClipboard(
                    location: location,
                    content: content,
                    len: len,
                    confirm: confirm)
            },
            close_surface_cb: { userdata, _ in
                guard let view = TerminalSurfaceView.from(userdata) else { return }
                DispatchQueue.main.async { view.surfaceRequestedClose() }
            }
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            logger.critical("ghostty_app_new failed")
            return
        }
        self.app = app
        ghostty_app_set_focus(app, true)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    // MARK: Config

    func register(_ view: TerminalSurfaceView) {
        surfaces.add(view)
    }

    /// Rebuild configs after Settings or a host's config changed, and
    /// apply them to every open terminal.
    func reloadConfig() {
        guard let app, let built = ConfigBuilder.build(remote: nil) else { return }
        // This pushes the app config to every surface; each surface then
        // re-applies its own layered config (which includes its host's).
        ghostty_app_update_config(app, built.config)
        config = built
        for view in surfaces.allObjects {
            view.reloadConfig()
        }
    }

    /// Move an overrides file from the old `~/.config` location (only
    /// ever writable on the simulator) to the current one.
    private static func migrateLegacyOverrides() {
        let fm = FileManager.default
        let old = ConfigPaths.legacyOverrides
        guard fm.fileExists(atPath: old.path),
              !fm.fileExists(atPath: ConfigPaths.overrides.path) else { return }
        try? fm.moveItem(at: old, to: ConfigPaths.overrides)
    }

    /// Version 1 seeded the overrides file with its defaults. Those now
    /// live in the bundled defaults layer; left in place they would
    /// override the Mac's config, so remove the untouched seed.
    private static func removeLegacySeedConfig() {
        let legacySeed = """
        # Ghostty for iOS configuration. See https://ghostty.org/docs/config
        font-size = 12
        window-padding-x = 4
        window-padding-y = 4
        """
        let url = ConfigPaths.overrides
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines) == legacySeed else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Actions

    private static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let view = TerminalSurfaceView.from(ghostty_surface_userdata(surface)) else {
            return false
        }

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let ptr = action.action.set_title.title else { return false }
            let title = String(cString: ptr)
            DispatchQueue.main.async { view.onTitleChange?(title) }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            return true

        default:
            // Tab and split actions go to the pane's workspace.
            guard let paneAction = PaneAction(action) else { return false }
            if Thread.isMainThread {
                return MainActor.assumeIsolated { view.onAction?(paneAction) ?? false }
            }
            DispatchQueue.main.async { _ = view.onAction?(paneAction) }
            return true
        }
    }

    // MARK: Clipboard

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let view = TerminalSurfaceView.from(userdata),
              let surface = view.surface else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        var wantsText = false
        if let mimes {
            for i in 0..<mimesLen {
                if let ptr = mimes[i], String(cString: ptr) == "text/plain" {
                    wantsText = true
                }
            }
        }

        let text = wantsText ? UIPasteboard.general.string : nil
        let hasText = UIPasteboard.general.hasStrings
        if text == nil && !list {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        completeClipboardRequest(
            surface,
            text: text,
            available: (list && hasText) ? ["text/plain"] : [],
            state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        text: String?,
        available: [String],
        state: UnsafeMutableRawPointer?
    ) {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        defer { cStrings.forEach { free($0) } }

        var contents: [ghostty_clipboard_content_s] = []
        if let text, let mime = strdup("text/plain"), let data = strdup(text) {
            cStrings.append(mime)
            cStrings.append(data)
            contents.append(ghostty_clipboard_content_s(
                mime: mime,
                data: data,
                len: text.utf8.count))
        }

        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let str = strdup(mime) else { continue }
            cStrings.append(str)
            cAvailable.append(UnsafePointer(str))
        }

        contents.withUnsafeBufferPointer { contentsBuf in
            cAvailable.withUnsafeBufferPointer { availableBuf in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentsBuf.baseAddress,
                    contents_len: contentsBuf.count,
                    available: availableBuf.baseAddress,
                    available_len: availableBuf.count,
                    confirmed: false,
                    remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }

    private static func writeClipboard(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        // Writes that need confirmation (OSC 52 from the remote program)
        // are dropped until there is a confirmation UI.
        guard !confirm, location == GHOSTTY_CLIPBOARD_STANDARD,
              let content, len > 0 else { return }

        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, String(cString: mime) == "text/plain",
                  let data = item.data else { continue }
            let bytes = Data(bytes: data, count: item.len)
            if let string = String(data: bytes, encoding: .utf8) {
                DispatchQueue.main.async { UIPasteboard.general.string = string }
            }
            return
        }
    }
}
