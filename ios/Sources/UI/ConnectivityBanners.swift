import SwiftUI

/// Shown when the host can only be reached through the tailnet from here
/// and this phone's tunnel is off.
struct TunnelBanner: View {
    @ObservedObject var workspace: TerminalWorkspace

    var body: some View {
        if workspace.needsTunnel {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "network.slash")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Can't reach \(workspace.host.displayName)")
                        .font(.subheadline.weight(.semibold))
                    Text("Connect Tailscale on this iPhone to reach it away from home. Sessions attach again once it's on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(white: 0.12))
        }
    }
}

/// Shown when the host goes to sleep when idle, which pauses its
/// sessions and makes it unreachable.
struct SleepBanner: View {
    @ObservedObject var sessions: HostSessions
    @AppStorage private var dismissed: Bool

    init(sessions: HostSessions) {
        self.sessions = sessions
        _dismissed = AppStorage(wrappedValue: false, "sleepBannerDismissed-\(sessions.host.id.uuidString)")
    }

    var body: some View {
        if sessions.probe?.sleeps == true && sessions.available && !dismissed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "powersleep")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(sessions.host.displayName) sleeps when idle")
                        .font(.subheadline.weight(.semibold))
                    Text("Its sessions pause and this phone can't reach it while it's asleep. To keep it awake on power, run this on it:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("sudo pmset -c sleep 0")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
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
        }
    }
}
