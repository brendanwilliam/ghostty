import UIKit
import GhosttyKit

/// A UIView hosting a libghostty terminal surface whose IO is provided by
/// a `TerminalBackend` (via libghostty's manual IO mode) instead of a
/// local subprocess.
final class TerminalSurfaceView: UIView {
    private(set) var surface: ghostty_surface_t?

    /// Connects libghostty's IO callbacks to the backend. Immutable so it
    /// can be read from libghostty's IO thread.
    private let io: SurfaceIO

    var onTitleChange: ((String) -> Void)?
    var onClose: (() -> Void)?

    /// Called when a pinch settles on a new column count.
    var onColumnsSettled: ((Int) -> Void)?

    /// Tab and split actions from Ghostty keybinds (Cmd+T, Cmd+D...).
    /// Returns whether the action was handled.
    var onAction: ((PaneAction) -> Bool)?

    /// Whether this is the focused pane of its tab. A tap on another pane
    /// only focuses it (calling `onActivate`), even if its program has
    /// the mouse.
    var isActivePane = true
    var onActivate: (() -> Void)?

    /// Whether the session ended without an exit status (the connection
    /// dropped), rather than the shell exiting. A dropped pane stays open
    /// so it can be reconnected.
    private(set) var sessionDropped = false
    /// Whether the session failed to start (its error is shown in the pane).
    private(set) var startFailed = false

    /// The width, in points, to fit `targetColumns` across instead of
    /// this view's own short side. Splits use the whole screen's, so every
    /// pane in a tab gets the font a lone pane would and shows however
    /// many columns fit in it.
    var fitWidth: CGFloat? {
        didSet {
            guard fitWidth != oldValue else { return }
            fitColumns(force: true)
        }
    }

    /// The short side columns are fitted across, in points.
    private var fitShortSide: CGFloat {
        fitWidth ?? min(bounds.width, bounds.height)
    }

    /// How opaque an unfocused split is (Ghostty's `unfocused-split-opacity`).
    private(set) var unfocusedSplitOpacity: Double = 0.7

    /// The host's cached Ghostty config, layered between the app defaults
    /// and the app's own settings. Nil when the host's config is off.
    var remoteConfig: URL? {
        didSet { reloadConfig() }
    }

    /// Columns to fit across the screen's portrait width by scaling the
    /// font. Nil uses the config's `font-size`.
    var targetColumns: Int? {
        didSet {
            guard targetColumns != oldValue, !suppressFit else { return }
            if targetColumns == nil, let surface {
                let action = "reset_font_size"
                ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
                fontPoints = configFontPoints
                fontOverridden = false
            }
            fitColumns(force: true)
        }
    }

    /// The font size currently applied, in points.
    private(set) var fontPoints: Float = 12
    /// The font size the config asks for.
    private var configFontPoints: Float = 12
    /// Whether we've set the font size ourselves (fit or pinch). Until
    /// then the surface follows the config's `font-size`.
    private var fontOverridden = false
    private var lastFitSignature: String?
    private var suppressFit = false
    private var pinchStartPoints: Float = 12
    static let fontPointRange: ClosedRange<Float> = 4...36

    /// Diagnostics from the last config build, for display.
    private(set) var configDiagnostics: [String] = []

    /// Software modifier state toggled from the accessory bar. These
    /// apply to the next typed character and then reset.
    private var ctrlLatched = false { didSet { accessoryBar.setCtrl(ctrlLatched) } }
    private var altLatched = false { didSet { accessoryBar.setAlt(altLatched) } }
    private var shiftLatched = false { didSet { accessoryBar.setShift(shiftLatched) } }

    /// Modifiers latched on the accessory bar, as libghostty mods.
    private var latchedMods: ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if ctrlLatched { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if altLatched { mods |= GHOSTTY_MODS_ALT.rawValue }
        if shiftLatched { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func clearLatches() {
        ctrlLatched = false
        altLatched = false
        shiftLatched = false
    }

    private lazy var accessoryBar = KeyAccessoryBar(target: self)

    /// Whether a long-press selection is currently shown.
    private var selectionActive = false

    /// The `mouse-reporting` config. When false, programs never see touches.
    private var mouseReportingEnabled = true

    /// Modifiers for the current long-press. Shift while a program has
    /// the mouse, so libghostty selects text instead of reporting it.
    private var longPressMods = GHOSTTY_MODS_NONE

    /// Keeps a flicked scroll going after the finger lifts.
    private lazy var momentum = MomentumScroller { [weak self] delta, phase in
        self?.momentumScrolled(delta, phase)
    }
    /// Text the keyboard is still composing (dictation, or an input
    /// method's marked text). It's drawn at the cursor as a preedit and
    /// only sent to the program once it's final. See TerminalTextInput.swift.
    var composing = ""
    /// The caret within `composing`, in UTF-16 units.
    var composingCaret = 0
    /// The input method's marked (provisional) part of `composing`.
    var composingMarked: NSRange?
    /// Whether dictation is running, so its text is held until it ends.
    var dictating = false
    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    /// Whether the program had the mouse when the glide started. A glide
    /// stops if that changes so it doesn't carry into another program.
    private var momentumCaptured = false

    /// Whether the running program has turned on mouse tracking (e.g.
    /// Claude Code's fullscreen TUI, vim with `mouse=a`, htop). Touches
    /// are then sent to it as mouse events.
    var mouseCaptured: Bool {
        guard let surface, mouseReportingEnabled else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    static func from(_ userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    init(
        app: ghostty_app_t,
        backend: TerminalBackend,
        remoteConfig: URL? = nil,
        columns: Int? = nil
    ) {
        self.io = SurfaceIO(backend: backend)
        self.remoteConfig = remoteConfig
        self.targetColumns = columns
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(inputModeDidChange),
            name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
        GhosttyRuntime.shared.register(self)
        reloadConfig()
    }

    // MARK: Config

    /// Build this terminal's layered config (defaults, host, app
    /// settings) and apply it.
    func reloadConfig() {
        guard let surface, let built = ConfigBuilder.build(remote: remoteConfig) else { return }
        ghostty_surface_update_config(surface, built.config)
        configDiagnostics = built.diagnostics
        mouseReportingEnabled = built.bool("mouse-reporting") ?? true
        unfocusedSplitOpacity = built.double("unfocused-split-opacity") ?? 0.7

        configFontPoints = built.float("font-size") ?? configFontPoints
        if !fontOverridden { fontPoints = configFontPoints }
        fitColumns(force: true)
    }

    // MARK: Column fitting

    /// Scale the font so `targetColumns` cells fit across the portrait
    /// width. Landscape keeps the same font and so shows more columns.
    func fitColumns(force: Bool = false) {
        guard let surface, let target = targetColumns,
              bounds.width > 1, bounds.height > 1 else { return }
        let scale = Double(window?.screen.scale ?? UIScreen.main.scale)
        let shortSide = Double(fitShortSide) * scale
        let signature = fitSignature(target: target)
        guard force || signature != lastFitSignature else { return }
        lastFitSignature = signature

        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.columns > 0 else { return }

        // First estimate: cell width scales with the font size.
        let usable = portraitUsableWidth(size, shortSide: shortSide)
        let targetCell = usable / Double(target)
        var points = fontPoints * Float(targetCell / Double(size.cell_width_px))
        points = (points * 4).rounded(.down) / 4
        applyFontSize(points)

        // Cell widths round to whole pixels, so the estimate can be off by
        // a step or two. Settle on the largest size that still fits.
        var steps = 0
        while portraitColumns(shortSide: shortSide) < target,
              fontPoints > Self.fontPointRange.lowerBound, steps < 16 {
            applyFontSize(fontPoints - 0.25)
            steps += 1
        }
        while steps < 16, fontPoints < Self.fontPointRange.upperBound {
            let fitting = fontPoints
            applyFontSize(fontPoints + 0.25)
            steps += 1
            if portraitColumns(shortSide: shortSide) < target {
                applyFontSize(fitting)
                break
            }
        }
    }

    /// Identifies a fit so layout passes that change nothing don't refit.
    /// Only the short side matters, so rotating doesn't refit.
    private func fitSignature(target: Int) -> String {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        return "\(target)|\(Int(fitShortSide))|\(scale)"
    }

    /// Columns that fit across the portrait width at the current font.
    func portraitColumns(shortSide: Double? = nil) -> Int {
        guard let surface else { return 0 }
        let scale = Double(window?.screen.scale ?? UIScreen.main.scale)
        let short = shortSide ?? Double(fitShortSide) * scale
        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0 else { return 0 }
        return Int(portraitUsableWidth(size, shortSide: short) / Double(size.cell_width_px))
    }

    /// The pixel width available to the grid in portrait. Everything the
    /// grid doesn't use now (padding plus any partial cell) is treated as
    /// padding, which is exact in portrait and errs small in landscape.
    private func portraitUsableWidth(_ size: ghostty_surface_size_s, shortSide: Double) -> Double {
        let unused = max(0, Double(size.width_px) - Double(size.columns) * Double(size.cell_width_px))
        return max(Double(size.cell_width_px), shortSide - unused)
    }

    private func applyFontSize(_ points: Float) {
        guard let surface else { return }
        let clamped = min(max(points, Self.fontPointRange.lowerBound), Self.fontPointRange.upperBound)
        let action = String(format: "set_font_size:%.2f", clamped)
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        fontPoints = clamped
        fontOverridden = true
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
                    self?.sessionDropped = code == nil
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
            startFailed = true
            writeNotice("Connection failed: \(error.localizedDescription)")
            ghostty_surface_session_exited(surface, 1)
        }
        await pump.value
        return startError
    }

    /// Print a dim status line into the terminal (e.g. connection errors).
    func writeNotice(_ message: String) {
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
        fitColumns()
    }

    // MARK: Focus

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        commitComposing()
        let result = super.resignFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, false) }
        return result
    }

    override var inputAccessoryView: UIView? { accessoryBar }

    // MARK: Software keyboard

    // A terminal wants exactly what was typed. The default keyboard (not
    // ASCII-only) is used so the dictation key is offered.
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var inlinePredictionType: UITextInlinePredictionType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .default } set {} }

    /// Send typed text to the program, with any latched modifiers.
    func typeText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        momentum.stop()
        KeyInput.type(text, into: surface, ctrl: ctrlLatched, alt: altLatched, shift: shiftLatched)
        clearLatches()
    }

    /// Send a Backspace to the program.
    func typeBackspace() {
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
        momentum.stop()
        commitComposing()
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
        case .shift: shiftLatched.toggle()
        case .escape: tapLatched(surface, .escape)
        case .tab: tapLatched(surface, .tab)
        case .up: tapLatched(surface, .arrowUp)
        case .down: tapLatched(surface, .arrowDown)
        case .left: tapLatched(surface, .arrowLeft)
        case .right: tapLatched(surface, .arrowRight)
        case .character(let c): insertText(String(c))
        case .paste: paste(nil)
        case .dismiss: _ = resignFirstResponder()
        }
    }

    /// Tap a special key with any latched modifiers (Shift+Tab, Ctrl+←).
    private func tapLatched(_ surface: ghostty_surface_t, _ usage: KeyInput.Usage) {
        commitComposing()
        KeyInput.tap(surface, keycode: KeyInput.keycode(usage), mods: latchedMods)
        clearLatches()
    }

    // MARK: Gestures

    private func installGestures() {
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: twoFingerTap)
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(press)
        pan.require(toFail: press)

        addInteraction(UIEditMenuInteraction(delegate: self))
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        touchTap(at: gesture.location(in: self))
    }

    /// Two fingers toggle the keyboard. A one-finger tap can't while a
    /// program has the mouse, because there it's a click.
    @objc private func handleTwoFingerTap() {
        if isFirstResponder {
            _ = resignFirstResponder()
        } else {
            _ = becomeFirstResponder()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        touchScroll(by: translation, at: gesture.location(in: self), began: gesture.state == .began)
        switch gesture.state {
        case .ended:
            touchScrollEnded(velocity: CGPoint(x: 0, y: gesture.velocity(in: self).y))
        case .cancelled, .failed:
            momentum.stop()
        default:
            break
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        touchLongPress(gesture.state, at: gesture.location(in: self))
    }

    // MARK: Touch as mouse

    /// A tap is a left click when a program tracks the mouse. Otherwise
    /// it focuses the terminal or clears the selection.
    func touchTap(at point: CGPoint) {
        guard let surface else { return }
        momentum.stop()
        commitComposing()
        guard isActivePane else {
            onActivate?()
            return
        }
        if mouseCaptured {
            ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            selectionActive = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if isFirstResponder {
            // A tap while focused clears any selection.
            if selectionActive {
                ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
                ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                selectionActive = false
            }
        } else {
            _ = becomeFirstResponder()
        }
    }

    /// A one-finger drag scrolls. libghostty decides what that means:
    /// wheel reports to a program tracking the mouse, arrow keys in an
    /// alternate-screen pager, or scrollback otherwise.
    func touchScroll(by translation: CGPoint, at point: CGPoint, began: Bool) {
        guard let surface else { return }
        // Wheel reports carry the pointer position.
        if began {
            momentum.stop()
            ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
        }
        sendScroll(translation, phase: GHOSTTY_MOUSE_MOMENTUM_NONE)
    }

    /// The finger lifted: keep gliding at its velocity (points per second).
    /// `driven` false lets tests step the glide themselves.
    func touchScrollEnded(velocity: CGPoint, driven: Bool = true) {
        momentumCaptured = mouseCaptured
        momentum.start(velocity: velocity, driven: driven)
    }

    /// Whether a flick is still gliding.
    var isGliding: Bool { momentum.isGliding }

    /// Advance a glide by one frame (tests; the display link does this).
    func advanceGlide(dt: Double) { momentum.advance(dt: dt) }

    private func momentumScrolled(_ delta: CGPoint, _ phase: MomentumScroller.Phase) {
        if phase != .ended, mouseCaptured != momentumCaptured {
            momentum.stop()
            return
        }
        switch phase {
        case .began: sendScroll(delta, phase: GHOSTTY_MOUSE_MOMENTUM_BEGAN)
        case .changed: sendScroll(delta, phase: GHOSTTY_MOUSE_MOMENTUM_CHANGED)
        case .ended: sendScroll(.zero, phase: GHOSTTY_MOUSE_MOMENTUM_ENDED)
        }
    }

    /// Precision scrolling in points, scaled like the macOS trackpad path,
    /// with the momentum phase in bits 1-3 as macOS sends it.
    private func sendScroll(_ delta: CGPoint, phase: ghostty_input_mouse_momentum_e) {
        guard let surface else { return }
        let precisionBit: Int32 = 0b1
        let mods = precisionBit | Int32(phase.rawValue) << 1
        ghostty_surface_mouse_scroll(surface, Double(delta.x) * 2, Double(delta.y) * 2, mods)
    }

    /// Pinch to zoom. When the pinch ends, the column count it settled
    /// on becomes the target so later layouts (and reconnects) keep it.
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            momentum.stop()
            pinchStartPoints = fontPoints
        case .changed:
            let points = (pinchStartPoints * Float(gesture.scale) * 4).rounded() / 4
            if points != fontPoints { applyFontSize(points) }
        case .ended:
            let columns = portraitColumns()
            guard columns > 0 else { return }
            // Record the result without refitting: the font is already
            // exactly what the user chose.
            suppressFit = true
            targetColumns = columns
            suppressFit = false
            lastFitSignature = fitSignature(target: columns)
            onColumnsSettled?(columns)
        default:
            break
        }
    }

    /// Long-press and drag selects text. While a program tracks the
    /// mouse this is sent with Shift, which libghostty treats as "select
    /// instead of reporting" (unless the program asked for Shift too).
    func touchLongPress(_ state: UIGestureRecognizer.State, at point: CGPoint) {
        guard let surface else { return }
        if state == .began {
            momentum.stop()
            longPressMods = mouseCaptured ? GHOSTTY_MODS_SHIFT : GHOSTTY_MODS_NONE
        }
        let mods = longPressMods
        ghostty_surface_mouse_pos(surface, point.x, point.y, mods)

        switch state {
        case .began:
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
            UISelectionFeedbackGenerator().selectionChanged()
        case .ended, .cancelled:
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
            longPressMods = GHOSTTY_MODS_NONE
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
