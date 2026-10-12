import UIKit

/// Shows what dictation has heard but not yet sent, in a panel at the
/// cursor. libghostty's preedit is drawn on the cursor's row only, so it
/// can't wrap long dictation or show the line breaks you speak.
final class DictationPreview: UIView {
    private let label = UILabel()
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.14, alpha: 0.96)
        layer.cornerRadius = 8
        layer.borderWidth = 1
        layer.borderColor = UIColor.tintColor.withAlphaComponent(0.6).cgColor
        layer.zPosition = 1
        clipsToBounds = true
        isUserInteractionEnabled = false
        isHidden = true
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The text being shown, for tests.
    var text: String { label.text ?? "" }

    /// Show `text` below the cursor (or above it when there's more room
    /// there), as wide as the terminal. Text taller than the room shows
    /// its end, where the words are arriving.
    func show(_ text: String, cursor: CGRect, in bounds: CGRect, visibleBottom: CGFloat, fontSize: CGFloat) {
        guard !text.isEmpty, bounds.width > 40 else {
            isHidden = true
            return
        }
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: UIColor.white,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])

        let padding = Self.padding
        let width = bounds.width - padding * 2
        let textWidth = width - padding * 2
        let textHeight = ceil(label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        let wanted = textHeight + padding * 2

        let below = visibleBottom - cursor.maxY - Self.gap - padding
        let above = cursor.minY - Self.gap - bounds.minY - padding
        let placeBelow = below >= wanted || below >= above
        let height = max(min(wanted, placeBelow ? below : above), 0)
        let y = placeBelow ? cursor.maxY + Self.gap : cursor.minY - Self.gap - height

        frame = CGRect(x: bounds.minX + padding, y: y, width: width, height: height)        // Pin the text to the bottom so the latest words stay in view.
        label.frame = CGRect(x: padding, y: height - padding - textHeight, width: textWidth, height: textHeight)
        isHidden = false
    }

    func hide() {
        isHidden = true
        label.attributedText = nil
    }
}
