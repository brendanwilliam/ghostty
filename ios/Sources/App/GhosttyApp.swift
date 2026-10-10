import SwiftUI

@main
struct GhosttyApp: App {
    @StateObject private var hosts = HostStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Initialize libghostty up front so the first terminal opens fast.
        _ = GhosttyRuntime.shared
    }

    var body: some Scene {
        WindowGroup {
            HostListView()
                .environmentObject(hosts)
        }
        .onChange(of: scenePhase) { _, phase in
            GhosttyRuntime.shared.setFocus(phase == .active)
        }
    }
}
