import SwiftUI

/// App settings. Values here are written to the app's Ghostty config and
/// override each Mac's own config.
struct SettingsView: View {
    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SettingsModel()

    var body: some View {
        NavigationStack {
            Form {
                widthSection
                appearanceSection

                Section("Behavior") {
                    OptionRow(model: model, key: "copy-on-select", title: "Copy on select")
                    OptionRow(model: model, key: "scrollback-limit-lines", title: "Scrollback lines")
                    OptionRow(model: model, key: "mouse-scroll-multiplier", title: "Scroll speed")
                }

                Section {
                    NavigationLink("All options") { AllOptionsView(model: model) }
                    NavigationLink("Edit config file") { RawConfigEditor(model: model) }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Every Ghostty option can be set here. See ghostty.org/docs/config.")
                }

                hostsSection

                Section {
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if model.previewHostID == nil {
                    model.previewHostID = store.hosts.first { $0.usesRemoteConfig }?.id
                }
            }
        }
    }

    private var widthSection: some View {
        Section {
            Toggle("Fit columns to screen width", isOn: Binding(
                get: { model.defaultColumns != nil },
                set: { model.defaultColumns = $0 ? 80 : nil }))
            if let columns = model.defaultColumns {
                Stepper(value: Binding(
                    get: { columns },
                    set: { model.defaultColumns = $0 }),
                    in: AppSettings.columnRange, step: 5) {
                    HStack {
                        Text("Columns")
                        Spacer()
                        Text("\(columns)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Terminal width")
        } footer: {
            Text(model.defaultColumns == nil
                 ? "The font size from the config is used as is."
                 : "The font is scaled so this many columns fit across the screen in portrait. Pinch a terminal to change it for that host.")
        }
    }

    private var appearanceSection: some View {
        Section {
            if store.hosts.contains(where: { $0.usesRemoteConfig }) {
                Picker("Show values for", selection: $model.previewHostID) {
                    Text("No host").tag(UUID?.none)
                    ForEach(store.hosts.filter(\.usesRemoteConfig)) { host in
                        Text(host.displayName).tag(UUID?.some(host.id))
                    }
                }
            }
            NavigationLink {
                ThemePicker(model: model)
            } label: {
                valueRow("Theme", key: "theme")
            }
            NavigationLink {
                FontFamilyPicker(model: model)
            } label: {
                valueRow("Font", key: "font-family")
            }
            let family = RemoteConfigFetcher.unquote(model.effective("font-family").values.last ?? "")
            if !FontFamilyPicker.isAvailable(family) {
                Label("\(family) isn't installed on this device, so \(FontFamilyPicker.builtIn) is used.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            OptionRow(model: model, key: "font-size", title: "Font size")
            OptionRow(model: model, key: "cursor-style", title: "Cursor")
            OptionRow(model: model, key: "cursor-style-blink", title: "Cursor blink")
            OptionRow(model: model, key: "window-padding-x", title: "Horizontal padding")
            OptionRow(model: model, key: "window-padding-y", title: "Vertical padding")
        } header: {
            Text("Appearance")
        } footer: {
            Text("Badges show where a value comes from: Mac (that host's Ghostty config), Settings (set here), or a default. Settings win.")
        }
    }

    private var hostsSection: some View {
        Section {
            ForEach(store.hosts) { host in
                NavigationLink {
                    HostConfigView(host: host)
                } label: {
                    HStack {
                        Text(host.displayName)
                        Spacer()
                        Text(syncSummary(host)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Host configs")
        } footer: {
            Text("Each Mac's Ghostty config is fetched when you connect and applied beneath these settings.")
        }
    }

    private func valueRow(_ title: String, key: String) -> some View {
        let effective = model.effective(key)
        let unset = effective.display == "—" || effective.display == "\"\""
        let display = !unset ? effective.display
            : key == "font-family" ? FontFamilyPicker.builtIn : "Ghostty default"
        return HStack {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(display)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                SourceBadge(source: effective.source)
            }
        }
    }

    private func syncSummary(_ host: Host) -> String {
        guard host.usesRemoteConfig else { return "Off" }
        guard let meta = RemoteConfigCache(hostID: host.id).metadata else { return "Not synced" }
        return meta.fetchedAt.formatted(.relative(presentation: .named))
    }
}
