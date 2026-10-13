import CryptoKit
import SwiftUI

/// Shows this device's public key so it can be added to a server's
/// `~/.ssh/authorized_keys`.
struct DeviceKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key: Curve25519.Signing.PrivateKey?
    @State private var error: String?
    @State private var confirmingRegenerate = false

    private var publicKeyLine: String? {
        key.map { DeviceKey.authorizedKeysLine(for: $0, comment: DeviceKey.defaultComment) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let publicKeyLine, let key {
                    Section {
                        Text(publicKeyLine)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = publicKeyLine
                        } label: {
                            Label("Copy Public Key", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: publicKeyLine) {
                            Label("Share Public Key", systemImage: "square.and.arrow.up")
                        }
                    } header: {
                        Text("Public key")
                    } footer: {
                        Text(DeviceKey.fingerprint(for: key)).font(.caption.monospaced())
                    }

                    Section("Set up your Mac") {
                        Text("1. System Settings → General → Sharing → turn on Remote Login.")
                        Text("2. Add this key on the Mac (e.g. AirDrop or Universal Clipboard the copied key), then run:")
                        Text("pbpaste >> ~/.ssh/authorized_keys")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }

                    Section {
                        Button("Regenerate Key", role: .destructive) {
                            confirmingRegenerate = true
                        }
                    } footer: {
                        Text("The private key is stored only in this device's Keychain.")
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Device Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Regenerate this device's key?",
                isPresented: $confirmingRegenerate,
                titleVisibility: .visible
            ) {
                Button("Regenerate", role: .destructive) {
                    load { try DeviceKey.regenerate() }
                }
            } message: {
                Text("Servers that trust the current key will stop accepting this device until you add the new key.")
            }
            .onAppear { load { try DeviceKey.loadOrCreate() } }
        }
    }

    private func load(_ body: () throws -> Curve25519.Signing.PrivateKey) {
        do {
            key = try body()
            error = nil
        } catch {
            self.error = "Couldn't access the Keychain: \(error.localizedDescription)"
        }
    }
}
