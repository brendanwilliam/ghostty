import SwiftUI

/// A small label showing which layer a value comes from.
struct SourceBadge: View {
    let source: SettingsModel.Source

    var body: some View {
        Text(source.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch source {
        case .ghostty: return .secondary
        case .app: return .gray
        case .host: return .blue
        case .settings: return .orange
        }
    }
}

/// A list row for one option: name, effective value, and its source.
/// Opens the option's editor.
struct OptionRow: View {
    @ObservedObject var model: SettingsModel
    let key: String
    var title: String?

    var body: some View {
        NavigationLink {
            OptionDetailView(model: model, key: key)
        } label: {
            let effective = model.effective(key)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? key)
                    if title != nil {
                        Text(key).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(effective.display)
                        .font(.callout.monospaced())
                        .foregroundStyle(effective.source == .settings ? .primary : .secondary)
                        .lineLimit(1)
                    SourceBadge(source: effective.source)
                }
            }
        }
        .swipeActions {
            if model.isOverridden(key) {
                Button("Reset") { model.reset(key) }.tint(.orange)
            }
        }
    }
}

/// Edits one option in the app's overrides, with an editor suited to its
/// type, its documentation, and a reset back to the inherited value.
struct OptionDetailView: View {
    @ObservedObject var model: SettingsModel
    let key: String

    @State private var draft: [String] = []
    @State private var errors: [String] = []

    private var option: ConfigCatalog.Option? { ConfigCatalog.shared.option(key) }
    private var kind: ConfigCatalog.Option.Kind { option?.kind ?? .text }
    private var repeatable: Bool { option?.repeatable ?? false }

    var body: some View {
        Form {
            Section {
                editor
                if !errors.isEmpty {
                    ForEach(errors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            } header: {
                Text("Value")
            } footer: {
                let inherited = model.inherited(key)
                HStack(spacing: 4) {
                    Text("Without this setting: \(inherited.display)")
                    SourceBadge(source: inherited.source)
                }
            }

            if model.isOverridden(key) {
                Section {
                    Button("Reset to inherited value", role: .destructive) {
                        model.reset(key)
                        load()
                    }
                }
            }

            if let platform = option?.platform {
                Section {
                    Label("This option only applies to Ghostty on \(platform == "macos" ? "macOS" : "Linux"). It has no effect here.",
                          systemImage: "info.circle")
                        .font(.callout)
                }
            }

            if let doc = option?.doc, !doc.isEmpty {
                Section("About") {
                    Text(doc)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(key)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if needsSaveButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { apply(draft) }
                }
            }
        }
        .onAppear(perform: load)
    }

    private var needsSaveButton: Bool {
        repeatable || kind == .text || kind == .number
    }

    private func load() {
        draft = model.effective(key).values
        if draft.isEmpty { draft = [""] }
        errors = []
    }

    private func apply(_ values: [String]) {
        let cleaned = repeatable ? values.filter { !$0.isEmpty } : values
        errors = model.set(key, values: cleaned.isEmpty ? [""] : cleaned)
    }

    @ViewBuilder
    private var editor: some View {
        if repeatable {
            ForEach(draft.indices, id: \.self) { index in
                TextField("Value", text: $draft[index])
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .onDelete { draft.remove(atOffsets: $0) }
            Button("Add value") { draft.append("") }
        } else {
            switch kind {
            case .bool:
                Toggle(key, isOn: Binding(
                    get: { draft.first == "true" },
                    set: { value in
                        draft = [value ? "true" : "false"]
                        apply(draft)
                    }))
            case .enumeration:
                Picker(key, selection: Binding(
                    get: { draft.first ?? "" },
                    set: { value in
                        draft = [value]
                        apply(draft)
                    })) {
                    if !(option?.values ?? []).contains(draft.first ?? "") {
                        Text(draft.first.flatMap { $0.isEmpty ? nil : $0 } ?? "Default").tag(draft.first ?? "")
                    }
                    ForEach(option?.values ?? [], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            case .color:
                ColorPicker(selection: Binding(
                    get: { Color(ghosttyHex: draft.first ?? "") ?? .black },
                    set: { color in
                        draft = [color.ghosttyHex]
                        apply(draft)
                    }), supportsOpacity: false) {
                    Text(draft.first ?? "").font(.body.monospaced())
                }
            case .number:
                TextField("Value", text: binding(0))
                    .keyboardType(.decimalPad)
                    .font(.body.monospaced())
            case .text:
                TextField("Value", text: binding(0))
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(
            get: { draft.indices.contains(index) ? draft[index] : "" },
            set: { value in
                if draft.indices.contains(index) { draft[index] = value } else { draft.append(value) }
            })
    }
}
