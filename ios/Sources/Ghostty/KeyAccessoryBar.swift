import UIKit

/// The row of terminal keys shown above the software keyboard.
final class KeyAccessoryBar: UIInputView {
    enum Key {
        case escape, ctrl, alt, shift, tab
        case up, down, left, right
        case character(Character)
        case paste, dismiss
    }

    private weak var target: TerminalSurfaceView?
    private var ctrlButton: UIButton?
    private var altButton: UIButton?
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
    func setAlt(_ on: Bool) { altButton?.isSelected = on }
    func setShift(_ on: Bool) { shiftButton?.isSelected = on }

    private static let titleFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
    private static let horizontalInset: CGFloat = 10

    /// The width of the `esc` key. Every key is at least this wide, and
    /// keys showing a single character or symbol are exactly this wide.
    static let minKeyWidth: CGFloat = {
        let text = ("esc" as NSString).size(withAttributes: [.font: titleFont])
        return ceil(text.width) + horizontalInset * 2
    }()

    private func build() {
        let keys: [(String, Key)] = [
            ("esc", .escape),
            ("ctrl", .ctrl),
            ("alt", .alt),
            ("shift", .shift),
            ("tab", .tab),
            ("↑", .up),
            ("↓", .down),
            ("←", .left),
            ("→", .right),
            ("|", .character("|")),
            ("~", .character("~")),
            ("-", .character("-")),
            ("/", .character("/")),
        ]

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (title, key) in keys {
            let button = makeButton(title: title, key: key)
            if case .ctrl = key { ctrlButton = button }
            if case .alt = key { altButton = button }
            if case .shift = key { shiftButton = button }
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(makeButton(image: "doc.on.clipboard", key: .paste))
        stack.addArrangedSubview(makeButton(image: "keyboard.chevron.compact.down", key: .dismiss))

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])
    }

    private func makeButton(title: String? = nil, image: String? = nil, key: Key) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.titleLineBreakMode = .byClipping
        let inset = Self.horizontalInset
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: inset, bottom: 4, trailing: inset)
        if let title {
            var attributed = AttributedString(title)
            attributed.font = Self.titleFont
            config.attributedTitle = attributed
        }
        if let image { config.image = UIImage(systemName: image) }

        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.target?.accessoryTapped(key)
        })
        button.configurationUpdateHandler = { button in
            var config = button.configuration
            config?.baseBackgroundColor = button.isSelected ? .tintColor : nil
            config?.baseForegroundColor = button.isSelected ? .white : .label
            button.configuration = config
        }

        // Single characters and icons are exactly as wide as `esc`;
        // longer labels (ctrl, shift) grow but never get narrower.
        let isSingleGlyph = image != nil || (title?.count ?? 0) == 1
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
