import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var store: HostStore
    @EnvironmentObject private var workspaces: WorkspaceStore
    @StateObject private var bonjour = BonjourBrowser()
    @State private var editing: Host?
    @State private var showingKey = false
    @State private var showingSettings = false
    /// A host whose sessions are about to be ended, pending confirmation.
    @State private var ending: Host?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(value: Host.local) {
                        VStack(alignment: .leading) {
                            Text(Host.local.displayName).font(.headline)
                            Text("A shell on this phone. Works without a network.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let open = workspaces.openWorkspace(for: .local) {
                                OpenSessionsLabel(workspace: open)
                            }
                        }
                    }
                    .swipeActions {
                        if workspaces.hasSessions(.local) {
                            Button("End Sessions") { ending = .local }.tint(.orange)
                        }
                    }
                }

                Section("Hosts") {
                    if store.hosts.isEmpty {
                        Text("Add your Mac to connect. Enable Remote Login in System Settings → General → Sharing.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    ForEach(store.hosts) { host in
                        NavigationLink(value: host) {
                            VStack(alignment: .leading) {
                                Text(host.displayName).font(.headline)
                                Text("\(host.username)@\(host.hostname)\(host.port == 22 ? "" : ":\(host.port)")")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                if let open = workspaces.openWorkspace(for: host) {
                                    OpenSessionsLabel(workspace: open)
                                } else if let saved = workspaces.savedTabCount(for: host) {
                                    TabCountLabel(tabs: saved)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                workspaces.remove(host)
                                store.delete(host)
                            }
                            Button("Edit") { editing = host }.tint(.gray)
                            if workspaces.hasSessions(host) {
                                Button("End Sessions") { ending = host }.tint(.orange)
                            }
                        }
                    }
                }

                let discovered = bonjour.services.filter { service in
                    !store.hosts.contains { $0.name == service.name }
                }
                if !discovered.isEmpty {
                    Section("On this network") {
                        ForEach(discovered) { service in
                            Button {
                                Task { await add(service) }
                            } label: {
                                Label(service.name, systemImage: "desktopcomputer")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ghostty")
            .navigationDestination(for: Host.self) { host in
                TerminalScreen(workspace: workspaces.workspace(for: host))
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { showingKey = true } label: {
                        Label("Device Key", systemImage: "key")
                    }
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = Host(name: "", hostname: "", username: "")
                    } label: {
                        Label("Add Host", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { host in
                HostEditView(host: host)
            }
            .sheet(isPresented: $showingKey) {
                DeviceKeyView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .confirmationDialog(
                "End all sessions on \(ending?.displayName ?? "")?",
                isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                titleVisibility: .visible,
                presenting: ending
            ) { host in
                Button("End Sessions", role: .destructive) { workspaces.endSessions(host) }
            } message: { host in
                Text(host.isLocal
                     ? "Closes every tab and stops the programs running in them."
                     : "Closes every tab and ends the programs running in them on the host.")
            }
            .onAppear { bonjour.start() }
            .onDisappear { bonjour.stop() }
        }
    }

    private func add(_ service: BonjourBrowser.Service) async {
        let resolved = await BonjourBrowser.resolve(service)
        editing = Host(
            name: service.name,
            hostname: resolved?.host ?? "",
            port: resolved?.port ?? 22,
            username: "")
    }
}

/// "2 tabs open" under a host that has sessions running.
private struct OpenSessionsLabel: View {
    @ObservedObject var workspace: TerminalWorkspace

    var body: some View {
        HStack(spacing: 6) {
            TabCountLabel(tabs: workspace.tabs.count)
            if let route = workspace.focusedPane?.route {
                Label(route.kind == .tailnet ? "tailnet" : route.kind == .lan ? "local network" : route.address,
                      systemImage: route.kind == .lan ? "house" : "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
            }
        }
    }
}

private struct TabCountLabel: View {
    let tabs: Int

    var body: some View {
        Label(tabs == 1 ? "1 tab open" : "\(tabs) tabs open", systemImage: "circle.fill")
            .labelStyle(OpenSessionsLabelStyle())
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct OpenSessionsLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(.green)
            configuration.title
        }
    }
}
