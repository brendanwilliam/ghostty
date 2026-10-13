import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var store: HostStore
    @StateObject private var bonjour = BonjourBrowser()
    @State private var editing: Host?
    @State private var showingKey = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
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
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.delete(host) }
                            Button("Edit") { editing = host }.tint(.gray)
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
                TerminalScreen(host: host)
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
