import UIKit
import GhosttyKit

/// UITextInput for the terminal, which is what makes iOS offer dictation
/// (and input methods with marked text) on the software keyboard.
///
/// The keyboard edits a local document (`composing`): the text typed since
/// the last Return. Final text is sent to the program as it appears, while
/// provisional text (dictation still listening, an input method's marked
/// text) is drawn at the cursor and held until it's final. If the keyboard
/// later revises text already sent (dictation correcting itself), the
/// difference is sent as backspaces and retyped text.
extension TerminalSurfaceView: UITextInput {

    /// Record a text-input call for diagnosis (see `TextInputTrace`).
    private func trace(_ event: @autoclosure () -> String) {
        guard TextInputTrace.enabled else { return }
        let mode = textInputMode?.primaryLanguage ?? "nil"
        let marked = composingMarked.map { "\($0.location),\($0.length)" } ?? "-"
        TextInputTrace.write("\(event()) | doc=\(composing.debugDescription) caret=\(composingCaret) "
            + "marked=\(marked) dictating=\(dictating) mode=\(mode)")
    }

    // MARK: Syncing with the program

    /// Whether the document's latest text is still provisional (dictation
    /// in progress, or an input method's marked text), so it's held back.
    private var holding: Bool { dictating || composingMarked != nil }

    /// Bring the program up to date with the document, unless its text is
    /// still provisional. Only the difference from what was already sent
    /// goes out: new text is typed, and text the keyboard revised after
    /// sending is backspaced over and retyped.
    ///
    /// Edits the keyboard makes itself never notify `inputDelegate`; doing
    /// so tells iOS the text changed underneath it, which ends dictation.
    private func sync() {
        if !holding {
            let old = Array(composingSent), new = Array(composing)
            var common = 0
            while common < old.count, common < new.count, old[common] == new[common] { common += 1 }
            for _ in common..<old.count { typeBackspace() }
            typeText(String(new[common...]))
            composingSent = composing
            // Programs like vim rarely see a Return; don't grow forever.
            if (composing as NSString).length > Self.documentLimit { resetDocument() }
        }
        updatePreedit()
    }

    /// Past this many UTF-16 units of settled text, the document restarts.
    private static var documentLimit: Int { 4000 }

    /// Send anything still provisional and start an empty document. For
    /// when the app moves on: Return, a tap, a special key, losing focus.
    func commitComposing() {
        trace("commitComposing")
        composingMarked = nil
        dictating = false
        sync()
        resetDocument()
    }

    /// Start an empty document, telling the keyboard (this change is ours,
    /// not its own). Only called once everything has been sent.
    private func resetDocument() {
        guard !composing.isEmpty else { return }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        composing = ""
        composingSent = ""
        composingCaret = 0
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    /// The provisional text (what hasn't been sent), drawn at the cursor.
    private func updatePreedit() {
        guard let surface else { return }
        let sent = Array(composingSent), all = Array(composing)
        var common = 0
        while common < sent.count, common < all.count, sent[common] == all[common] { common += 1 }
        let pending = String(all[common...])
        pending.withCString { ghostty_surface_preedit(surface, $0, UInt(strlen($0))) }
    }

    /// Dictation is the active input mode while the user is speaking.
    private func noteInputMode() {
        if textInputMode?.primaryLanguage == "dictation" { dictating = true }
    }

    @objc func inputModeDidChange() {
        trace("inputModeDidChange")
        guard isFirstResponder else { return }
        if textInputMode?.primaryLanguage == "dictation" {
            dictating = true
        } else if dictating {
            dictating = false
            sync()
        }
    }

    // MARK: UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        trace("insertText \(text.debugDescription)")
        noteInputMode()
        if text == "\n" {
            // Return sends whatever is composed, then runs it.
            commitComposing()
            typeText(text)
            return
        }
        let target = composingMarked ?? NSRange(location: composingCaret, length: 0)
        composingMarked = nil
        edit(target, with: text)
        sync()
    }

    func deleteBackward() {
        trace("deleteBackward")
        noteInputMode()
        guard composingCaret > 0 else {
            // Nothing of ours to delete: it's a Backspace for the program.
            typeBackspace()
            return
        }
        let range = (composing as NSString).rangeOfComposedCharacterSequence(at: composingCaret - 1)
        let marked = composingMarked
        edit(range, with: "")
        if let marked {
            let length = marked.length - NSIntersectionRange(marked, range).length
            composingMarked = length > 0 ? NSRange(location: min(marked.location, range.location), length: length) : nil
        }
        sync()
    }

    // MARK: Marked text

    var markedTextRange: UITextRange? {
        trace("markedTextRange get")
        return composingMarked.map { TextOffsetRange($0.location, $0.location + $0.length) }
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        trace("setMarkedText \(markedText.debugDescription) sel=\(selectedRange)")
        noteInputMode()
        let text = markedText ?? ""
        let target = composingMarked ?? NSRange(location: composingCaret, length: 0)
        edit(target, with: text)
        let length = (text as NSString).length
        composingMarked = length > 0 ? NSRange(location: target.location, length: length) : nil
        composingCaret = target.location + min(selectedRange.location + selectedRange.length, length)
        sync()
    }

    func unmarkText() {
        trace("unmarkText")
        guard composingMarked != nil else { return }
        composingMarked = nil
        sync()
    }

    // MARK: Dictation

    func insertDictationResultPlaceholder() -> Any {
        trace("insertDictationResultPlaceholder")
        dictating = true
        return TextOffsetRange(composingCaret, composingCaret)
    }

    func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {
        trace("removeDictationResultPlaceholder willInsert=\(willInsertResult)")
        if !willInsertResult {
            dictating = false
            sync()
        }
    }

    func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        trace("insertDictationResult \(dictationResult.map(\.text))")
        edit(NSRange(location: composingCaret, length: 0), with: dictationResult.map(\.text).joined())
        dictating = false
        sync()
    }

    func insertText(_ text: String, alternatives: [String], style: UITextAlternativeStyle) {
        trace("insertText(alternatives) \(text.debugDescription) alts=\(alternatives.count)")
        insertText(text)
    }

    func dictationRecordingDidEnd() {
        trace("dictationRecordingDidEnd")
    }

    func dictationRecognitionFailed() {
        trace("dictationRecognitionFailed")
        dictating = false
        sync()
    }

    // MARK: Document

    /// Apply an edit the keyboard asked for, leaving the caret after it.
    private func edit(_ nsRange: NSRange, with text: String) {
        let range = clamp(nsRange)
        composing = (composing as NSString).replacingCharacters(in: range, with: text)
        composingCaret = range.location + (text as NSString).length
        if let marked = composingMarked, NSMaxRange(marked) > (composing as NSString).length {
            composingMarked = nil
        }
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
        trace("text(in: \(nsRange(range).map { "\($0)" } ?? "?"))")
        guard let r = nsRange(range) else { return nil }
        return (composing as NSString).substring(with: clamp(r))
    }

    func replace(_ range: UITextRange, withText text: String) {
        trace("replace(\(nsRange(range).map { "\($0)" } ?? "?"), \(text.debugDescription))")
        noteInputMode()
        guard let r = nsRange(range) else { return }
        edit(r, with: text)
        sync()
    }

    var selectedTextRange: UITextRange? {
        get {
            trace("selectedTextRange get")
            return TextOffsetRange(composingCaret, composingCaret)
        }
        set {
            trace("selectedTextRange set \((newValue as? TextOffsetRange).map { "\($0.lower)-\($0.upper)" } ?? "nil")")
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

/// An opt-in trace of text-input calls, for diagnosing dictation and input
/// methods on a device. It records typed text, so it only runs when the
/// app is launched with GHOSTTY_TRACE_TEXT_INPUT=1. The trace is written to
/// Library/Caches/text-input-trace.log in the app's container.
enum TextInputTrace {
    static let enabled = ProcessInfo.processInfo.environment["GHOSTTY_TRACE_TEXT_INPUT"] == "1"

    static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("text-input-trace.log")

    private static let start = Date()

    static func write(_ line: String) {
        let stamped = String(format: "%8.3f ", Date().timeIntervalSince(start)) + line + "\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
