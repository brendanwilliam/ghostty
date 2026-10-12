import UIKit
import GhosttyKit
import os

/// UITextInput for the terminal, which is what makes iOS offer dictation
/// (and input methods with marked text) on the software keyboard.
///
/// The terminal can't take back bytes it has sent, but dictation keeps
/// revising its words as you speak. So the "document" the keyboard sees
/// is only the text still being composed: typed keys go straight to the
/// program, while dictated and marked text is held in `composing`, drawn
/// at the cursor as a preedit, and sent once it's final.
extension TerminalSurfaceView: UITextInput {
    private static let log = Logger(subsystem: "com.brendanwilliam.ghostty-ios", category: "text-input")

    // MARK: Committing

    /// Whether text is being held rather than sent.
    private var holding: Bool { dictating || composingMarked != nil }

    /// Send the composed text to the program and start a new document.
    func commitComposing() {
        guard !composing.isEmpty || composingMarked != nil || dictating else { return }
        let text = composing
        Self.log.debug("commit \(text.count) chars")
        replaceDocument("", caret: 0)
        composingMarked = nil
        dictating = false
        updatePreedit()
        typeText(text)
    }

    /// Change the document behind the keyboard's back, telling it so.
    private func replaceDocument(_ text: String, caret: Int) {
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        composing = text
        composingCaret = caret
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    private func updatePreedit() {
        guard let surface else { return }
        composing.withCString { ghostty_surface_preedit(surface, $0, UInt(strlen($0))) }
    }

    /// Dictation is the active input mode while the user is speaking.
    private func noteInputMode() {
        if textInputMode?.primaryLanguage == "dictation" { dictating = true }
    }

    @objc func inputModeDidChange() {
        guard isFirstResponder else { return }
        if textInputMode?.primaryLanguage == "dictation" {
            dictating = true
        } else if dictating {
            commitComposing()
        }
    }

    // MARK: UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        noteInputMode()
        Self.log.debug("insertText \(text.count) chars dictating=\(self.dictating)")
        if text == "\n" {
            // Return sends whatever is composed, then runs it.
            commitComposing()
            typeText(text)
        } else if let marked = composingMarked {
            // An input method finishing its marked text.
            replace(nsRange: marked, with: text)
            composingMarked = nil
            if !dictating { commitComposing() }
        } else if dictating {
            replace(nsRange: NSRange(location: composingCaret, length: 0), with: text)
        } else {
            commitComposing()
            typeText(text)
        }
    }

    func deleteBackward() {
        noteInputMode()
        guard !composing.isEmpty else {
            typeBackspace()
            return
        }
        guard composingCaret > 0 else { return }
        let range = (composing as NSString).rangeOfComposedCharacterSequence(at: composingCaret - 1)
        let marked = composingMarked
        replace(nsRange: range, with: "")
        if let marked {
            let length = marked.length - NSIntersectionRange(marked, range).length
            composingMarked = length > 0 ? NSRange(location: marked.location, length: length) : nil
        }
    }

    // MARK: Marked text

    var markedTextRange: UITextRange? {
        composingMarked.map { TextOffsetRange($0.location, $0.location + $0.length) }
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        noteInputMode()
        let text = markedText ?? ""
        let target = composingMarked ?? NSRange(location: composingCaret, length: 0)
        replace(nsRange: target, with: text)
        let length = (text as NSString).length
        composingMarked = length > 0 ? NSRange(location: target.location, length: length) : nil
        composingCaret = target.location + min(selectedRange.location + selectedRange.length, length)
    }

    func unmarkText() {
        guard composingMarked != nil else { return }
        composingMarked = nil
        if !dictating { commitComposing() }
    }

    // MARK: Dictation

    func insertDictationResultPlaceholder() -> Any {
        Self.log.debug("dictation placeholder")
        dictating = true
        return TextOffsetRange(composingCaret, composingCaret)
    }

    func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {
        if !willInsertResult { commitComposing() }
    }

    func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        let text = dictationResult.map(\.text).joined()
        Self.log.debug("dictation result \(text.count) chars")
        dictating = true
        replace(nsRange: NSRange(location: composingCaret, length: 0), with: text)
        commitComposing()
    }

    func insertText(_ text: String, alternatives: [String], style: UITextAlternativeStyle) {
        // Recognized speech arrives this way; hold it like dictation.
        dictating = true
        insertText(text)
    }

    func dictationRecordingDidEnd() {
        Self.log.debug("dictation recording ended")
    }

    func dictationRecognitionFailed() {
        commitComposing()
    }

    // MARK: Document

    private func replace(nsRange: NSRange, with text: String) {
        let ns = composing as NSString
        let range = clamp(nsRange)
        let updated = ns.replacingCharacters(in: range, with: text)
        let caret = range.location + (text as NSString).length
        replaceDocument(updated, caret: caret)
        if let marked = composingMarked, NSMaxRange(marked) > (updated as NSString).length {
            composingMarked = nil
        }
        updatePreedit()
    }

    private func clamp(_ range: NSRange) -> NSRange {
        let length = (composing as NSString).length
        let start = min(max(range.location, 0), length)
        let end = min(max(range.location + range.length, start), length)
        return NSRange(location: start, length: end - start)
    }

    private func nsRange(_ range: UITextRange) -> NSRange? {
        guard let range = range as? TextOffsetRange else { return nil }
        return NSRange(location: range.lower, length: range.upper - range.lower)
    }

    func text(in range: UITextRange) -> String? {
        guard let r = nsRange(range) else { return nil }
        return (composing as NSString).substring(with: clamp(r))
    }

    func replace(_ range: UITextRange, withText text: String) {
        noteInputMode()
        guard let r = nsRange(range) else { return }
        replace(nsRange: r, with: text)
        if !holding { commitComposing() }
    }

    var selectedTextRange: UITextRange? {
        get { TextOffsetRange(composingCaret, composingCaret) }
        set {
            guard let range = newValue as? TextOffsetRange else { return }
            composingCaret = min(max(range.upper, 0), (composing as NSString).length)
        }
    }

    var beginningOfDocument: UITextPosition { TextOffset(0) }
    var endOfDocument: UITextPosition { TextOffset((composing as NSString).length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TextOffset, let to = toPosition as? TextOffset else { return nil }
        return TextOffsetRange(from.offset, to.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TextOffset else { return nil }
        let target = position.offset + offset
        guard target >= 0, target <= (composing as NSString).length else { return nil }
        return TextOffset(target)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: return self.position(from: position, offset: -offset)
        default: return self.position(from: position, offset: offset)
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = (position as? TextOffset)?.offset ?? 0
        let b = (other as? TextOffset)?.offset ?? 0
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? TextOffset)?.offset ?? 0) - ((from as? TextOffset)?.offset ?? 0)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: return range.start
        default: return range.end
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? TextOffset else { return nil }
        switch direction {
        case .left, .up: return TextOffsetRange(0, position.offset)
        default: return TextOffsetRange(position.offset, (composing as NSString).length)
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: Geometry

    /// The terminal cursor's cell, in this view's coordinates. Dictation
    /// and input-method UI anchor here.
    private var cursorRect: CGRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        // libghostty gives the bottom of the cursor, from the top left.
        return CGRect(x: x, y: y - height, width: 0, height: height)
    }

    func firstRect(for range: UITextRange) -> CGRect { cursorRect }
    func caretRect(for position: UITextPosition) -> CGRect { cursorRect }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { TextOffset(composingCaret) }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }
}

/// A position in the composing text, in UTF-16 units.
final class TextOffset: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class TextOffsetRange: UITextRange {
    let lower: Int
    let upper: Int

    init(_ a: Int, _ b: Int) {
        lower = min(a, b)
        upper = max(a, b)
    }

    override var start: UITextPosition { TextOffset(lower) }
    override var end: UITextPosition { TextOffset(upper) }
    override var isEmpty: Bool { lower == upper }
}
