import SwiftUI

/// Shown on a terminal screen when the host doesn't have zmx, so its
/// sessions end when the app closes.
struct ZmxBanner: View {
    @ObservedObject var sessions: HostSessions
    @AppStorage private var dismissed: Bool
    @State private var installing = false

    init(sessions: HostSessions) {
        self.sessions = sessions
        _dismissed = AppStorage(wrappedValue: false, "zmxBannerDismissed-\(sessions.host.id.uuidString)")
    }

    var body: some View {
        if sessions.missing && !dismissed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sessions end when the app closes")
                        .font(.subheadline.weight(.semibold))
                    Text("Install zmx on \(sessions.host.displayName) to keep them running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Set Up…") { installing = true }
                        .font(.caption.weight(.semibold))
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(Color(white: 0.12))
            .sheet(isPresented: $installing) {
                ZmxInstallSheet(sessions: sessions)
            }
        }
    }
}

/// Installs zmx on the host with Homebrew, or explains how to.
struct ZmxInstallSheet: View {
    @ObservedObject var sessions: HostSessions
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var output = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("""
                    zmx keeps each tab's shell running on \(sessions.host.displayName) when this app is \
                    closed or loses its connection. Opening the host again picks up where you left off.
                    """)
                }
                if sessions.available {
                    Section {
                        Label("zmx is installed. New tabs keep running when the app closes.",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else if sessions.probe?.brew != nil {
                    Section {
                        Button {
                            Task { await install() }
                        } label: {
                            HStack {
                                Text("Install with Homebrew")
                                if running {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(running)
                    } footer: {
                        Text("Runs brew install neurosnap/tap/zmx on the host.")
                    }
                }
                if !sessions.available {
                    Section("Or on the host") {
                        CodeBlock(text: "brew install neurosnap/tap/zmx")
                        Link("Other ways to install", destination: URL(string: "https://zmx.sh")!)
                    }
                }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.red)
                    }
                }
                if !output.isEmpty {
                    Section("Output") {
                        Text(output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Keep Sessions Running")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func install() async {
        running = true
        failure = nil
        defer { running = false }
        do {
            output = try await sessions.install()
            if !sessions.available {
                failure = "zmx still wasn't found after installing."
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}
