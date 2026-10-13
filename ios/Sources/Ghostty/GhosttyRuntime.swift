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
    private var config: ghostty_config_t?

    private init() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            logger.critical("ghostty_init failed")
            return
        }

        guard let cfg = ghostty_config_new() else {
            logger.critical("ghostty_config_new failed")
            return
        }
        Self.writeDefaultConfigIfNeeded()
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        self.config = cfg

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

    /// The Ghostty config file inside the app sandbox. libghostty loads
    /// this through its normal XDG lookup ($HOME/.config/ghostty/config.ghostty).
    static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/ghostty/config.ghostty")
    }

    /// Seed a config with phone-friendly defaults on first launch. Users
    /// can edit it later (e.g. via the Files app once that is exposed).
    private static func writeDefaultConfigIfNeeded() {
        let url = configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let contents = """
        # Ghostty for iOS configuration. See https://ghostty.org/docs/config
        font-size = 12
        window-padding-x = 4
        window-padding-y = 4
        """
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("failed to write default config: \(error.localizedDescription)")
        }
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
            return false
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
