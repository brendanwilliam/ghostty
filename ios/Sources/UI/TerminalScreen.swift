import SwiftUI

/// Full-screen terminal for one host.
struct TerminalScreen: View {
    @StateObject private var session: TerminalSession
    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    init(host: Host) {
        _session = StateObject(wrappedValue: TerminalSession(host: host))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let view = session.surfaceView {
                SurfaceRepresentable(view: view)
                    .id(session.attempt)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.ended {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reconnect") {
                        Task { await session.connect() }
                    }
                }
            }
        }
        .task {
            let hostID = session.host.id
            session.onColumnsSettled = { [store] columns in
                store.setColumns(columns, for: hostID)
            }
            await session.connect()
        }
        .onDisappear { session.disconnect() }
        .alert(
            "Trust this host?",
            isPresented: Binding(
                get: { session.hostKeyPrompt != nil },
                set: { if !$0 { session.hostKeyPrompt = nil } }),
            presenting: session.hostKeyPrompt
        ) { prompt in
            Button("Trust") {
                prompt.respond(true)
                session.hostKeyPrompt = nil
            }
            Button("Cancel", role: .cancel) {
                prompt.respond(false)
                session.hostKeyPrompt = nil
            }
        } message: { prompt in
            Text("""
            First connection to \(session.host.endpoint). Verify the fingerprint matches \
            the server before trusting it.

            On the Mac: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

            \(prompt.fingerprint)
            """)
        }
        .alert("Password for \(session.host.username)@\(session.host.hostname)",
               isPresented: $session.needsPassword) {
            SecureField("Password", text: $password)
            Button("Connect") {
                let entered = password
                password = ""
                Task { await session.connect(password: entered) }
            }
            Button("Cancel", role: .cancel) { password = "" }
        } message: {
            Text("The server didn't accept this device's key. Add the key from the Device Key screen to ~/.ssh/authorized_keys, or log in with a password.")
        }
    }
}

private struct SurfaceRepresentable: UIViewRepresentable {
    let view: TerminalSurfaceView

    func makeUIView(context: Context) -> TerminalSurfaceView {
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: TerminalSurfaceView, context: Context) {}
}
