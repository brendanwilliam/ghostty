import Combine
import SwiftUI

/// The open workspace for each host, kept for the life of the app so
/// leaving a terminal screen (to the host list, Settings, another host)
/// doesn't end its sessions. A workspace goes away when its last tab
/// closes, or when its sessions are ended from the host list.
///
/// Workspaces whose panes run in zmx sessions are saved, and come back
/// (attaching to the same sessions) after the app is closed.
@MainActor
final class WorkspaceStore: ObservableObject {
    private var workspaces: [UUID: TerminalWorkspace] = [:]
    private var observers: [UUID: [AnyCancellable]] = [:]
    private var hostSessions: [UUID: HostSessions] = [:]
    private let archive: WorkspaceArchive
    /// Makes workspaces. Tests replace this to avoid SSH.
    private let make: @MainActor (Host, WorkspaceLayout?, HostSessions?) -> TerminalWorkspace

    init(archive: WorkspaceArchive? = nil,
         make: (@MainActor (Host, WorkspaceLayout?, HostSessions?) -> TerminalWorkspace)? = nil) {
        self.archive = archive ?? WorkspaceArchive()
        self.make = make ?? { TerminalWorkspace(host: $0, layout: $1, sessions: $2) }
    }

    /// The host's open workspace, or one restored from its saved layout,
    /// or a new one.
    func workspace(for host: Host) -> TerminalWorkspace {
        if let existing = workspaces[host.id], !existing.closed { return existing }
        // The on-device shell has no zmx sessions to keep, so it has no
        // saved layout either: it starts fresh with the app.
        let workspace = host.isLocal
            ? make(host, nil, nil)
            : make(host, archive.layout(for: host.id), sessions(for: host))
        workspaces[host.id] = workspace
        // Asked for while building the terminal screen, so announce the
        // change (to the host list) after this view update.
        DispatchQueue.main.async { self.objectWillChange.send() }
        observers[host.id] = [
            workspace.$closed.sink { [weak self, weak workspace] closed in
                guard closed, let self, let workspace else { return }
                // Defer: `closed` publishes before it's set.
                DispatchQueue.main.async { self.forget(workspace) }
            },
            workspace.objectWillChange
                .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
                .sink { [weak self, weak workspace] _ in
                    guard let workspace else { return }
                    self?.save(workspace)
                },
        ]
        return workspace
    }

    /// The host's zmx sessions.
    func sessions(for host: Host) -> HostSessions {
        if let sessions = hostSessions[host.id] {
            sessions.host = host
            return sessions
        }
        let sessions = HostSessions(host: host, record: archive.record(for: host.id) ?? HostSessionRecord())
        sessions.onChange = { [weak self, weak sessions] in
            guard let self, let sessions else { return }
            self.archive.setRecord(sessions.record, for: host.id)
        }
        hostSessions[host.id] = sessions
        return sessions
    }

    /// The host's workspace, if it has one open.
    func openWorkspace(for host: Host) -> TerminalWorkspace? {
        workspaces[host.id].flatMap { $0.closed ? nil : $0 }
    }

    /// Tabs saved from an earlier launch that haven't been opened yet.
    func savedTabCount(for host: Host) -> Int? {
        guard openWorkspace(for: host) == nil else { return nil }
        return archive.layout(for: host.id)?.tabCount
    }

    /// Whether the host has sessions, open or saved.
    func hasSessions(_ host: Host) -> Bool {
        openWorkspace(for: host) != nil || savedTabCount(for: host) != nil
    }

    /// End all of a host's sessions, including their zmx sessions.
    func endSessions(_ host: Host) {
        if let workspace = openWorkspace(for: host) {
            workspace.endAll()
            forget(workspace)
        } else if let layout = archive.layout(for: host.id) {
            sessions(for: host).end(Array(layout.sessions.values))
        }
        objectWillChange.send()
        archive.setLayout(nil, for: host.id)
    }

    /// The host was deleted: end its sessions and forget it.
    func remove(_ host: Host) {
        endSessions(host)
        let sessions = sessions(for: host)
        sessions.onChange = nil
        hostSessions[host.id] = nil
        archive.setRecord(nil, for: host.id)
        Task { await sessions.flushKills() }
    }

    // MARK: Lifecycle

    func saveAll() {
        for workspace in workspaces.values { save(workspace) }
    }

    /// Close every connection; zmx sessions keep running on their hosts.
    func suspendAll() {
        saveAll()
        for workspace in workspaces.values { workspace.suspend() }
    }

    /// The app is active again: attach panes that dropped.
    func resumeAll() {
        for workspace in workspaces.values { workspace.resume() }
    }

    /// Save a workspace whose panes run in zmx, so it can be restored.
    /// Others (and closed ones) aren't saved: there's nothing to go back to.
    private func save(_ workspace: TerminalWorkspace) {
        let id = workspace.host.id
        guard workspaces[id] === workspace else { return }
        let keep = !workspace.closed && workspace.sessions?.available == true
        archive.setLayout(keep ? workspace.layout : nil, for: id)
    }

    private func forget(_ workspace: TerminalWorkspace) {
        let id = workspace.host.id
        guard workspaces[id] === workspace else { return }
        objectWillChange.send()
        workspaces[id] = nil
        observers[id] = nil
        archive.setLayout(nil, for: id)
    }
}
