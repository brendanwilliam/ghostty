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

    /// The command with the key hidden, until the user taps to reveal it.
    private var maskedCommand: String? {
        guard let command, let publicKeyLine else { return nil }
        return command.replacingOccurrences(of: publicKeyLine, with: DeviceKey.masked(publicKeyLine))
    }

    var body: some View {
        NavigationStack {
            List {
                if let command, let maskedCommand, let publicKeyLine, let key {
                    Section {
                        Text("1. On the Mac, open System Settings → General → Sharing and turn on Remote Login.")
                        Text("2. Copy this command, then paste it into Terminal on the Mac and press Return. (Universal Clipboard or AirDrop can carry it across.)")
                        CodeBlock(text: command, masked: maskedCommand)
                            .id(command) // a new key is a new command
                        Button("Show full command") { showingCommand = true }
                    } header: {
                        Text("Set up your Mac")
                    }

                    Section {
                        CodeBlock(text: publicKeyLine, masked: DeviceKey.masked(publicKeyLine), wraps: true)
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
                if let command, let maskedCommand {
                    CommandSheet(command: command, masked: maskedCommand)
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
    let masked: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    CodeBlock(text: command, masked: masked, wraps: true)
                } footer: {
                    Text("Run on the Mac, it creates ~/.ssh and authorized_keys if needed, adds this device's public key unless it's already there, and prints a checkmark when it worked. It contains no private key. Tap the eye to see the key.")
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
