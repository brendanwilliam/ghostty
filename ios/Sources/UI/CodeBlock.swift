import SwiftUI

/// A command or snippet to copy, styled like GitHub's code blocks: the text
/// in a bordered, monospaced box with a copy icon in the top-right corner
/// that turns into a green checkmark (with a haptic) for two seconds.
///
/// Use this wherever the user is meant to copy text somewhere else.
struct CodeBlock: View {
    /// What gets copied.
    let text: String
    /// What's shown instead of `text`, e.g. a partly hidden key.
    var display: String?
    /// Wrap long text. Otherwise it stays on one line and scrolls sideways,
    /// as long commands do on GitHub.
    var wraps = false

    /// How long the icon says "copied".
    static let confirmation: Duration = .seconds(2)

    @State private var copied = false
    /// Counts copies, so tapping again restarts the two seconds.
    @State private var copies = 0

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            code
            copyButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separator)))
        // In a List row, keep the row itself from being tappable.
        .buttonStyle(.borderless)
        .sensoryFeedback(.success, trigger: copies)
        .task(id: copies) {
            guard copies > 0 else { return }
            do { try await Task.sleep(for: Self.confirmation) } catch { return }
            withAnimation(.easeInOut(duration: 0.15)) { copied = false }
        }
    }

    @ViewBuilder
    private var code: some View {
        let shown = Text(display ?? text)
            .font(.callout.monospaced())
            .padding(.vertical, 8)
        if wraps {
            shown
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                shown.lineLimit(1).fixedSize()
            }
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = text
            copies += 1
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(copied ? "Copied" : "Copy")
    }
}
