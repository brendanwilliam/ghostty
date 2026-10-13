import SwiftUI

@main
struct GhosttyApp: App {
    @StateObject private var hosts = HostStore()
    @StateObject private var workspaces = WorkspaceStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Initialize libghostty up front so the first terminal opens fast.
        _ = GhosttyRuntime.shared
    }

    var body: some Scene {
        WindowGroup {
            HostListView()
                .environmentObject(hosts)
                .environmentObject(workspaces)
        }
        .onChange(of: scenePhase) { _, phase in
            GhosttyRuntime.shared.setFocus(phase == .active)
            switch phase {
            case .background:
                SessionLifecycle.shared.didEnterBackground(workspaces)
            case .active:
                SessionLifecycle.shared.didBecomeActive()
                workspaces.resumeAll()
            default:
                break
            }
        }
    }
}
