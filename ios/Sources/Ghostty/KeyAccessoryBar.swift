import UIKit

/// The row of terminal keys shown above the software keyboard.
final class KeyAccessoryBar: UIInputView {
    enum Key {
        case escape, ctrl, option, command, shift, tab
        case up, down, left, right
        case character(Character)
        case dismiss
    }

    /// How a key is labeled: text, or an SF Symbol with a spoken name.
    private enum Face {
        case text(String)
        case symbol(String, label: String)
    }

    private weak var target: TerminalSurfaceView?
    private var ctrlButton: UIButton?
    private var optionButton: UIButton?
    private var commandButton: UIButton?
    private var shiftButton: UIButton?

    init(target: TerminalSurfaceView) {
        self.target = target
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    func setCtrl(_ on: Bool) { ctrlButton?.isSelected = on }
    func setOption(_ on: Bool) { optionButton?.isSelected = on }
    func setCommand(_ on: Bool) { commandButton?.isSelected = on }
    func setShift(_ on: Bool) { shiftButton?.isSelected = on }

    private static let titleFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
    private static let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
    private static let horizontalInset: CGFloat = 10

    /// The width of a three-letter key. Every key is at least this wide,
    /// and keys showing a single character or symbol are exactly this wide.
    static let minKeyWidth: CGFloat = {
        let text = ("esc" as NSString).size(withAttributes: [.font: titleFont])
        return ceil(text.width) + horizontalInset * 2
    }()

    private func build() {
        // Modifier and special keys use the symbols printed on Apple keyboards.
        let keys: [(Face, Key)] = [
            (.symbol("escape", label: "Escape"), .escape),
            (.symbol("control", label: "Control"), .ctrl),
            (.symbol("option", label: "Option"), .option),
            (.symbol("command", label: "Command"), .command),
            (.symbol("shift", label: "Shift"), .shift),
            (.symbol("arrow.right.to.line", label: "Tab"), .tab),
            (.text("↑"), .up),
            (.text("↓"), .down),
            (.text("←"), .left),
            (.text("→"), .right),
            (.text("|"), .character("|")),
            (.text("~"), .character("~")),
            (.text("-"), .character("-")),
            (.text("/"), .character("/")),
        ]

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (face, key) in keys {
            let button = makeButton(face, key: key)
            switch key {
            case .ctrl: ctrlButton = button
            case .option: optionButton = button
            case .command: commandButton = button
            case .shift: shiftButton = button
            default: break
            }
            stack.addArrangedSubview(button)
        }

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)

        // Hiding the keyboard stays at the right edge, outside the
        // scrolling keys, so it's always in reach.
        let dismiss = makeButton(.symbol("keyboard.chevron.compact.down", label: "Hide Keyboard"), key: .dismiss)
        addSubview(dismiss)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -2),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
            dismiss.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            dismiss.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            dismiss.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    private func makeButton(_ face: Face, key: Key) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.titleLineBreakMode = .byClipping
        let inset = Self.horizontalInset
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: inset, bottom: 4, trailing: inset)
        switch face {
        case .text(let title):
            var attributed = AttributedString(title)
            attributed.font = Self.titleFont
            config.attributedTitle = attributed
        case .symbol(let name, _):
            config.image = UIImage(systemName: name, withConfiguration: Self.symbolConfiguration)
        }

        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.target?.accessoryTapped(key)
        })
        if case .symbol(_, let label) = face { button.accessibilityLabel = label }
        button.configurationUpdateHandler = { button in
            var config = button.configuration
            config?.baseBackgroundColor = button.isSelected ? .tintColor : nil
            config?.baseForegroundColor = button.isSelected ? .white : .label
            button.configuration = config
        }

        // Single characters and symbols are exactly the minimum width;
        // longer labels grow but never get narrower.
        let isSingleGlyph: Bool
        switch face {
        case .text(let title): isSingleGlyph = title.count == 1
        case .symbol: isSingleGlyph = true
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        let width = isSingleGlyph
            ? button.widthAnchor.constraint(equalToConstant: Self.minKeyWidth)
            : button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minKeyWidth)
        width.isActive = true
        // Labels stay on one line at their natural width; the bar scrolls.
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.titleLabel?.numberOfLines = 1
        return button
    }
}

extension KeyAccessoryBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
