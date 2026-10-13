import SwiftUI

/// The terminal screen for one host: its tabs, each holding one or more
/// split panes. The workspace outlives the screen (see WorkspaceStore), so
/// leaving and coming back finds the same sessions.
struct TerminalScreen: View {
    @ObservedObject var workspace: TerminalWorkspace
    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(spacing: 0) {
            if let sessions = workspace.sessions {
                ZmxBanner(sessions: sessions)
            }
            if workspace.tabs.count > 1 {
                TabStrip(workspace: workspace)
            }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    // Every tab stays alive so its sessions keep running.
                    ForEach(workspace.tabs) { tab in
                        let selected = tab.id == workspace.selectedTabID
                        SplitTreeView(workspace: workspace, tab: tab, size: geometry.size)
                            .opacity(selected ? 1 : 0)
                            .allowsHitTesting(selected)
                    }
                }
                .onChange(of: geometry.size, initial: true) { _, size in
                    workspace.layoutSize = size
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(workspace.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let pane = workspace.focusedPane, pane.ended, !pane.reconnecting {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reconnect") { workspace.reconnect(pane) }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                tabMenu
            }
        }
        .task {
            let hostID = workspace.host.id
            workspace.onColumnsSettled = { [store] columns in
                store.setColumns(columns, for: hostID)
            }
            workspace.start()
        }
        .onChange(of: workspace.closed) { _, closed in
            if closed { dismiss() }
        }
        .alert(
            "Trust this host?",
            isPresented: Binding(
                get: { workspace.promptingPane?.hostKeyPrompt != nil },
                set: { if !$0 { workspace.promptingPane?.hostKeyPrompt = nil } }),
            presenting: workspace.promptingPane?.hostKeyPrompt
        ) { prompt in
            Button("Trust") {
                prompt.respond(true)
                workspace.promptingPane?.hostKeyPrompt = nil
            }
            Button("Cancel", role: .cancel) {
                prompt.respond(false)
                workspace.promptingPane?.hostKeyPrompt = nil
            }
        } message: { prompt in
            Text("""
            First connection to \(workspace.host.endpoint). Verify the fingerprint matches \
            the server before trusting it.

            On the Mac: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

            \(prompt.fingerprint)
            """)
        }
        .alert("Password for \(workspace.host.username)@\(workspace.host.hostname)",
               isPresented: Binding(
                get: { workspace.promptingPane?.hostKeyPrompt == nil && workspace.promptingPane?.needsPassword == true },
                set: { if !$0 { workspace.promptingPane?.needsPassword = false } })
        ) {
            SecureField("Password", text: $password)
            Button("Connect") {
                let entered = password
                password = ""
                if let pane = workspace.promptingPane {
                    pane.needsPassword = false
                    workspace.reconnect(pane, password: entered)
                }
            }
            Button("Cancel", role: .cancel) {
                password = ""
                workspace.promptingPane?.needsPassword = false
            }
        } message: {
            Text("The server didn't accept this device's key. Add the key from the Device Key screen to ~/.ssh/authorized_keys, or log in with a password.")
        }
    }

    /// New tab, splits, and closing, like Ghostty's File and View menus.
    private var tabMenu: some View {
        let preferred = workspace.defaultSplitDirection
        let other: SplitDirection = preferred == .down ? .right : .down
        let splits = (workspace.selectedTab?.tree.count ?? 1) > 1
        return Menu {
            Button {
                workspace.perform(.newTab)
            } label: {
                Label("New Tab", systemImage: "plus.square.on.square")
            }
            Section {
                Button {
                    workspace.splitFocused(preferred)
                } label: {
                    Label(Self.name(preferred), systemImage: Self.icon(preferred))
                }
                Button {
                    workspace.splitFocused(other)
                } label: {
                    Label(Self.name(other), systemImage: Self.icon(other))
                }
                if splits {
                    Button {
                        workspace.perform(.toggleSplitZoom)
                    } label: {
                        Label(workspace.selectedTab?.zoomed == nil ? "Zoom Split" : "Unzoom Split",
                              systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Button {
                        workspace.perform(.equalizeSplits)
                    } label: {
                        Label("Equalize Splits", systemImage: "equal.square")
                    }
                }
            }
            Section {
                if let pane = workspace.focusedPane {
                    Button(role: .destructive) {
                        workspace.close(pane.id)
                    } label: {
                        Label(splits ? "Close Split" : "Close Tab", systemImage: "xmark.square")
                    }
                }
            }
        } label: {
            Image(systemName: "plus.square.on.square")
        }
        .accessibilityLabel("Tabs and Splits")
    }

    private static func name(_ direction: SplitDirection) -> String {
        direction == .down ? "Split Down" : "Split Right"
    }

    private static func icon(_ direction: SplitDirection) -> String {
        direction == .down ? "rectangle.split.1x2" : "rectangle.split.2x1"
    }
}
