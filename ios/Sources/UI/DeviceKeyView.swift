import CryptoKit
import SwiftUI

/// Sets up this device's key on a Mac: one command to paste into Terminal
/// there, which adds the public key to `~/.ssh/authorized_keys`. The key
/// itself is shown with most of it hidden.
struct DeviceKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key: Curve25519.Signing.PrivateKey?
    @State private var error: String?
    @State private var confirmingRegenerate = false
    @State private var showingCommand = false

    private var publicKeyLine: String? {
        key.map { DeviceKey.authorizedKeysLine(for: $0, comment: DeviceKey.defaultComment) }
    }

    private var command: String? {
        key.map { DeviceKey.authorizeCommand(for: $0, comment: DeviceKey.defaultComment) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let command, let publicKeyLine, let key {
                    Section {
                        Text("1. On the Mac, open System Settings → General → Sharing and turn on Remote Login.")
                        Text("2. Copy this command, then paste it into Terminal on the Mac and press Return. (Universal Clipboard or AirDrop can carry it across.)")
                        HStack {
                            // A new key is a new command: start over.
                            CopyButton(title: "Copy Command", text: command)
                                .id(command)
                            Spacer()
                            Button {
                                showingCommand = true
                            } label: {
                                Image(systemName: "info.circle")
                                    .imageScale(.large)
                            }
                            .accessibilityLabel("Show command")
                        }
                        // Two buttons in one row: tap each, not the row.
                        .buttonStyle(.borderless)
                    } header: {
                        Text("Set up your Mac")
                    }

                    Section {
                        Text(DeviceKey.masked(publicKeyLine))
                            .font(.caption.monospaced())
                            .accessibilityLabel("Public key, partly hidden")
                        CopyButton(title: "Copy Public Key", text: publicKeyLine)
                            .id(publicKeyLine)
                        Button("Regenerate Key", role: .destructive) {
                            confirmingRegenerate = true
                        }
                    } header: {
                        Text("SSH key")
                    } footer: {
                        Text("""
                            The private key is stored only in this device's Keychain. \
                            Fingerprint: \(DeviceKey.fingerprint(for: key))
                            """)
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
            .sheet(isPresented: $showingCommand) {
                if let command {
                    CommandSheet(command: command)
                }
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

/// The command in full, so it can be read before it's pasted anywhere.
private struct CommandSheet: View {
    let command: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    CopyButton(title: "Copy Command", text: command)
                } footer: {
                    Text("Run on the Mac, it creates ~/.ssh and authorized_keys if needed, adds this device's public key unless it's already there, and says what it did. It contains no private key.")
                }
            }
            .navigationTitle("Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Copies `text` to the pasteboard and says so: the label turns into a
/// green "Copied" with a checkmark for two seconds, with a haptic.
struct CopyButton: View {
    let title: String
    let text: String

    /// How long the button says "Copied".
    static let confirmation: Duration = .seconds(2)

    @State private var copied = false
    /// Counts copies, so tapping again restarts the two seconds.
    @State private var copies = 0

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copies += 1
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .sensoryFeedback(.success, trigger: copies)
        .task(id: copies) {
            guard copies > 0 else { return }
            do { try await Task.sleep(for: Self.confirmation) } catch { return }
            withAnimation(.easeInOut(duration: 0.15)) { copied = false }
        }
        .accessibilityLabel(copied ? "Copied" : title)
    }
}
