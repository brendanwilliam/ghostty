import SwiftUI

/// Every Ghostty option, searchable, with effective values and sources.
struct AllOptionsView: View {
    @ObservedObject var model: SettingsModel
    @State private var search = ""
    @State private var showDesktopOnly = false
    @State private var onlyChanged = false

    private var options: [ConfigCatalog.Option] {
        ConfigCatalog.shared.options.filter { option in
            (showDesktopOnly || option.platform == nil)
                && (!onlyChanged || model.effective(option.key).source != .ghostty)
                && (search.isEmpty
                    || option.key.localizedCaseInsensitiveContains(search)
                    || option.summary.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("Only options that are set", isOn: $onlyChanged)
                Toggle("Show macOS/Linux-only options", isOn: $showDesktopOnly)
            }
            Section {
                ForEach(options) { option in
                    OptionRow(model: model, key: option.key)
                }
            } footer: {
                Text("Values set here override the Mac's config and the app's defaults. Swipe to reset.")
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("All Options")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Edit the app's overrides file directly.
struct RawConfigEditor: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errors: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            if !errors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(errors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                    }
                }
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 8)
        }
        .navigationTitle("config.ghostty")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    errors = model.saveText(text)
                    if errors.isEmpty { dismiss() }
                }
            }
        }
        .onAppear { text = model.overrides.text }
    }
}

/// What the app fetched from one host.
struct HostConfigView: View {
    let host: Host
    @State private var cache: RemoteConfigCache
    @State private var cleared = false

    init(host: Host) {
        self.host = host
        _cache = State(initialValue: RemoteConfigCache(hostID: host.id))
    }

    var body: some View {
        List {
            if !host.usesRemoteConfig {
                Section {
                    Text("This host's Ghostty config is turned off. Turn it on in the host's settings.")
                        .foregroundStyle(.secondary)
                }
            }
            if let meta = cache.metadata, !cleared {
                Section("Last synced") {
                    Text(meta.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                    ForEach(meta.sources, id: \.self) { source in
                        Text(source).font(.caption.monospaced())
                    }
                    if meta.sources.isEmpty {
                        Text("No Ghostty config found on this host.").foregroundStyle(.secondary)
                    }
                }
                if !meta.dropped.isEmpty {
                    Section {
                        ForEach(meta.dropped, id: \.self) { line in
                            Text(line).font(.caption.monospaced())
                        }
                    } header: {
                        Text("Not applied on iOS")
                    } footer: {
                        Text("Commands, working directories, keybinds, and desktop window options don't apply to a terminal on this device.")
                    }
                }
                if let text = cache.text {
                    Section("Applied config") {
                        Text(text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button("Forget synced config", role: .destructive) {
                        cache.clear()
                        cleared = true
                        GhosttyRuntime.shared.reloadConfig()
                    }
                } footer: {
                    Text("It's fetched again the next time you connect.")
                }
            } else {
                Section {
                    Text("Nothing synced yet. The config is fetched each time you connect.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(host.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
