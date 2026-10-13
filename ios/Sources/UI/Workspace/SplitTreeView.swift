import SwiftUI

/// One tab's panes laid out by its split tree, with draggable dividers.
/// Panes are placed by frame (not nested views) so a terminal keeps its
/// identity as the tree around it changes.
struct SplitTreeView: View {
    @ObservedObject var workspace: TerminalWorkspace
    let tab: TerminalWorkspace.Tab
    let size: CGSize

    /// Space between panes, where the divider line is drawn.
    static let gap: CGFloat = 2

    var body: some View {
        let bounds = CGRect(origin: .zero, size: size)
        let frames = tab.zoomed.map { [$0: bounds] } ?? tab.tree.frames(in: bounds, gap: Self.gap)
        let split = frames.count > 1

        ZStack(alignment: .topLeading) {
            ForEach(tab.tree.panes, id: \.self) { id in
                if let pane = workspace.panes[id], let frame = frames[id] {
                    PaneView(pane: pane, workspace: workspace, dimmed: split && id != tab.focused)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            if tab.zoomed == nil {
                ForEach(tab.tree.dividers(in: bounds, gap: Self.gap), id: \.path) { divider in
                    SplitDividerView(divider: divider) { ratio in
                        workspace.setRatio(ratio, at: divider.path, in: tab.id)
                    } onEqualize: {
                        workspace.equalize(tab.id)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }
}

/// A terminal pane, dimmed while another split has focus.
private struct PaneView: View {
    @ObservedObject var pane: TerminalPane
    let workspace: TerminalWorkspace
    let dimmed: Bool

    var body: some View {
        ZStack {
            Color.black
            if let view = pane.surfaceView {
                SurfaceRepresentable(view: view) { workspace.takeKeyboard(for: pane.id) }
                    .id(pane.attempt)
            }
            if dimmed {
                // Ghostty's unfocused-split-opacity, over a black fill.
                Color.black
                    .opacity(1 - (pane.surfaceView?.unfocusedSplitOpacity ?? 0.7))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if pane.reconnecting {
                Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: pane.reconnecting)
        .clipped()
    }
}

struct SurfaceRepresentable: UIViewRepresentable {
    let view: TerminalSurfaceView
    /// Whether this view should take the keyboard when it appears.
    let takesKeyboard: () -> Bool

    func makeUIView(context: Context) -> TerminalSurfaceView {
        if takesKeyboard() {
            DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        }
        return view
    }

    func updateUIView(_ uiView: TerminalSurfaceView, context: Context) {}
}

/// The line between two splits. Drag to resize; double-tap to equalize.
private struct SplitDividerView: View {
    let divider: SplitTree.Divider
    let onRatio: (Double) -> Void
    let onEqualize: () -> Void

    /// How far either side of the line a touch grabs it.
    private static let grab: CGFloat = 10
    @State private var snapped = false

    var body: some View {
        let (first, _) = SplitTree.split(divider.bounds, axis: divider.axis, ratio: divider.ratio,
                                         gap: SplitTreeView.gap)
        let horizontal = divider.axis == .horizontal
        let line = horizontal
            ? CGRect(x: first.maxX, y: divider.bounds.minY, width: SplitTreeView.gap, height: divider.bounds.height)
            : CGRect(x: divider.bounds.minX, y: first.maxY, width: divider.bounds.width, height: SplitTreeView.gap)
        let hit = line.insetBy(dx: horizontal ? -Self.grab : 0, dy: horizontal ? 0 : -Self.grab)

        ZStack {
            Color.clear.contentShape(Rectangle())
            Rectangle()
                .fill(Color(white: 0.35))
                .frame(width: horizontal ? SplitTreeView.gap : nil, height: horizontal ? nil : SplitTreeView.gap)
        }
        .frame(width: hit.width, height: hit.height)
        .offset(x: hit.minX, y: hit.minY)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(SplitTreeView.space))
                .onChanged { drag in
                    let bounds = divider.bounds
                    var ratio = horizontal
                        ? (drag.location.x - bounds.minX) / bounds.width
                        : (drag.location.y - bounds.minY) / bounds.height
                    // Snap to the middle, with a tick as it catches.
                    let nearMiddle = abs(ratio - 0.5) < 0.03
                    if nearMiddle {
                        ratio = 0.5
                        if !snapped { UISelectionFeedbackGenerator().selectionChanged() }
                    }
                    snapped = nearMiddle
                    onRatio(ratio)
                }
        )
        .onTapGesture(count: 2, perform: onEqualize)
    }
}

extension SplitTreeView {
    /// The coordinate space dividers measure drags in.
    static let space = "split-tree"
}
