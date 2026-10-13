import Foundation

/// A host's tabs and splits, saved so they come back after the app is
/// closed. Each pane's zmx session is still running on the host.
struct WorkspaceLayout: Codable, Equatable {
    var tabs: [TerminalWorkspace.Tab]
    var selectedTabID: UUID
    /// Each pane's zmx session.
    var sessions: [UUID: String]

    var tabCount: Int { tabs.count }
}

/// Saves workspace layouts and each host's session state as JSON in
/// Application Support.
@MainActor
final class WorkspaceArchive {
    struct Contents: Codable, Equatable {
        var layouts: [UUID: WorkspaceLayout] = [:]
        var hosts: [UUID: HostSessionRecord] = [:]
    }

    private(set) var contents: Contents
    private let url: URL?

    /// - Parameter url: Where to save; nil keeps everything in memory.
    init(url: URL? = WorkspaceArchive.defaultURL) {
        self.url = url
        contents = url
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Contents.self, from: $0) } ?? Contents()
    }

    nonisolated static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("workspaces.json")
    }

    func layout(for host: UUID) -> WorkspaceLayout? { contents.layouts[host] }

    func record(for host: UUID) -> HostSessionRecord? { contents.hosts[host] }

    func setLayout(_ layout: WorkspaceLayout?, for host: UUID) {
        guard contents.layouts[host] != layout else { return }
        contents.layouts[host] = layout
        save()
    }

    func setRecord(_ record: HostSessionRecord?, for host: UUID) {
        guard contents.hosts[host] != record else { return }
        contents.hosts[host] = record
        save()
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(contents).write(to: url, options: .atomic)
        } catch {
            print("failed to save workspaces: \(error)")
        }
    }
}
