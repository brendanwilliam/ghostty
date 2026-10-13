import SwiftUI

/// The open tabs, shown under the navigation bar once there's more than
/// one. Tap to switch; × closes.
struct TabStrip: View {
    @ObservedObject var workspace: TerminalWorkspace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(workspace.tabs) { tab in
                        chip(for: tab).id(tab.id)
                    }
                    Button {
                        workspace.perform(.newTab)
                    } label: {
                        Image(systemName: "plus")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 30, height: 28)
                    }
                    .accessibilityLabel("New Tab")
                }
                .padding(.horizontal, 8)
            }
            .onChange(of: workspace.selectedTabID) { _, id in
                withAnimation { proxy.scrollTo(id) }
            }
        }
        .padding(.vertical, 4)
        .background(Color.black)
    }

    private func chip(for tab: TerminalWorkspace.Tab) -> some View {
        let selected = tab.id == workspace.selectedTabID
        return HStack(spacing: 6) {
            Text(workspace.title(of: tab))
                .font(.footnote)
                .lineLimit(1)
                .frame(maxWidth: 140)
            Button {
                workspace.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .frame(width: 18, height: 18)
            }
            .accessibilityLabel("Close Tab")
        }
        .foregroundStyle(selected ? Color.white : Color(white: 0.6))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(Capsule().fill(Color(white: selected ? 0.24 : 0.11)))
        .contentShape(Capsule())
        .onTapGesture { workspace.select(tab.id) }
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
