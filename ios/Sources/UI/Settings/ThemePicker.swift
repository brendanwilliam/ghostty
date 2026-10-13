import SwiftUI

/// Searchable list of the bundled themes with color previews.
struct ThemePicker: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var errors: [String] = []

    enum Filter: String, CaseIterable {
        case all = "All", dark = "Dark", light = "Light"
    }

    private static let themes: [ThemeCatalog.Theme] =
        ThemeCatalog.names.compactMap(ThemeCatalog.theme(named:))

    private var current: String { model.effective("theme").values.last ?? "" }

    private var filtered: [ThemeCatalog.Theme] {
        Self.themes.filter { theme in
            (search.isEmpty || theme.name.localizedCaseInsensitiveContains(search))
                && (filter == .all || (filter == .light) == theme.isLight)
        }
    }

    var body: some View {
        List {
            if !errors.isEmpty {
                ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) }
            }
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)

                if model.isOverridden("theme") {
                    Button("Use inherited theme (\(model.inherited("theme").display))") {
                        model.reset("theme")
                        dismiss()
                    }
                }
            }
            ForEach(filtered) { theme in
                Button {
                    errors = model.set("theme", theme.name)
                    if errors.isEmpty { dismiss() }
                } label: {
                    ThemeRow(theme: theme, selected: current == theme.name)
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ThemeRow: View {
    let theme: ThemeCatalog.Theme
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ghostty $ ls")
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.foreground ?? .white)
                HStack(spacing: 2) {
                    ForEach(theme.palette.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.palette[index])
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .padding(8)
            .background(theme.background ?? .black, in: RoundedRectangle(cornerRadius: 6))

            Text(theme.name)
            Spacer()
            if selected {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Picks the primary font family from fonts available on this device.
struct FontFamilyPicker: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var errors: [String] = []

    /// The font libghostty embeds and falls back to.
    static let builtIn = "JetBrains Mono"

    static let monospacedFamilies: [String] = UIFont.familyNames.filter { family in
        UIFont.fontNames(forFamilyName: family).contains { name in
            UIFont(name: name, size: 12)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ?? false
        }
    }.sorted()

    static func isAvailable(_ family: String) -> Bool {
        family.isEmpty || family == builtIn || UIFont.familyNames.contains(family)
    }

    private var current: String {
        RemoteConfigFetcher.unquote(model.effective("font-family").values.last ?? "")
    }

    var body: some View {
        List {
            if !errors.isEmpty {
                ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) }
            }
            if model.isOverridden("font-family") {
                Section {
                    Button("Use inherited font (\(model.inherited("font-family").display))") {
                        model.reset("font-family")
                        dismiss()
                    }
                }
            }
            Section {
                row(label: "\(Self.builtIn) (built in)", family: "", selected: current.isEmpty || current == Self.builtIn)
            }
            Section("On this device") {
                ForEach(Self.monospacedFamilies, id: \.self) { family in
                    row(label: family, family: family, selected: current == family)
                }
            }
        }
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(label: String, family: String, selected: Bool) -> some View {
        Button {
            // An empty value resets the list to the built-in font, which
            // also drops a host font the phone doesn't have.
            errors = model.set("font-family", family.isEmpty ? "\"\"" : family)
            if errors.isEmpty { dismiss() }
        } label: {
            HStack {
                Text(label)
                    .font(family.isEmpty ? .body.monospaced() : .custom(family, size: 17))
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
