import SwiftUI

struct HostEditView: View {
    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss

    @State private var host: Host
    @State private var password = ""
    @State private var knownFingerprint: String?

    init(host: Host) {
        _host = State(initialValue: host)
    }

    private var isNew: Bool { !store.hosts.contains { $0.id == host.id } }

    private var isValid: Bool {
        !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.username.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(host.port)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $host.name)
                    TextField("Hostname or IP", text: $host.hostname)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $host.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    TextField("Username", text: $host.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Toggle("Save password", isOn: $host.savesPassword)
                    if host.savesPassword {
                        SecureField(isNew ? "Password" : "New password (leave blank to keep)", text: $password)
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("This device's key is always tried first. A saved password is used if the key is refused.")
                }

                Section {
                    Picker("TERM", selection: $host.term) {
                        Text("xterm-256color").tag("xterm-256color")
                        Text("xterm-ghostty").tag("xterm-ghostty")
                    }
                } footer: {
                    Text("xterm-ghostty requires Ghostty's terminfo on the server.")
                }

                if let knownFingerprint {
                    Section("Host key") {
                        Text(knownFingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Forget host key", role: .destructive) {
                            KnownHosts.shared.forget(endpoint: host.endpoint)
                            self.knownFingerprint = nil
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!isValid)
                }
            }
            .onAppear {
                knownFingerprint = KnownHosts.shared.fingerprint(endpoint: host.endpoint)
            }
        }
    }

    private func save() {
        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        host.username = host.username.trimmingCharacters(in: .whitespaces)
        if host.savesPassword {
            if !password.isEmpty {
                try? Keychain.write(Data(password.utf8), for: host.passwordAccount)
            }
        } else {
            try? Keychain.delete(host.passwordAccount)
        }
        store.upsert(host)
        dismiss()
    }
}
