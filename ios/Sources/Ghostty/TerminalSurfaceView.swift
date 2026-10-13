import UIKit
import GhosttyKit

/// A UIView hosting a libghostty terminal surface whose IO is provided by
/// a `TerminalBackend` (via libghostty's manual IO mode) instead of a
/// local subprocess.
final class TerminalSurfaceView: UIView, UIKeyInput {
    private(set) var surface: ghostty_surface_t?

    /// Connects libghostty's IO callbacks to the backend. Immutable so it
    /// can be read from libghostty's IO thread.
    private let io: SurfaceIO

    var onTitleChange: ((String) -> Void)?
    var onClose: (() -> Void)?

    /// Software modifier state toggled from the accessory bar. These
    /// apply to the next typed character and then reset.
    private var ctrlLatched = false { didSet { accessoryBar.setCtrl(ctrlLatched) } }
    private var altLatched = false { didSet { accessoryBar.setAlt(altLatched) } }

    private lazy var accessoryBar = KeyAccessoryBar(target: self)

    /// Whether a long-press selection is currently shown.
    private var selectionActive = false

    static func from(_ userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    init(app: ghostty_app_t, backend: TerminalBackend) {
        self.io = SurfaceIO(backend: backend)
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        backgroundColor = .black
        isMultipleTouchEnabled = true

        let unmanaged = Unmanaged.passUnretained(self).toOpaque()
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: unmanaged))
        config.userdata = unmanaged
        config.scale_factor = Double(UIScreen.main.scale)
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        config.io_write_cb = { userdata, ptr, len in
            guard let view = TerminalSurfaceView.from(userdata), let ptr, len > 0 else { return }
            view.io.backend.write(Data(bytes: ptr, count: Int(len)))
        }
        config.io_resize_cb = { userdata, columns, rows, width, height in
            guard let view = TerminalSurfaceView.from(userdata) else { return }
            view.io.resized(TerminalSize(
                columns: Int(columns),
                rows: Int(rows),
                widthPixels: Int(width),
                heightPixels: Int(height)))
        }
        surface = ghostty_surface_new(app, &config)

        installGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        io.backend.close()
        if let surface { ghostty_surface_free(surface) }
    }

    /// Start the backend and pump its output into the terminal. Returns
    /// when the session ends, with the error if the session failed to
    /// start.
    @MainActor
    @discardableResult
    func run() async -> Error? {
        guard let surface else { return nil }
        let backend = io.backend

        // Consume events first so no output is lost while connecting.
        let pump = Task { @MainActor [weak self] in
            for await event in backend.events {
                switch event {
                case .output(let data):
                    data.withUnsafeBytes { buf in
                        guard let base = buf.baseAddress else { return }
                        ghostty_surface_write_output(
                            surface,
                            base.assumingMemoryBound(to: CChar.self),
                            UInt(buf.count))
                    }
                case .exited(let code, let message):
                    if let message { self?.writeNotice(message) }
                    ghostty_surface_session_exited(surface, UInt32(bitPattern: code ?? 1))
                }
            }
        }

        var startError: Error?
        do {
            try await backend.start(size: io.currentSize)
        } catch {
            startError = error
            writeNotice("Connection failed: \(error.localizedDescription)")
            ghostty_surface_session_exited(surface, 1)
        }
        await pump.value
        return startError
    }

    /// Print a dim status line into the terminal (e.g. connection errors).
    private func writeNotice(_ message: String) {
        guard let surface else { return }
        let text = "\r\n\u{1B}[2m[\(message)]\u{1B}[0m\r\n"
        text.withCString { ghostty_surface_write_output(surface, $0, UInt(strlen($0))) }
    }

    func surfaceRequestedClose() {
        onClose?()
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        sizeDidChange()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sizeDidChange()
    }

    private func sizeDidChange() {
        guard let surface else { return }
        let scale = window?.screen.scale ?? UIScreen.main.scale

        // libghostty renders into a sublayer it adds to our layer. On iOS
        // that sublayer doesn't track our bounds automatically.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in layer.sublayers ?? [] {
            sublayer.frame = bounds
            sublayer.contentsScale = scale
        }
        CATransaction.commit()

        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(
            surface,
            UInt32(max(bounds.width * scale, 1)),
            UInt32(max(bounds.height * scale, 1)))
    }

    // MARK: Focus

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, false) }
        return result
    }

    override var inputAccessoryView: UIView? { accessoryBar }

    // MARK: UIKeyInput (software keyboard)

    var hasText: Bool { true }

    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }

    func insertText(_ text: String) {
        guard let surface else { return }
        KeyInput.type(text, into: surface, ctrl: ctrlLatched, alt: altLatched)
        ctrlLatched = false
        altLatched = false
    }

    func deleteBackward() {
        guard let surface else { return }
        KeyInput.tap(surface, keycode: KeyInput.keycode(.backspace))
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if !handlePress(press, action: press.phase == .began ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_REPEAT) {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses where !handlePress(press, action: GHOSTTY_ACTION_RELEASE) {
            unhandled.insert(press)
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    private func handlePress(_ press: UIPress, action: ghostty_input_action_e) -> Bool {
        guard let surface, let key = press.key else { return false }
        let unshifted = key.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0
        let handled = KeyInput.send(
            to: surface,
            keycode: KeyInput.keycode(UInt32(key.keyCode.rawValue)),
            mods: KeyInput.mods(key.modifierFlags),
            text: KeyInput.eventText(key.characters),
            unshifted: (0xF700...0xF8FF).contains(unshifted) ? 0 : unshifted,
            action: action)

        // Let the system have Cmd shortcuts libghostty doesn't bind.
        if !handled && key.modifierFlags.contains(.command) { return false }
        return true
    }

    // MARK: Accessory bar actions

    func accessoryTapped(_ key: KeyAccessoryBar.Key) {
        guard let surface else { return }
        switch key {
        case .ctrl: ctrlLatched.toggle()
        case .alt: altLatched.toggle()
        case .escape: KeyInput.tap(surface, keycode: KeyInput.keycode(.escape))
        case .tab: KeyInput.tap(surface, keycode: KeyInput.keycode(.tab))
        case .up: KeyInput.tap(surface, keycode: KeyInput.keycode(.arrowUp))
        case .down: KeyInput.tap(surface, keycode: KeyInput.keycode(.arrowDown))
        case .left: KeyInput.tap(surface, keycode: KeyInput.keycode(.arrowLeft))
        case .right: KeyInput.tap(surface, keycode: KeyInput.keycode(.arrowRight))
        case .character(let c): insertText(String(c))
        case .paste: paste(nil)
        case .dismiss: _ = resignFirstResponder()
        }
    }

    // MARK: Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(press)
        pan.require(toFail: press)

        addInteraction(UIEditMenuInteraction(delegate: self))
    }

    @objc private func handleTap() {
        if isFirstResponder {
            // A tap while focused clears any selection.
            if selectionActive, let surface {
                ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                selectionActive = false
            }
        } else {
            _ = becomeFirstResponder()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let surface else { return }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        // Precision scrolling in points, scaled like the macOS trackpad path.
        let precisionBit: Int32 = 0b1
        ghostty_surface_mouse_scroll(
            surface,
            Double(translation.x) * 2,
            Double(translation.y) * 2,
            precisionBit)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let surface else { return }
        let point = gesture.location(in: self)
        ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)

        switch gesture.state {
        case .began:
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            UISelectionFeedbackGenerator().selectionChanged()
        case .ended, .cancelled:
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            selectionActive = ghostty_surface_has_selection(surface)
            if let interaction = interactions.compactMap({ $0 as? UIEditMenuInteraction }).first {
                interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            }
        default:
            break
        }
    }

    // MARK: Copy / paste

    override func copy(_ sender: Any?) {
        guard let surface else { return }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        if let ptr = text.text {
            let data = Data(bytes: ptr, count: Int(text.text_len))
            UIPasteboard.general.string = String(decoding: data, as: UTF8.self)
        }
    }

    override func paste(_ sender: Any?) {
        guard let surface, let string = UIPasteboard.general.string else { return }
        // ghostty_surface_text is treated as a paste (bracketed if enabled).
        string.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            guard let surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)):
            return UIPasteboard.general.hasStrings
        default:
            return false
        }
    }
}

extension TerminalSurfaceView: UIEditMenuInteractionDelegate {}

/// State shared with libghostty's IO thread.
private final class SurfaceIO: @unchecked Sendable {
    let backend: TerminalBackend
    private let lock = NSLock()
    private var size: TerminalSize = .default

    init(backend: TerminalBackend) {
        self.backend = backend
    }

    var currentSize: TerminalSize {
        lock.withLock { size }
    }

    func resized(_ newSize: TerminalSize) {
        let changed: Bool = lock.withLock {
            defer { size = newSize }
            return size != newSize
        }
        if changed { backend.resize(newSize) }
    }
}
