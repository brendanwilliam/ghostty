import Foundation

/// What a workspace does with its connections when the phone's network
/// changes. Only panes in zmx sessions are touched: they can be attached
/// again without losing anything, while a plain shell lives and dies with
/// its connection.
enum NetworkReaction {
    struct Pane {
        let id: UUID
        /// The kind of route its connection went over.
        let route: HostRoute.Kind?
        let connected: Bool
        /// In a zmx session.
        let attached: Bool
    }

    enum Action: Equatable {
        /// The connection can't have survived: attach again now.
        case drop
        /// It may have survived (a tailnet connection rides the tunnel
        /// across networks): attach again only if it doesn't answer.
        case check
    }

    static func actions(
        for changes: [NetworkMonitor.Change],
        on network: NetworkMonitor.Snapshot,
        panes: [Pane]
    ) -> [UUID: Action] {
        var actions: [UUID: Action] = [:]
        let local = network.interfaceType == .wifi || network.interfaceType == .wired
        for pane in panes where pane.connected && pane.attached {
            if changes.contains(.switched) {
                // A local-network route off the local network is gone.
                actions[pane.id] = pane.route == .lan && !local ? .drop : .check
            }
            if changes.contains(.tunnelDown) && pane.route == .tailnet {
                actions[pane.id] = .check
            }
        }
        return actions
    }

    /// Whether a pane should move onto the tailnet now that it's up.
    static func shouldMoveToTailnet(route: HostRoute.Kind?, connected: Bool, attached: Bool,
                                    hostRoutes: [HostRoute]) -> Bool {
        connected && attached && route != nil && route != .tailnet
            && hostRoutes.contains { $0.kind == .tailnet }
    }
}
