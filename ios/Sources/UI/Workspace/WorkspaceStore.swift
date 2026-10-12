import Combine
import SwiftUI

/// The open workspace for each host, kept for the life of the app so
/// leaving a terminal screen (to the host list, Settings, another host)
/// doesn't end its sessions. A workspace goes away when its last tab
/// closes, or when it's disconnected from the host list.
@MainActor
final class WorkspaceStore: ObservableObject {
    private var workspaces: [UUID: TerminalWorkspace] = [:]
    private var observers: [UUID: AnyCancellable] = [:]
    /// Makes workspaces. Tests replace this to avoid SSH.
    private let make: @MainActor (Host) -> TerminalWorkspace

    init(make: (@MainActor (Host) -> TerminalWorkspace)? = nil) {
        self.make = make ?? { TerminalWorkspace(host: $0) }
    }

    /// The host's open workspace, or a new one.
    func workspace(for host: Host) -> TerminalWorkspace {
        if let existing = workspaces[host.id], !existing.closed { return existing }
        let workspace = make(host)
        workspaces[host.id] = workspace
        // Asked for while building the terminal screen, so announce the
        // change (to the host list) after this view update.
        DispatchQueue.main.async { self.objectWillChange.send() }
        observers[host.id] = workspace.$closed.sink { [weak self, weak workspace] closed in
            guard closed, let self, let workspace else { return }
            // Defer: `closed` publishes before it's set.
            DispatchQueue.main.async { self.forget(workspace) }
        }
        return workspace
    }

    /// The host's workspace, if it has one open.
    func openWorkspace(for host: Host) -> TerminalWorkspace? {
        workspaces[host.id].flatMap { $0.closed ? nil : $0 }
    }

    /// End all of a host's sessions.
    func disconnect(_ host: Host) {
        guard let workspace = workspaces[host.id] else { return }
        workspace.disconnectAll()
        forget(workspace)
    }

    private func forget(_ workspace: TerminalWorkspace) {
        let id = workspace.host.id
        guard workspaces[id] === workspace else { return }
        objectWillChange.send()
        workspaces[id] = nil
        observers[id] = nil
    }
}
